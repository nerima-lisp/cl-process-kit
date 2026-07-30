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
  (let ((process (process-kit/pty:spawn-pty
                   (process-kit::make-command "/bin/sh" (list "-c" "printf %s $$")))))
    (unwind-protect
         (let* ((foreground-pgid (process-kit/pty:pty-foreground-pgid process))
                (pid (parse-integer (%octets-string (%read-to-eof process))))
                (result (process-kit/pty:pty-wait process :timeout 2)))
           (expect (= pid foreground-pgid) :to-be-truthy)
           (expect (= (process-kit::process-result-exit-code result) 0) :to-be-truthy))
      (process-kit/pty:pty-close process))))

(it "propagates terminal resize state"
  (let ((process (process-kit/pty:spawn-pty
                   (process-kit::make-command "/bin/sh" (list "-c" "read ready; stty size")))))
    (unwind-protect
         (progn
           (process-kit/pty:pty-resize process 41 113)
           (process-kit/pty:pty-write-string process (string #\Newline))
           (expect (search "41 113" (%octets-string (%read-to-eof process))) :to-be-truthy)
           (expect (= (process-kit::process-result-exit-code
                       (process-kit/pty:pty-wait process :timeout 2))
                      0)
                   :to-be-truthy))
      (process-kit/pty:pty-close process))))

(it "preserves raw octets"
  (let ((process (process-kit/pty:spawn-pty
                   (process-kit::make-command
                    "/bin/sh" (list "-c" "stty raw -echo; printf \"\\001\\377\"")))))
    (unwind-protect
         (progn
           (expect (equalp (%read-to-eof process) #(1 255)) :to-be-truthy)
           (expect (= (process-kit::process-result-exit-code
                       (process-kit/pty:pty-wait process :timeout 2))
                      0)
                   :to-be-truthy))
      (process-kit/pty:pty-close process))))

(it "sends the configured canonical EOF character"
  (let ((process (process-kit/pty:spawn-pty (process-kit::make-command "cat" nil :search t))))
    (unwind-protect
         (progn
           (process-kit/pty:pty-send-eof process)
           (expect (= (process-kit::process-result-exit-code
                       (process-kit/pty:pty-wait process :timeout 2))
                      0)
                   :to-be-truthy))
      (process-kit/pty:pty-close process))))

(it "signals only the validated foreground process group"
  (let ((process (process-kit/pty:spawn-pty
                   (process-kit::make-command "/bin/sh" (list "-c" "printf READY; exec sleep 5")))))
    (unwind-protect
         (progn
           (%read-exactly process 5)
           (process-kit/pty:pty-signal-foreground process 2)
           (let ((result (process-kit/pty:pty-wait process :timeout 2)))
             (expect (= (process-kit::process-result-signal result) 2) :to-be-truthy)))
      (process-kit/pty:pty-close process))))

(it "kills and reaps a session after timeout"
  (let ((process (process-kit/pty:spawn-pty
                   (process-kit::make-command "/bin/sh" (list "-c" "trap '' TERM; sleep 5")))))
    (unwind-protect
         (let ((result (process-kit/pty:pty-wait process :timeout 0.05)))
           (expect result :to-have-timed-out)
           (expect (= (process-kit::process-result-signal result) 9) :to-be-truthy)
           (expect (eq result (process-kit/pty:pty-wait process)) :to-be-truthy))
      (process-kit/pty:pty-close process))))
