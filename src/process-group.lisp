;;;; src/process-group.lisp
;;;;
;;;; Signaling and lifecycle control for the POSIX process group each
;;;; PROCESS-HANDLE owns. cl-process-kit always isolates a spawned child in
;;;; its own process group (see %VALIDATE-SPAWN-INPUTS / SPAWN in
;;;; spawn.lisp) so that a timeout or CLOSE-PROCESS can terminate not just
;;;; the immediate child but anything it forked.

(in-package #:process-kit)

(defmacro with-posix-errno-case (body &body errno-clauses)
  "Evaluate BODY. If it signals SB-POSIX:SYSCALL-ERROR, match the
condition's errno against ERRNO-CLAUSES, each (ERRNO-FORMS RESULT-FORM)
where ERRNO-FORMS is one errno-valued form or a list of them, evaluated at
call time -- not read time, unlike the #.SB-POSIX:ESRCH literals this
replaces. A T clause head matches unconditionally. An unmatched errno
re-signals the original condition."
  (let ((condition (gensym "CONDITION")))
    `(handler-case ,body
       (sb-posix:syscall-error (,condition)
         (cond
           ,@(loop for (errnos result) in errno-clauses
                   collect (if (eq errnos t)
                               `(t ,result)
                               `((member (sb-posix:syscall-errno ,condition)
                                         (list ,@(if (listp errnos) errnos (list errnos))))
                                 ,result)))
           (t (error ,condition)))))))

(defun %validate-signal (signal)
  (unless (and (integerp signal) (<= 1 signal 31))
    (error 'type-error :datum signal :expected-type '(integer 1 31)))
  signal)

(defun %group-exists-p (pgid)
  (with-posix-errno-case (progn (sb-posix:kill (- pgid) 0) t)
    (sb-posix:esrch nil)
    (sb-posix:eperm t)))

(defun %process-group-alive-p (process) (%group-exists-p (%process-handle-pgid process)))

(defun %owned-process-group-p (process allow-terminal-leader)
  (let ((pid (%process-handle-pid process))
        (pgid (%process-handle-pgid process))
        (state (%process-handle-state process)))
    (and (= pid pgid)
         (with-posix-errno-case (= (sb-posix:getpgid pid) pgid)
           (sb-posix:esrch (and allow-terminal-leader
                                 (eq (%process-state-group-ownership state) :leader-terminal)
                                 (%group-exists-p pgid)))))))

(defun %signal-process-group (process signal &key allow-terminal-leader)
  (check-type process process-handle)
  (%validate-signal signal)
  (with-locked-process-state (state process)
    (when (%owned-process-group-p process allow-terminal-leader)
      (with-posix-errno-case (progn (sb-posix:kill (- (%process-handle-pgid process)) signal) t)
        ((sb-posix:esrch sb-posix:eperm) nil)))))

(defun %signal-process-group-after-leader-exit (process signal)
  (%signal-process-group process signal :allow-terminal-leader t))

(defun process-terminate (process &optional (signal +default-timeout-signal+))
  "Send SIGNAL (default SIGTERM) to the process group PROCESS owns. A no-op
if PROCESS's group is not owned or already gone."
  (%signal-process-group process signal))
(defun process-kill (process &optional (signal +default-kill-signal+))
  "Send SIGNAL (default SIGKILL) to the process group PROCESS owns. A no-op
if PROCESS's group is not owned or already gone."
  (%signal-process-group process signal))

(defun process-send-leader-signal (process signal)
  "Send SIGNAL only to the live process-group leader."
  (check-type process process-handle)
  (%validate-signal signal)
  (unless (process-try-wait process)
    (with-locked-process-state (state process)
      (unless (%terminal-process-status-p (%process-state-status state))
        (handler-case (progn (sb-ext:process-kill (%handle-raw-process process) signal) t)
          (error () nil))))))

(defun process-send-group-signal (process signal)
  "Send SIGNAL to the live process group owned by PROCESS."
  (check-type process process-handle)
  (%validate-signal signal)
  (unless (process-try-wait process)
    (%signal-process-group process signal)))

(defun close-process-streams (process)
  "Close PROCESS's stdin/stdout/stderr streams, once. Idempotent: a repeat
call is a no-op. Return PROCESS."
  (check-type process process-handle)
  (let ((streams (with-locked-process-state (state process)
                    (unless (%process-state-streams-closed-p state)
                      (setf (%process-state-streams-closed-p state) t)
                      (list (process-stdin process) (process-output process)
                            (process-stderr process))))))
    (dolist (stream streams)
      (when (streamp stream) (ignore-errors (close stream)))))
  process)

(defun %wait-until-process-group-gone (process timeout)
  "The same DONEP as COMMUNICATE.LISP's %WAIT-UNTIL-GROUP-GONE -- CLOSE-
PROCESS has no injectable clock/sleeper of its own to pass through, so this
uses the real system clock/SLEEP directly rather than threading DI params
through just for this one caller."
  (flet ((seconds () (/ (get-internal-real-time) internal-time-units-per-second)))
    (%poll-until (lambda () (process-try-wait process) (not (%process-group-alive-p process)))
                 (+ (seconds) timeout) +default-poll-interval+ #'seconds #'sleep)))

(defun close-process (process &key (terminate t) (timeout +default-close-timeout-seconds+))
  "Terminate PROCESS's group (SIGTERM, escalating to SIGKILL after TIMEOUT
if TERMINATE is true), wait for it to be reaped, close its streams, and
return PROCESS. Safe to call more than once or on an already-terminated
PROCESS. The cleanup CALL-WITH-PROCESS/WITH-PROCESS perform automatically."
  (check-type process process-handle)
  (when (and terminate (%process-group-alive-p process))
    (%signal-process-group process +default-timeout-signal+ :allow-terminal-leader t)
    (unless (%wait-until-process-group-gone process timeout)
      (%signal-process-group-after-leader-exit process +default-kill-signal+)))
  (unless (process-handle-reaped-p process)
    (process-wait process :timeout timeout))
  (when (and terminate (%process-group-alive-p process))
    (%signal-process-group-after-leader-exit process +default-kill-signal+)
    (%wait-until-process-group-gone process timeout))
  (close-process-streams process)
  process)

(defun call-with-process (process continuation
                           &key (terminate t) (timeout +default-close-timeout-seconds+))
  "Call CONTINUATION with PROCESS, then terminate/reap it and close its
streams via CLOSE-PROCESS on the way out -- success or error. The
continuation-passing core of WITH-PROCESS: the cleanup contract lives here
once, as a plain function, and the macro below only supplies the syntax."
  (unwind-protect (funcall continuation process)
    (when process (ignore-errors (close-process process :terminate terminate :timeout timeout)))))

(defmacro with-process ((variable form &key (terminate t)
                                            (timeout +default-close-timeout-seconds+))
                         &body body)
  "Bind VARIABLE to FORM (a PROCESS-HANDLE) for BODY, then terminate/reap
and close its streams via CLOSE-PROCESS on the way out, success or error.
Thin syntax over CALL-WITH-PROCESS."
  `(call-with-process ,form (lambda (,variable) (declare (ignorable ,variable)) ,@body)
                      :terminate ,terminate :timeout ,timeout))
