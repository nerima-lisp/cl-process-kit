;;;; t/spawn-test.lisp

(in-package #:cl-process-kit/test)

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

(it "spawn captures stdout via :output :stream for manual reading"
  (let ((process (spawn "/bin/sh" (list "-c" "printf hello") :output :stream)))
    (process-wait process)
    (expect (string= (read-line (sb-ext:process-output process) nil "")
                     "hello")
           :to-be-truthy)))
