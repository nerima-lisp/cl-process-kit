;;;; src/logging.lisp
;;;;
;;;; Optional structured observability via CL-LOG-KIT. *PROCESS-LOGGER* is
;;;; NIL by default -- launch, timeout/cancellation signal escalation, and
;;;; pipeline stage failures become log-kit records only once a caller binds
;;;; it, so the library stays silent (and allocation-free on this path) the
;;;; way it always has.

(in-package #:process-kit)

(defvar *process-logger* nil
  "NIL, or a CL-LOG-KIT (package LOG-KIT) logger -- see LOG-KIT:MAKE-LOGGER.
Bind this to observe process lifecycle events -- launch outcomes,
timeout/cancellation signal escalation, and pipeline stage failures -- as
structured log records in addition to the library's return values and
conditions.")

(defmacro %log (level message &rest fields)
  "Emit MESSAGE at LEVEL (:INFO, :WARN, or :ERROR) through *PROCESS-LOGGER*
with FIELDS, a plist of key/value forms. Expands to a no-op guarded solely by
*PROCESS-LOGGER* being non-NIL, so LEVEL's dispatch to the matching LOG-KIT
function is resolved once at macroexpansion time rather than on every call."
  (let ((log-function (ecase level
                         (:info 'log-kit:log-info)
                         (:warn 'log-kit:log-warn)
                         (:error 'log-kit:log-error))))
    `(when *process-logger*
       (,log-function *process-logger* ,message ,@fields))))
