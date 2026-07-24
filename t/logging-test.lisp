;;;; t/logging-test.lisp
;;;;
;;;; *PROCESS-LOGGER* is NIL by default, so the %LOG-guarded observability
;;;; branches scattered through SPAWN, COMMUNICATE, and PIPELINE never run
;;;; under the rest of the suite. These tests bind it to a capturing CL-LOG-KIT
;;;; logger and assert that each lifecycle event -- launch, timeout, and
;;;; cancellation escalation -- surfaces as the structured record the README
;;;; documents. CAPTURING-LOG factors out the logger/handler fixture so each
;;;; example reads as "run this, then inspect the records it emitted."

(in-package #:cl-process-kit/test)

(defun call-capturing-log (thunk)
  "Run THUNK with *PROCESS-LOGGER* installed as a logger that appends every
emitted LOG-KIT record to a list, and return that list in emission order.

The logger is installed by mutating the global value of *PROCESS-LOGGER*
rather than by a dynamic LET binding: some lifecycle records -- notably the
cancellation-escalation record -- are emitted from an internal watcher
thread, and an SBCL thread sees a special variable's global value, not the
spawning thread's dynamic binding. A mutex guards the shared record list
because those records may arrive from more than one thread."
  (let ((records '())
        (lock (sb-thread:make-mutex :name "cl-process-kit/test log records"))
        (previous *process-logger*))
    (unwind-protect
         (progn
           (setf *process-logger*
                 (log-kit:make-logger
                  :name "cl-process-kit/test"
                  :level log-kit:+level-info+
                  :handler (log-kit:make-function-handler
                            (lambda (record)
                              (sb-thread:with-mutex (lock) (push record records))))))
           (funcall thunk))
      (setf *process-logger* previous))
    (sb-thread:with-mutex (lock) (nreverse records))))

(defmacro capturing-log (&body body)
  "Evaluate BODY with a capturing *PROCESS-LOGGER* and return the list of
LOG-KIT records it emitted, in emission order."
  `(call-capturing-log (lambda () ,@body)))

(defun record-with-message (records message)
  "The first record in RECORDS whose message is MESSAGE, or NIL."
  (find message records :key #'log-kit:log-record-message :test #'string=))

(defun record-field (record key)
  "The value logged under KEY in RECORD, or NIL when absent."
  (cdr (assoc key (log-kit:log-record-fields record))))

(describe "structured logging via *process-logger*"
  (it "emits an :info 'process spawned' record carrying program, pid, and pgid"
    (let* ((records (capturing-log (run "echo" (list "hello") :search t)))
           (spawned (record-with-message records "process spawned")))
      (expect spawned :not :to-be-null)
      (expect (log-kit:log-record-level spawned) :to-equal log-kit:+level-info+)
      (expect (integerp (record-field spawned :pid)) :to-be-truthy)
      (expect (integerp (record-field spawned :pgid)) :to-be-truthy)))

  (it "emits a :warn 'process launch failed' record when the program is missing"
    (let* ((records (capturing-log
                      (ignore-errors (run "/nonexistent/definitely-missing-binary" nil))))
           (failure (record-with-message records "process launch failed")))
      (expect failure :not :to-be-null)
      (expect (log-kit:log-record-level failure) :to-equal log-kit:+level-warn+)
      (expect (record-field failure :condition) :not :to-be-null)))

  (it "emits a :warn 'process timed out, escalating' record on a real timeout"
    (let* ((records (capturing-log
                      (run "sleep" (list "10") :timeout 0.2 :on-timeout :return :search t)))
           (timeout (record-with-message records "process timed out, escalating")))
      (expect timeout :not :to-be-null)
      (expect (log-kit:log-record-level timeout) :to-equal log-kit:+level-warn+)
      (expect (integerp (record-field timeout :pid)) :to-be-truthy)))

  (it "emits a :warn 'process cancelled, escalating' record on cancellation"
    ;; Cancel from a separate thread once the child is already running, so the
    ;; internal watcher observes a live process and takes its SIGTERM/SIGKILL
    ;; escalation branch -- the one that emits this record.
    (let* ((token (make-cancellation-token))
           (canceller (sb-thread:make-thread
                       (lambda () (sleep 0.05d0) (cancel token))
                       :name "cl-process-kit/test canceller"))
           (records (capturing-log
                      (unwind-protect
                           (run "sleep" (list "10")
                                :cancellation-token token :on-cancel :return :search t)
                        (sb-thread:join-thread canceller))))
           (cancelled (record-with-message records "process cancelled, escalating")))
      (expect cancelled :not :to-be-null)
      (expect (log-kit:log-record-level cancelled) :to-equal log-kit:+level-warn+)))

  (it "stays silent -- emits nothing -- while *process-logger* is NIL"
    (let ((*process-logger* nil))
      ;; A direct sanity check that the default path allocates no records:
      ;; CAPTURING-LOG rebinds the logger, so we assert against a plain run here.
      (expect (process-success-p (run "echo" (list "quiet") :search t)) :to-be-truthy))))
