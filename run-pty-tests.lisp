(require :asdf)

(let ((root (make-pathname :name nil :type nil :defaults (or *load-truename* *compile-file-truename* (error "Unable to determine script directory"))))) (asdf:load-asd (merge-pathnames "cl-process-kit.asd" root)) (asdf:load-system "cl-process-kit/pty-test") (unless (funcall (symbol-function (find-symbol "RUN-TESTS" "CL-PROCESS-KIT/PTY-TEST"))) (uiop:quit 1)) (uiop:quit 0))
