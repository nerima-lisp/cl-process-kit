(in-package #:cl-process-kit/test)

;;;; Thread lifecycle: loading the system must start no thread, and
;;;; SHUTDOWN-PROCESS-KIT must leave an image that SAVE-LISP-AND-DIE and
;;;; SB-POSIX:FORK accept. Load-time and save/fork behavior can only be observed
;;;; in a fresh image, so those cases run a child SBCL that inherits this
;;;; process's CL_SOURCE_REGISTRY.

(defparameter +kit-thread-names+
  '("process-kit communicate workers" "process-kit event dispatchers"))

(defparameter +child-lisp-timeout-seconds+ 240)

(defparameter +async-probe-form+
  "(process-kit:await-process
    (process-kit:run-command-async
     (process-kit:make-command \"/bin/sh\" (list \"-c\" \"printf kit-ok\"))))"
  "Run one process through the executor-backed asynchronous API.")

(defun %kit-threads ()
  (remove-if-not
   (lambda (thread)
     (and (sb-thread:thread-alive-p thread)
          (member (sb-thread:thread-name thread) +kit-thread-names+ :test #'equal)))
   (sb-thread:list-all-threads)))

(defun %run-child-lisp (&rest forms)
  "Run FORMS, each a string read and evaluated in order, in a fresh
non-interactive SBCL child of the running runtime and core."
  (run (namestring sb-ext:*runtime-pathname*)
       (append
        (list "--core" (namestring sb-ext:*core-pathname*) "--noinform"
              "--no-sysinit" "--no-userinit" "--disable-debugger" "--non-interactive"
              "--eval" "(require :asdf)")
        (loop for form in forms append (list "--eval" form)))
       :timeout +child-lisp-timeout-seconds+))

(defun %child-marker-line (result prefix)
  "The first line of RESULT's stdout that starts with PREFIX, so a failed
expectation reports what the child printed."
  (find-if (lambda (line) (uiop:string-prefix-p prefix line))
           (uiop:split-string (process-result-stdout result) :separator (string #\Newline))))

(defun %child-exit-report (result)
  "RESULT's exit code, paired with the tail of its stderr when nonzero."
  (let ((code (process-result-exit-code result))
        (stderr (process-result-stderr result)))
    (if (eql code 0)
        0
        (list code (subseq stderr (max 0 (- (length stderr) 600)))))))

(defun %call-with-scratch-directory (function)
  (let ((directory
          (uiop:ensure-directory-pathname
           (merge-pathnames
            (format nil "cl-process-kit-lifecycle-~36R/"
                    (random (expt 36 10) (make-random-state t)))
            (uiop:temporary-directory)))))
    (ensure-directories-exist directory)
    (unwind-protect (funcall function directory)
      (uiop:delete-directory-tree directory :validate t :if-does-not-exist :ignore))))

(describe
 "thread lifecycle"
 (it
  "starts no thread while loading the system"
  (:timeout-ms 300000)
  ;; The baseline is taken after the dependencies load, so only threads the
  ;; kit itself starts are counted. SBCL's finalizer thread starts on demand
  ;; after a GC, which loading may trigger, so it is excluded by identity.
  (let ((result
          (%run-child-lisp
           "(asdf:load-systems \"cl-boundary-kit\" \"cl-log-kit\" \"cl-codec-kit\"
                               \"cl-concurrent-kit\")"
           "(defparameter cl-user::*baseline* (sb-thread:list-all-threads))"
           "(asdf:load-system \"cl-process-kit\")"
           "(let ((new (remove sb-impl::*finalizer-thread*
                         (set-difference (sb-thread:list-all-threads) cl-user::*baseline*))))
              (format t \"~&NEW-THREADS ~D~{ ~S~}~%\"
                      (length new) (mapcar #'sb-thread:thread-name new)))")))
    (expect (%child-exit-report result) :to-equal 0)
    (expect (%child-marker-line result "NEW-THREADS") :to-equal "NEW-THREADS 0")))

 (it
  "stops and joins kit threads on shutdown and recreates them on next use"
  (:timeout-ms 60000)
  (let ((command (make-command "/bin/sh" (list "-c" "printf again"))))
    (expect (process-result-exit-code (await-process (run-command-async command))) :to-be 0)
    (expect (plusp (length (%kit-threads))) :to-be-truthy)
    (shutdown-process-kit)
    (expect (%kit-threads) :to-be nil)
    (expect process-kit::*process-kit-communicate-executor* :to-be nil)
    (expect process-kit::*process-kit-dispatch-executor* :to-be nil)
    (shutdown-process-kit)
    (let ((result (await-process (run-command-async command))))
      (expect (process-result-stdout result) :to-equal "again"))
    (expect (plusp (length (%kit-threads))) :to-be-truthy)))

 (it
  "is registered on sb-ext:*save-hooks*"
  (expect (member 'shutdown-process-kit sb-ext:*save-hooks*) :to-be-truthy))

 (it
  "saves an executable after use and runs processes in the restarted image"
  (:timeout-ms 600000)
  (%call-with-scratch-directory
   (lambda (directory)
     (let* ((executable (merge-pathnames "saved-kit" directory))
            (saved
              (%run-child-lisp
               "(asdf:load-system \"cl-process-kit\")"
               (format nil "(defun cl-user::main ()
                              (let ((result ~A))
                                (format t \"~~&SAVED-STDOUT ~~A~~%\"
                                        (process-kit:process-result-stdout result))
                                (finish-output)
                                (sb-ext:exit :code 0)))"
                       +async-probe-form+)
               +async-probe-form+
               (format nil "(sb-ext:save-lisp-and-die ~S :executable t
                              :toplevel #'cl-user::main)"
                       (namestring executable)))))
       (expect (%child-exit-report saved) :to-equal 0)
       (expect (probe-file executable) :to-be-truthy)
       (let ((restarted (run (namestring executable) nil :timeout 60)))
         (expect (%child-exit-report restarted) :to-equal 0)
         (expect (%child-marker-line restarted "SAVED-STDOUT") :to-equal "SAVED-STDOUT kit-ok"))))))

 (it
  "forks after loading and after shutdown"
  (:timeout-ms 300000)
  (let ((result
          (%run-child-lisp
           "(require :sb-posix)"
           "(asdf:load-system \"cl-process-kit\")"
           "(defun cl-user::fork-status ()
              (handler-case
                  (let ((pid (sb-posix:fork)))
                    (if (zerop pid)
                        (sb-ext:exit :code 0 :abort t)
                        (multiple-value-bind (waited status) (sb-posix:waitpid pid 0)
                          (declare (ignore waited))
                          (if (and (sb-posix:wifexited status)
                                   (zerop (sb-posix:wexitstatus status)))
                              :ok
                              :child-failed))))
                (error (condition) (remove #\\Newline (princ-to-string condition)))))"
           "(format t \"~&FORK-AFTER-LOAD ~A~%\" (cl-user::fork-status))"
           +async-probe-form+
           "(process-kit:shutdown-process-kit)"
           "(format t \"~&FORK-AFTER-SHUTDOWN ~A~%\" (cl-user::fork-status))")))
    (expect (%child-marker-line result "FORK-AFTER-LOAD") :to-equal "FORK-AFTER-LOAD OK")
    (expect (%child-marker-line result "FORK-AFTER-SHUTDOWN") :to-equal "FORK-AFTER-SHUTDOWN OK")
    (expect (%child-exit-report result) :to-equal 0))))
