;;;; src/run.lisp
;;;;
;;;; RUN is the high-level, synchronous entry point: spawn -> COMMUNICATE ->
;;;; return a PROCESS-RESULT (or signal PROCESS-TIMEOUT-ERROR/PROCESS-CANCELLED-ERROR).
;;;; RUN-COMMAND is its COMMAND-SPEC-driven counterpart, and RUN-COMMAND-ASYNC
;;;; is the COMMAND-SPEC-driven counterpart of COMMUNICATE-ASYNC.
(in-package #:process-kit)

(defun %valid-run-output-policy-p (policy)
  "A RUN OUTPUT policy names how a child fd is wired: :CAPTURE collects it into
the PROCESS-RESULT, :INHERIT lets the child write straight to this process's own
fd (live and uncaptured), and a STREAM sends it there. ERROR additionally
accepts :OUTPUT, merging stderr into wherever stdout goes."
  (or (member policy '(:capture :inherit) :test #'eq) (streamp policy)))

(defun %run-fd-target (policy)
  "Translate a RUN OUTPUT/ERROR POLICY into the fd target SPAWN passes to
RUN-PROGRAM: :STREAM to capture, T to inherit, or the policy itself for a stream
or the :OUTPUT (merge-into-stdout) marker."
  (case policy
    (:capture :stream)
    (:inherit t)
    (t policy)))

(defun %finalize-run-result (result program arguments timeout on-timeout on-cancel)
  "Attach PROGRAM and ARGUMENTS to RESULT, then apply RUN/RUN-COMMAND outcome
policies before returning it."
  (setf (process-result-program result) program
        (process-result-arguments result) arguments)
  (cond
    ((and (process-result-timed-out-p result) (eq on-timeout :error))
     (error
      'process-timeout-error
      :command
      program
      :arguments
      arguments
      :timeout
      timeout
      :result
      result))
    ((and (process-result-cancelled-p result) (eq on-cancel :error))
     (error 'process-cancelled-error :result result)))
  result)

(defun %run-base (command
                  arguments
                  &key
                  (search nil)
                  input
                  environment
                  directory
                  (output :capture)
                  ((:error error-policy) :capture)
                  timeout
                  (grace-period +default-grace-period-seconds+)
                  (poll-interval +default-poll-interval+)
                  (timeout-signal +default-timeout-signal+)
                  (kill-signal +default-kill-signal+)
                  (on-timeout :error)
                  cancellation-token
                  (on-cancel :error)
                  (max-output-characters +default-output-limit+)
                  (drain-timeout-seconds +default-drain-timeout-seconds+)
                  (result-type :string)
                  (external-format :default)
                  (decoding-error-policy :replace)
                  (clock +default-clock+)
                  (sleeper +default-sleeper+)
                  fd-limit)
  (%ensure
   (and (or (stringp command) (pathnamep command)) (plusp (length (namestring command))))
   "COMMAND must be a non-empty string or pathname.")
  (%ensure
   (and (listp arguments) (every #'stringp arguments))
   "ARGUMENTS must be a proper list of strings.")
  (%ensure (%valid-run-output-policy-p output) "OUTPUT must be :CAPTURE, :INHERIT, or a stream.")
  (%ensure
   (or (%valid-run-output-policy-p error-policy) (eq error-policy :output))
   "ERROR must be :CAPTURE, :OUTPUT, :INHERIT, or a stream.")
  (%validate-outcome-policy 'on-timeout on-timeout)
  (%validate-outcome-policy 'on-cancel on-cancel)
  (setf grace-period (or grace-period +default-grace-period-seconds+))
  (let* ((effective-environment (or environment (copy-list (sb-ext:posix-environ))))
         (process
          (spawn
           command
           arguments
           :search
           search
           :input
           (and input :stream)
           :output
           (%run-fd-target output)
           :error
           (%run-fd-target error-policy)
           :environment
           effective-environment
           :directory
           directory
           :external-format
           :latin-1
           :fd-limit
           fd-limit)))
    (unwind-protect (let ((result
                           (communicate
                            process
                            :input
                            input
                            :timeout
                            timeout
                            :grace-period
                            grace-period
                            :poll-interval
                            poll-interval
                            :timeout-signal
                            timeout-signal
                            :kill-signal
                            kill-signal
                            :on-timeout
                            :return
                            :cancellation-token
                            cancellation-token
                            :on-cancel
                            :return
                            :max-output-characters
                            max-output-characters
                            :drain-timeout-seconds
                            drain-timeout-seconds
                            :result-type
                            result-type
                            :external-format
                            external-format
                            :decoding-error-policy
                            decoding-error-policy
                            :clock
                            clock
                            :sleeper
                            sleeper)))
                      (%finalize-run-result result command arguments timeout on-timeout on-cancel))
      (unless (process-handle-reaped-p process)
        (ignore-errors (close-process process :terminate t :timeout grace-period)))
      (ignore-errors (close-process-streams process)))))

(defun run (command arguments &rest options)
  "Spawn COMMAND with ARGUMENTS and pass OPTIONS directly to %RUN-BASE."
  (apply #'%run-base command arguments options))

(defun run-shell (command &rest options)
  "Run COMMAND (a single shell command line) through \"/bin/sh -c\", with
the same OPTIONS as RUN. A convenience for a shell command string; RUN
itself never introduces a shell on its own."
  (apply #'run "/bin/sh" (list "-c" command) options))

(defun run/checked (command arguments &rest options)
  "Run COMMAND with ARGUMENTS and signal PROCESS-CANCELLED-ERROR or
PROCESS-EXIT-ERROR unless it succeeds."
  (let ((result (apply #'run command arguments options)))
    (cond
      ((process-result-cancelled-p result) (error 'process-cancelled-error :result result))
      ((not (process-success-p result)) (error 'process-exit-error :result result)))
    result))

(defun run-command (command
                    &key
                    input
                    timeout
                    (grace-period +default-grace-period-seconds+)
                    (on-timeout :error)
                    cancellation-token
                    (on-cancel :error)
                    (max-output-characters +default-output-limit+)
                    (drain-timeout-seconds +default-drain-timeout-seconds+))
  "Run COMMAND (a validated COMMAND-SPEC) and return a PROCESS-RESULT,
mirroring RUN but reading its I/O policy, environment, and search behavior
from the spec's own slots instead of keyword arguments. Prefer this over
RUN when a command is built once and reused, needs inspecting before
running, or is composed into a pipeline (see RUN-PIPELINE)."
  (check-type command command-spec)
  (%validate-outcome-policy 'on-timeout on-timeout)
  (%validate-outcome-policy 'on-cancel on-cancel)
  (with-process
   (process
    (spawn-command
     command
     :stdin
     (if input :pipe
       nil)))
   (let ((result
          (communicate
           process
           :input
           input
           :timeout
           timeout
           :grace-period
           grace-period
           :on-timeout
           :return
           :on-cancel
           :return
           :cancellation-token
           cancellation-token
           :max-output-characters
           max-output-characters
           :drain-timeout-seconds
           drain-timeout-seconds
           :result-type
           (command-result-type command)
           :external-format
           (command-external-format command)
           :decoding-error-policy
           (command-decoding-error-policy command))))
     (%finalize-run-result
      result
      (command-program command)
      (command-arguments command)
      timeout
      on-timeout
      on-cancel))))

(defun run-command-async (command &rest options)
  "Spawn COMMAND and return a PROCESS-TASK whose terminal event owns
stream cleanup. If communication setup fails after spawning, terminate and
reap the child before re-signaling the condition."
  (check-type command command-spec)
  (%ensure
   (not (member :cancellation-token options :test (function eq)))
   "RUN-COMMAND-ASYNC owns its cancellation token; cancel the returned task.")
  (let* ((input (getf options :input))
         (user-callback (getf options :event-callback))
         (process
          (spawn-command
           command
           :stdin
           (if input :pipe
             nil))))
    (handler-case (let ((communication-options
                         (%plist-without
                          options
                          (list
                           :event-callback
                           :result-type
                           :external-format
                           :decoding-error-policy))))
                    (apply
                     (function communicate-async)
                     process
                     (append
                      communication-options
                      (list
                       :result-type
                       (command-result-type command)
                       :external-format
                       (command-external-format command)
                       :decoding-error-policy
                       (command-decoding-error-policy command)
                       :event-callback
                       (lambda (event)
                         (when (eq (process-event-kind event) :terminal)
                           (close-process-streams process))
                         (when user-callback
                           (funcall user-callback event)))))))
      (condition (condition)
        (ignore-errors (close-process process :terminate t
                         :timeout +default-grace-period-seconds+))
        (error condition)))))

(defun run-command/checked (command &rest options)
  "Run COMMAND and signal PROCESS-EXIT-ERROR unless it succeeds."
  (let ((result (apply #'run-command command options)))
    (unless (process-success-p result)
      (error 'process-exit-error :result result))
    result))
