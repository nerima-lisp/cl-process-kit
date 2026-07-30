(in-package #:process-kit)

(defun %bounded-ring-push (ring start count value)
  (let ((capacity (length ring)))
    (if (zerop capacity)
        (values start count)
        (progn
          (setf (aref ring (mod (+ start count) capacity)) value)
          (if (< count capacity)
              (values start (1+ count))
              (values (mod (1+ start) capacity) count))))))

(defun %bounded-ring-contents (ring start count)
  (loop for offset below count collect (aref ring (mod (+ start offset) (length ring)))))

(defun %task-next-sequence (task) (incf (%process-task-next-sequence task)))

(defun %task-record-and-callback (task event)
  (sb-thread:with-mutex ((%process-task-mutex task))
    (let* ((ring (%process-task-events task))
           (capacity (length ring))
           (count (%process-task-event-history-count task))
           (evicted-p (or (zerop capacity) (= count capacity))))
      (multiple-value-bind (start new-count)
          (%bounded-ring-push ring (%process-task-event-history-start task) count event)
        (setf (%process-task-event-history-start task) start
              (%process-task-event-history-count task) new-count
              (%process-task-last-event-sequence task) (process-event-sequence event))
        (when evicted-p (incf (%process-task-history-evicted-count task)))
        (sb-thread:condition-broadcast (%process-task-waitqueue task)))))
  (let ((callback (%process-task-callback task)))
    (when callback
      (handler-case (funcall callback event)
        (condition (condition)
          (sb-thread:with-mutex ((%process-task-mutex task))
            (multiple-value-bind (start count)
                (%bounded-ring-push (%process-task-callback-errors task)
                                    (%process-task-callback-error-history-start task)
                                    (%process-task-callback-error-history-count task)
                                    condition)
              (setf (%process-task-callback-error-history-start task) start
                    (%process-task-callback-error-history-count task) count))))))))

(defun %flush-pending-drops-event (task)
  "If TASK has any pending dropped-event count and its queue currently has
room, push one :OVERFLOW PROCESS-EVENT summarizing them, reset the
counter, and notify a waiter. A no-op otherwise. Call with TASK's
queue-mutex already held. %TASK-SUBMIT-OUTPUT and %TASK-FINISH share this
exact flush shape, differing only in whether they wait for room first."
  (when (and (plusp (%process-task-pending-drops task))
             (< (%process-task-queue-count task) (%process-task-capacity task)))
    (push (%make-process-event :kind :overflow :sequence (%task-next-sequence task)
                               :dropped-count (%process-task-pending-drops task))
          (%process-task-queue task))
    (incf (%process-task-queue-count task))
    (setf (%process-task-pending-drops task) 0)
    (sb-thread:condition-notify (%process-task-queue-ready task))))

(defun %task-submit-output (task kind octets)
  (let ((token (%process-task-token task)))
    (sb-thread:with-mutex ((%process-task-queue-mutex task))
      (loop while (and (>= (%process-task-queue-count task) (%process-task-capacity task))
                       (eq (%process-task-overflow-policy task) :block)
                       (not (cancellation-requested-p token)))
            do (sb-thread:condition-wait (%process-task-queue-space task)
                                         (%process-task-queue-mutex task)))
      (when (cancellation-requested-p token) (return-from %task-submit-output nil))
      (%flush-pending-drops-event task)
      (if (>= (%process-task-queue-count task) (%process-task-capacity task))
          (progn
            (incf (%process-task-pending-drops task))
            (sb-thread:with-mutex ((%process-task-mutex task))
              (incf (%process-task-dropped-event-count task)))
            nil)
          (progn
            (push (%make-process-event :kind kind :sequence (%task-next-sequence task)
                                       :octets (copy-seq octets))
                  (%process-task-queue task))
            (incf (%process-task-queue-count task))
            (sb-thread:condition-notify (%process-task-queue-ready task))
            t)))))

(defun %task-finish (task result condition)
  (sb-thread:with-mutex ((%process-task-queue-mutex task))
    (loop while (and (plusp (%process-task-pending-drops task))
                     (>= (%process-task-queue-count task) (%process-task-capacity task)))
          do (sb-thread:condition-wait (%process-task-queue-space task)
                                       (%process-task-queue-mutex task)))
    (%flush-pending-drops-event task)
    (setf (%process-task-terminal-event task)
          (%make-process-event :kind :terminal :sequence (%task-next-sequence task)
                               :result result :condition condition)
          (%process-task-producer-finished-p task) t)
    (sb-thread:condition-broadcast (%process-task-queue-ready task))))

(defparameter +task-terminal-state-rules+
  (list (cons #'process-event-condition :failed)
        (cons (lambda (event)
                (let ((result (process-event-result event)))
                  (and result (process-result-cancelled-p result))))
              :cancelled))
  "Ordered (PREDICATE . STATE) data classifying a terminal PROCESS-EVENT into
PROCESS-TASK's final state. %CLASSIFY-TERMINAL-STATE is the only logic that
walks this table -- which predicate maps to which state lives here, as
data, separately from the traversal that applies it.")

(defun %classify-terminal-state (terminal-event)
  (or (cdr (assoc terminal-event +task-terminal-state-rules+
                  :test (lambda (event predicate) (funcall predicate event))))
      :completed))

(defun %task-dispatch (task)
  (loop
    (let (event terminal)
      (sb-thread:with-mutex ((%process-task-queue-mutex task))
        (loop while (and (null (%process-task-queue task))
                         (not (%process-task-producer-finished-p task)))
              do (sb-thread:condition-wait (%process-task-queue-ready task)
                                           (%process-task-queue-mutex task)))
        (if (%process-task-queue task)
            (progn
              (setf event (car (last (%process-task-queue task)))
                    (%process-task-queue task) (butlast (%process-task-queue task)))
              (decf (%process-task-queue-count task))
              (sb-thread:condition-broadcast (%process-task-queue-space task)))
            (setf terminal (%process-task-terminal-event task))))
      (when event (%task-record-and-callback task event))
      (when terminal
        (%task-record-and-callback task terminal)
        (sb-thread:with-mutex ((%process-task-mutex task))
          (setf (%process-task-result task) (process-event-result terminal)
                (%process-task-condition task) (process-event-condition terminal)
                (%process-task-state task) (%classify-terminal-state terminal))
          (sb-thread:condition-broadcast (%process-task-waitqueue task)))
        (return)))))
