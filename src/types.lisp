;;;; src/types.lisp
;;;;
;;;; Pure data shapes shared across the library: process specifications,
;;;; results, and the event/task records used by the asynchronous API.
;;;; Every struct here is a plain data container -- validation, defensive
;;;; copying, and derived predicates live in command.lisp, not here.

(in-package #:process-kit)

(defstruct (command-spec
            (:constructor %make-command-spec)
            (:predicate command-p)
            (:conc-name %command-spec-))
  program
  (arguments nil)
  (search nil :type boolean)
  (environment-policy :inherit)
  environment-update
  directory
  stdin
  stdout
  stderr
  (result-type :string :type keyword)
  external-format
  (decoding-error-policy :replace :type keyword))

(defstruct (cancellation-token
            (:constructor %make-cancellation-token (mutex))
            (:conc-name %cancellation-token-))
  mutex
  (requested-p nil :type boolean))

(defstruct (process-event
            (:constructor %make-process-event
                (&key kind sequence octets result condition dropped-count))
            (:conc-name %process-event-)
            (:copier nil))
  kind sequence octets result condition dropped-count)

(defstruct (process-event-step
            (:constructor make-process-event-step (event cursor status gap-count)))
  (event nil :read-only t)
  (cursor nil :read-only t)
  (status nil :read-only t)
  (gap-count 0 :read-only t))

(defstruct (process-task
            (:constructor %make-process-task)
            (:conc-name %process-task-)
            (:copier nil))
  process
  token
  (mutex (sb-thread:make-mutex :name "process-kit task state"))
  (waitqueue (sb-thread:make-waitqueue :name "process-kit task completion and events"))
  (queue-mutex (sb-thread:make-mutex :name "process-kit task events"))
  (queue-ready (sb-thread:make-waitqueue :name "process-kit event ready"))
  (queue-space (sb-thread:make-waitqueue :name "process-kit event space"))
  (capacity 64)
  (overflow-policy :drop-newest)
  callback
  (state :reserved)
  result
  condition
  (events #())
  (event-history-start 0)
  (event-history-count 0)
  (history-evicted-count 0)
  last-event-sequence
  (callback-errors #())
  (callback-error-history-start 0)
  (callback-error-history-count 0)
  (dropped-event-count 0)
  (next-sequence 0)
  (queue nil)
  (queue-count 0)
  (pending-drops 0)
  terminal-event
  producer-finished-p
  worker
  dispatcher)

(defstruct process-result
  program
  (arguments nil)
  pid
  status
  duration-seconds
  exit-code
  (stdout "")
  (stderr "")
  (timed-out-p nil :type boolean)
  (cancelled-p nil :type boolean)
  signal
  (stdout-truncated-p nil :type boolean)
  (stderr-truncated-p nil :type boolean))

(defstruct (pipeline-result
            (:constructor make-pipeline-result
                (&key results stdout stderr timed-out-p cancelled-p duration-seconds)))
  (results nil :read-only t)
  stdout
  (stderr nil :read-only t)
  (timed-out-p nil :read-only t)
  (cancelled-p nil :read-only t)
  (duration-seconds 0d0 :read-only t))
