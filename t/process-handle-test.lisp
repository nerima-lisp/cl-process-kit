;;;; t/process-handle-test.lisp

(in-package #:cl-process-kit/test)

(describe "process handle and command bookkeeping"
  (it "closes captured process streams after communicate"
    (let* ((process (spawn "/bin/sh" (list "-c" "printf out; printf err >&2")
                           :input :stream :output :stream :error :stream))
           (stdin (process-kit::process-stdin process))
           (stdout (process-output process))
           (stderr (process-stderr process))
           (result (communicate process)))
      (expect (string= (process-result-stdout result) "out") :to-be-truthy)
      (expect (open-stream-p stdin) :to-be nil)
      (expect (open-stream-p stdout) :to-be nil)
      (expect (open-stream-p stderr) :to-be nil)))

  (it "command environment policy reader returns deep copies"
    (let* ((source (list (copy-seq "KEY=original")))
           (command (make-command "/bin/true" nil :environment-policy source))
           (expected (command-environment-policy command))
           (first (command-environment-policy command)))
      (setf (char (car source) 4) #\X (char (car first) 5) #\X)
      (setf (car first) "KEY=changed")
      (expect (equal (command-environment-policy command) expected) :to-be-truthy)))

  (it "empty replacement environment never falls back to ambient PATH"
    (signals process-launch-error
      (run-command (make-command "sh" (list "-c" "printf hidden") :environment-policy nil)))
    (signals process-launch-error
      (run-command (make-command "sh" (list "-c" "printf hidden") :environment-policy nil :search t)))
    (let ((result (run-command (make-command "sh" (list "-c" "printf visible")
                                             :environment-policy (list "PATH=/bin:/usr/bin") :search t))))
      (expect (string= (process-result-stdout result) "visible") :to-be-truthy)))

  (it "command stdio distinguishes null and inherited streams"
    (expect (process-kit::%command-stdio :null :stdout) :to-be nil)
    (expect (process-kit::%command-stdio :inherit :stdout) :to-be t)
    (expect (process-kit::%command-stdio :null :stderr) :to-be nil)
    (expect (process-kit::%command-stdio :inherit :stderr) :to-be t)
    (let ((input (process-kit::%command-stdio :inherit :stdin)))
      (unwind-protect (expect (streamp input) :to-be-truthy) (close input)))))