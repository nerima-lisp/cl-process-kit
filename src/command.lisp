;;;; src/command.lisp
;;;;
;;;; Validation, defensive copying, and derived predicates for the data
;;;; types declared in types.lisp: command-spec construction and its public
;;;; accessors, cancellation-token operations, process-event accessors, and
;;;; the process/pipeline success predicates.

(in-package #:process-kit)

(defun %proper-string-list-p (value)
  (and (listp value)
       (handler-case
           (and (or (null value) (integerp (list-length value)))
                (every #'stringp value))
         (type-error () nil))))

(defun %copy-command-data (value)
  (typecase value
    (string (copy-seq value))
    (cons (cons (%copy-command-data (car value))
                (%copy-command-data (cdr value))))
    (t value)))

(defun %valid-stdio-policy-p (value role)
  (or (streamp value)
      (pathnamep value)
      (member value
              (if (eq role :stderr)
                  '(:inherit :null :pipe :capture :stdout)
                  '(:inherit :null :pipe :capture))
              :test #'eq)))

(defun %validate-environment-entries (entries label)
  (let ((seen (make-hash-table :test #'equal)))
    (dolist (entry entries)
      (%ensure (not (position #\Null entry)) "~A entry contains NUL: ~S" label entry)
      (%validate-environment-entry-shape entry label seen))))

(defun %valid-environment-update-p (environment-update)
  (or (null environment-update)
      (and (listp environment-update)
           (handler-case
               (and (integerp (list-length environment-update))
                    (every #'%valid-environment-update-entry-p environment-update))
             (type-error () nil)))))

(defun %valid-environment-update-entry-p (entry)
  (and (consp entry)
       (stringp (car entry))
       (plusp (length (car entry)))
       (not (position #\= (car entry)))
       (not (position #\Null (car entry)))
       (or (null (cdr entry))
           (and (stringp (cdr entry)) (not (position #\Null (cdr entry)))))))

(defun make-command (program arguments
                      &key (search nil) (environment-policy :inherit) environment-update
                        directory (stdin :inherit) (stdout :capture) (stderr :capture)
                        (result-type :string) (external-format :default)
                        (decoding-error-policy :replace))
  "Create a validated, immutable-by-public-API command specification."
  (%ensure (and (or (stringp program) (pathnamep program))
                (plusp (length (namestring program)))
                (not (position #\Null (namestring program))))
           "PROGRAM must be a non-empty string or pathname without NUL.")
  (%ensure (and (%proper-string-list-p arguments)
                (notany (lambda (argument) (position #\Null argument)) arguments))
           "ARGUMENTS must be a proper list of strings without NUL.")
  (%ensure (typep search 'boolean) "SEARCH must be a boolean.")
  (%ensure (or (eq environment-policy :inherit) (%proper-string-list-p environment-policy))
           "ENVIRONMENT-POLICY must be :INHERIT or a proper list of KEY=VALUE strings.")
  (unless (eq environment-policy :inherit)
    (%validate-environment-entries environment-policy "ENVIRONMENT-POLICY"))
  (%ensure (%valid-environment-update-p environment-update)
           "ENVIRONMENT-UPDATE must be an alist of valid (KEY . VALUE) pairs; NIL values delete keys.")
  (let ((seen-updates (make-hash-table :test #'equal)))
    (dolist (entry environment-update)
      (%ensure (not (gethash (car entry) seen-updates))
               "Duplicate ENVIRONMENT-UPDATE key: ~S" (car entry))
      (setf (gethash (car entry) seen-updates) t)))
  (dolist (entry (list (cons stdin :stdin) (cons stdout :stdout) (cons stderr :stderr)))
    (%ensure (%valid-stdio-policy-p (car entry) (cdr entry))
             "Invalid ~A standard I/O policy: ~S" (cdr entry) (car entry)))
  (%ensure (member result-type '(:string :octets)) "RESULT-TYPE must be :STRING or :OCTETS.")
  (%ensure (member decoding-error-policy '(:replace :error))
           "DECODING-ERROR-POLICY must be :REPLACE or :ERROR.")
  (%make-command-spec
   :program (%copy-command-data program) :arguments (%copy-command-data arguments)
   :search search
   :environment-policy (%copy-command-data environment-policy)
   :environment-update (%copy-command-data environment-update)
   :directory directory :stdin stdin :stdout stdout :stderr stderr
   :result-type result-type :external-format external-format
   :decoding-error-policy decoding-error-policy))

(defmacro define-command-accessor (name slot-accessor &key copy)
  "Define NAME as a public COMMAND-SPEC reader over SLOT-ACCESSOR. With
COPY, the read defensively deep-copies the slot via %COPY-COMMAND-DATA (for
the mutable PROGRAM, ARGUMENTS, ENVIRONMENT-POLICY, and ENVIRONMENT-UPDATE
data), so a caller cannot mutate a COMMAND-SPEC's internals through its
return value; every other slot is immutable once constructed and reads
straight through."
  `(defun ,name (command)
     ,(if copy `(%copy-command-data (,slot-accessor command)) `(,slot-accessor command))))

(define-command-accessor command-program %command-spec-program :copy t)
(define-command-accessor command-arguments %command-spec-arguments :copy t)
(define-command-accessor command-search %command-spec-search)
(define-command-accessor command-environment-policy %command-spec-environment-policy :copy t)
(define-command-accessor command-environment-update %command-spec-environment-update :copy t)
(define-command-accessor command-directory %command-spec-directory)
(define-command-accessor command-stdin %command-spec-stdin)
(define-command-accessor command-stdout %command-spec-stdout)
(define-command-accessor command-stderr %command-spec-stderr)
(define-command-accessor command-result-type %command-spec-result-type)
(define-command-accessor command-external-format %command-spec-external-format)
(define-command-accessor command-decoding-error-policy %command-spec-decoding-error-policy)

(defun make-cancellation-token ()
  "Create a thread-safe cancellation token."
  (%make-cancellation-token (sb-thread:make-mutex :name "process-kit cancellation token")))

(defun cancel (token)
  "Request cancellation of TOKEN. Repeated requests are harmless."
  (check-type token cancellation-token)
  (sb-thread:with-mutex ((%cancellation-token-mutex token))
    (setf (%cancellation-token-requested-p token) t))
  token)

(defun cancellation-requested-p (token)
  "Return whether cancellation has been requested for TOKEN."
  (check-type token cancellation-token)
  (sb-thread:with-mutex ((%cancellation-token-mutex token))
    (%cancellation-token-requested-p token)))

(defmacro define-event-accessor (name slot-accessor &key copy-octets)
  "Define NAME as a public PROCESS-EVENT reader over SLOT-ACCESSOR. With
COPY-OCTETS, the read returns a fresh copy of the slot's octet vector (or
NIL) instead of the stored one, so a caller cannot mutate a delivered
event's bytes in place."
  `(defun ,name (event)
     ,(if copy-octets
          `(let ((octets (,slot-accessor event))) (and octets (copy-seq octets)))
          `(,slot-accessor event))))

(define-event-accessor process-event-kind %process-event-kind)
(define-event-accessor process-event-sequence %process-event-sequence)
(define-event-accessor process-event-octets %process-event-octets :copy-octets t)
(define-event-accessor process-event-result %process-event-result)
(define-event-accessor process-event-condition %process-event-condition)
(define-event-accessor process-event-dropped-count %process-event-dropped-count)

(defun process-success-p (result)
  (and (not (process-result-timed-out-p result))
       (not (process-result-cancelled-p result))
       (eq (process-result-status result) :exited)
       (eql (process-result-exit-code result) 0)))

(defun pipeline-success-p (result)
  (and (typep result 'pipeline-result)
       (not (pipeline-result-timed-out-p result))
       (not (pipeline-result-cancelled-p result))
       (every #'process-success-p (pipeline-result-results result))))

(defun %validate-environment-entry-shape (entry label seen) (let ((separator (position #\= entry)))
        (%ensure (and separator (plusp separator))
                 "~A entry must contain a non-empty key followed by =: ~S" label entry)
        (let ((key (subseq entry 0 separator)))
          (%ensure (not (gethash key seen)) "Duplicate ~A key: ~S" label key)
          (setf (gethash key seen) t))))
