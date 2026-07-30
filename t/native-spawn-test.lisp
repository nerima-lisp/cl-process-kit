;;;; t/native-spawn-test.lisp

(in-package #:cl-process-kit/test)

(it "launches through the native trampoline" (let* ((process (spawn-native "/bin/sh" (list "-c" "printf native") :output :stream)) (result (communicate process))) (expect result :to-have-succeeded) (expect (process-result-stdout result) :to-equal "native")))

(it "reports native exec failures with a typed phase and errno" (handler-case (progn (spawn-native "/definitely/missing-cl-process-kit-program" nil) (error "Expected a native launch error.")) (native-process-launch-error (condition) (expect (native-process-launch-error-phase condition) :to-be :exec) (expect (plusp (native-process-launch-error-errno condition)) :to-be-truthy))))

(it "reports a native chdir failure with a typed phase" (handler-case (progn (spawn-native "/bin/sh" nil :directory #P"/definitely/missing-cl-process-kit-directory/") (error "Expected a native launch error.")) (native-process-launch-error (condition) (expect (native-process-launch-error-phase condition) :to-be :chdir) (expect (plusp (native-process-launch-error-errno condition)) :to-be-truthy))))
