;;;; t/pipeline-test.lisp

(in-package #:cl-process-kit/test)

(describe "pipelines"
  (it "run-pipeline streams stdout between stages"
    (let ((result (run-pipeline (list (make-command "printf" (list "abc") :search t)
                                      (make-command "tr" (list "a-z" "A-Z") :search t)))))
      (expect result :to-have-succeeded)
      (expect (string= (pipeline-result-stdout result) "ABC") :to-be-truthy)
      (expect (= (length (pipeline-result-results result)) 2) :to-be-truthy)))

  (it "run-pipeline preserves arbitrary bytes across two stages"
    (let* ((octets (make-array 3 :element-type '(unsigned-byte 8) :initial-contents '(0 128 255)))
           (result (run-pipeline (list (make-command "cat" nil :result-type :octets :search t)
                                       (make-command "cat" nil :result-type :octets :search t))
                                 :input octets)))
      (expect result :to-have-succeeded)
      (expect (equalp (pipeline-result-stdout result) octets) :to-be-truthy)))

  (it "run-pipeline/checked reports the first failed stage"
    (handler-case
        (run-pipeline/checked (list (make-command "/bin/sh" (list "-c" "exit 3"))
                                    (make-command "/bin/sh" (list "-c" "exit 7"))))
      (pipeline-exit-error (condition)
        (let ((result (pipeline-exit-error-result condition))
              (stage-result (pipeline-exit-error-stage-result condition)))
          (expect (= (pipeline-exit-error-stage-index condition) 0) :to-be-truthy)
          (expect (= (process-result-exit-code stage-result) 3) :to-be-truthy)
          (expect (eq stage-result (first (pipeline-result-results result))) :to-be-truthy)))))

  (it "pipeline cleans up processes after partial startup"
    (let ((processes nil)
          (original (function process-kit::spawn-command)))
      (with-mocked-functions
          (((symbol-function 'process-kit::spawn-command)
            (lambda (command &rest options)
              (let ((process (apply original command options)))
                (push process processes)
                process))))
        (signals process-launch-error
          (run-pipeline (list (make-command "/bin/sh" (list "-c" "sleep 5"))
                              (make-command "/definitely/missing/process-kit-command" nil))
                        :grace-period 0.05d0)))
      (expect (every (function process-kit::process-handle-reaped-p) processes) :to-be-truthy)))

  (it "pipeline propagates worker errors after cleaning every process"
    (let ((processes nil)
          (original-spawn (function process-kit::spawn-command)))
      (with-mocked-functions
          (((symbol-function 'process-kit::spawn-command)
            (lambda (command &rest options)
              (let ((process (apply original-spawn command options)))
                (push process processes)
                process)))
           ((symbol-function 'process-kit::communicate)
            (lambda (process &rest options)
              (declare (ignore process options))
              (error "pipeline worker failure"))))
        (handler-case
            (run-pipeline (list (make-command "/bin/sh" (list "-c" "sleep 5"))
                                (make-command "/bin/sh" (list "-c" "sleep 5")))
                          :grace-period 0.05d0)
          (simple-error (condition)
            (expect (search "pipeline worker failure" (princ-to-string condition)) :to-be-truthy))))
      (expect (= (length processes) 2) :to-be-truthy)
      (expect (every (function process-kit::process-handle-reaped-p) processes) :to-be-truthy)))

  (it "attaches the matching stage and full pipeline result to timeout and cancellation conditions"
    (flet ((check-condition (condition expected-kind)
             (let* ((stage-index
                      (etypecase condition
                        (process-timeout-error (process-timeout-error-stage-index condition))
                        (process-cancelled-error (process-cancelled-error-stage-index condition))))
                    (stage-result
                      (etypecase condition
                        (process-timeout-error (process-timeout-error-result condition))
                        (process-cancelled-error (process-cancelled-error-result condition))))
                    (pipeline-result
                      (etypecase condition
                        (process-timeout-error
                          (process-timeout-error-pipeline-result condition))
                        (process-cancelled-error
                          (process-cancelled-error-pipeline-result condition)))))
               (expect (integerp stage-index) :to-be-truthy)
               (expect (= (length (pipeline-result-results pipeline-result)) 2) :to-be-truthy)
               (expect (eq stage-result (nth stage-index (pipeline-result-results pipeline-result)))
                       :to-be-truthy)
               (if (eq expected-kind :timeout)
                   (progn (expect stage-result :to-have-timed-out)
                          (expect pipeline-result :to-have-timed-out))
                   (progn (expect stage-result :to-have-been-cancelled)
                          (expect pipeline-result :to-have-been-cancelled)))
               (expect-not stage-result :to-have-succeeded)
               (expect-not pipeline-result :to-have-succeeded))))
      (handler-case
          (run-pipeline (list (make-command "/bin/sh" (list "-c" "trap \"\" TERM; sleep 5"))
                              (make-command "cat" nil :search t))
                        :timeout 0.1d0 :grace-period 0.1d0 :on-timeout :error)
        (process-timeout-error (condition) (check-condition condition :timeout)))
      (let* ((token (make-cancellation-token))
             (canceller
               (sb-thread:make-thread (lambda () (sleep 0.1d0) (cancel token))
                                      :name "process-kit pipeline condition cancellation test")))
        (unwind-protect
             (handler-case
                 (run-pipeline (list (make-command "/bin/sh" (list "-c" "trap \"\" TERM; sleep 5"))
                                     (make-command "cat" nil :search t))
                               :cancellation-token token :grace-period 0.1d0 :on-cancel :error)
               (process-cancelled-error (condition) (check-condition condition :cancel)))
          (sb-thread:join-thread canceller))))))