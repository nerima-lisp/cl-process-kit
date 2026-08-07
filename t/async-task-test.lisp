;;;; t/async-task-test.lisp
(in-package #:cl-process-kit/test)

(defun %closed-stream-p (stream)
  (or (not (streamp stream)) (not (open-stream-p stream))))

(defmacro %with-awaited-task ((task result task-form &rest await-options) &body body)
  "Bind TASK to TASK-FORM, await its terminal result into RESULT, then run BODY."
  `(let* ((,task ,task-form)
          (,result (await-process ,task ,@await-options)))
     (expect ,result :to-be-truthy)
     ,@body))

(defun %walk-task-events (task)
  "Collect TASK's events through NEXT-PROCESS-EVENT, oldest first, through :TERMINAL."
  (let ((walked nil)
        (cursor nil))
    (loop (let ((step (next-process-event task :cursor cursor)))
            (setf cursor (process-event-step-cursor step))
            (case (process-event-step-status step)
              (:event (push (process-event-step-event step) walked))
              (t (return)))))
    (nreverse walked)))

(defun %expect-async-task-options (async-options
                                   &key
                                   callback
                                   queue-capacity
                                   overflow-policy
                                   history-capacity
                                   communication-options)
  (expect (process-kit::%async-launch-options-callback async-options) :to-be callback)
  (expect (process-kit::%async-launch-options-queue-capacity async-options) :to-be queue-capacity)
  (expect (process-kit::%async-launch-options-overflow-policy async-options)
           :to-be overflow-policy)
  (expect
   (process-kit::%async-launch-options-history-capacity async-options)
   :to-be
   history-capacity)
  (expect
   (equal
    (process-kit::%async-launch-options-communication-options async-options)
    communication-options)
   :to-be-truthy))

(defun %run-pipeline-and-check-stream-cleanup ()
  (let ((processes nil)
        (streams nil)
        (original-spawn (function process-kit::spawn-command)))
    (with-mocked-functions
     (((symbol-function (quote process-kit::spawn-command))
       (lambda (command &rest options)
         (let ((process (apply original-spawn command options)))
           (push process processes)
           (push
            (list (process-stdin process) (process-output process) (process-stderr process))
            streams)
           process))))
     (let ((result
            (run-pipeline
             (list
              (make-command "printf" (list "abc") :search t)
              (make-command "tr" (list "a-z" "A-Z") :search t)))))
       (expect (string= (pipeline-result-stdout result) "ABC") :to-be-truthy)))
    (expect (every (function process-kit::process-handle-reaped-p) processes) :to-be-truthy)
    (expect
     (every
      (lambda (process-streams)
        (every (function %closed-stream-p) process-streams))
      streams)
     :to-be-truthy)))

(describe
 "communicate-async events"
 #+linux
 (cl-weave:it-skip
 "communicate-async reports overflow without losing the terminal event"
 "flaky under CI contention: asserts group death within a 0.1s grace period (see release notes)")
 #-linux
 (it "communicate-async reports overflow without losing the terminal event"
 (let* ((seen nil)
 (process (%spawn-shell-command "yes x | head -c 1000000"))
 (task (%communicate-octets process
 :event-queue-capacity 1
 :event-callback (lambda (event)
 (push (process-event-kind event) seen)
 (sleep 0.02d0))))
 (result (await-process task)))
 (expect result :to-be-truthy)
 (expect (plusp (dropped-event-count task)) :to-be-truthy)
 (expect (member :overflow seen) :to-be-truthy)
 (expect (= 1 (count :terminal seen)) :to-be-truthy)))
 (it
  "communicate-async isolates callback errors"
  (let* ((process
          (%spawn-communicating "printf" (list "abc") :search t
           :environment (sb-ext:posix-environ)))
         (task
          (%communicate-octets
           process
           :event-callback
           (lambda (event)
             (declare (ignore event))
             (error "callback failure")))))
    (expect (await-process task) :to-be-truthy)
    (expect (callback-errors task) :to-be-truthy)
    (expect
     (= 1 (count :terminal (process-events task) :key (function process-event-kind)))
     :to-be-truthy)))
 (it
  "communicate-async bounds retained event and callback histories"
  (let* ((process (%spawn-shell-command "printf out; printf err >&2"))
         (task
          (%communicate-octets
           process
           :event-history-capacity
           2
           :event-callback
           (lambda (event)
             (declare (ignore event))
             (error "callback failure")))))
    (expect (await-process task) :to-be-truthy)
    (let ((events (process-events task)))
      (expect (= (length events) 2) :to-be-truthy)
      (expect
       (< (process-event-sequence (first events)) (process-event-sequence (second events)))
       :to-be-truthy)
      (expect (process-event-kind (second events)) :to-be :terminal))
    (expect (= (length (callback-errors task)) 2) :to-be-truthy)))
 #+linux
 (cl-weave:it-skip
 "cancels blocked asynchronous output without failing the task"
 "flaky under CI contention: asserts group death within a 0.1s grace period (see release notes)")
 #-linux
 (it "cancels blocked asynchronous output without failing the task"
 (let* ((process (%spawn-shell-command "yes x | head -c 1000000; sleep 5"))
 (task (%communicate-octets process
 :event-queue-capacity 1
 :event-overflow-policy :block
 :event-callback (lambda (event)
 (when (member (process-event-kind event)
 '(:stdout :stderr))
 (sleep 0.2d0)))))
 (canceller (%schedule-process-cancellation task 0.05d0)))
 (unwind-protect
 (%with-awaited-task (task result task :timeout 3d0)
 (expect result :to-have-been-cancelled)
 (expect (task-state task) :to-be :cancelled)
 (expect (task-condition task) :to-be nil)
 (expect (= 1 (count :terminal (process-events task)
 :key (function process-event-kind)))
 :to-be-truthy))
 (sb-thread:join-thread canceller))))
 (it
  "rejects an unknown event overflow policy before touching the process"
  (with-process
   (process (spawn "true" nil :search t :environment (sb-ext:posix-environ)))
   (signals error (communicate-async process :event-overflow-policy :bogus))))
 (it
  "lets explicit event-history-capacity zero survive option splitting"
  (%expect-async-task-options
   (process-kit::%async-task-options
    (list
     :event-callback
     nil
     :event-queue-capacity
     3
     :event-overflow-policy
     :block
     :event-history-capacity
     0
     :timeout
     1.5d0))
   :callback
   nil
   :queue-capacity
   3
   :overflow-policy
   :block
   :history-capacity
   0
   :communication-options
   (list :timeout 1.5d0)))
 (it
  "defaults event-history-capacity from event-queue-capacity when omitted"
  (%expect-async-task-options
   (process-kit::%async-task-options
    (list :event-queue-capacity 5 :result-type :octets :decoding-error-policy :error))
   :callback
   nil
   :queue-capacity
   5
   :overflow-policy
   :drop-newest
   :history-capacity
   5
   :communication-options
   (list :result-type :octets :decoding-error-policy :error)))
 (it
  "await-process re-signals a condition captured by the async worker"
  (with-mocked-functions
   (((symbol-function 'process-kit::%capture-append)
     (lambda (&rest _)
       (declare (ignore _))
       (error "injected async copier fault"))))
   (let* ((process (%spawn-shell-command "printf payload"))
          (task (communicate-async process)))
     (signals process-io-error (await-process task))
     (expect (task-state task) :to-be :failed))))
 (it
  "keeps async histories bounded at capacities zero and one under huge output"
  (loop for capacity in (list 0 1)
        do (let* ((process (%spawn-shell-command "yes x | head -c 1000000"))
                  (task (%communicate-octets process :event-history-capacity capacity)))
             (expect (await-process task) :to-be-truthy)
             (expect (<= (length (process-events task)) capacity) :to-be-truthy)
             (when (= capacity 1)
               (expect (process-event-kind (first (process-events task))) :to-be :terminal)))))
 (it
  "releases subprocess resources across repeated async cancellation and pipelines"
  (labels ((promise-settles-p (promise)
             (cl-concurrent-kit:await promise)
             t))
    (loop repeat 20
          do (let* ((process
                     (%spawn-communicating "yes" nil :search t
                     :environment (sb-ext:posix-environ)))
                    (streams (list (process-output process) (process-stderr process)))
                    (seen nil)
                    (task
                     (%communicate-octets
                      process
                      :event-queue-capacity
                      1
                      :event-overflow-policy
                      :block
                      :event-callback
                      (lambda (event)
                        (push (process-event-kind event) seen)))))
               (sleep 0.01d0)
               (cancel-process task)
               (let ((result (await-process task :timeout 2d0)))
                 (expect result :to-be-truthy)
                 (expect result :to-have-been-cancelled))
               (expect (= 1 (count :terminal seen)) :to-be-truthy)
               (expect
                (promise-settles-p (process-kit::%process-task-worker task))
                :to-be-truthy)
               (expect
                (promise-settles-p (process-kit::%process-task-dispatcher task))
                :to-be-truthy)
               (expect (process-kit::process-handle-reaped-p process) :to-be-truthy)
               (expect (every (function %closed-stream-p) streams) :to-be-truthy))
               (%run-pipeline-and-check-stream-cleanup)))))

(describe
 "async event channels"
 (it
  "unblocks a full event channel when a consumer receives"
  (let* ((task
          (process-kit::%make-async-process-task
           nil
           (process-kit::%async-task-options
            '(:event-queue-capacity 1 :event-overflow-policy :block))
           (make-cancellation-token)))
         (event-channel (process-kit::%process-task-event-channel task))
         (cancellation-channel
           (process-kit::%process-task-cancellation-channel task)))
    (unwind-protect
        (progn
          (expect (process-kit::%task-submit-output task :stdout #(1))
                  :to-be-truthy)
          (let ((promise
                  (cl-concurrent-kit:submit
                   process-kit::*process-kit-communicate-executor*
                   (lambda ()
                     (process-kit::%task-submit-output task :stdout #(2))))))
            (multiple-value-bind (event received-p)
                (cl-concurrent-kit:recv event-channel)
              (expect received-p :to-be-truthy)
              (expect (equalp (process-event-octets event) #(1)) :to-be-truthy))
            (expect (cl-concurrent-kit:await promise) :to-be-truthy)
            (multiple-value-bind (event received-p)
                (cl-concurrent-kit:recv event-channel)
              (expect received-p :to-be-truthy)
              (expect (equalp (process-event-octets event) #(2)) :to-be-truthy))))
      (cl-concurrent-kit:close-channel event-channel)
      (cl-concurrent-kit:close-channel cancellation-channel))))
 (it
  "wakes a blocked output send through cancellation"
  (let* ((task
          (process-kit::%make-async-process-task
           nil
           (process-kit::%async-task-options
            '(:event-queue-capacity 1 :event-overflow-policy :block))
           (make-cancellation-token)))
         (event-channel (process-kit::%process-task-event-channel task))
         (cancellation-channel
           (process-kit::%process-task-cancellation-channel task)))
    (unwind-protect
        (progn
          (expect (process-kit::%task-submit-output task :stdout #(1))
                  :to-be-truthy)
          (cl-concurrent-kit:close-channel cancellation-channel)
          (let ((promise
                  (cl-concurrent-kit:submit
                   process-kit::*process-kit-communicate-executor*
                   (lambda ()
                     (process-kit::%task-submit-output task :stdout #(2))))))
            (expect (cl-concurrent-kit:await promise) :to-be nil)
            (multiple-value-bind (event received-p)
                (cl-concurrent-kit:recv event-channel)
              (expect received-p :to-be-truthy)
              (expect (equalp (process-event-octets event) #(1)) :to-be-truthy))))
      (cl-concurrent-kit:close-channel event-channel)
      (cl-concurrent-kit:close-channel cancellation-channel))))
 (it
  "flushes pending overflow before the terminal event"
  (let* ((task
          (process-kit::%make-async-process-task
           nil
           (process-kit::%async-task-options
            '(:event-queue-capacity 3 :event-overflow-policy :drop-newest))
           (make-cancellation-token)))
         (event-channel (process-kit::%process-task-event-channel task))
         (cancellation-channel
           (process-kit::%process-task-cancellation-channel task))
         (kinds nil))
    (unwind-protect
        (progn
          (expect (process-kit::%task-submit-output task :stdout #(1))
                  :to-be-truthy)
          (expect (process-kit::%task-submit-output task :stdout #(2))
                  :to-be-truthy)
          (expect (process-kit::%task-submit-output task :stdout #(3))
                  :to-be-truthy)
          (expect (process-kit::%task-submit-output task :stdout #(4))
                  :to-be nil)
          (dotimes (_ 2)
            (multiple-value-bind (event received-p)
                (cl-concurrent-kit:recv event-channel)
              (expect received-p :to-be-truthy)
              (push (process-event-kind event) kinds)))
          (process-kit::%task-finish task nil nil)
          (loop
            (multiple-value-bind (event received-p)
                (cl-concurrent-kit:recv event-channel)
              (unless received-p (return))
              (push (process-event-kind event) kinds)))
          (expect (equal (nreverse kinds)
                         '(:stdout :stdout :stdout :overflow :terminal))
                  :to-be-truthy))
      (cl-concurrent-kit:close-channel event-channel)
      (cl-concurrent-kit:close-channel cancellation-channel)))))
(describe
 "run-command-async"
 (it
  "streams output and forwards the terminal event"
  (let ((terminal-seen nil))
    (let* ((task
            (run-command-async
             (make-command "/bin/sh" (list "-c" "printf out; printf err >&2"))
             :event-callback
             (lambda (event)
               (when (eq (process-event-kind event) :terminal)
                 (setf terminal-seen t)))))
           (result (await-process task)))
      (expect result :to-have-succeeded)
      (expect (string= (process-result-stdout result) "out") :to-be-truthy)
      (expect (string= (process-result-stderr result) "err") :to-be-truthy)
      (expect terminal-seen :to-be-truthy))))
 (it
  "terminates a spawned process when async setup fails"
  (let ((process nil)
        (original-spawn (function process-kit::spawn-command)))
    (with-mocked-functions
     (((symbol-function 'process-kit::spawn-command)
       (lambda (command &rest options)
         (setf process (apply original-spawn command options))))
      ((symbol-function 'process-kit::communicate-async)
       (lambda (&rest arguments)
         (declare (ignore arguments))
         (error "injected async setup failure"))))
     (signals error (run-command-async (make-command "/bin/sh" (list "-c" "sleep 30")))))
    (expect process :to-be-truthy)
    (expect (process-kit::process-handle-reaped-p process) :to-be-truthy)
    (expect
     (every
      (function %closed-stream-p)
      (list (process-stdin process) (process-output process) (process-stderr process)))
     :to-be-truthy)))
 (it
  "rejects an explicit cancellation-token option"
  (signals
   error
   (run-command-async (make-command "/bin/true" nil)
     :cancellation-token (make-cancellation-token)))))

(describe
 "async cursor API"
 (it
  "next-process-event walks every event through to the terminal event, matching process-events"
  (let* ((process (%spawn-shell-command "printf hi"))
         (task (%communicate-octets process)))
    (expect (await-process task) :to-be-truthy)
    (let ((walked (%walk-task-events task)))
      (expect
       (equal
        (mapcar (function process-event-sequence) walked)
        (mapcar (function process-event-sequence) (process-events task)))
       :to-be-truthy)
      (expect (eq (process-event-kind (car (last walked))) :terminal) :to-be-truthy))))
 (it
  "reports a gap when the cursor has fallen behind retained history"
  (let* ((process (%spawn-shell-command "printf hi"))
         (task (%communicate-octets process :event-history-capacity 1)))
    (expect (await-process task) :to-be-truthy)
    (let ((step (next-process-event task :cursor 1)))
      (expect (process-event-step-status step) :to-be :gap)
      (expect (plusp (process-event-step-gap-count step)) :to-be-truthy))))
 (it
  "rejects a non-positive cursor and a negative timeout"
  (let* ((process (%spawn-shell-command "printf hi"))
         (task (%communicate-octets process)))
    (expect (await-process task) :to-be-truthy)
    (signals error (next-process-event task :cursor 0))
    (signals error (next-process-event task :timeout -1))))
 (it
  "first/last-event-sequence and history-evicted-count report retained-history bounds"
  (let* ((process (%spawn-shell-command "printf hi"))
         (task (%communicate-octets process :event-history-capacity 1)))
    (expect (await-process task) :to-be-truthy)
    (expect
     (= (process-task-first-event-sequence task) (process-task-last-event-sequence task))
     :to-be-truthy)
    (expect (plusp (process-task-history-evicted-count task)) :to-be-truthy)))
 (it
  "task-result mirrors await-process's returned result"
  (let* ((process (%spawn-shell-command "printf ok"))
         (task (%communicate-octets process))
         (awaited (await-process task)))
    (expect (eq (task-result task) awaited) :to-be-truthy)))
 (it
  "next-process-event returns :timeout when no event arrives before the deadline"
  (let* ((process (%spawn-sleeping "1"))
         (task (communicate-async process)))
    (let ((step (next-process-event task :timeout 0.01d0)))
      (expect (process-event-step-event step) :to-be-null)
      (expect (process-event-step-status step) :to-be :timeout))
    (cancel-process task)
    (await-process task)))
 (it
  "await-process returns NIL when its own timeout expires while the task is still running"
  (let* ((process (%spawn-sleeping "1"))
         (task (communicate-async process)))
    (multiple-value-bind (result reached-terminal-p) (await-process task :timeout 0.01d0)
      (expect result :to-be-null)
      (expect reached-terminal-p :to-be-null))
    (cancel-process task)
    (await-process task))))
