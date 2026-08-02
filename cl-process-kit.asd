;;;; cl-process-kit.asd

;;;; This form comes FIRST, before any defsystem. ASDF binds *package* to
;;;; ASDF-USER only for a file it loads itself; read any other way -- a REPL
;;;; `load`, an editor evaluating the buffer, flake.nix parsing :version -- the
;;;; file is read in whatever package happens to be current. Saying it makes
;;;; the file self-contained.
(in-package #:asdf-user)

(asdf:defsystem "cl-process-kit"
  :description "SBCL-only process execution toolkit"
  :long-description "A timeout-aware subprocess runner for SBCL, inspired by
Python's subprocess.run() and Node.js's child_process.spawn(). Consolidates
the ad-hoc \"timeout-guarded process launch\" logic previously reimplemented
across several sister projects into a single, reusable library."
  :author "takeokunn <bararararatty@gmail.com>"
  :maintainer "takeokunn <bararararatty@gmail.com>"
  :license "MIT"
  :version "3.1.0"
  :homepage "https://github.com/nerima-lisp/cl-process-kit"
  :bug-tracker "https://github.com/nerima-lisp/cl-process-kit/issues"
  :source-control (:git "https://github.com/nerima-lisp/cl-process-kit.git")
  :depends-on (:asdf :cl-boundary-kit :cl-log-kit :cl-codec-kit)
  :pathname "src"
  :serial t
  :components
  ((:file "package")
   (:file "types")
   (:file "conditions")
   (:file "parameters")
   (:file "logging")
   (:file "fd-readiness")
   (:file "command")
   (:file "process-handle")
   (:file "process-group")
   (:file "communication-state")
   (:file "spawn")
   (:file "native-spawn")
   (:file "capture")
   (:file "copier")
   (:file "communicate")
   (:file "async-events")
   (:file "async-task")
   (:file "run")
   (:file "pipeline"))
  :in-order-to ((test-op (test-op "cl-process-kit/test"))))

(asdf:defsystem "cl-process-kit/test"
  :description "Test system for cl-process-kit"
  :version "3.1.0"
  :author "takeokunn <bararararatty@gmail.com>"
  :maintainer "takeokunn <bararararatty@gmail.com>"
  :license "MIT"
  :homepage "https://github.com/nerima-lisp/cl-process-kit"
  :bug-tracker "https://github.com/nerima-lisp/cl-process-kit/issues"
  :source-control (:git "https://github.com/nerima-lisp/cl-process-kit.git")
  :depends-on ("cl-process-kit" "cl-weave" "cl-log-kit")
  :perform (test-op (op c)
             (declare (ignore op c))
             (uiop:symbol-call :cl-process-kit/test :run-tests))
  :pathname "t"
  :serial t
  :components
  ((:file "package") (:file "conditions-test") (:file "spawn-test") (:file "native-spawn-test")
   (:file "run-test") (:file "run-timeout-test") (:file "process-handle-test") (:file "pipeline-test")
   (:file "async-task-test") (:file "fd-readiness-test")
   (:file "logging-test") (:file "edge-coverage-test") (:file "validation-test")
   (:file "property-test") (:file "mutation-test") (:file "performance-test")))

(asdf:defsystem "cl-process-kit/pty"
  :description "Optional native controlling-terminal PTY backend"
  :version "3.1.0"
  :author "takeokunn <bararararatty@gmail.com>"
  :maintainer "takeokunn <bararararatty@gmail.com>"
  :license "MIT"
  :homepage "https://github.com/nerima-lisp/cl-process-kit"
  :bug-tracker "https://github.com/nerima-lisp/cl-process-kit/issues"
  :source-control (:git "https://github.com/nerima-lisp/cl-process-kit.git")
  :depends-on ("cl-process-kit" "cl-tty-kit" "cl-codec-kit")
  :in-order-to ((test-op (test-op "cl-process-kit/pty-test")))
  :pathname "src"
  :serial t
  :components
  ((:file "package-pty")
   (:file "pty")))

(asdf:defsystem "cl-process-kit/pty-test"
  :description "Integration tests for the optional PTY backend"
  :version "3.1.0"
  :author "takeokunn <bararararatty@gmail.com>"
  :maintainer "takeokunn <bararararatty@gmail.com>"
  :license "MIT"
  :homepage "https://github.com/nerima-lisp/cl-process-kit"
  :bug-tracker "https://github.com/nerima-lisp/cl-process-kit/issues"
  :source-control (:git "https://github.com/nerima-lisp/cl-process-kit.git")
  :depends-on ("cl-process-kit/pty" "cl-weave")
  :perform (test-op (op c)
             (declare (ignore op c))
             (uiop:symbol-call :cl-process-kit/pty-test :run-tests))
  :pathname "t"
  :serial t
  :components
  ((:file "package")
   (:file "pty-test")))
