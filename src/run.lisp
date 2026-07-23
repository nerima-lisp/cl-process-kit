;;;; src/run.lisp
;;;;
;;;; RUN is the high-level, synchronous entry point: spawn -> poll for
;;;; completion/timeout -> escalate signals on timeout -> return a
;;;; PROCESS-RESULT (or signal PROCESS-TIMEOUT-ERROR).

(in-package #:process-kit)

(defparameter *default-poll-interval-seconds* 0.05
  "Interval between liveness checks while RUN waits for a process.")

(defun %coerce-input-stream (input)
  "Convert a plain string INPUT into a stream so SB-EXT:RUN-PROGRAM can use
it as the child's standard input. Everything else (NIL, T, a stream, a
pathname) is passed through unchanged."
  (if (stringp input)
      (make-string-input-stream input)
      input))

(defun %start-output-copier (process-stream sink)
  "Spawn a thread that copies everything read from PROCESS-STREAM into SINK.
Returns the thread, or NIL if PROCESS-STREAM is NIL."
  (when process-stream
    (sb-thread:make-thread
     (lambda ()
       (ignore-errors
        (let ((buffer (make-string 4096)))
          (loop for count = (read-sequence buffer process-stream)
                while (plusp count)
                do (write-string buffer sink :end count)))))
     :name "process-kit output copier")))

(defun %join-copier (thread)
  (when thread
    (ignore-errors (sb-thread:join-thread thread))))

(defun %poll-until (predicate deadline clock sleep-fn poll-interval)
  "Call PREDICATE repeatedly until it returns true, or until (FUNCALL CLOCK)
reaches or passes DEADLINE (both expressed in INTERNAL-TIME-UNITS-PER-SECOND
units). Sleeps POLL-INTERVAL seconds between polls via SLEEP-FN. Returns T
if PREDICATE became true, NIL on timeout."
  (loop
    (when (funcall predicate)
      (return t))
    (when (>= (funcall clock) deadline)
      (return nil))
    (funcall sleep-fn poll-interval)))

(defun %deadline-from-now (clock seconds)
  (+ (funcall clock) (round (* seconds internal-time-units-per-second))))

(defun %process-outcome (process)
  "Return (VALUES EXIT-CODE SIGNAL) for a finished PROCESS. EXIT-CODE is NIL
when the process was terminated by a signal instead of exiting normally."
  (let ((status (sb-ext:process-status process))
        (code (sb-ext:process-exit-code process)))
    (if (eq status :signaled)
        (values nil code)
        (values (or code 0) nil))))

(defun %escalate-to-kill (process kill-signal grace-period-seconds clock sleep-fn poll-interval)
  "Send KILL-SIGNAL to PROCESS, wait up to GRACE-PERIOD-SECONDS for it to
exit, and send SIGKILL if it is still alive afterwards."
  (sb-ext:process-kill process kill-signal :process-group)
  (unless (%poll-until (lambda () (not (process-alive-p process)))
                       (%deadline-from-now clock grace-period-seconds)
                       clock sleep-fn poll-interval)
    (process-kill process))
  (process-wait process))

(defun run (command args
            &key input (search t)
                 timeout-seconds
                 (on-timeout :error)
                 (grace-period-seconds 0.2)
                 (kill-signal 15)
                 (clock #'get-internal-real-time)
                 (sleep-fn #'sleep)
                 (poll-interval *default-poll-interval-seconds*))
  "Run COMMAND with ARGS synchronously, capturing standard output and
standard error as strings, and return a PROCESS-RESULT.

If TIMEOUT-SECONDS is given and exceeded, the process is escalated from
KILL-SIGNAL (SIGTERM by default) to SIGKILL after GRACE-PERIOD-SECONDS. When
ON-TIMEOUT is :ERROR (the default), a PROCESS-TIMEOUT-ERROR is signalled
after the process has been cleaned up. When ON-TIMEOUT is :RETURN, a
PROCESS-RESULT with TIMED-OUT-P set to T is returned instead and no error is
signalled.

CLOCK and SLEEP-FN are the polling primitives (default GET-INTERNAL-REAL-TIME
and SLEEP); replacing them lets tests exercise the timeout/escalation logic
deterministically without consuming real wall-clock time."
  (let* ((process (spawn command args
                         :input (%coerce-input-stream input)
                         :output :stream
                         :error :stream
                         :search search))
         (stdout-buffer (make-string-output-stream))
         (stderr-buffer (make-string-output-stream))
         (stdout-copier (%start-output-copier (sb-ext:process-output process) stdout-buffer))
         (stderr-copier (%start-output-copier (sb-ext:process-error process) stderr-buffer)))
    (unwind-protect
        (let ((timed-out-p
                (and timeout-seconds
                     (not (%poll-until (lambda () (not (process-alive-p process)))
                                       (%deadline-from-now clock timeout-seconds)
                                       clock sleep-fn poll-interval)))))
          (if timed-out-p
              (%escalate-to-kill process kill-signal grace-period-seconds
                                 clock sleep-fn poll-interval)
              (process-wait process))
          (%join-copier stdout-copier)
          (%join-copier stderr-copier)
          (multiple-value-bind (exit-code signal) (%process-outcome process)
            (if (and timed-out-p (eq on-timeout :error))
                (error 'process-timeout-error
                       :command command
                       :args args
                       :timeout-seconds timeout-seconds)
                (make-process-result :exit-code exit-code
                                     :stdout (get-output-stream-string stdout-buffer)
                                     :stderr (get-output-stream-string stderr-buffer)
                                     :timed-out-p timed-out-p
                                     :signal signal))))
      (%join-copier stdout-copier)
      (%join-copier stderr-copier))))
