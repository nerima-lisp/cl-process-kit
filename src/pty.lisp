;;;; src/pty.lisp
;;;;
;;;; Optional native controlling-terminal PTY backend. Every native call
;;;; goes through the trio DEFINE-PTY-SYSCALL declares for a given C symbol:
;;;; the raw alien routine, a %CHECK-NATIVE-wrapped /CHECKED entry point,
;;;; and the shared "cpk_pty_..." label used by both -- so the C symbol
;;;; name is never repeated (and risks drifting) across the file.

(in-package #:process-kit/pty)

(defparameter +poll-interval+ 0.01d0
  "Interval, in seconds, between liveness/deadline polls in PTY-WAIT and
%TERMINATE-AND-WAIT. Kept local to this package rather than reaching into
PROCESS-KIT::+DEFAULT-POLL-INTERVAL+ -- the same value, by convention, but
a separate tunable, since cl-process-kit/pty is an optional, independently
loadable subsystem.")

(defparameter +timeout-signal+ 15
  "SIGTERM, sent by %TERMINATE-AND-WAIT's first attempt. Kept local for the
same reason as +POLL-INTERVAL+.")

(defparameter +kill-signal+ 9
  "SIGKILL, sent by %TERMINATE-AND-WAIT if +TIMEOUT-SIGNAL+ alone did not
end the session in time. Kept local for the same reason as +POLL-INTERVAL+.")

(eval-when (:compile-toplevel :load-toplevel :execute)
  (unless (member :sbcl *features*) (error "cl-process-kit/pty requires SBCL.")))

(sb-alien:load-shared-object
 (or (uiop:getenv "CL_PROCESS_KIT_PTY_LIBRARY")
     (error "Set CL_PROCESS_KIT_PTY_LIBRARY to the native PTY shared library.")))

(defun %native-error (operation)
  (let ((errno (sb-alien:get-errno)))
    (error "~A failed with errno ~D: ~A" operation errno (sb-int:strerror errno))))

(defun %check-native (value operation)
  (when (minusp value) (%native-error operation))
  value)

(defmacro define-pty-syscall (name return-type &rest arguments)
  "Define the native cpk_pty_NAME alien routine as %NATIVE-NAME, plus
%NATIVE-NAME/CHECKED, which calls it and forwards the result through
%CHECK-NATIVE labelled with that same derived C name. The C symbol, the
Lisp entry point, and the error label are declared exactly once here
instead of being repeated -- and risking drift -- at every call site."
  (let* ((c-name (format nil "cpk_pty_~A" (substitute #\_ #\- (string-downcase (string name)))))
         (routine-name (intern (format nil "%NATIVE-~A" name)))
         (checked-name (intern (format nil "%NATIVE-~A/CHECKED" name)))
         (arg-names (mapcar #'first arguments)))
    `(progn
       (sb-alien:define-alien-routine (,c-name ,routine-name) ,return-type ,@arguments)
       (defun ,checked-name (,@arg-names)
         (%check-native (,routine-name ,@arg-names) ,c-name)))))

(define-pty-syscall spawn sb-alien:int
  (path sb-alien:c-string)
  (arguments sb-sys:system-area-pointer)
  (argument-size sb-alien:unsigned-long)
  (argument-count sb-alien:unsigned-long)
  (environment sb-sys:system-area-pointer)
  (environment-size sb-alien:unsigned-long)
  (environment-count sb-alien:unsigned-long)
  (cwd sb-alien:c-string)
  (rows sb-alien:unsigned-short)
  (cols sb-alien:unsigned-short)
  (master (* sb-alien:int))
  (pid (* sb-alien:int)))

(define-pty-syscall read sb-alien:long
  (fd sb-alien:int) (buffer sb-sys:system-area-pointer) (length sb-alien:unsigned-long))

(define-pty-syscall write sb-alien:long
  (fd sb-alien:int) (buffer sb-sys:system-area-pointer) (length sb-alien:unsigned-long))

(define-pty-syscall resize sb-alien:int
  (fd sb-alien:int) (rows sb-alien:unsigned-short) (cols sb-alien:unsigned-short))

(define-pty-syscall send-eof sb-alien:int (fd sb-alien:int))

(define-pty-syscall foreground-pgid sb-alien:int
  (fd sb-alien:int) (session sb-alien:int) (pgid (* sb-alien:int)))

(define-pty-syscall signal-foreground sb-alien:int
  (fd sb-alien:int) (session sb-alien:int) (signal-number sb-alien:int))

(define-pty-syscall signal-session sb-alien:int
  (session sb-alien:int) (signal-number sb-alien:int))

(define-pty-syscall wait sb-alien:int
  (pid sb-alien:int) (nohang sb-alien:int) (status (* sb-alien:int)) (ready (* sb-alien:int)))

(define-pty-syscall close sb-alien:int (fd sb-alien:int))

(defun %string-block (strings)
  (let* ((encoded (mapcar (lambda (string) (sb-ext:string-to-octets string :external-format :utf-8))
                          strings))
         (size (reduce #'+ encoded :key (lambda (octets) (1+ (length octets))) :initial-value 0))
         (storage (make-array (max 1 size) :element-type '(unsigned-byte 8) :initial-element 0))
         (offset 0))
    (dolist (octets encoded)
      (replace storage octets :start1 offset)
      (incf offset (1+ (length octets))))
    (values storage size (length strings))))

(defstruct (pty-process (:constructor %make-pty-process) (:copier nil))
  fd pid program arguments started-at external-format
  (mutex (sb-thread:make-mutex :name "process-kit PTY state"))
  result (closed-p nil :type boolean))

(defun process-pty (process)
  (check-type process pty-process)
  (pty-process-fd process))

(defun %command-values (command)
  (check-type command command-spec)
  (let* ((arguments (command-arguments command))
         (environment (process-kit::%command-environment command))
         (directory (process-kit::%effective-directory (command-directory command)))
         (program (command-program command))
         (resolved (if (command-search command)
                       (process-kit::%resolve-executable program arguments environment directory)
                       (merge-pathnames program directory))))
    (unless (and (uiop:absolute-pathname-p resolved) (process-kit::%executable-file-p resolved))
      (error "PTY executable is not an executable absolute path: ~A" resolved))
    (values (namestring resolved) arguments environment (namestring directory))))

(defun %default-terminal-size ()
  "The controlling terminal's own geometry, via CL-TTY-KIT:TERMINAL-SIZE, as
(VALUES ROWS COLS) -- or 24x80 when standard input is not a terminal (a
pipe, a test harness, CI)."
  (multiple-value-bind (columns rows) (cl-tty-kit:terminal-size)
    (values (or rows 24) (or columns 80))))

(defun spawn-pty (command &key (rows nil rows-p) (cols nil cols-p))
  (multiple-value-bind (default-rows default-cols) (%default-terminal-size)
    (setf rows (if rows-p rows default-rows)
          cols (if cols-p cols default-cols)))
  (check-type rows (integer 1 65535))
  (check-type cols (integer 1 65535))
  (multiple-value-bind (path arguments environment directory) (%command-values command)
    (multiple-value-bind (argument-block argument-size argument-count)
        (%string-block (cons path arguments))
      (multiple-value-bind (environment-block environment-size environment-count)
          (%string-block environment)
        (sb-sys:with-pinned-objects (argument-block environment-block)
          (sb-alien:with-alien ((fd sb-alien:int) (pid sb-alien:int))
            (%native-spawn/checked
             path (sb-sys:vector-sap argument-block) argument-size argument-count
             (sb-sys:vector-sap environment-block) environment-size environment-count
             directory rows cols (sb-alien:addr fd) (sb-alien:addr pid))
            (%make-pty-process :fd fd :pid pid :program path :arguments arguments
                               :started-at (get-internal-real-time)
                               :external-format (command-external-format command))))))))

(defun pty-read-octets (process &key (size 4096))
  (check-type process pty-process)
  (check-type size (integer 1))
  (let ((buffer (make-array size :element-type '(unsigned-byte 8))))
    (sb-sys:with-pinned-objects (buffer)
      (let ((count (%native-read/checked (pty-process-fd process) (sb-sys:vector-sap buffer) size)))
        (subseq buffer 0 count)))))

(defun pty-write-octets (process octets)
  (check-type process pty-process)
  (check-type octets (simple-array (unsigned-byte 8) (*)))
  (sb-sys:with-pinned-objects (octets)
    (loop with offset = 0
          while (< offset (length octets))
          for count = (%native-write/checked
                       (pty-process-fd process) (sb-sys:sap+ (sb-sys:vector-sap octets) offset)
                       (- (length octets) offset))
          do (when (zerop count) (error "PTY write made no progress."))
             (incf offset count)))
  (length octets))

(defun pty-read-string (process &key (size 4096))
  (sb-ext:octets-to-string (pty-read-octets process :size size)
                           :external-format (pty-process-external-format process)))

(defun pty-write-string (process string)
  (pty-write-octets
   process
   (sb-ext:string-to-octets string :external-format (pty-process-external-format process))))

(defun pty-resize (process rows cols)
  (check-type rows (integer 1 65535))
  (check-type cols (integer 1 65535))
  (%native-resize/checked (pty-process-fd process) rows cols)
  process)

(defun pty-send-eof (process)
  (%native-send-eof/checked (pty-process-fd process))
  process)

(defun pty-foreground-pgid (process)
  (sb-alien:with-alien ((pgid sb-alien:int))
    (%native-foreground-pgid/checked (pty-process-fd process)
                                     (pty-process-pid process) (sb-alien:addr pgid))
    pgid))

(defun pty-signal-foreground (process signal-number)
  (check-type signal-number (integer 1))
  (%native-signal-foreground/checked (pty-process-fd process)
                                     (pty-process-pid process) signal-number)
  process)

(defun %decode-status (status)
  (let ((low (logand status #x7f)))
    (cond ((zerop low) (values :exited (ldb (byte 8 8) status) nil))
          ((/= low #x7f) (values :signaled nil low))
          (t (values :stopped nil (ldb (byte 8 8) status))))))

(defun %make-result (process status &key timed-out-p cancelled-p)
  (multiple-value-bind (kind exit-code signal) (%decode-status status)
    (make-process-result
     :program (pty-process-program process) :arguments (pty-process-arguments process)
     :pid (pty-process-pid process) :status kind
     :duration-seconds (/ (- (get-internal-real-time) (pty-process-started-at process))
                          (coerce internal-time-units-per-second 'double-float))
     :exit-code exit-code :signal signal :stdout "" :stderr ""
     :timed-out-p timed-out-p :cancelled-p cancelled-p)))

(defun %try-wait (process nohang &key timed-out-p cancelled-p)
  (sb-thread:with-mutex ((pty-process-mutex process))
    (or (pty-process-result process)
        (sb-alien:with-alien ((status sb-alien:int) (ready sb-alien:int))
          (%native-wait/checked (pty-process-pid process) (if nohang 1 0)
                                (sb-alien:addr status) (sb-alien:addr ready))
          (when (plusp ready)
            (setf (pty-process-result process)
                  (%make-result process status :timed-out-p timed-out-p
                                :cancelled-p cancelled-p)))))))

(defun %terminate-and-wait (process flag)
  (ignore-errors (%native-signal-session (pty-process-pid process) +timeout-signal+))
  (loop repeat 25
        for result = (%try-wait process t :timed-out-p (eq flag :timeout)
                                          :cancelled-p (eq flag :cancel))
        when result return result
        do (sleep +poll-interval+)
        finally
           (ignore-errors (%native-signal-session (pty-process-pid process) +kill-signal+))
           (return (%try-wait process nil :timed-out-p (eq flag :timeout)
                              :cancelled-p (eq flag :cancel)))))

(defun pty-wait (process &key timeout cancellation-token)
  (check-type process pty-process)
  (let ((deadline (and timeout
                       (+ (get-internal-real-time) (* timeout internal-time-units-per-second)))))
    (loop
      for result = (%try-wait process t)
      when result return result
      when (and cancellation-token (cancellation-requested-p cancellation-token))
        return (%terminate-and-wait process :cancel)
      when (and deadline (>= (get-internal-real-time) deadline))
        return (%terminate-and-wait process :timeout)
      do (sleep +poll-interval+))))

(defun pty-cancel (process) (%terminate-and-wait process :cancel))

(defun pty-close (process)
  (check-type process pty-process)
  (unless (pty-process-result process) (%terminate-and-wait process :cancel))
  (sb-thread:with-mutex ((pty-process-mutex process))
    (unless (pty-process-closed-p process)
      (%native-close/checked (pty-process-fd process))
      (setf (pty-process-closed-p process) t)))
  (pty-process-result process))
