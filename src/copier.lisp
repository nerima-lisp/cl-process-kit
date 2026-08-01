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
  (stop-requested-p nil :type boolean)
  (forced-close-p nil :type boolean)
  (condition-after-forced-close-p nil :type boolean))

(defvar *process-event-sink* nil
  "NIL, or a function of (STREAM-NAME OCTETS) invoked with every chunk a
copier reads. COMMUNICATE-ASYNC binds this to publish :STDOUT/:STDERR
PROCESS-EVENTs -- the continuation-passing seam between the synchronous
copier threads and the asynchronous event queue.")

(defun %await-fd-readable (fd stop-requested-fn)
  "Park until FD has bytes (or EOF) to offer, returning :READY -- or return
:STOPPED as soon as STOP-REQUESTED-FN reports that %DRAIN-COPIERS has given up
waiting for this copier.

Polling on a bounded timeout, rather than parking in a blocking READ(2), is
what makes a copier thread interruptible at all. Closing the stream out from
under a thread already parked in READ(2) wakes it on macOS/BSD, but that is a
BSD courtesy rather than anything POSIX promises, and on Linux it does not
happen: the reader stays parked until whoever still holds the pipe's write end
-- which, after `sh -c \"sleep 5 & exit 0\"`, is a backgrounded descendant that
outlives the leader by design -- finally closes it. Waiting via POLL(2)
instead moves the decision to stop out of the kernel and into this thread,
where a plain flag settles it, so DRAIN-TIMEOUT-SECONDS is honoured by
construction on every POSIX platform instead of by accident on some.

The stop flag is checked before readiness, not after, so the bound holds even
against a child that never stops producing: each turn costs at most one poll
interval plus one bounded READ(2). Output still buffered at that point is
forfeit, which is precisely what blowing the drain deadline means."
  (loop
    (when (funcall stop-requested-fn) (return :stopped))
    (when (sb-unix:unix-simple-poll fd :input +copier-poll-interval-milliseconds+)
      (return :ready))))

(defun %copy-stream-bounded (input capture stream-name event-sink stop-requested-fn)
  (labels ((emit (buffer count)
             (%capture-append capture buffer count)
             (when event-sink (funcall event-sink stream-name (subseq buffer 0 count))))
           (copy-octets ()
             (let ((buffer (make-array +default-copy-buffer-size+
                                       :element-type '(unsigned-byte 8))))
               (loop for count = (read-sequence buffer input)
                     while (plusp count)
                     do (emit buffer count))))
           (copy-fd-octets ()
             (let ((buffer (make-array +default-copy-buffer-size+ :element-type '(unsigned-byte 8)))
                   (fd (sb-sys:fd-stream-fd input)))
               (sb-sys:with-pinned-objects (buffer)
                 (loop while (eq (%await-fd-readable fd stop-requested-fn) :ready)
                       for count =
                         (handler-case (sb-posix:read fd (sb-sys:vector-sap buffer) (length buffer))
                           (sb-posix:syscall-error (condition)
                             (if (= (sb-posix:syscall-errno condition) sb-posix:eintr)
                                 -1
                                 (error condition))))
                       while (/= count 0)
                       when (plusp count) do (emit buffer count)))))
           (copy-characters ()
             (let ((buffer (make-string +default-copy-buffer-size+)))
               (loop for count = (read-sequence buffer input)
                     while (plusp count)
                     for octets = (cl-codec-kit:string-to-octets
                                   buffer :end count
                                   :encoding (%codec-kit-encoding (stream-external-format input)))
                     do (emit octets (length octets))))))
    (cond
      ((subtypep (stream-element-type input) '(unsigned-byte 8)) (copy-octets))
      ((typep input 'sb-sys:fd-stream) (copy-fd-octets))
      (t (copy-characters)))))

(defmacro %run-copier-thread (copier stream-name &body work)
  "Run WORK as COPIER's thread body: any ERROR it signals is caught and
recorded on COPIER as a PROCESS-IO-ERROR (tagged with STREAM-NAME, and
honoring whether COPIER's stream was already force-closed) instead of
letting the thread die silently. %START-COPIER and %START-FEEDER share this
exact catch-and-record shape, differing only in what WORK actually does."
  `(handler-case (progn ,@work)
     (error (condition)
       (setf (%copier-condition-after-forced-close-p ,copier) (%copier-forced-close-p ,copier)
             (%copier-condition ,copier)
             (make-condition 'process-io-error :stream ,stream-name :cause condition)))))

(defun %start-copier (input capture stream-name)
  (when input
    (let ((copier (%make-copier))
          (event-sink *process-event-sink*))
      (setf (%copier-thread copier)
            (sb-thread:make-thread
             (lambda ()
               (%run-copier-thread copier stream-name
                 (%copy-stream-bounded input capture stream-name event-sink
                                       (lambda () (%copier-stop-requested-p copier)))))
             :name (format nil "process-kit ~A copier" stream-name)))
      copier)))

(defun %join-copier (copier timeout)
  "Join COPIER's thread, bounded by TIMEOUT (a non-negative real number of
seconds -- never unbounded, since a copier thread can be blocked on a real,
possibly-hung child process). Returns :TIMED-OUT if TIMEOUT elapses (or is
non-positive) before the thread finishes."
  (when copier
    (if (plusp timeout)
        (sb-thread:join-thread (%copier-thread copier) :timeout timeout :default :timed-out)
        :timed-out)))

(defun %request-copier-stop (copier)
  "Ask COPIER to leave its read loop at the next poll turn. The cooperative
half of the escalation %CLOSE-STREAM-FOR-COPIER completes: this leaves the
descriptor alone and lets the thread unwind on its own terms, so it neither
loses a race against the reader nor risks the closed descriptor being reissued
to something else mid-read."
  (when copier (setf (%copier-stop-requested-p copier) t)))

(defun %close-stream-for-copier (stream copier)
  (when copier (setf (%copier-forced-close-p copier) t))
  (when stream (close stream :abort t)))

(defun %join-copier-unless-timed-out (copier timeout on-timeout)
  "Join COPIER within TIMEOUT seconds; call the ON-TIMEOUT continuation only
if it has not finished by then. Expresses each rung of %DRAIN-COPIERS'
escalation as a continuation, the same call-with-X-style idiom
ESCALATE-UNLESS-GONE (communicate.lisp) uses for the SIGTERM->SIGKILL
escalation this mirrors at the copier-thread level."
  (when (and copier (eq (%join-copier copier timeout) :timed-out))
    (funcall on-timeout)))

(defun %drain-copiers (entries drain-timeout clock-fn)
  "Wait out ENTRIES' copier threads within DRAIN-TIMEOUT seconds, then escalate
on whichever have not finished -- ask politely, then force, then give up:

  1. cooperative stop (%REQUEST-COPIER-STOP), which an FD copier honours within
     one poll turn on any POSIX platform;
  2. force-close the stream, for a thread parked somewhere the flag cannot
     reach it -- the stdin feeder blocked writing to a full pipe, or a
     READ-SEQUENCE on a non-FD stream, neither of which consults the flag;
  3. PROCESS-IO-ERROR on :CLEANUP, for a thread that survived even that.

The rungs are ordered by how much they cost when they fire, not by how likely
they are to work: stage 1 leaves the descriptor untouched and the thread
unwinding normally, so it raises no condition to suppress, whereas stage 2
closes a descriptor under a live reader and must then discount whatever the
reader signals about it (%COPIER-CONDITION-AFTER-FORCED-CLOSE-P). Errors a
copier hit on its own, before any of this, are re-signalled at the end."
  (let* ((timeout (or drain-timeout +default-drain-timeout-seconds+))
         (deadline (+ (funcall clock-fn) timeout))
         (cleanup-failure nil))
    (dolist (entry entries)
      (let* ((stream (car entry))
             (copier (cdr entry))
             (remaining (max 0 (- deadline (funcall clock-fn)))))
        (%join-copier-unless-timed-out
         copier remaining
         (lambda ()
           (%request-copier-stop copier)
           (%join-copier-unless-timed-out
            copier +copier-stop-grace-seconds+
            (lambda ()
              (%close-stream-for-copier stream copier)
              (%join-copier-unless-timed-out
               copier +default-poll-interval+
               (lambda () (setf cleanup-failure copier)))))))))
    (when cleanup-failure
      (error 'process-io-error
             :stream :cleanup
             :cause (make-condition
                     'simple-error
                     :format-control
                     "Copier thread did not terminate after its stream was closed.")))
    (dolist (entry entries)
      (let ((copier (cdr entry)))
        (when (and copier (%copier-condition copier)
                   (not (%copier-condition-after-forced-close-p copier)))
          (error (%copier-condition copier)))))))

(defun %write-process-octets (stream octets)
  (if (subtypep (stream-element-type stream) '(unsigned-byte 8))
      (write-sequence octets stream)
      (let ((fd (sb-sys:fd-stream-fd stream)))
        (sb-sys:with-pinned-objects (octets)
          (loop with offset = 0
                while (< offset (length octets))
                for written = (sb-posix:write
                               fd (sb-sys:sap+ (sb-sys:vector-sap octets) offset)
                               (- (length octets) offset))
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
                (%write-process-octets
                 stream (cl-codec-kit:string-to-octets
                         input :encoding (%codec-kit-encoding external-format))))
               ((vector (unsigned-byte 8)) (%write-process-octets stream input))
               (stream
                (if (subtypep (stream-element-type input) '(unsigned-byte 8))
                    (let ((buffer (make-array +default-copy-buffer-size+
                                              :element-type '(unsigned-byte 8))))
                      (loop for count = (read-sequence buffer input)
                            while (plusp count)
                            do (%write-process-octets stream (subseq buffer 0 count))))
                    (let ((buffer (make-string +default-copy-buffer-size+)))
                      (loop for count = (read-sequence buffer input)
                            while (plusp count)
                            do (%write-process-octets
                                stream
                                (cl-codec-kit:string-to-octets
                                 buffer :end count
                                 :encoding (%codec-kit-encoding external-format)))))))))
        (close stream)))))

(defun %start-feeder (process input external-format)
  (let ((stream (process-stdin process)))
    (when stream
      (let ((feeder (%make-copier)))
        (setf (%copier-thread feeder)
              (sb-thread:make-thread
               (lambda ()
                 (%run-copier-thread feeder :stdin
                   (%write-process-input process input external-format)))
               :name "cl-process-kit stdin feeder"))
        feeder))))
