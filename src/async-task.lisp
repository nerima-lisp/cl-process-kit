(in-package #:process-kit)

(defvar *process-kit-communicate-executor*
  (cl-concurrent-kit:make-executor
   :size 8
   :name "process-kit communicate workers"
   :queue-capacity 256))

(defvar *process-kit-dispatch-executor*
  (cl-concurrent-kit:make-executor
   :size 4
   :name "process-kit event dispatchers"
   :queue-capacity 256))

(defun %submit-process-kit-job (executor thunk role)
  (multiple-value-bind (promise accepted-p)
      (cl-concurrent-kit:try-submit executor thunk)
    (if accepted-p
        promise
        (error "Unable to submit process-kit ~A job." role))))

(defmacro with-plist-options ((plist) bindings &body body)
  "Bind each (VAR KEY DEFAULT) in BINDINGS from PLIST: VAR is PLIST's value
for KEY when KEY is present -- even if that value is NIL/false -- and
DEFAULT otherwise. Plain GETF cannot make that distinction on its own,
which %ASYNC-CONTRACT's option set (below) needs for every key."
  (let ((plist-var (gensym "PLIST")))
    `(let ((,plist-var ,plist))
       (let ,(loop for (var key default) in bindings
                   collect `(,var
                             (if (member ,key ,plist-var :test #'eq) (getf ,plist-var ,key)
                               ,default)))
         ,@body))))

