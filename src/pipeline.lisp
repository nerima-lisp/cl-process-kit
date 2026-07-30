;;;; src/pipeline.lisp
;;;;
;;;; RUN-PIPELINE wires N COMMAND-SPECs stdout-to-stdin, runs each stage's
;;;; COMMUNICATE concurrently on its own thread (so a downstream stage can
;;;; start consuming before an upstream one finishes producing), and
;;;; aggregates the per-stage PROCESS-RESULTs into one PIPELINE-RESULT.

(in-package #:process-kit)

(defun %make-pipe-streams ()
  (multiple-value-bind (read-fd write-fd) (sb-posix:pipe)
    (let ((read-stream nil) (write-stream nil) (completed-p nil))
      (unwind-protect
           (prog1
               (cons
                (setf read-stream
                      (sb-sys:make-fd-stream read-fd :input t
                                             :element-type '(unsigned-byte 8) :auto-close t))
                (setf write-stream
                      (sb-sys:make-fd-stream write-fd :output t
                                             :element-type '(unsigned-byte 8) :auto-close t)))
             (setf completed-p t))
        (unless completed-p
          (if read-stream (ignore-errors (close read-stream :abort t))
              (ignore-errors (sb-posix:close read-fd)))
          (if write-stream (ignore-errors (close write-stream :abort t))
              (ignore-errors (sb-posix:close write-fd))))))))

(defun %close-pipeline-streams (pipes)
  (dolist (pipe pipes)
    (ignore-errors (close (car pipe)))
    (ignore-errors (close (cdr pipe)))))

(defun %terminate-processes (processes grace-period)
  (labels ((clock () (/ (get-internal-real-time) internal-time-units-per-second))
           (alive-p (process) (handler-case (%process-group-alive-p process) (error () nil))))
    (dolist (process processes) (ignore-errors (process-terminate process)))
    (%poll-until (lambda () (notany #'alive-p processes))
                 (+ (clock) grace-period) +default-poll-interval+ #'clock #'sleep)
    (dolist (process processes)
      (when (alive-p process) (ignore-errors (process-kill process))))
    (let ((reap-deadline (+ (clock) grace-period)))
      (dolist (process processes)
        (ignore-errors (process-wait process :timeout (max 0 (- reap-deadline (clock)))))
        (ignore-errors (close-process-streams process))))))

(defun %spawn-pipeline-stages (commands pipes input grace-period)
  "Spawn each stage of COMMANDS wired stdout-to-stdin through PIPES --
INPUT feeds the first stage's stdin, and the last stage's stdout is left
as a pipe for the caller to drain. Returns the spawned PROCESS-HANDLEs in
stage order. On error partway through, terminates and reaps whatever had
already spawned before re-signaling."
  (let ((count (length commands)) (processes nil))
    (handler-case
        (loop for command in commands
              for index from 0
              for stdin = (if (zerop index) (if input :pipe nil) (car (nth (1- index) pipes)))
              for stdout = (if (= index (1- count)) :pipe (cdr (nth index pipes)))
              do (push (spawn-command command :stdin stdin :stdout stdout :stderr :pipe) processes))
      (error (condition)
        (%terminate-processes processes grace-period)
        (error condition)))
    (nreverse processes)))

(defun %build-pipeline-result (result-list commands timeout on-timeout on-cancel started clock)
  "Aggregate RESULT-LIST (one PROCESS-RESULT per stage, in stage order)
into a PIPELINE-RESULT. Signals PROCESS-TIMEOUT-ERROR or
PROCESS-CANCELLED-ERROR for the first timed-out/cancelled stage when
ON-TIMEOUT/ON-CANCEL is :ERROR; otherwise returns the PIPELINE-RESULT."
  (let* ((timed-out-stage-index (position-if #'process-result-timed-out-p result-list))
         (cancelled-stage-index (position-if #'process-result-cancelled-p result-list))
         (timed-out-p (not (null timed-out-stage-index)))
         (cancelled-p (not (null cancelled-stage-index)))
         (pipeline-result
           (make-pipeline-result
            :results result-list :stdout (process-result-stdout (car (last result-list)))
            :stderr (mapcar #'process-result-stderr result-list)
            :timed-out-p timed-out-p :cancelled-p cancelled-p
            :duration-seconds (- (funcall clock) started))))
    (cond
      ((and timed-out-p (eq on-timeout :error))
       (let* ((stage-index timed-out-stage-index)
              (stage-result (nth stage-index result-list))
              (stage-command (nth stage-index commands)))
         (error 'process-timeout-error
                :command (command-program stage-command)
                :arguments (command-arguments stage-command)
                :timeout timeout :result stage-result :stage-index stage-index
                :pipeline-result pipeline-result)))
      ((and cancelled-p (eq on-cancel :error))
       (let ((stage-index cancelled-stage-index))
         (error 'process-cancelled-error
                :result (nth stage-index result-list) :stage-index stage-index
                :pipeline-result pipeline-result))))
    pipeline-result))

(defun %communicate-pipeline-stage
    (process input timeout grace-period cancellation-token max-output-characters command)
  "Run one pipeline stage's COMMUNICATE and classify the outcome as
(VALUES RESULT NIL) on success or (VALUES NIL WORKER-ERROR) on failure. This
is the per-stage logic on its own, separated from the mutex-guarded
bookkeeping that RUN-PIPELINE's worker thread wraps around it."
  (handler-case
      (values (communicate process
                           :input input :timeout timeout :grace-period grace-period
                           :on-timeout :return :cancellation-token cancellation-token
                           :on-cancel :return :max-output-characters max-output-characters
                           :result-type (command-result-type command)
                           :external-format (command-external-format command)
                           :decoding-error-policy (command-decoding-error-policy command))
              nil)
    (condition (condition) (values nil condition))))

;;; Raised from inside AWAIT-PIPELINE-STAGES, nested deeply enough that the
;;; message cannot be written at its point of use and stay inside 100 columns.
(defparameter +pipeline-join-failure-message+
  "Pipeline worker thread did not terminate after process streams were closed.")

(defun run-pipeline (commands &key input timeout (grace-period 1.0d0) cancellation-token
                                (on-timeout :error) (on-cancel :error)
                                (max-output-characters +default-output-limit+))
  "Wire each of COMMANDS' stdout to the next one's stdin, run every stage's
COMMUNICATE concurrently on its own thread, and return one aggregated
PIPELINE-RESULT once every stage has finished. :TIMEOUT/:ON-TIMEOUT and
:CANCELLATION-TOKEN/:ON-CANCEL apply across the whole pipeline, not per
stage: a timeout or cancellation terminates every stage's process group,
not just whichever one was slow. See RUN-PIPELINE/CHECKED to signal
PIPELINE-EXIT-ERROR for the first failed stage instead of inspecting the
result."
  (%ensure (and (consp commands) (every #'command-p commands))
           "COMMANDS must be a non-empty proper list of command specifications.")
  (%validate-outcome-policy 'on-timeout on-timeout)
  (%validate-outcome-policy 'on-cancel on-cancel)
  (flet ((clock () (/ (get-internal-real-time) internal-time-units-per-second)))
    (let* ((started (clock))
           (count (length commands))
           (pipes nil)
           (processes nil)
           (results (make-array count :initial-element nil))
           (worker-errors (make-array count :initial-element nil))
           (completed-count 0)
           (state-lock (sb-thread:make-mutex :name "process-kit pipeline state")))
      (labels ((await-pipeline-stages (threads)
                 "Poll until every stage thread has recorded a result or one
signals a worker error, terminating the remaining stages on error; then
join every thread (escalating to a forced stream close, then signaling
PROCESS-IO-ERROR if a thread still won't join) before returning."
                 (let ((worker-error nil))
                   (loop
                     (sb-thread:with-mutex (state-lock)
                       (setf worker-error (find-if #'identity worker-errors))
                       (when (or worker-error (= completed-count count)) (return)))
                     (sleep +default-poll-interval+))
                   (when worker-error
                     (%log :error "pipeline stage failed, terminating pipeline"
                           :condition worker-error)
                     (%terminate-processes processes grace-period))
                   (let ((join-deadline (+ (clock) grace-period +default-drain-timeout-seconds+))
                         (cleanup-failure nil))
                     (dolist (thread threads)
                       (when (eq (sb-thread:join-thread thread
                                                        :timeout (max 0 (- join-deadline (clock)))
                                                        :default :timed-out)
                                 :timed-out)
                         (dolist (process processes)
                           (ignore-errors (close-process-streams process)))
                         (when (eq (sb-thread:join-thread thread :timeout +default-poll-interval+
                                                          :default :timed-out)
                                   :timed-out)
                           (setf cleanup-failure t))))
                     (when cleanup-failure
                       (error 'process-io-error
                              :stream :cleanup
                              :cause (make-condition
                                      'simple-error
                                      :format-control
                                      +pipeline-join-failure-message+))))
                   (when worker-error (error worker-error)))))
        (unwind-protect
             (progn
               (loop repeat (1- count) do (push (%make-pipe-streams) pipes))
               (setf pipes (nreverse pipes))
               (setf processes (%spawn-pipeline-stages commands pipes input grace-period))
               (%close-pipeline-streams pipes)
               (let ((threads
                       (loop for process in processes
                             for index from 0
                             for command in commands
                             collect
                             (sb-thread:make-thread
                              (let ((stage-process process) (stage-index index)
                                    (stage-command command))
                                (lambda ()
                                  (multiple-value-bind (result worker-error)
                                      (%communicate-pipeline-stage
                                       stage-process (and (zerop stage-index) input)
                                       timeout grace-period
                                       cancellation-token max-output-characters stage-command)
                                    (sb-thread:with-mutex (state-lock)
                                      (setf (aref results stage-index) result
                                            (aref worker-errors stage-index) worker-error)
                                      (incf completed-count)))))
                              :name "process-kit pipeline stage"))))
                 (await-pipeline-stages threads))
               (%build-pipeline-result (coerce results 'list) commands timeout
                                       on-timeout on-cancel started #'clock))
          (unless (every #'process-handle-reaped-p processes)
            (%terminate-processes processes grace-period))
          (%close-pipeline-streams pipes))))))

(defun run-pipeline/checked (commands &rest options)
  "Run COMMANDS and signal PIPELINE-EXIT-ERROR for the first failed stage."
  (let* ((result (apply #'run-pipeline commands options))
         (results (pipeline-result-results result))
         (stage-index (position-if-not #'process-success-p results)))
    (when stage-index
      (error 'pipeline-exit-error :result result :stage-index stage-index
             :stage-result (nth stage-index results)))
    result))
