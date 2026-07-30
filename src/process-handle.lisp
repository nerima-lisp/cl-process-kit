;;;; src/process-handle.lisp
;;;;
;;;; PROCESS-HANDLE wraps SB-EXT:PROCESS with the state cl-process-kit needs
;;;; beyond what SBCL tracks itself: a cached terminal PROCESS-RESULT (so a
;;;; process can be waited on and queried more than once), a communication
;;;; reservation, and enough about the process group to tell an owned group
;;;; from a merely-inherited pgid. Process-group signaling lives in
;;;; process-group.lisp; the communication reservation state machine lives
;;;; in communication-state.lisp.

(in-package #:process-kit)

(defstruct (process-state
            (:constructor %make-process-state)
            (:conc-name %process-state-))
  (mutex (sb-thread:make-mutex :name "process-kit process state"))
  result
  communication-result
  communication-contract
  communication-reservation-owner
  (communication-status :idle)
  (status :running)
  (group-ownership :verified)
  (streams-closed-p nil :type boolean))

(defstruct (process-handle
            (:constructor %make-process-handle)
            (:conc-name %process-handle-)
            (:copier nil))
  "SPAWN's returned handle to a running or terminated subprocess, isolated
in its own process group. Inspect it with PROCESS-ID, PROCESS-STATUS,
PROCESS-STDIN/-OUTPUT/-STDERR, PROCESS-ALIVE-P, PROCESS-TRY-WAIT,
PROCESS-WAIT, PROCESS-EXIT-CODE, and PROCESS-SIGNAL; terminate it with
PROCESS-TERMINATE/PROCESS-KILL or clean it up with CLOSE-PROCESS/
WITH-PROCESS."
  (raw-process (error "RAW-PROCESS is required") :read-only t)
  (pid (error "PID is required") :type integer :read-only t)
  (pgid (error "PGID is required") :type integer :read-only t)
  (program nil :read-only t)
  (arguments nil :read-only t)
  (directory nil :read-only t)
  (started-at 0d0 :type double-float :read-only t)
  (state (%make-process-state) :type process-state :read-only t))

(defmacro with-locked-process-state ((state-var process) &body body)
  "Bind STATE-VAR to PROCESS's internal PROCESS-STATE, holding its mutex
for BODY. Used throughout process-handle.lisp, process-group.lisp, and
communication-state.lisp to keep every state transition critical section
spelled the same way."
  `(let ((,state-var (%process-handle-state ,process)))
     (sb-thread:with-mutex ((%process-state-mutex ,state-var))
       ,@body)))

(defun process-handle-reaped-p (process)
  (not (null (%process-state-result (%process-handle-state process)))))

(defun %handle-raw-process (process)
  (check-type process process-handle)
  (%process-handle-raw-process process))

(defun %process-output (process) (sb-ext:process-output (%handle-raw-process process)))
(defun %process-error (process) (sb-ext:process-error (%handle-raw-process process)))

(defun process-id (process)
  "Return PROCESS's PID."
  (check-type process process-handle) (%process-handle-pid process))
(defun process-stdin (process)
  "Return PROCESS's raw stdin stream, or NIL unless it was spawned with a
stream-valued :INPUT."
  (sb-ext:process-input (%handle-raw-process process)))
(defun process-output (process)
  "Return PROCESS's raw stdout stream, or NIL unless it was spawned with a
stream-valued :OUTPUT."
  (%process-output process))
(defun process-stderr (process)
  "Return PROCESS's raw stderr stream, or NIL unless it was spawned with a
stream-valued :ERROR."
  (%process-error process))

(defun %terminal-process-status-p (status) (member status '(:exited :signaled) :test #'eq))
(defun %normalize-status (status) (if (%terminal-process-status-p status) status :running))

(defun process-status (process)
  "Return PROCESS's current status: :RUNNING, :EXITED, or :SIGNALED."
  (with-locked-process-state (state process)
    (or (and (%process-state-result state) (process-result-status (%process-state-result state)))
        (%normalize-status (sb-ext:process-status (%handle-raw-process process))))))

(defun %make-terminal-result (process status)
  (let* ((raw (%handle-raw-process process))
         (code (sb-ext:process-exit-code raw))
         (duration (- (get-internal-real-time) (%process-handle-started-at process))))
    (make-process-result
     :program (%process-handle-program process)
     :arguments (copy-list (%process-handle-arguments process))
     :pid (%process-handle-pid process)
     :status status
     :exit-code (and (eq status :exited) code)
     :signal (and (eq status :signaled) code)
     :duration-seconds (/ (coerce duration 'double-float) internal-time-units-per-second))))

(defun %cache-terminal-result (process)
  (with-locked-process-state (state process)
    (or (%process-state-result state)
        (let ((status (%normalize-status (sb-ext:process-status (%handle-raw-process process)))))
          (when (%terminal-process-status-p status)
            (sb-ext:process-wait (%handle-raw-process process))
            (let ((result (%make-terminal-result process status)))
              (setf (%process-state-result state) result
                    (%process-state-status state) status
                    (%process-state-group-ownership state) :leader-terminal)
              result))))))

(defun process-try-wait (process)
  "Return PROCESS's PROCESS-RESULT if it has already terminated, else NIL,
without blocking."
  (check-type process process-handle)
  (%cache-terminal-result process))

(defun process-wait (process &key timeout (poll-interval +default-poll-interval+)
                                (clock +default-clock+))
  "Block, polling every POLL-INTERVAL seconds, until PROCESS terminates or
TIMEOUT (NIL for no bound) elapses on CLOCK. Return its PROCESS-RESULT, or
NIL on timeout."
  (check-type process process-handle)
  (check-type poll-interval (real (0)))
  (%ensure (%clock-p clock)
           "CLOCK must be a CL-BOUNDARY-KIT clock boundary (see CL-BOUNDARY-KIT:MAKE-CLOCK).")
  (when timeout (check-type timeout (real 0)))
  (let* ((start (cl-boundary-kit:clock-monotonic clock))
         (deadline (and timeout (+ start timeout))))
    (loop for result = (process-try-wait process)
          when result return result
          when (and deadline (>= (cl-boundary-kit:clock-monotonic clock) deadline)) return nil
          do (sleep poll-interval))))

(defun process-exit-code (process)
  "Return PROCESS's exit code once it has exited normally, else NIL (still
running, or terminated by a signal)."
  (let ((result (process-try-wait process)))
    (and result (eq (process-result-status result) :exited) (process-result-exit-code result))))

(defun process-signal (process)
  "Return the signal number that terminated PROCESS, else NIL (still
running, or exited normally)."
  (let ((result (process-try-wait process)))
    (and result (eq (process-result-status result) :signaled) (process-result-signal result))))

(defun process-alive-p (process)
  "True while PROCESS's status is :RUNNING."
  (eq (process-status process) :running))

(defun (setf process-handle-reaped-p) (value process)
  (when value (%cache-terminal-result process))
  value)
