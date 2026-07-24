;;;; src/copier.lisp
;;;;
;;;; Background threads that pump bytes between a child process and its
;;;; captures: one %COPIER per output stream drains it into a %CAPTURE
;;;; (optionally also publishing each chunk to *PROCESS-EVENT-SINK*, the
;;;; continuation COMMUNICATE-ASYNC installs to turn raw bytes into
;;;; PROCESS-EVENTs), and one feeder thread writes INPUT to the child's
;;;; stdin.

(in-package #:process-kit)

(defstruct (%copier (:constructor %make-copier))
  thread
  condition
  (forced-close-p nil :type boolean)
  (condition-after-forced-close-p nil :type boolean))

(defvar *process-event-sink* nil
  "NIL, or a function of (STREAM-NAME OCTETS) invoked with every chunk a
copier reads. COMMUNICATE-ASYNC binds this to publish :STDOUT/:STDERR
PROCESS-EVENTs -- the continuation-passing seam between the synchronous
copier threads and the asynchronous event queue.")

(defun %copy-stream-bounded (input capture stream-name event-sink)
  (labels ((emit (buffer count)
             (%capture-append capture buffer count)
             (when event-sink (funcall event-sink stream-name (subseq buffer 0 count))))
           (copy-octets ()
             (let ((buffer (make-array 4096 :element-type '(unsigned-byte 8))))
               (loop for count = (read-sequence buffer input)
                     while (plusp count)
                     do (emit buffer count))))
           (copy-fd-octets ()
             (let ((buffer (make-array 4096 :element-type '(unsigned-byte 8)))
                   (fd (sb-sys:fd-stream-fd input)))
               (sb-sys:with-pinned-objects (buffer)
                 (loop for count =
                         (handler-case (sb-posix:read fd (sb-sys:vector-sap buffer) (length buffer))
                           (sb-posix:syscall-error (condition)
                             (if (= (sb-posix:syscall-errno condition) sb-posix:eintr)
                                 -1
                                 (error condition))))
                       while (/= count 0)
                       when (plusp count) do (emit buffer count)))))
           (copy-characters ()
             (let ((buffer (make-string 4096)))
               (loop for count = (read-sequence buffer input)
                     while (plusp count)
                     for octets = (sb-ext:string-to-octets
                                   buffer :end count :external-format (stream-external-format input))
                     do (emit octets (length octets))))))
    (cond
      ((subtypep (stream-element-type input) '(unsigned-byte 8)) (copy-octets))
      ((typep input 'sb-sys:fd-stream) (copy-fd-octets))
      (t (copy-characters)))))

(defun %start-copier (input capture stream-name)
  (when input
    (let ((copier (%make-copier))
          (event-sink *process-event-sink*))
      (setf (%copier-thread copier)
            (sb-thread:make-thread
             (lambda ()
               (handler-case (%copy-stream-bounded input capture stream-name event-sink)
                 (error (condition)
                   (setf (%copier-condition-after-forced-close-p copier) (%copier-forced-close-p copier)
                         (%copier-condition copier)
                         (make-condition 'process-io-error :stream stream-name :cause condition)))))
             :name (format nil "process-kit ~A copier" stream-name)))
      copier)))

(defun %join-copier (copier &optional timeout)
  (when copier
    (cond
      ((null timeout) (sb-thread:join-thread (%copier-thread copier)))
      ((plusp timeout)
       (sb-thread:join-thread (%copier-thread copier) :timeout timeout :default :timed-out))
      (t :timed-out))))

(defun %close-stream-for-copier (stream copier)
  (when copier (setf (%copier-forced-close-p copier) t))
  (when stream (close stream :abort t)))

(defun %drain-copiers (entries drain-timeout clock-fn)
  (let* ((timeout (or drain-timeout +default-drain-timeout-seconds+))
         (deadline (+ (funcall clock-fn) timeout))
         (cleanup-failure nil))
    (dolist (entry entries)
      (let* ((stream (car entry))
             (copier (cdr entry))
             (remaining (max 0 (- deadline (funcall clock-fn)))))
        (when (and copier (eq (%join-copier copier remaining) :timed-out))
          (%close-stream-for-copier stream copier)
          (when (eq (%join-copier copier +default-poll-interval+) :timed-out)
            (setf cleanup-failure copier)))))
    (when cleanup-failure
      (error 'process-io-error
             :stream :cleanup
             :cause (make-condition
                     'simple-error
                     :format-control "Copier thread did not terminate after its stream was closed.")))
    (dolist (entry entries)
      (let ((copier (cdr entry)))
        (when (and copier (%copier-condition copier) (not (%copier-condition-after-forced-close-p copier)))
          (error (%copier-condition copier)))))))

(defun %write-process-octets (stream octets)
  (if (subtypep (stream-element-type stream) '(unsigned-byte 8))
      (write-sequence octets stream)
      (let ((fd (sb-sys:fd-stream-fd stream)))
        (sb-sys:with-pinned-objects (octets)
          (loop with offset = 0
                while (< offset (length octets))
                for written = (sb-posix:write
                               fd (sb-sys:sap+ (sb-sys:vector-sap octets) offset) (- (length octets) offset))
                do (incf offset written))))))

(defun %write-process-input (process input external-format)
  (let ((stream (process-stdin process)))
    (%ensure (not (and input (null stream)))
             "The process was not spawned with a writable standard input stream.")
    (when stream
      (unwind-protect
           (when input
             (etypecase input
               (string
                (%write-process-octets stream (sb-ext:string-to-octets input :external-format external-format)))
               ((vector (unsigned-byte 8)) (%write-process-octets stream input))
               (stream
                (if (subtypep (stream-element-type input) '(unsigned-byte 8))
                    (let ((buffer (make-array 4096 :element-type '(unsigned-byte 8))))
                      (loop for count = (read-sequence buffer input)
                            while (plusp count)
                            do (%write-process-octets stream (subseq buffer 0 count))))
                    (let ((buffer (make-string 4096)))
                      (loop for count = (read-sequence buffer input)
                            while (plusp count)
                            do (%write-process-octets
                                stream (sb-ext:string-to-octets buffer :end count :external-format external-format))))))))
        (close stream)))))

(defun %start-feeder (process input external-format)
  (let ((stream (process-stdin process)))
    (when stream
      (let ((feeder (%make-copier)))
        (setf (%copier-thread feeder)
              (sb-thread:make-thread
               (lambda ()
                 (handler-case (%write-process-input process input external-format)
                   (error (condition)
                     (setf (%copier-condition-after-forced-close-p feeder) (%copier-forced-close-p feeder)
                           (%copier-condition feeder)
                           (make-condition 'process-io-error :stream :stdin :cause condition)))))
               :name "cl-process-kit stdin feeder"))
        feeder))))
