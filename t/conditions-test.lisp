;;;; t/conditions-test.lisp
;;;;
;;;; Every PROCESS-ERROR subtype's :REPORT function is user-facing output --
;;;; what a caller sees from (format nil "~A" condition) or an uncaught
;;;; error. These tests construct each condition directly via MAKE-CONDITION
;;;; and assert its report mentions the diagnostic details it promises,
;;;; instead of only exercising the (harder to reach, and often
;;;; timing-sensitive) real failure paths that signal them.

(in-package #:cl-process-kit/test)

(defun %sample-process-result (&key (status :exited) (exit-code 0) signal (program "prog"))
  (make-process-result :program program :arguments nil :status status :exit-code exit-code :signal signal))

(describe "condition reports"
  (it "process-launch-error reports the program"
    (let ((condition (make-condition 'process-launch-error
                                      :program "/bin/missing" :arguments nil :directory nil :cause nil)))
      (expect (search "/bin/missing" (princ-to-string condition)) :to-be-truthy)))

  (it "process-exit-error reports status, exit-code, and signal"
    (let ((condition (make-condition 'process-exit-error
                                      :result (%sample-process-result :exit-code 7))))
      (let ((report (princ-to-string condition)))
        (expect (search "EXITED" report) :to-be-truthy)
        (expect (search "7" report) :to-be-truthy))))

  (it "pipeline-exit-error reports the failed stage index and its result"
    (let ((condition (make-condition 'pipeline-exit-error
                                      :result nil :stage-index 2
                                      :stage-result (%sample-process-result :exit-code 3))))
      (let ((report (princ-to-string condition)))
        (expect (search "2" report) :to-be-truthy)
        (expect (search "3" report) :to-be-truthy))))

  (it "communicate-options-mismatch reports both option sets"
    (let ((condition (make-condition 'communicate-options-mismatch
                                      :process nil :expected-options '(:input "a") :actual-options '(:input "b"))))
      (let ((report (princ-to-string condition)))
        (expect (search "\"a\"" report) :to-be-truthy)
        (expect (search "\"b\"" report) :to-be-truthy))))

  (it "process-timeout-error reports the command and timeout"
    (let ((condition (make-condition 'process-timeout-error
                                      :command "/bin/sleep" :arguments (list "5") :timeout 1.5d0
                                      :result (%sample-process-result))))
      (let ((report (princ-to-string condition)))
        (expect (search "/bin/sleep" report) :to-be-truthy)
        (expect (search "1.5" report) :to-be-truthy))
      (expect (process-timeout-error-timeout condition) :to-equal 1.5d0)
      (expect (process-timeout-error-stage-index condition) :to-be nil)
      (expect (process-timeout-error-pipeline-result condition) :to-be nil)))

  (it "process-cancelled-error reports the cancelled program"
    (let ((condition (make-condition 'process-cancelled-error :result (%sample-process-result :program "cancelled-prog"))))
      (expect (search "cancelled-prog" (princ-to-string condition)) :to-be-truthy)
      (expect (process-cancelled-error-stage-index condition) :to-be nil)
      (expect (process-cancelled-error-pipeline-result condition) :to-be nil)))

  (it "process-group-isolation-error reports the pid and pgid"
    (let ((condition (make-condition 'process-group-isolation-error :pid 111 :pgid 222)))
      (let ((report (princ-to-string condition)))
        (expect (search "111" report) :to-be-truthy)
        (expect (search "222" report) :to-be-truthy))))

  (it "process-io-error reports the offending stream"
    (let ((condition (make-condition 'process-io-error :stream :stdout :cause nil)))
      (expect (search "STDOUT" (princ-to-string condition)) :to-be-truthy))))
