;;;; t/run-test.lisp
;;;;
;;;; RUN/RUN-COMMAND's non-timeout behavior: environment/directory handling,
;;;; stdio policies, and output capture/encoding. Timeout/SIGTERM->SIGKILL
;;;; escalation and cancellation-token handling live in
;;;; run-timeout-test.lisp.

(in-package #:cl-process-kit/test)

(describe "run-command"
  (it "run-command distinguishes an empty replacement environment"
    ;; :environment-policy nil below deliberately gives the child (and thus
    ;; :search's own PATH lookup) an empty environment, so the program must
    ;; already be resolved to an absolute path via the real environment
    ;; before the command is built, rather than via :search t.
    (let* ((env-program (process-kit::%resolve-executable "env" nil (sb-ext:posix-environ) nil))
           (result (run-command (make-command (namestring env-program) nil :environment-policy nil))))
      (expect (string= (process-result-stdout result) "") :to-be-truthy)))

  (it "run-command applies environment updates and deletions"
    (let* ((command (make-command "/bin/sh" (list "-c" "printf %s:${DROP+present} \"$KEEP\"")
                                  :environment-policy (list "KEEP=old" "DROP=yes")
                                  :environment-update (list (cons "KEEP" "new") (cons "DROP" nil))))
           (result (run-command command)))
      (expect (string= (process-result-stdout result) "new:") :to-be-truthy)))

  (it "run-command merges stderr into stdout"
    (let ((result (run-command (make-command "/bin/sh" (list "-c" "printf out; printf err >&2") :stderr :stdout))))
      (expect (string= (process-result-stdout result) "outerr") :to-be-truthy)
      (expect (string= (process-result-stderr result) "") :to-be-truthy)))

  (it "run-command cancels a blocked stdin write"
    (let* ((token (make-cancellation-token))
           (input (make-string (* 1024 1024) :initial-element (code-char 120))))
      (sb-thread:make-thread (lambda () (sleep 0.1d0) (cancel token)) :name "process-kit cancellation test")
      (let ((result (run-command (make-command "/bin/sh" (list "-c" "trap \"\" TERM; sleep 5"))
                                 :input input :cancellation-token token :grace-period 0.1d0 :on-cancel :return)))
        (expect (process-result-cancelled-p result) :to-be-truthy)
        (expect (= (process-result-signal result) 9) :to-be-truthy)
        (expect (process-success-p result) :to-be nil))))

  (it "run-command/checked returns a successful command result"
    (let ((result (run-command/checked (make-command "/bin/sh" (list "-c" "printf ok")))))
      (expect (process-success-p result) :to-be-truthy)
      (expect (string= (process-result-stdout result) "ok") :to-be-truthy)))

  (it "run-command/checked signals process-exit-error"
    (handler-case (run-command/checked (make-command "/bin/sh" (list "-c" "exit 6")))
      (process-exit-error (condition)
        (expect (= (process-result-exit-code (process-exit-error-result condition)) 6) :to-be-truthy))))

  (it "run-command signals process-timeout-error on its default :on-timeout :error"
    (signals process-timeout-error
      (run-command (make-command "/bin/sh" (list "-c" "sleep 5")) :timeout 0.2d0 :grace-period 0.1d0)))

  (it "run-command signals process-cancelled-error on its default :on-cancel :error"
    (let* ((token (make-cancellation-token)))
      (sb-thread:make-thread (lambda () (sleep 0.1d0) (cancel token)) :name "process-kit cancellation test")
      (signals process-cancelled-error
        (run-command (make-command "/bin/sh" (list "-c" "trap \"\" TERM; sleep 5"))
                     :cancellation-token token :grace-period 0.1d0)))))

(describe "run basics"
  (it "run captures stdout and a zero exit-code on success"
    (let ((result (run "echo" (list "hello") :search t)))
      (expect (= (process-result-exit-code result) 0) :to-be-truthy)
      (expect (string= (process-result-stdout result) (format nil "hello~%")) :to-be-truthy)
      (expect (process-result-timed-out-p result) :to-be nil)
      (expect (process-result-signal result) :to-be nil)))

  (it "run reports a non-zero exit-code"
    (let ((result (run "/bin/sh" (list "-c" "exit 3"))))
      (expect (= (process-result-exit-code result) 3) :to-be-truthy)))

  (cl-weave:it-property "run reports exactly the requested exit code, for any code in [0, 255]"
      ((code (cl-weave:gen-integer :min 0 :max 255)))
    (let ((result (run "/bin/sh" (list "-c" (format nil "exit ~D" code)))))
      (expect (process-result-timed-out-p result) :to-be nil)
      (expect (= (process-result-exit-code result) code) :to-be-truthy)
      (expect (process-success-p result) :to-equal (zerop code))))

  (it "run captures stderr separately from stdout"
    (let ((result (run "/bin/sh" (list "-c" "echo out; echo err 1>&2"))))
      (expect (string= (process-result-stdout result) (format nil "out~%")) :to-be-truthy)
      (expect (string= (process-result-stderr result) (format nil "err~%")) :to-be-truthy)))

  (it "run forwards a string INPUT to the child's standard input"
    (let ((result (run "cat" nil :input "piped-in" :search t)))
      (expect (string= (process-result-stdout result) "piped-in") :to-be-truthy)))

  (it "run does not search PATH unless explicitly requested"
    (signals error (run "echo" (list "hidden")))
    (let ((result (run "echo" (list "visible") :search t)))
      (expect (string= (process-result-stdout result) (format nil "visible~%")) :to-be-truthy)))

  (it "preserves a searched executable symlink as argv zero"
    (let* ((directory (merge-pathnames (format nil "cl-process-kit-~A/" (gensym)) (uiop:temporary-directory)))
           (target (merge-pathnames "target-script" directory))
           (alias (merge-pathnames "applet" directory)))
      (unwind-protect
           (progn
             (ensure-directories-exist target)
             (with-open-file (stream target :direction :output :if-exists :supersede)
               (format stream "#!/bin/sh~%printf %s \"$0\"~%"))
             (sb-posix:chmod (namestring target) #o755)
             (sb-posix:symlink (namestring target) (namestring alias))
             (let ((result (run "applet" nil
                                :environment (list (format nil "PATH=~A" (namestring directory))) :search t)))
               (expect (string= (process-result-stdout result) (namestring alias)) :to-be-truthy)))
        (uiop:delete-directory-tree directory :validate t :if-does-not-exist :ignore))))

  (it "run rejects inherited standard input because it cannot be isolated"
    (signals error (run "cat" nil :input t :search t)))

  (it "run rejects a clock that does not implement the CL-BOUNDARY-KIT protocol"
    (signals error (run "/bin/true" nil :clock :not-a-clock)))

  (it "run rejects a sleeper that does not implement the CL-BOUNDARY-KIT protocol"
    (signals error (run "/bin/true" nil :sleeper :not-a-sleeper)))

  (it "run-shell executes a command through the shell"
    (let ((result (run-shell "printf shell")))
      (expect (string= (process-result-stdout result) "shell") :to-be-truthy)))

  (it "run supports an unlimited drain deadline"
    (let ((result (run "/bin/sh" (list "-c" "printf complete") :drain-timeout-seconds nil)))
      (expect (string= (process-result-stdout result) "complete") :to-be-truthy)))

  (it "run replaces the environment and directory"
    (let* ((directory #P"/tmp/")
           (result (run "/bin/sh"
                        (list "-c" "printf '%s:%s:%s' \"$ONLY\" \"$PWD\" \"${HOME+inherited}\"")
                        :environment (list "ONLY=yes" "PATH=/usr/bin:/bin")
                        :directory directory))
           (expected (format nil "yes:~A:" (string-right-trim "/" (namestring (truename directory))))))
      (expect (string= (process-result-stdout result) expected) :to-be-truthy)))

  (it "run can merge stderr into stdout"
    (let ((result (run "/bin/sh" (list "-c" "printf out; printf err >&2") :error :output)))
      (expect (string= (process-result-stdout result) "outerr") :to-be-truthy)
      (expect (string= (process-result-stderr result) "") :to-be-truthy)))

  (it "run with :output :inherit leaves stdout to the parent fd rather than capturing"
    ;; The child's stdout goes straight to this process's fd (nothing to assert
    ;; on that here); RUN still enforces the timeout and reports the exit code,
    ;; and the captured stdout is empty because nothing was drained.
    (let ((result (run "/bin/sh" (list "-c" "printf ignored; exit 0")
                       :output :inherit :error :inherit)))
      (expect (string= (process-result-stdout result) "") :to-be-truthy)
      (expect (string= (process-result-stderr result) "") :to-be-truthy)
      (expect (zerop (process-result-exit-code result)) :to-be-truthy)))

  (it "run with :error :inherit still captures stdout but not stderr"
    (let ((result (run "/bin/sh" (list "-c" "printf out; printf err >&2")
                       :output :capture :error :inherit)))
      (expect (string= (process-result-stdout result) "out") :to-be-truthy)
      (expect (string= (process-result-stderr result) "") :to-be-truthy)))

  (it "run sends stdout to a caller-provided stream instead of capturing it"
    (uiop:with-temporary-file (:pathname path)
      (with-open-file (stream path :direction :output :if-exists :supersede)
        (let ((result (run "/bin/sh" (list "-c" "printf streamed") :output stream)))
          (expect (string= (process-result-stdout result) "") :to-be-truthy)
          (expect (zerop (process-result-exit-code result)) :to-be-truthy)))
      (expect (string= (uiop:read-file-string path) "streamed") :to-be-truthy)))

  (it "run rejects an unknown :output policy before spawning"
    (expect (lambda () (run "/bin/sh" (list "-c" "true") :output :bogus))
            :to-throw 'error))

  (it "run/checked signals a typed error retaining the result"
    (handler-case (run/checked "/bin/sh" (list "-c" "printf failed >&2; exit 7"))
      (process-exit-error (condition)
        (let ((result (process-exit-error-result condition)))
          (expect (= (process-result-exit-code result) 7) :to-be-truthy)
          (expect (string= (process-result-stderr result) "failed") :to-be-truthy)))))

  (it "run/checked signals process-cancelled-error on its default :on-cancel :error"
    (let* ((token (make-cancellation-token)))
      (sb-thread:make-thread (lambda () (sleep 0.1d0) (cancel token)) :name "process-kit cancellation test")
      (signals process-cancelled-error
        (run/checked "/bin/sh" (list "-c" "trap \"\" TERM; sleep 5")
                     :cancellation-token token :grace-period 0.1d0)))))

(describe "run output capture and encoding"
  (it "run caps both output streams without pipe deadlock"
    (let ((result (run "/bin/sh"
                       (list "-c" "i=0; while [ $i -lt 1000 ]; do printf x; printf y >&2; i=$((i+1)); done")
                       :max-output-characters 32)))
      (expect (= (length (process-result-stdout result)) 32) :to-be-truthy)
      (expect (= (length (process-result-stderr result)) 32) :to-be-truthy)
      (expect (process-result-stdout-truncated-p result) :to-be-truthy)
      (expect (process-result-stderr-truncated-p result) :to-be-truthy)))

  (it "run captures arbitrary bytes as octets"
    (let ((result (run "/bin/sh" (list "-c" "printf '\\000\\200\\377'") :result-type :octets)))
      (expect (equalp (process-result-stdout result)
                      (make-array 3 :element-type '(unsigned-byte 8) :initial-contents '(0 128 255)))
              :to-be-truthy)))

  (it "writes octet input without character-stream re-encoding"
    (let* ((input (make-array 4 :element-type '(unsigned-byte 8) :initial-contents '(0 127 128 255)))
           (result (run "cat" nil :input input :result-type :octets :search t)))
      (expect (equalp (process-result-stdout result) input) :to-be-truthy)))

  (it "run decodes UTF-8 after a multibyte sequence crosses a read boundary"
    (let* ((prefix (make-string 4095 :initial-element (code-char 97)))
           (expected (concatenate 'string prefix (string (code-char #xE9))))
           (result (run "/bin/sh"
                        (list "-c" "i=0; while [ $i -lt 4095 ]; do printf a; i=$((i+1)); done; printf '\\303\\251'")
                        :external-format :utf-8)))
      (expect (string= (process-result-stdout result) expected) :to-be-truthy)))

  (it "limits UTF-8 output by complete characters"
    (dolist (entry '(("\\303\\251x" . #xE9) ("\\342\\230\\203x" . #x2603) ("\\360\\237\\230\\200x" . #x1F600)))
      (let ((result (run "/bin/sh" (list "-c" (format nil "printf '~A'" (car entry)))
                         :external-format :utf-8 :max-output-characters 1)))
        (expect (string= (process-result-stdout result) (string (code-char (cdr entry)))) :to-be-truthy)
        (expect (process-result-stdout-truncated-p result) :to-be-truthy))))

  (it "run encodes string input at the API boundary"
    (let* ((input (concatenate 'string "snowman " (string (code-char #x2603))))
           (result (run "cat" nil :input input :external-format :utf-8 :search t)))
      (expect (string= (process-result-stdout result) input) :to-be-truthy)))

  (it "run signals process-io-error for invalid UTF-8 when decoding-error-policy is :error"
    (signals process-io-error
      (run "/bin/sh" (list "-c" "printf '\\377'")
           :external-format :utf-8 :decoding-error-policy :error))))

