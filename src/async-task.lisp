;;;; src/async-task.lisp
;;;;
;;;; COMMUNICATE-ASYNC runs COMMUNICATE on a worker thread and publishes its
;;;; progress as an ordered PROCESS-EVENT stream instead of blocking the
;;;; caller. Producer (the worker thread, via *PROCESS-EVENT-SINK*) and
;;;; consumer (a bounded event queue drained by a dispatcher thread that
;;;; invokes the caller's :EVENT-CALLBACK continuation) run concurrently;
;;;; PROCESS-TASK is the shared, mutex-guarded state between them.

(in-package #:process-kit)

(defmacro with-plist-options ((plist) bindings &body body)
  "Bind each (VAR KEY DEFAULT) in BINDINGS from PLIST: VAR is PLIST's value
for KEY when KEY is present -- even if that value is NIL/false -- and
DEFAULT otherwise. Plain GETF cannot make that distinction on its own,
which %ASYNC-CONTRACT's option set (below) needs for every key."
  (let ((plist-var (gensym "PLIST")))
    `(let ((,plist-var ,plist))
       (let ,(loop for (var key default) in bindings
                   collect `(,var (if (member ,key ,plist-var :test #'eq)
                                       (getf ,plist-var ,key)
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
  (check-type task process-task)
  (sb-thread:with-mutex ((%process-task-mutex task))
    (%bounded-ring-contents
     (%process-task-events task) (%process-task-event-history-start task) (%process-task-event-history-count task))))

(defun process-task-first-event-sequence (task)
  (check-type task process-task)
  (sb-thread:with-mutex ((%process-task-mutex task))
    (when (plusp (%process-task-event-history-count task))
      (process-event-sequence (aref (%process-task-events task) (%process-task-event-history-start task))))))

(define-task-reader process-task-last-event-sequence %process-task-last-event-sequence)
(define-task-reader process-task-history-evicted-count %process-task-history-evicted-count)

(defun %task-history-first-event (task)
  (when (plusp (%process-task-event-history-count task))
    (aref (%process-task-events task) (%process-task-event-history-start task))))

(defun %task-history-event-at-sequence (task sequence)
  (let ((first (%task-history-first-event task)))
    (when first
      (let ((offset (- sequence (process-event-sequence first))))
        (when (and (not (minusp offset)) (< offset (%process-task-event-history-count task)))
          (aref (%process-task-events task)
                (mod (+ (%process-task-event-history-start task) offset) (length (%process-task-events task)))))))))

(defun next-process-event (task &key cursor timeout)
  "Return EVENT, NEXT-CURSOR, STATUS, and GAP-COUNT for one independent consumer."
  (check-type task process-task)
  (%ensure (or (null cursor) (and (integerp cursor) (plusp cursor)))
           "CURSOR must be NIL or a positive sequence number.")
  (%ensure (or (null timeout) (and (realp timeout) (not (minusp timeout))))
           "TIMEOUT must be NIL or non-negative.")
  (let ((deadline (and timeout (+ (get-internal-real-time) (* timeout internal-time-units-per-second)))))
    (sb-thread:with-mutex ((%process-task-mutex task))
      (loop
        (let* ((first (%task-history-first-event task))
               (first-sequence (and first (process-event-sequence first)))
               (last-sequence (%process-task-last-event-sequence task))
               (requested (or cursor first-sequence 1)))
          (when (and last-sequence (< requested (or first-sequence (1+ last-sequence))))
            (let ((resume (or first-sequence (1+ last-sequence))))
              (return-from next-process-event (values nil resume :gap (- resume requested)))))
          (let ((event (%task-history-event-at-sequence task requested)))
            (when event (return-from next-process-event (values event (1+ requested) :event 0))))
          (unless (member (%process-task-state task) '(:reserved :running) :test #'eq)
            (return-from next-process-event (values nil requested :terminal 0)))
          (if deadline
              (let ((remaining (/ (- deadline (get-internal-real-time)) internal-time-units-per-second)))
                (when (<= remaining 0) (return-from next-process-event (values nil requested :timeout 0)))
                (sb-thread:condition-wait (%process-task-waitqueue task) (%process-task-mutex task) :timeout remaining))
              (sb-thread:condition-wait (%process-task-waitqueue task) (%process-task-mutex task))))))))

(defun callback-errors (task)
  (check-type task process-task)
  (sb-thread:with-mutex ((%process-task-mutex task))
    (%bounded-ring-contents (%process-task-callback-errors task)
                            (%process-task-callback-error-history-start task)
                            (%process-task-callback-error-history-count task))))

(define-task-reader dropped-event-count %process-task-dropped-event-count)

(defun %async-contract (options)
  (with-plist-options (options)
      ((input :input nil)
       (timeout :timeout nil)
       (grace-period :grace-period 1.0d0)
       (timeout-signal :timeout-signal 15)
       (kill-signal :kill-signal 9)
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
     input timeout grace-period timeout-signal kill-signal on-timeout
     max-output-characters drain-timeout-seconds result-type external-format
     decoding-error-policy clock sleeper poll-interval)))

(defun communicate-async (process &rest options)
  (check-type process process-handle)
  (%ensure (not (member :cancellation-token options :test #'eq))
           "COMMUNICATE-ASYNC owns its cancellation token.")
  (flet ((launch-communicate-async-threads (task process communication-options token)
           "Start TASK's dispatcher and worker threads and return TASK. On
any failure to get both threads running, release TASK's communication
reservation and mark it finished with the failing CONDITION before
re-signaling, so a caller never sees a task stuck in :RESERVED."
           (handler-case
               (progn
                 (setf (%process-task-dispatcher task)
                       (sb-thread:make-thread (lambda () (%task-dispatch task)) :name "process-kit event dispatcher"))
                 (setf (%process-task-worker task)
                       (sb-thread:make-thread
                        (lambda ()
                          (sb-thread:with-mutex ((%process-task-mutex task)) (setf (%process-task-state task) :running))
                          (let ((*communication-reservation-owner* task)
                                (*process-event-sink* (lambda (kind octets) (%task-submit-output task kind octets))))
                            (handler-case
                                (%task-finish task
                                              (apply #'communicate process
                                                     (append communication-options
                                                             (list :cancellation-token token :on-cancel :return)))
                                              nil)
                              (condition (condition) (%task-finish task nil condition)))))
                        :name "process-kit communicate worker"))
                 task)
             (condition (condition)
               (%release-communication-reservation process task)
               (when (%process-task-dispatcher task) (%task-finish task nil condition))
               (error condition)))))
    (let* ((callback (getf options :event-callback))
           (capacity (if (member :event-queue-capacity options :test #'eq)
                         (getf options :event-queue-capacity) 64))
           (policy (if (member :event-overflow-policy options :test #'eq)
                       (getf options :event-overflow-policy) :drop-newest))
           (history-capacity (if (member :event-history-capacity options :test #'eq)
                                 (getf options :event-history-capacity) capacity))
           (communication-options
             (%plist-without options '(:event-callback :event-queue-capacity :event-overflow-policy
                                        :event-history-capacity)))
           (token (make-cancellation-token))
           (task (%make-process-task
                  :process process :token token :capacity capacity :overflow-policy policy :callback callback
                  :events (make-array (if (and (integerp history-capacity) (not (minusp history-capacity)))
                                           history-capacity 0))
                  :callback-errors (make-array (if (and (integerp history-capacity) (not (minusp history-capacity)))
                                                    history-capacity 0))))
           (contract (%async-contract communication-options)))
      (%ensure (and (integerp capacity) (plusp capacity)) "EVENT-QUEUE-CAPACITY must be positive.")
      (%ensure (and (integerp history-capacity) (not (minusp history-capacity)))
               "EVENT-HISTORY-CAPACITY must be non-negative.")
      (%ensure (member policy '(:drop-newest :block) :test #'eq) "Unknown event overflow policy ~S." policy)
      (when callback (check-type callback function))
      (%validate-communication-options
       (getf contract :input) (getf contract :timeout) (getf contract :grace-period) (getf contract :poll-interval)
       (getf contract :timeout-signal) (getf contract :kill-signal) (getf contract :on-timeout)
       (getf contract :max-output-characters) (getf contract :drain-timeout-seconds) (getf contract :result-type)
       (getf contract :decoding-error-policy) (getf contract :clock) (getf contract :sleeper))
      (%reserve-communication process contract task)
      (launch-communicate-async-threads task process communication-options token))))

(defun await-process (task &key timeout)
  (check-type task process-task)
  (%ensure (or (null timeout) (and (realp timeout) (not (minusp timeout))))
           "TIMEOUT must be NIL or non-negative.")
  (let ((deadline (and timeout (+ (get-internal-real-time) (* timeout internal-time-units-per-second)))))
    (sb-thread:with-mutex ((%process-task-mutex task))
      (loop while (member (%process-task-state task) '(:reserved :running) :test #'eq)
            do (if deadline
                   (let ((remaining (/ (- deadline (get-internal-real-time)) internal-time-units-per-second)))
                     (when (<= remaining 0) (return-from await-process (values nil nil)))
                     (sb-thread:condition-wait (%process-task-waitqueue task) (%process-task-mutex task)
                                               :timeout remaining))
                   (sb-thread:condition-wait (%process-task-waitqueue task) (%process-task-mutex task))))
      (when (%process-task-condition task) (error (%process-task-condition task)))
      (values (%process-task-result task) t))))

(defun cancel-process (task)
  (check-type task process-task)
  (cancel (%process-task-token task))
  (sb-thread:with-mutex ((%process-task-queue-mutex task))
    (sb-thread:condition-broadcast (%process-task-queue-space task)))
  task)
