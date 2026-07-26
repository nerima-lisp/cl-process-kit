;;;; src/package.lisp

(eval-when (:compile-toplevel :load-toplevel :execute)
  (require :sb-posix))

(defpackage #:process-kit
  (:documentation
   "Running an external program and collecting what it did. Commands are
described declaratively as a COMMAND-SPEC — program, argv, environment policy,
stdio disposition, decoding — and executed with a deadline and a cancellation
token, so a hung child fails the caller rather than the build. Pipelines
compose specs without a shell.")
  (:use #:cl)
  (:export
   ;; command-spec: declarative program/argv/environment/stdio description
   #:command-spec #:command-p #:make-command
   #:command-program #:command-arguments #:command-search
   #:command-environment-policy #:command-environment-update #:command-directory
   #:command-stdin #:command-stdout #:command-stderr
   #:command-result-type #:command-external-format #:command-decoding-error-policy

   ;; cancellation
   #:cancellation-token #:make-cancellation-token #:cancel #:cancellation-requested-p

   ;; process-result / pipeline-result: synchronous outcome data
   #:make-process-result #:process-result
   #:process-result-program #:process-result-arguments #:process-result-pid
   #:process-result-status #:process-result-duration-seconds #:process-result-exit-code
   #:process-result-stdout #:process-result-stderr
   #:process-result-timed-out-p #:process-result-cancelled-p #:process-result-signal
   #:process-result-stdout-truncated-p #:process-result-stderr-truncated-p
   #:process-success-p
   #:pipeline-result
   #:pipeline-result-results #:pipeline-result-stdout #:pipeline-result-stderr
   #:pipeline-result-timed-out-p #:pipeline-result-cancelled-p #:pipeline-result-duration-seconds
   #:pipeline-success-p

   ;; conditions
   #:process-error
   #:process-launch-error
   #:process-launch-error-program #:process-launch-error-arguments
   #:process-launch-error-directory #:process-launch-error-cause
   #:process-exit-error #:process-exit-error-result
   #:pipeline-exit-error
   #:pipeline-exit-error-result #:pipeline-exit-error-stage-index #:pipeline-exit-error-stage-result
   #:process-timeout-error
   #:process-timeout-error-command #:process-timeout-error-args
   #:process-timeout-error-timeout #:process-timeout-error-result
   #:process-timeout-error-stage-index #:process-timeout-error-pipeline-result
   #:process-cancelled-error
   #:process-cancelled-error-result #:process-cancelled-error-stage-index
   #:process-cancelled-error-pipeline-result
   #:communicate-options-mismatch
   #:communicate-options-mismatch-process #:communicate-options-mismatch-expected-options
   #:communicate-options-mismatch-actual-options
   #:process-group-isolation-error
   #:process-group-isolation-error-pid #:process-group-isolation-error-pgid
   #:process-io-error #:process-io-error-stream #:process-io-error-cause

   ;; process-handle: the low-level asynchronous primitive
   #:spawn #:spawn-command
   #:process-handle #:process-id #:process-status
   #:process-stdin #:process-output #:process-stderr
   #:process-alive-p #:process-try-wait #:process-wait
   #:process-exit-code #:process-signal
   #:process-send-leader-signal #:process-send-group-signal
   #:process-terminate #:process-kill
   #:close-process-streams #:close-process #:with-process #:call-with-process

   ;; communicate: draining, feeding, and waiting on a process-handle
   #:communicate

   ;; process-event / process-task: the asynchronous event-stream API
   #:process-event
   #:process-event-kind #:process-event-sequence #:process-event-octets
   #:process-event-result #:process-event-condition #:process-event-dropped-count
   #:process-task #:communicate-async #:await-process #:cancel-process
   #:task-state #:task-result #:task-condition
   #:process-events #:next-process-event
   #:process-task-first-event-sequence #:process-task-last-event-sequence
   #:process-task-history-evicted-count
   #:callback-errors #:dropped-event-count

   ;; run / run-command / run-pipeline: the high-level synchronous entry points
   #:run #:run/checked #:run-shell
   #:run-command #:run-command-async #:run-command/checked
   #:run-pipeline #:run-pipeline/checked

   ;; native spawn trampoline
   #:spawn-native
   #:native-process-launch-error
   #:native-process-launch-error-phase #:native-process-launch-error-errno
   #:*native-spawn-program*

   ;; optional CL-LOG-KIT observability
   #:*process-logger*

   ;; CL-BOUNDARY-KIT clock/sleeper boundary defaults
   #:+default-clock+ #:+default-sleeper+))
