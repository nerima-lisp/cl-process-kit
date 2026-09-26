(in-package #:cl-process-kit/test)

(it "launches through the native trampoline"
  (let* ((process (spawn-native "/bin/sh" (list "-c" "printf native") :output :stream))
         (result (communicate process)))
    (expect result :to-have-succeeded)
    (expect (process-result-stdout result) :to-equal "native")))

(it "reports native exec failures with a typed phase and errno"
  (handler-case
      (progn
        (spawn-native "/definitely/missing-cl-process-kit-program" nil)
        (error "Expected a native launch error."))
    (native-process-launch-error (condition)
      (expect (native-process-launch-error-phase condition) :to-be :exec)
      (expect (plusp (native-process-launch-error-errno condition)) :to-be-truthy))))

(it "reports a native chdir failure with a typed phase"
  (handler-case
      (progn
        (spawn-native "/bin/sh" nil :directory #P"/definitely/missing-cl-process-kit-directory/")
        (error "Expected a native launch error."))
    (native-process-launch-error (condition)
      (expect (native-process-launch-error-phase condition) :to-be :chdir)
      (expect (plusp (native-process-launch-error-errno condition)) :to-be-truthy))))

(defun %native-session-launch-report (options)
  "Launch a sleeping child through SPAWN-NATIVE with OPTIONS and return :OK
when it leads its own session and process group, or a description of the
launch failure or mismatch otherwise. The child is killed and reaped."
  (handler-case
      (let* ((process (apply #'spawn-native "sleep" (list "5")
                             :search t :environment (sb-ext:posix-environ) options))
             (pid (process-id process)))
        (unwind-protect
             (let ((pgid (sb-posix:getpgid pid))
                   (sid (sb-posix:getsid pid)))
               (if (= pid pgid sid) :ok (list :pid pid :pgid pgid :sid sid)))
          (process-kill process)
          (process-wait process)))
    (error (condition) (list (type-of condition) (princ-to-string condition)))))

;; The trampoline leaves the group run-program gave it and then calls
;; setsid; both halves once raced (a transient setsid EPERM in the child, and
;; SPAWN's group check observing the child mid-move), failing a few percent
;; of launches. One launch rarely shows it, so the case repeats enough
;; launches for that rate to surface.
(it "makes every :session and :detached child lead its own session and group"
  (let ((failures
          (loop for index below 100
                for options = (if (evenp index) '(:session t) '(:detached t))
                for report = (%native-session-launch-report options)
                unless (eq report :ok)
                  collect (list options report))))
    (expect failures :to-equal nil)))

(it "accepts :process-group 0 together with :detached"
  (expect (%native-session-launch-report '(:detached t :process-group 0)) :to-be :ok))
