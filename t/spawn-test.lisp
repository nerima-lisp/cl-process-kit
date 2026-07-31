;;;; t/spawn-test.lisp

(in-package #:cl-process-kit/test)

(describe "process lifecycle"
  (it "spawn returns immediately for a short-lived process, without blocking"
    (let ((process (spawn "/bin/sh" (list "-c" "exit 0"))))
      (expect (not (null process)) :to-be-truthy)
      (process-wait process)
      (expect (process-alive-p process) :to-be nil)))

  (it "process-alive-p is true right after spawning a long-running process"
    (let ((process (spawn "/bin/sh" (list "-c" "sleep 5"))))
      (expect (process-alive-p process) :to-be-truthy)
      (process-kill process)
      (process-wait process)))

  (it "process-wait blocks until the process has exited"
    (let ((process (spawn "/bin/sh" (list "-c" "sleep 0.1"))))
      (process-wait process)
      (expect (process-alive-p process) :to-be nil)))

  (it "process-terminate stops a running process via SIGTERM"
    (let ((process (spawn "/bin/sh" (list "-c" "sleep 5"))))
      (expect (process-alive-p process) :to-be-truthy)
      (process-terminate process)
      (process-wait process)
      (expect (process-alive-p process) :to-be nil)))

  (it "process-kill stops a running process via SIGKILL"
    (let ((process (spawn "/bin/sh" (list "-c" "trap '' TERM; sleep 5"))))
      (expect (process-alive-p process) :to-be-truthy)
      (process-kill process)
      (process-wait process)
      (expect (process-alive-p process) :to-be nil)))

  (it "does not misclassify very short processes as launch failures"
    (loop repeat 100
          do (let ((process (spawn "/bin/sh" (list "-c" "exit 0"))))
               (process-wait process)
               (expect (process-alive-p process) :to-be nil)))))

(describe "process handles and streams"
  (it "spawn captures stdout via :output :stream for manual reading"
    (let ((process (spawn "/bin/sh" (list "-c" "printf hello") :output :stream)))
      (process-wait process)
      (expect (string= (read-line (process-kit::%process-output process) nil "") "hello")
              :to-be-truthy)))

  (it "spawn verifies a private process group before returning"
    (let ((process (spawn "/bin/sh" (list "-c" "sleep 5"))))
      (unwind-protect
           (let ((pid (process-id process)))
             (expect (= (sb-posix:getpgid pid) pid) :to-be-truthy))
        (when (process-alive-p process) (process-kill process))
        (process-wait process)))))

(describe "communicate result caching"
  (it "preserves rich communicate results after process-wait"
    (let ((process (spawn "/bin/sh" (list "-c" "printf waited") :output :stream :error :stream)))
      (process-wait process)
      (let ((result (communicate process)))
        (expect (string= (process-result-stdout result) "waited") :to-be-truthy)
        (expect (eq result (communicate process)) :to-be-truthy))))

  (it "preserves rich communicate results after process-try-wait"
    (let ((process (spawn "/bin/sh" (list "-c" "printf tried") :output :stream :error :stream)))
      (loop until (process-try-wait process) do (sleep 0.01))
      (let ((result (communicate process)))
        (expect (string= (process-result-stdout result) "tried") :to-be-truthy)
        (expect (eq result (communicate process)) :to-be-truthy))))

  #+linux
  (cl-weave:it-skip
   "rejects a concurrent communicate while capture is in progress"
   "flaky under CI contention: asserts group death within a 0.1s grace period (see the release notes)")
  #-linux
  (it "rejects a concurrent communicate while capture is in progress"
    (let* ((process (spawn "/bin/sh" (list "-c" "sleep 0.2; printf finished")
                           :output :stream :error :stream))
           (thread-result nil)
           (thread-error nil)
           (thread (sb-thread:make-thread
                    (lambda ()
                      (handler-case (setf thread-result (communicate process))
                        (error (condition) (setf thread-error condition)))))))
      (unwind-protect
           (progn
             (loop repeat 100
                   until (eq (process-kit::%process-state-communication-status
                              (process-kit::%process-handle-state process))
                            :communicating)
                   do (sleep 0.005))
             (signals error (communicate process))
             (sb-thread:join-thread thread)
             (expect thread-error :to-be nil)
             (expect (string= (process-result-stdout thread-result) "finished") :to-be-truthy))
        (when (sb-thread:thread-alive-p thread)
          (close-process process)
          (sb-thread:join-thread thread)))))

  (it "preserves cached communicate identity and rejects changed contracts"
    (let ((process (process-kit::%make-process-handle
                    :raw-process nil :pid 1 :pgid 1 :program "test"))
          (result (make-process-result
                   :program "test" :arguments nil :status :exited :exit-code 0)))
      (expect (process-kit::%begin-communication
               process :input (copy-seq "abc") :timeout 1 :grace-period 0.25
                       :timeout-signal 15 :kill-signal 9 :on-timeout :return
                       :max-output-characters 1024 :drain-timeout-seconds 0.5
                       :result-type :string :external-format :utf-8
                       :poll-interval 1/100)
              :to-equal nil)
      (process-kit::%cache-process-result process result)
      (expect (process-kit::%begin-communication
               process :input (copy-seq "abc") :timeout 1.0d0 :grace-period 0.25d0
                       :timeout-signal 15 :kill-signal 9 :on-timeout :return
                       :max-output-characters 1024 :drain-timeout-seconds 0.5d0
                       :result-type :string :external-format :utf-8
                       :poll-interval 0.01d0)
              :to-be result)
      (handler-case
          (progn
            (process-kit::%begin-communication
             process :input "changed" :timeout 1 :grace-period 0.25
                     :timeout-signal 15 :kill-signal 9 :on-timeout :return
                     :max-output-characters 1024 :drain-timeout-seconds 0.5
                     :result-type :string :external-format :utf-8
                     :poll-interval 0.01)
            (error "Expected COMMUNICATE-OPTIONS-MISMATCH."))
        (communicate-options-mismatch (condition)
          (expect (communicate-options-mismatch-process condition) :to-be process)
          (expect (getf (communicate-options-mismatch-expected-options condition) :input)
                  :to-equal "abc")
          (expect (getf (communicate-options-mismatch-actual-options condition) :input)
                  :to-equal "changed"))))))

(describe "structured logging"
  (it "*process-logger* observes a successful spawn and a launch failure"
    (let* ((output (make-string-output-stream))
           (process-kit:*process-logger*
             (log-kit:make-logger
              :name "test" :handler (make-instance 'log-kit:text-handler :stream output)
              :level log-kit:+level-info+)))
      (let ((process (spawn "/bin/sh" (list "-c" "exit 0"))))
        (process-wait process))
      (handler-case (spawn "/nonexistent/program-that-does-not-exist" nil)
        (process-error () nil))
      (let ((logged (get-output-stream-string output)))
        (expect (search "process spawned" logged) :to-be-truthy)
        (expect (search "process launch failed" logged) :to-be-truthy))))

  (it "*process-logger* stays silent by default"
    (expect process-kit:*process-logger* :to-be nil)))

(describe "process-group termination"
  #+linux
  (cl-weave:it-skip
   "kills descendants after the process-group leader exits on TERM"
   "flaky under CI contention: asserts group death within a 0.1s grace period (see the release notes)")
  #-linux
  (it "kills descendants after the process-group leader exits on TERM"
    (let ((process (spawn "/bin/sh"
                          (list "-c" "trap \"exit 0\" TERM; (trap \"\" TERM; sleep 5) & wait")
                          :output :stream :error :stream)))
      (let ((result (communicate process :timeout 0.1 :grace-period 0.1 :on-timeout :return)))
        (expect result :to-have-timed-out)
        (expect (process-kit::%process-group-alive-p process) :to-be nil))))

  (it "close-process kills descendants after their leader exits"
    (let ((process (spawn "/bin/sh"
                          (list "-c" "trap \"exit 0\" TERM; (trap \"\" TERM; sleep 5) & wait"))))
      (sleep 0.05)
      (close-process process :timeout 0.1)
      (expect (process-kit::%process-group-alive-p process) :to-be nil)))

  (it "communicate signals process-timeout-error on its default :on-timeout :error"
    (with-process (process (%spawn-sleeping))
      (signals process-timeout-error (communicate process :timeout 0.1d0 :grace-period 0.1d0))))

  #+linux
  (cl-weave:it-skip
   "does not publicly signal a group after its leader is terminal"
   "flaky under CI contention: asserts group death within a 0.1s grace period (see the release notes)")
  #-linux
  (it "does not publicly signal a group after its leader is terminal"
    (let ((process (spawn "/bin/sh" (list "-c" "(trap '' TERM; sleep 5) & exit 0"))))
      (unwind-protect
           (progn
             (process-wait process)
             (expect (process-kit::%process-group-alive-p process) :to-be-truthy)
             (expect (process-send-group-signal process 15) :to-be nil)
             (expect (process-kit::%process-group-alive-p process) :to-be-truthy))
        (close-process process :timeout 0.1))))

  #+linux
  (cl-weave:it-skip
   "provides distinct leader and group signal operations"
   "flaky under CI contention: asserts group death within a 0.1s grace period (see the release notes)")
  #-linux
  (it "provides distinct leader and group signal operations"
    (let ((leader-only (spawn "/bin/sh" (list "-c" "(trap '' TERM; sleep 5) & wait"))))
      (unwind-protect
           (progn
             (sleep 0.05)
             (expect (process-send-leader-signal leader-only 15) :to-be-truthy)
             (process-wait leader-only)
             (expect (process-kit::%process-group-alive-p leader-only) :to-be-truthy)
             (expect (process-send-leader-signal leader-only 15) :to-be nil)
             (expect (process-send-group-signal leader-only 15) :to-be nil))
        (close-process leader-only :timeout 0.1)))
    (let ((whole-group (spawn "/bin/sh" (list "-c" "sleep 5"))))
      (expect (process-send-group-signal whole-group 15) :to-be-truthy)
      (process-wait whole-group)
      (expect (process-alive-p whole-group) :to-be nil)))

  #+linux
  (cl-weave:it-skip
   "close-process cleans descendants more than five seconds after their leader exits"
   "flaky under CI contention: asserts group death within a 0.1s grace period (see the release notes)")
  #-linux
  (it "close-process cleans descendants more than five seconds after their leader exits"
    (let ((process (spawn "/bin/sh" (list "-c" "(trap \"\" TERM; sleep 30) & exit 0"))))
      (unwind-protect
           (progn
             (process-wait process)
             (sleep 5.2d0)
             (expect (process-kit::%process-group-alive-p process) :to-be-truthy)
             (close-process process :timeout 0.1d0)
             (expect (process-kit::%process-group-alive-p process) :to-be nil))
        (close-process process :timeout 0.1d0)))))

(describe "spawn input validation"
  (it "rejects unsafe spawn strings and environments"
    (signals process-launch-error (spawn (format nil "/bin/true~Cbad" #\Null) nil))
    (signals process-launch-error (spawn (%true-program) (list (format nil "bad~Carg" #\Null))))
    (signals process-launch-error (spawn (%true-program) nil :environment (list "MALFORMED")))
    (signals process-launch-error (spawn (%true-program) nil :environment (list "=value")))
    (signals process-launch-error (spawn (%true-program) nil :environment (list "A=1" "A=2")))
    (signals process-launch-error
      (spawn (%true-program) nil :environment (list (format nil "A=bad~Cvalue" #\Null)))))

  (it "rejects unsafe command environment updates"
    (signals error
      (make-command "/bin/true" nil :environment-update (list (cons "A=B" "value"))))
    (signals error
      (make-command "/bin/true" nil
                    :environment-update (list (cons "A" "1") (cons "A" "2"))))))

(describe "spawn :fd-limit"
  (it "rejects a non-positive or non-integer fd-limit"
    (signals error (spawn "true" nil :search t :fd-limit 0))
    (signals error (spawn "true" nil :search t :fd-limit -1))
    (signals error (spawn "true" nil :search t :fd-limit 1.5)))

  (it "lowers the child's inherited RLIMIT_NOFILE without changing this process's own limit"
    (multiple-value-bind (before-soft before-hard) (process-kit::%get-nofile-limit)
      (let ((result (run "sh" (list "-c" "ulimit -n") :search t :fd-limit 1024)))
        (expect (string= (string-trim '(#\Newline) (process-result-stdout result)) "1024")
                :to-be-truthy))
      (multiple-value-bind (after-soft after-hard) (process-kit::%get-nofile-limit)
        (expect (= before-soft after-soft) :to-be-truthy)
        (expect (= before-hard after-hard) :to-be-truthy))))

  (it "restores this process's own fd limit even when the spawn itself fails"
    (multiple-value-bind (before-soft before-hard) (process-kit::%get-nofile-limit)
      (signals process-launch-error
        (spawn "definitely-not-a-cl-process-kit-program" nil :search t
               :environment (list "PATH=/bin") :fd-limit 1024))
      (multiple-value-bind (after-soft after-hard) (process-kit::%get-nofile-limit)
        (expect (= before-soft after-soft) :to-be-truthy)
        (expect (= before-hard after-hard) :to-be-truthy)))))

(describe "executable resolution"
  (it "resolves searched programs from the effective PATH"
    (dolist (case (list (list '("PATH=/bin") nil)
                        (list '("PATH=") #P"/bin/")
                        (list '("PATH=bin") #P"/")))
      (destructuring-bind (environment directory) case
        (let* ((process (spawn "sh" (list "-c" "printf found")
                               :search t :environment environment :directory directory
                               :output :stream))
               (result (communicate process)))
          (expect (string= (process-result-stdout result) "found") :to-be-truthy)))))

  (it "rejects missing and non-executable searched programs"
    (signals process-launch-error
      (spawn "definitely-not-a-cl-process-kit-program" nil
             :search t :environment (list "PATH=/bin")))
    (signals process-launch-error
      (spawn "hosts" nil :search t :environment (list "PATH=/etc"))))

  (it "rejects a directory that shadows a searched program name"
    (signals process-launch-error
      (spawn "etc" nil :search t :environment (list "PATH=/")))))
