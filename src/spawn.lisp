;;;; src/spawn.lisp
;;;;
;;;; SPAWN is the low-level, asynchronous primitive. It hands back the raw
;;;; SB-EXT:PROCESS object so callers can do their own streaming I/O or job
;;;; control; RUN (in run.lisp) is built on top of it.

(eval-when (:compile-toplevel :load-toplevel :execute)
  (require :sb-posix))

(in-package #:process-kit)

(defun %isolate-process-group (process)
  "Move PROCESS into a new process group of its own (PGID = its own PID), so
that PROCESS-TERMINATE/PROCESS-KILL can later signal the whole group -
including any child processes PROCESS itself goes on to fork (a shell that
spawns an external command, for example) - instead of leaving orphaned
descendants running past a timeout. Best-effort: a process that has already
exited by the time we get here is not worth failing over."
  (let ((pid (sb-ext:process-pid process)))
    (when (and (integerp pid) (plusp pid))
      (ignore-errors (sb-posix:setpgid pid pid))))
  process)

(defun spawn (command args &key input output error (search t))
  "Start COMMAND with ARGS asynchronously and return the underlying
SB-EXT:PROCESS object immediately, without waiting for it to finish.

INPUT, OUTPUT and ERROR are passed straight through to SB-EXT:RUN-PROGRAM
(e.g. NIL, T, a pathname, a stream designator, or :STREAM). SEARCH controls
whether COMMAND is looked up on PATH.

The child is placed in its own process group so that PROCESS-TERMINATE and
PROCESS-KILL reach any of its own descendants too, not just itself."
  (%isolate-process-group
   (sb-ext:run-program command args
                       :input input
                       :output output
                       :error error
                       :search search
                       :wait nil)))

(defun process-alive-p (process)
  "Return T while PROCESS (as returned by SPAWN) is still running."
  (eq (sb-ext:process-status process) :running))

(defun process-wait (process)
  "Block until PROCESS has exited. Returns PROCESS."
  (sb-ext:process-wait process)
  process)

(defun process-terminate (process)
  "Politely ask PROCESS (and its process group) to exit by sending SIGTERM."
  (sb-ext:process-kill process 15 :process-group)
  process)

(defun process-kill (process)
  "Forcibly stop PROCESS (and its process group) by sending SIGKILL."
  (sb-ext:process-kill process 9 :process-group)
  process)