(defmacro define-task-reader (name slot-accessor)
  "Define NAME as a mutex-guarded reader of PROCESS-TASK's SLOT-ACCESSOR
slot -- the pattern every read-only, no-argument PROCESS-TASK accessor in
this file follows."
  `(defun ,name (task)
     (check-type task process-task)
     (sb-thread:with-mutex ((%process-task-mutex task)) (,slot-accessor task))))

(define-task-reader task-state %process-task-state)

(define-task-reader task-result %process-task-result)

(define-task-reader task-condition %process-task-condition)

(defun process-events (task)
  "Return TASK's currently retained PROCESS-EVENT history as a fresh list,
oldest first, bounded by its :EVENT-HISTORY-CAPACITY."
  (check-type task process-task)
  (sb-thread:with-mutex
   ((%process-task-mutex task))
   (%bounded-ring-contents
    (%process-task-events task)
    (%process-task-event-history-start task)
    (%process-task-event-history-count task))))

(defun process-task-first-event-sequence (task)
  "Return the SEQUENCE of the oldest event TASK still retains, or NIL if its
history is currently empty."
  (check-type task process-task)
  (sb-thread:with-mutex
   ((%process-task-mutex task))
   (when (plusp (%process-task-event-history-count task))
     (process-event-sequence
      (aref (%process-task-events task) (%process-task-event-history-start task))))))

(define-task-reader process-task-last-event-sequence %process-task-last-event-sequence)

(define-task-reader process-task-history-evicted-count %process-task-history-evicted-count)

(defstruct (%async-launch-options
            (:constructor
             %make-async-launch-options
             (&key callback queue-capacity overflow-policy history-capacity communication-options))
            (:conc-name %async-launch-options-)
            (:copier nil)) callback
  (queue-capacity 64 :type integer)
  (overflow-policy :drop-newest :type keyword)
  (history-capacity 64 :type integer)
  (communication-options nil :type list))

(defun %task-history-first-event (task)
  (when (plusp (%process-task-event-history-count task))
    (aref (%process-task-events task) (%process-task-event-history-start task))))

(defun %task-history-event-at-sequence (task sequence)
  (let ((first (%task-history-first-event task)))
    (when first
      (let ((offset (- sequence (process-event-sequence first))))
        (when (and (not (minusp offset)) (< offset (%process-task-event-history-count task)))
          (aref
           (%process-task-events task)
           (mod
            (+ (%process-task-event-history-start task) offset)
            (length (%process-task-events task)))))))))

(defun %deadline-from-timeout (timeout)
  "NIL if TIMEOUT is NIL, else the GET-INTERNAL-REAL-TIME tick TIMEOUT
seconds from now. NEXT-PROCESS-EVENT and AWAIT-PROCESS both take a relative
:TIMEOUT but need an absolute deadline to re-check across a loop's
iterations."
  (and timeout (+ (get-internal-real-time) (* timeout internal-time-units-per-second))))

(defun %wait-on-task (task deadline on-timeout)
  "Block on TASK's condition variable until notified, or call the ON-TIMEOUT
thunk instead of blocking (or after waiting the last of it out) once DEADLINE
-- a GET-INTERNAL-REAL-TIME tick, or NIL for no deadline -- has passed.

NEXT-PROCESS-EVENT and AWAIT-PROCESS each wait on this same condition
variable across a polling loop and differ only in what they return on a
timeout, which is why that difference is passed in as a continuation rather
than this function returning a value for the caller to check."
  (if deadline (let ((remaining
                      (/ (- deadline (get-internal-real-time)) internal-time-units-per-second)))
                 (if (<= remaining 0) (funcall on-timeout)
                   (sb-thread:condition-wait
                    (%process-task-waitqueue task)
                    (%process-task-mutex task)
                    :timeout
                    remaining)))
    (sb-thread:condition-wait (%process-task-waitqueue task) (%process-task-mutex task))))

(defun %next-event-requested-sequence (cursor first-sequence)
  (or cursor first-sequence 1))

(defun %next-event-gap-step (requested first-sequence last-sequence)
  (when (and last-sequence (< requested (or first-sequence (1+ last-sequence))))
    (let ((resume (or first-sequence (1+ last-sequence))))
      (make-process-event-step nil resume :gap (- resume requested)))))

(defun %next-event-deliverable-step (task requested)
  (let ((event (%task-history-event-at-sequence task requested)))
    (when event
      (make-process-event-step event (1+ requested) :event 0))))

(defun %next-event-terminal-step (task requested)
  (unless (member (%process-task-state task) '(:reserved :running) :test #'eq)
    (make-process-event-step nil requested :terminal 0)))

(defun next-process-event (task &key cursor timeout)
  "Return a PROCESS-EVENT-STEP for one independent consumer: its EVENT (or
NIL), the CURSOR to pass on the following call, STATUS (:EVENT, :GAP,
:TERMINAL, or :TIMEOUT), and GAP-COUNT (nonzero only when STATUS is :GAP)."
  (check-type task process-task)
  (%ensure
   (or (null cursor) (and (integerp cursor) (plusp cursor)))
   "CURSOR must be NIL or a positive sequence number.")
  (%ensure
   (or (null timeout) (and (realp timeout) (not (minusp timeout))))
   "TIMEOUT must be NIL or non-negative.")
  (let ((deadline (%deadline-from-timeout timeout)))
    (sb-thread:with-mutex
     ((%process-task-mutex task))
     (loop (let* ((first (%task-history-first-event task))
                  (first-sequence (and first (process-event-sequence first)))
                  (last-sequence (%process-task-last-event-sequence task))
                  (requested (%next-event-requested-sequence cursor first-sequence))
                  (step
                   (or
                    (%next-event-gap-step requested first-sequence last-sequence)
                    (%next-event-deliverable-step task requested)
                    (%next-event-terminal-step task requested))))
             (when step
               (return-from next-process-event step))
             (%wait-on-task
              task
              deadline
              (lambda ()
                (return-from next-process-event
                (make-process-event-step nil requested :timeout 0)))))))))

(defun callback-errors (task)
  (check-type task process-task)
  (sb-thread:with-mutex
   ((%process-task-mutex task))
   (%bounded-ring-contents
    (%process-task-callback-errors task)
    (%process-task-callback-error-history-start task)
    (%process-task-callback-error-history-count task))))

(define-task-reader dropped-event-count %process-task-dropped-event-count)

(defun %async-contract (options)
  (with-plist-options
   (options)
   ((input :input nil)
    (timeout :timeout nil)
    (grace-period :grace-period +default-grace-period-seconds+)
    (timeout-signal :timeout-signal +default-timeout-signal+)
    (kill-signal :kill-signal +default-kill-signal+)
    (on-timeout :on-timeout :error)
    (max-output-characters :max-output-characters +default-output-limit+)
    (drain-timeout-seconds :drain-timeout-seconds +default-drain-timeout-seconds+)
    (result-type :result-type :string)
    (external-format :external-format :default)
    (decoding-error-policy :decoding-error-policy :replace)
    (clock :clock +default-clock+)
    (sleeper :sleeper +default-sleeper+)
    (poll-interval :poll-interval +default-poll-interval+))
   (build-communication-contract
    input
    timeout
    grace-period
    timeout-signal
    kill-signal
    on-timeout
    max-output-characters
    drain-timeout-seconds
    result-type
    external-format
    decoding-error-policy
    clock
    sleeper
    poll-interval)))

(defun %validated-async-contract (communication-options)
  (let ((contract (%async-contract communication-options)))
    (%validate-communication-options
     (getf contract :input)
     (getf contract :timeout)
     (getf contract :grace-period)
     (getf contract :poll-interval)
     (getf contract :timeout-signal)
     (getf contract :kill-signal)
     (getf contract :on-timeout)
     (getf contract :max-output-characters)
     (getf contract :drain-timeout-seconds)
     (getf contract :result-type)
     (getf contract :decoding-error-policy)
     (getf contract :clock)
     (getf contract :sleeper))
    contract))

(defun %async-task-options (options)
  "Split COMMUNICATE-ASYNC's task-local options from the COMMUNICATE option
plist the worker thread should forward unchanged."
  (with-plist-options
   (options)
   ((callback :event-callback nil)
    (capacity :event-queue-capacity 64)
    (policy :event-overflow-policy :drop-newest)
    (history-capacity-option :event-history-capacity nil))
   (let ((history-capacity (or history-capacity-option capacity)))
     (%make-async-launch-options
      :callback
      callback
      :queue-capacity
      capacity
      :overflow-policy
      policy
      :history-capacity
      history-capacity
      :communication-options
      (%plist-without
       options
       '(:event-callback :event-queue-capacity :event-overflow-policy :event-history-capacity))))))

(defun %validate-async-task-options (async-options)
  (%ensure
   (and
    (integerp (%async-launch-options-queue-capacity async-options))
    (plusp (%async-launch-options-queue-capacity async-options)))
   "EVENT-QUEUE-CAPACITY must be positive.")
  (%ensure
   (and
    (integerp (%async-launch-options-history-capacity async-options))
    (not (minusp (%async-launch-options-history-capacity async-options))))
   "EVENT-HISTORY-CAPACITY must be non-negative.")
  (%ensure
   (member (%async-launch-options-overflow-policy async-options) '(:drop-newest :block) :test #'eq)
   "Unknown event overflow policy ~S."
   (%async-launch-options-overflow-policy async-options))
  (when (%async-launch-options-callback async-options)
    (check-type (%async-launch-options-callback async-options) function))
  async-options)

(defun %make-async-process-task (process async-options token)
  (let ((history-capacity (%async-launch-options-history-capacity async-options)))
    (%make-process-task
     :process process
     :token token
     :capacity (%async-launch-options-queue-capacity async-options)
     :overflow-policy (%async-launch-options-overflow-policy async-options)
     :callback (%async-launch-options-callback async-options)
     :events (make-array history-capacity)
     :callback-errors (make-array history-capacity)
     :event-channel
     (cl-concurrent-kit:make-channel
      :buffer-size (%async-launch-options-queue-capacity async-options))
     :cancellation-channel
     (cl-concurrent-kit:make-channel :buffer-size 1))))

(defun %launch-communicate-async-threads (task process communication-options token)
  "Submit TASK dispatcher and worker jobs to shared executors and return
TASK. On any failure to submit both jobs, release TASK communication
reservation and mark it finished with the failing CONDITION before
re-signaling, so a caller never sees a task stuck in :RESERVED."
  (handler-case
      (progn
        (setf (%process-task-dispatcher task)
              (%submit-process-kit-job
               *process-kit-dispatch-executor*
               (lambda ()
                 (%task-dispatch task))
               "event dispatcher"))
        (setf (%process-task-worker task)
              (%submit-process-kit-job
               *process-kit-communicate-executor*
               (lambda ()
                 (sb-thread:with-mutex
                  ((%process-task-mutex task))
                  (setf (%process-task-state task) :running))
                 (let ((*communication-reservation-owner* task)
                       (*process-event-sink*
                        (lambda (kind octets)
                          (%task-submit-output task kind octets))))
                   (handler-case
                       (progn
                         (%task-finish
                          task
                          (apply
                           (function communicate)
                           process
                           (append
                            (%plist-without
                             communication-options
                             (list :cancellation-token :on-cancel))
                            (list
                             :cancellation-token
                             token
                             :on-cancel
                             :return)))
                         nil))
                     (condition (condition)
                       (%task-finish task nil condition)
                       task))))
               "communicate worker"))
        task)
    (condition (condition)
      (%release-communication-reservation process task)
      (when (%process-task-dispatcher task)
        (%task-finish task nil condition))
      (error condition))))

(defun communicate-async (process &rest options)
  "Start COMMUNICATE running on a worker thread against PROCESS and return
a PROCESS-TASK publishing its progress as an ordered PROCESS-EVENT stream
instead of blocking the caller -- the asynchronous counterpart to
COMMUNICATE. Consume events via :EVENT-CALLBACK, the bounded/retained
history accessors (PROCESS-EVENTS, DROPPED-EVENT-COUNT, ...), or the
cursor-based NEXT-PROCESS-EVENT API; call AWAIT-PROCESS to block for the
final PROCESS-RESULT COMMUNICATE would otherwise have returned directly.
Owns its own cancellation token -- pass CANCEL-PROCESS the returned task
rather than a :CANCELLATION-TOKEN option, which this rejects."
  (check-type process process-handle)
  (%ensure
   (not (member :cancellation-token options :test #'eq))
   "COMMUNICATE-ASYNC owns its cancellation token.")
  (let* ((async-options (%validate-async-task-options (%async-task-options options)))
         (token (make-cancellation-token))
         (task (%make-async-process-task process async-options token))
         (communication-options (%async-launch-options-communication-options async-options))
         (contract (%validated-async-contract communication-options)))
    (%reserve-communication process contract task)
    (%launch-communicate-async-threads task process communication-options token)))

(defun await-process (task &key timeout)
  "Block until TASK's COMMUNICATE-ASYNC run finishes or TIMEOUT (NIL for no
bound) elapses. Return its PROCESS-RESULT, re-signaling any condition the
worker thread captured, or NIL on timeout while TASK is still running."
  (check-type task process-task)
  (%ensure
   (or (null timeout) (and (realp timeout) (not (minusp timeout))))
   "TIMEOUT must be NIL or non-negative.")
  (let ((deadline (%deadline-from-timeout timeout)))
    (sb-thread:with-mutex
     ((%process-task-mutex task))
     (loop while (member (%process-task-state task) '(:reserved :running) :test #'eq)
           do (%wait-on-task
               task
               deadline
               (lambda ()
                 (return-from await-process (values nil nil)))))
     (when (%process-task-condition task)
       (error (%process-task-condition task)))
     (values (%process-task-result task) t))))

(defun cancel-process (task)
  "Request cancellation of TASK COMMUNICATE-ASYNC run via its owned
cancellation token, wake event producers blocked in channel SELECT, and
wake any thread blocked in AWAIT-PROCESS or NEXT-PROCESS-EVENT. Does not
itself block; return TASK."
  (check-type task process-task)
  (cancel (%process-task-token task))
  (cl-concurrent-kit:close-channel
   (%process-task-cancellation-channel task))
  (sb-thread:with-mutex
   ((%process-task-mutex task))
   (sb-thread:condition-broadcast (%process-task-waitqueue task)))
  task)
