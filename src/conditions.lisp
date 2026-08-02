;;;; src/conditions.lisp
;;;;
;;;; The PROCESS-ERROR condition hierarchy. DEFINE-PROCESS-CONDITION factors
;;;; out the initarg/reader/report boilerplate that CL's DEFINE-CONDITION
;;;; requires to be spelled out per slot.

(in-package #:process-kit)

(defmacro %ensure (test datum &rest arguments)
  "Signal (ERROR DATUM . ARGUMENTS) unless TEST holds -- the guard-clause
counterpart to CL:ASSERT that raises a plain condition instead of a
continuable ASSERTION-ERROR. Every argument validation in the library is
one (%ENSURE test control-or-class ...) line instead of a two-line
UNLESS/ERROR pair, so a function's preconditions read as a flat list of
demands. DATUM is a format control string or a condition class name, exactly
as CL:ERROR expects."
  `(unless ,test (error ,datum ,@arguments)))

(defmacro define-process-condition (name superclasses slots (condition stream) &body report)
  "Define NAME as a condition with less boilerplate than DEFINE-CONDITION.

Each entry in SLOTS is either a bare slot name -- which defaults to
:INITARG :<NAME> and a single reader NAME-<SLOT> -- or
(SLOT-NAME &key INITARG INITFORM READERS), for the cases (multiple reader
aliases, an :INITFORM, an :INITARG that does not match the slot name) that
need one. REPORT is the body of the condition's :REPORT function, with
CONDITION and STREAM bound; an empty REPORT omits :REPORT entirely."
  (flet ((slot-clause (slot)
           (destructuring-bind
               (slot-name &key
                          (initarg (intern (string slot-name) :keyword))
                          (initform nil initform-p)
                          (readers (list (intern (format nil "~A-~A" name slot-name)))))
               (if (consp slot) slot (list slot))
             `(,slot-name :initarg ,initarg
                          ,@(when initform-p (list :initform initform))
                          ,@(loop for reader in readers append (list :reader reader))))))
    `(define-condition ,name ,superclasses ,(mapcar #'slot-clause slots)
       ,@(when report
           `((:report (lambda (,condition ,stream) ,@report)))))))

(define-process-condition process-error (error) () (condition stream))

(define-process-condition process-launch-error (process-error)
    (program arguments directory cause)
    (condition stream)
  (format stream "Failed to launch subprocess ~S."
          (process-launch-error-program condition)))

(define-process-condition process-exit-error (process-error)
    (result)
    (condition stream)
  (let ((result (process-exit-error-result condition)))
    (format stream "Subprocess failed with status ~S, exit code ~S, and signal ~S."
            (process-result-status result)
            (process-result-exit-code result)
            (process-result-signal result))))

(define-process-condition pipeline-exit-error (process-error)
    (result stage-index stage-result)
    (condition stream)
  (format stream "Pipeline stage ~D failed with status ~S, exit code ~S, and signal ~S."
          (pipeline-exit-error-stage-index condition)
          (process-result-status (pipeline-exit-error-stage-result condition))
          (process-result-exit-code (pipeline-exit-error-stage-result condition))
          (process-result-signal (pipeline-exit-error-stage-result condition))))

(define-process-condition communicate-options-mismatch (process-error)
    (process expected-options actual-options)
    (condition stream)
  (format stream "COMMUNICATE options ~S do not match the initial options ~S."
          (communicate-options-mismatch-actual-options condition)
          (communicate-options-mismatch-expected-options condition)))

(define-process-condition process-timeout-error (process-error)
    ((command)
     (args :initarg :arguments)
     (timeout :readers (process-timeout-error-timeout))
     (result :readers (process-timeout-error-result))
     (stage-index :initform nil)
     (pipeline-result :initform nil))
    (condition stream)
  (format stream "Subprocess ~S timed out after ~A second~:P."
          (process-timeout-error-command condition)
          (process-timeout-error-timeout condition)))

(define-process-condition process-cancelled-error (process-error)
    (result
     (stage-index :initform nil)
     (pipeline-result :initform nil))
    (condition stream)
  (format stream "Subprocess ~S was cancelled."
          (process-result-program (process-cancelled-error-result condition))))

(define-process-condition process-group-isolation-error (process-error)
    (pid pgid)
    (condition stream)
  (format stream "Subprocess ~D was not isolated in its own process group (group ~D)."
          (process-group-isolation-error-pid condition)
          (process-group-isolation-error-pgid condition)))

(define-process-condition process-io-error (process-error)
    (stream cause)
    (condition stream)
  (format stream "Failed while draining subprocess ~A."
          (process-io-error-stream condition)))

(define-process-condition fd-set-overflow (process-error)
    (fd limit)
    (condition stream)
  (format stream "File descriptor ~D is above ~D, the highest select(2) can watch here."
          (fd-set-overflow-fd condition)
          (fd-set-overflow-limit condition)))

(define-process-condition fd-wait-failed (process-error)
    (errno read-fds write-fds except-fds)
    (condition stream)
  (format stream "Waiting on file descriptors (read ~S, write ~S, except ~S) ~
failed with errno ~D: ~A."
          (fd-wait-failed-read-fds condition)
          (fd-wait-failed-write-fds condition)
          (fd-wait-failed-except-fds condition)
          (fd-wait-failed-errno condition)
          (sb-int:strerror (fd-wait-failed-errno condition))))
