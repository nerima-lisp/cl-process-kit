;;;; src/result.lisp
;;;;
;;;; PROCESS-RESULT and PROCESS-TIMEOUT-ERROR are the data types shared by
;;;; RUN and (indirectly) SPAWN callers who choose to build their own result.

(in-package #:process-kit)

(defstruct process-result
  "The outcome of a synchronous subprocess execution performed by RUN.

EXIT-CODE     - integer exit status of the process, or NIL if it never exited
                normally (e.g. it was killed).
STDOUT        - captured standard output, as a string.
STDERR        - captured standard error, as a string.
TIMED-OUT-P   - T when TIMEOUT-SECONDS was exceeded and the process had to be
                escalated (SIGTERM/SIGKILL).
SIGNAL        - the signal number that terminated the process, or NIL if the
                process exited normally."
  exit-code
  stdout
  stderr
  timed-out-p
  signal)

(define-condition process-timeout-error (error)
  ((command :initarg :command :reader process-timeout-error-command)
   (args :initarg :args :reader process-timeout-error-args)
   (timeout-seconds :initarg :timeout-seconds :reader process-timeout-error-timeout-seconds))
  (:documentation "Signalled by RUN when TIMEOUT-SECONDS is exceeded and
ON-TIMEOUT is :ERROR.")
  (:report (lambda (c s)
             (format s "Subprocess timed out: ~A ~S (after ~A seconds)"
                     (process-timeout-error-command c)
                     (process-timeout-error-args c)
                     (process-timeout-error-timeout-seconds c)))))
