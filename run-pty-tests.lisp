;;;; run-pty-tests.lisp
;;;;
;;;; Bootstrap script for the separate cl-process-kit/pty-test system: load
;;;; the PTY backend and its tests, then run them. Kept apart from
;;;; run-tests.lisp because the PTY backend needs CL_PROCESS_KIT_PTY_LIBRARY
;;;; pointing at a compiled native/pty.c shared library, which the core
;;;; suite has no reason to require.
;;;;
;;;; Usage: sbcl --script run-pty-tests.lisp

(require :asdf)

(let ((root (make-pathname :name nil
                            :type nil
                            :defaults (or *load-truename*
                                          *compile-file-truename*
                                          (error "Unable to determine script directory")))))
  (asdf:load-asd (merge-pathnames "cl-process-kit.asd" root))
  (asdf:load-system "cl-process-kit/pty-test")
  ;; Same per-test ceiling as run-tests.lisp, and for the same reason: this
  ;; suite is small (6 tests today) but each one drives a real PTY session,
  ;; so a hang here is exactly the kind of failure a bare process kill would
  ;; leave undiagnosed.
  (set (find-symbol "*DEFAULT-TIMEOUT-MS*" "CL-WEAVE") 30000)
  (unless (funcall (symbol-function (find-symbol "RUN-TESTS" "CL-PROCESS-KIT/PTY-TEST")))
    (uiop:quit 1))
  (uiop:quit 0))
