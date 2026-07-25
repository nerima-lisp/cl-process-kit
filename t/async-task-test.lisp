;;;; t/async-task-test.lisp

(in-package #:cl-process-kit/test)

(defun %closed-stream-p (stream) (or (not (streamp stream)) (not (open-stream-p stream))))

(describe "communicate-async events"
  #+linux
  (cl-weave:it-skip "communicate-async reports overflow without losing the terminal event"
                    "known limitation: process-group/communicate timing is not guaranteed identical on Linux (see CHANGELOG)")
  #-linux
  (it "communicate-async reports overflow without losing the terminal event"
    (let* ((seen nil)
           (process (spawn "/bin/sh" (list "-c" "yes x | head -c 1000000") :output :stream :error :stream))
           (task (communicate-async process :result-type :octets
                                    :event-queue-capacity 1
                                    :event-callback (lambda (event)
                                                      (push (process-event-kind event) seen)
                                                      (sleep 0.02d0))))
           (result (await-process task)))
      (expect result :to-be-truthy)
      (expect (plusp (dropped-event-count task)) :to-be-truthy)
      (expect (member :overflow seen) :to-be-truthy)
      (expect (= 1 (count :terminal seen)) :to-be-truthy)))

  (it "communicate-async isolates callback errors"
    (let* ((process (spawn "printf" (list "abc") :output :stream :error :stream :search t :environment (sb-ext:posix-environ)))
           (task (communicate-async process :result-type :octets
                                    :event-callback (lambda (event)
                                                      (declare (ignore event))
                                                      (error "callback failure")))))
      (expect (await-process task) :to-be-truthy)
      (expect (callback-errors task) :to-be-truthy)
      (expect (= 1 (count :terminal (process-events task) :key (function process-event-kind))) :to-be-truthy)))

  (it "communicate-async bounds retained event and callback histories"
    (let* ((process (spawn "/bin/sh" (list "-c" "printf out; printf err >&2") :output :stream :error :stream))
           (task (communicate-async process :result-type :octets
                                    :event-history-capacity 2
                                    :event-callback (lambda (event)
                                                      (declare (ignore event))
                                                      (error "callback failure")))))
      (expect (await-process task) :to-be-truthy)
      (let ((events (process-events task)))
        (expect (= (length events) 2) :to-be-truthy)
        (expect (< (process-event-sequence (first events)) (process-event-sequence (second events))) :to-be-truthy)
        (expect (process-event-kind (second events)) :to-be :terminal))
      (expect (= (length (callback-errors task)) 2) :to-be-truthy)))

  #+linux
  (cl-weave:it-skip "cancels blocked asynchronous output without failing the task"
                    "known limitation: process-group/communicate timing is not guaranteed identical on Linux (see CHANGELOG)")
  #-linux
  (it "cancels blocked asynchronous output without failing the task"
    (let* ((process (spawn "/bin/sh" (list "-c" "yes x | head -c 1000000; sleep 5") :output :stream :error :stream))
           (task (communicate-async process :result-type :octets :event-queue-capacity 1 :event-overflow-policy :block
                                    :event-callback (lambda (event)
                                                      (when (member (process-event-kind event) '(:stdout :stderr))
                                                        (sleep 0.2d0)))))
           (canceller (sb-thread:make-thread (lambda () (sleep 0.05d0) (cancel-process task))
                                             :name "process-kit async cancellation test")))
      (unwind-protect
           (let ((result (await-process task :timeout 3d0)))
             (expect result :to-be-truthy)
             (expect (process-result-cancelled-p result) :to-be-truthy)
             (expect (task-state task) :to-be :cancelled)
             (expect (task-condition task) :to-be nil)
             (expect (= 1 (count :terminal (process-events task) :key (function process-event-kind))) :to-be-truthy))
        (sb-thread:join-thread canceller))))

  (it "rejects an unknown event overflow policy before touching the process"
    (with-process (process (spawn "true" nil :search t :environment (sb-ext:posix-environ)))
      (signals error (communicate-async process :event-overflow-policy :bogus))))

  (it "await-process re-signals a condition captured by the async worker"
    (with-mocked-functions
        (((symbol-function 'process-kit::%capture-append)
          (lambda (&rest _) (declare (ignore _)) (error "injected async copier fault"))))
      (let* ((process (spawn "/bin/sh" (list "-c" "printf payload") :output :stream :error :stream))
             (task (communicate-async process)))
        (signals process-io-error (await-process task))
        (expect (task-state task) :to-be :failed))))

  (it "keeps async histories bounded at capacities zero and one under huge output"
    (loop for capacity in (list 0 1)
          do (let* ((process (spawn "/bin/sh" (list "-c" "yes x | head -c 1000000") :output :stream :error :stream))
                    (task (communicate-async process :result-type :octets :event-history-capacity capacity)))
               (expect (await-process task) :to-be-truthy)
               (expect (<= (length (process-events task)) capacity) :to-be-truthy)
               (when (= capacity 1)
                 (expect (process-event-kind (first (process-events task))) :to-be :terminal)))))

  (it "releases subprocess resources across repeated async cancellation and pipelines"
    (labels ((thread-stops-p (thread)
               (let ((timed-out (gensym)))
                 (not (eq (sb-thread:join-thread thread :timeout 2d0 :default timed-out) timed-out)))))
      (loop repeat 20
            do (let* ((process (spawn "yes" nil :output :stream :error :stream :search t :environment (sb-ext:posix-environ)))
                      (streams (list (process-output process) (process-stderr process)))
                      (seen nil)
                      (task (communicate-async process :result-type :octets :event-queue-capacity 1
                                               :event-overflow-policy :block
                                               :event-callback (lambda (event) (push (process-event-kind event) seen)))))
                 (sleep 0.01d0)
                 (cancel-process task)
                 (let ((result (await-process task :timeout 2d0)))
                   (expect result :to-be-truthy)
                   (expect (process-result-cancelled-p result) :to-be-truthy))
                 (expect (= 1 (count :terminal seen)) :to-be-truthy)
                 (expect (thread-stops-p (process-kit::%process-task-worker task)) :to-be-truthy)
                 (expect (thread-stops-p (process-kit::%process-task-dispatcher task)) :to-be-truthy)
                 (expect (process-kit::process-handle-reaped-p process) :to-be-truthy)
                 (expect (every (function %closed-stream-p) streams) :to-be-truthy))
               (let ((processes nil) (streams nil) (original-spawn (function process-kit::spawn-command)))
                 (with-mocked-functions
                     (((symbol-function 'process-kit::spawn-command)
                       (lambda (command &rest options)
                         (let ((process (apply original-spawn command options)))
                           (push process processes)
                           (push (list (process-stdin process) (process-output process) (process-stderr process))
                                 streams)
                           process))))
                   (let ((result (run-pipeline (list (make-command "printf" (list "abc") :search t)
                                                     (make-command "tr" (list "a-z" "A-Z") :search t)))))
                     (expect (string= (pipeline-result-stdout result) "ABC") :to-be-truthy)))
                 (expect (every (function process-kit::process-handle-reaped-p) processes) :to-be-truthy)
                 (expect (every (lambda (process-streams) (every (function %closed-stream-p) process-streams)) streams)
                         :to-be-truthy))))))
(describe "run-command-async"
  (it "streams output and closes streams on the terminal event"
    (let* ((task (run-command-async (make-command "/bin/sh" (list "-c" "printf out; printf err >&2"))))
           (result (await-process task)))
      (expect (process-success-p result) :to-be-truthy)
      (expect (string= (process-result-stdout result) "out") :to-be-truthy)
      (expect (string= (process-result-stderr result) "err") :to-be-truthy)))

  (it "rejects an explicit cancellation-token option"
    (signals error
      (run-command-async (make-command "/bin/true" nil) :cancellation-token (make-cancellation-token)))))
(describe "async cursor API"
  (it "next-process-event walks every event through to the terminal event, matching process-events"
    (let* ((process (spawn "/bin/sh" (list "-c" "printf hi") :output :stream :error :stream))
           (task (communicate-async process :result-type :octets)))
      (expect (await-process task) :to-be-truthy)
      (let ((walked nil) (cursor nil))
        (loop
          (multiple-value-bind (event next-cursor status gap-count) (next-process-event task :cursor cursor)
            (declare (ignore gap-count))
            (setf cursor next-cursor)
            (case status
              (:event (push event walked))
              (t (return)))))
        (setf walked (nreverse walked))
        (expect (equal (mapcar (function process-event-sequence) walked)
                       (mapcar (function process-event-sequence) (process-events task)))
                :to-be-truthy)
        (expect (eq (process-event-kind (car (last walked))) :terminal) :to-be-truthy))))

  (it "reports a gap when the cursor has fallen behind retained history"
    (let* ((process (spawn "/bin/sh" (list "-c" "printf hi") :output :stream :error :stream))
           (task (communicate-async process :result-type :octets :event-history-capacity 1)))
      (expect (await-process task) :to-be-truthy)
      (multiple-value-bind (event next-cursor status gap-count) (next-process-event task :cursor 1)
        (declare (ignore event next-cursor))
        (expect status :to-be :gap)
        (expect (plusp gap-count) :to-be-truthy))))

  (it "rejects a non-positive cursor and a negative timeout"
    (let* ((process (spawn "/bin/sh" (list "-c" "printf hi") :output :stream :error :stream))
           (task (communicate-async process :result-type :octets)))
      (expect (await-process task) :to-be-truthy)
      (signals error (next-process-event task :cursor 0))
      (signals error (next-process-event task :timeout -1))))

  (it "first/last-event-sequence and history-evicted-count report retained-history bounds"
    (let* ((process (spawn "/bin/sh" (list "-c" "printf hi") :output :stream :error :stream))
           (task (communicate-async process :result-type :octets :event-history-capacity 1)))
      (expect (await-process task) :to-be-truthy)
      (expect (= (process-task-first-event-sequence task) (process-task-last-event-sequence task)) :to-be-truthy)
      (expect (plusp (process-task-history-evicted-count task)) :to-be-truthy)))

  (it "task-result mirrors await-process's returned result"
    (let* ((process (spawn "/bin/sh" (list "-c" "printf ok") :output :stream :error :stream))
           (task (communicate-async process :result-type :octets))
           (awaited (await-process task)))
      (expect (eq (task-result task) awaited) :to-be-truthy)))

  (it "next-process-event returns :timeout when no event arrives before the deadline"
    (let* ((process (%spawn-sleeping "1"))
           (task (communicate-async process)))
      (multiple-value-bind (event next-cursor status gap-count) (next-process-event task :timeout 0.01d0)
        (declare (ignore next-cursor gap-count))
        (expect event :to-be-null)
        (expect status :to-be :timeout))
      (cancel-process task)
      (await-process task)))

  (it "await-process returns NIL when its own timeout expires while the task is still running"
    (let* ((process (%spawn-sleeping "1"))
           (task (communicate-async process)))
      (multiple-value-bind (result reached-terminal-p) (await-process task :timeout 0.01d0)
        (expect result :to-be-null)
        (expect reached-terminal-p :to-be-null))
      (cancel-process task)
      (await-process task))))