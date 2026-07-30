;;;; t/pty-test.lisp

(in-package #:cl-process-kit/pty-test)

(defun %read-exactly (process count)
  (let ((output (make-array count :element-type '(unsigned-byte 8)))
        (offset 0))
    (loop while (< offset count)
          for chunk = (process-kit/pty:pty-read-octets process :size (- count offset))
          do (when (zerop (length chunk))
               (error "PTY reached EOF after ~D of ~D octets" offset count))
             (replace output chunk :start1 offset)
             (incf offset (length chunk)))
    output))

(defun %read-to-eof (process)
  (let ((chunks nil)
        (length 0))
    (loop for chunk = (process-kit/pty:pty-read-octets process)
          while (plusp (length chunk))
          do (push chunk chunks) (incf length (length chunk)))
    (let ((output (make-array length :element-type '(unsigned-byte 8)))
          (offset 0))
      (dolist (chunk (nreverse chunks) output)
        (replace output chunk :start1 offset)
        (incf offset (length chunk))))))

(defun %octets-string (octets)
  (sb-ext:octets-to-string octets :external-format :utf-8))

(defun run-tests ()
  (unless (run-all :reporter :spec)
    (error "cl-process-kit PTY test suite failed"))
  t)

(it "creates a controlling session with its own foreground process group"
  (process-kit/pty:with-pty-process
      (process (process-kit/pty:spawn-pty
                (process-kit::make-command "/bin/sh" (list "-c" "printf %s $$"))))
    (let* ((foreground-pgid (process-kit/pty:pty-foreground-pgid process))
           (pid (parse-integer (%octets-string (%read-to-eof process))))
           (result (process-kit/pty:pty-wait process :timeout 2)))
      (expect (= pid foreground-pgid) :to-be-truthy)
      (expect (= (process-kit::process-result-exit-code result) 0) :to-be-truthy))))

(it "propagates terminal resize state"
  (process-kit/pty:with-pty-process
      (process (process-kit/pty:spawn-pty
                (process-kit::make-command "/bin/sh" (list "-c" "read ready; stty size"))))
    (process-kit/pty:pty-resize process 41 113)
    (process-kit/pty:pty-write-string process (string #\Newline))
    (expect (search "41 113" (%octets-string (%read-to-eof process))) :to-be-truthy)
    (expect (= (process-kit::process-result-exit-code
                (process-kit/pty:pty-wait process :timeout 2))
               0)
            :to-be-truthy)))

(it "preserves raw octets"
  (process-kit/pty:with-pty-process
      (process (process-kit/pty:spawn-pty
                (process-kit::make-command
                 "/bin/sh" (list "-c" "stty raw -echo; printf \"\\001\\377\""))))
    (expect (equalp (%read-to-eof process) #(1 255)) :to-be-truthy)
    (expect (= (process-kit::process-result-exit-code
                (process-kit/pty:pty-wait process :timeout 2))
               0)
            :to-be-truthy)))

(it "sends the configured canonical EOF character"
  (process-kit/pty:with-pty-process
      (process (process-kit/pty:spawn-pty (process-kit::make-command "cat" nil :search t)))
    (process-kit/pty:pty-send-eof process)
    (expect (= (process-kit::process-result-exit-code
                (process-kit/pty:pty-wait process :timeout 2))
               0)
            :to-be-truthy)))

(it "signals only the validated foreground process group"
  (process-kit/pty:with-pty-process
      (process (process-kit/pty:spawn-pty
                (process-kit::make-command "/bin/sh" (list "-c" "printf READY; exec sleep 5"))))
    (%read-exactly process 5)
    (process-kit/pty:pty-signal-foreground process 2)
    (let ((result (process-kit/pty:pty-wait process :timeout 2)))
      (expect (= (process-kit::process-result-signal result) 2) :to-be-truthy))))

(it "kills and reaps a session after timeout"
  (process-kit/pty:with-pty-process
      (process (process-kit/pty:spawn-pty
                (process-kit::make-command "/bin/sh" (list "-c" "trap '' TERM; sleep 5"))))
    (let ((result (process-kit/pty:pty-wait process :timeout 0.05)))
      (expect result :to-have-timed-out)
      (expect (= (process-kit::process-result-signal result) 9) :to-be-truthy)
      (expect (eq result (process-kit/pty:pty-wait process)) :to-be-truthy))))

(it "pty-try-wait and pty-alive-p report liveness without blocking"
  (process-kit/pty:with-pty-process
      (process (process-kit/pty:spawn-pty
                (process-kit::make-command "/bin/sh" (list "-c" "sleep 0.2; exit 0"))))
    (expect (process-kit/pty:pty-try-wait process) :to-be-null)
    (expect (process-kit/pty:pty-alive-p process) :to-be-truthy)
    (let ((result (process-kit/pty:pty-wait process :timeout 2)))
      (expect (= (process-kit::process-result-exit-code result) 0) :to-be-truthy)
      (expect (eq (process-kit/pty:pty-try-wait process) result) :to-be-truthy)
      (expect (process-kit/pty:pty-alive-p process) :to-be nil))))
