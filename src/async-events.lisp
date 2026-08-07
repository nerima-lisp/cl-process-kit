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

(defun %task-next-sequence (task &optional event)
  "Return TASK's next sequence, or commit EVENT's sequence after delivery."
  (if event
      (setf (%process-task-next-sequence task)
            (process-event-sequence event))
      (1+ (%process-task-next-sequence task))))

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

(defun %flush-pending-drops-event (task &key block (cancelable-p t))
  "Try to publish TASK's pending overflow event.
When BLOCK is true, wait for channel capacity, optionally waking on
cancellation. Call with TASK's event lock already held."
  (when (plusp (%process-task-pending-drops task))
    (let ((event
            (%make-process-event
             :kind :overflow
             :sequence (%task-next-sequence task)
             :dropped-count (%process-task-pending-drops task))))
      (flet ((send-event (event)
               (handler-case
                   (if block
                       (if cancelable-p
                           (cl-concurrent-kit:select
                             ((cl-concurrent-kit:send
                               (%process-task-event-channel task) event)
                              ()
                              t)
                             ((cl-concurrent-kit:recv
                               (%process-task-cancellation-channel task))
                              ()
                              nil))
                           (progn
                             (cl-concurrent-kit:send
                              (%process-task-event-channel task) event)
                             t))
                       (cl-concurrent-kit:try-send
                        (%process-task-event-channel task) event))
                 (cl-concurrent-kit:channel-closed ()
                   nil))))
        (when (send-event event)
          (%task-next-sequence task event)
          (setf (%process-task-pending-drops task) 0)
          t)))))

(defun %task-submit-output (task kind octets)
  (let ((token (%process-task-token task))
        (block (eq (%process-task-overflow-policy task) :block)))
    (cl-concurrent-kit:with-lock-held
        ((%process-task-queue-mutex task))
      (when (cancellation-requested-p token)
        (return-from %task-submit-output nil))
      (when (and (plusp (%process-task-pending-drops task))
                 (not (%flush-pending-drops-event
                       task :block block :cancelable-p t)))
        (when block
          (return-from %task-submit-output nil)))
      (let* ((event
               (%make-process-event
                :kind kind
                :sequence (%task-next-sequence task)
                :octets octets))
             (sent-p
               (handler-case
                   (if block
                       (cl-concurrent-kit:select
                         ((cl-concurrent-kit:send
                           (%process-task-event-channel task) event)
                          ()
                          t)
                         ((cl-concurrent-kit:recv
                           (%process-task-cancellation-channel task))
                          ()
                          nil))
                       (cl-concurrent-kit:try-send
                        (%process-task-event-channel task) event))
                 (cl-concurrent-kit:channel-closed ()
                   nil))))
        (if sent-p
            (progn
              (%task-next-sequence task event)
              t)
            (if (or block (cancellation-requested-p token))
                nil
                (progn
                  (incf (%process-task-pending-drops task))
                  (sb-thread:with-mutex ((%process-task-mutex task))
                    (incf (%process-task-dropped-event-count task)))
                  nil)))))))

(defun %task-finish (task result condition)
  (cl-concurrent-kit:with-lock-held
      ((%process-task-queue-mutex task))
    ;; Keep terminal delivery after all output and overflow events in FIFO order.
    (%flush-pending-drops-event task :block t :cancelable-p nil)
    (let ((terminal
            (%make-process-event
             :kind :terminal
             :sequence (%task-next-sequence task)
             :result result
             :condition condition)))
      (setf (%process-task-terminal-event task) terminal)
      (cl-concurrent-kit:send (%process-task-event-channel task) terminal)
      (%task-next-sequence task terminal)
      (cl-concurrent-kit:close-channel
       (%process-task-event-channel task))
      (cl-concurrent-kit:close-channel
       (%process-task-cancellation-channel task))
      task)))

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
    (multiple-value-bind (event received-p)
        (cl-concurrent-kit:recv (%process-task-event-channel task))
      (unless received-p
        (return))
      (%task-record-and-callback task event)
      (when (eq (process-event-kind event) :terminal)
        (sb-thread:with-mutex ((%process-task-mutex task))
          (setf (%process-task-result task) (process-event-result event)
                (%process-task-condition task) (process-event-condition event)
                (%process-task-state task)
                (%classify-terminal-state event))
          (sb-thread:condition-broadcast (%process-task-waitqueue task)))
        (return)))))
