;;;; cl-process-kit.asd

(asdf:defsystem "cl-process-kit"
  :description "SBCL-only process execution toolkit"
  :long-description "A timeout-aware subprocess runner for SBCL, inspired by
Python's subprocess.run() and Node.js's child_process.spawn(). Consolidates
the ad-hoc \"timeout-guarded process launch\" logic previously reimplemented
across several sister projects into a single, reusable library."
  :version "0.2.0"
  :author "nerima-lisp"
  :maintainer "nerima-lisp"
  :license "MIT"
  :homepage "https://github.com/nerima-lisp/cl-process-kit"
  :bug-tracker "https://github.com/nerima-lisp/cl-process-kit/issues"
  :source-control (:git "https://github.com/nerima-lisp/cl-process-kit.git")
  :depends-on (:asdf :cl-boundary-kit :cl-log-kit)
  :pathname "src"
  :serial t
  :components
  ((:file "package")
   (:file "types")
   (:file "conditions")
   (:file "parameters")
   (:file "logging")
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
   (:file "pipeline")))

(asdf:defsystem "cl-process-kit/test"
  :description "Test system for cl-process-kit"
  :version "0.2.0"
  :author "nerima-lisp"
  :maintainer "nerima-lisp"
  :license "MIT"
  :homepage "https://github.com/nerima-lisp/cl-process-kit"
  :bug-tracker "https://github.com/nerima-lisp/cl-process-kit/issues"
  :source-control (:git "https://github.com/nerima-lisp/cl-process-kit.git")
  :depends-on ("cl-process-kit" "cl-weave" "cl-log-kit")
  :pathname "t"
  :serial t
  :components
  ((:file "package") (:file "conditions-test") (:file "spawn-test") (:file "native-spawn-test")
   (:file "run-test") (:file "run-timeout-test") (:file "process-handle-test") (:file "pipeline-test")
   (:file "async-task-test")
   (:file "logging-test") (:file "edge-coverage-test") (:file "validation-test")
   (:file "property-test") (:file "mutation-test") (:file "performance-test")))

(asdf:defsystem "cl-process-kit/pty"
  :description "Optional native controlling-terminal PTY backend"
  :depends-on ("cl-process-kit" "cl-tty-kit")
  :pathname "src"
  :serial t
  :components
  ((:file "pty-package")
   (:file "pty")))

(asdf:defsystem "cl-process-kit/pty-test"
  :description "Integration tests for the optional PTY backend"
  :depends-on ("cl-process-kit/pty" "cl-weave")
  :pathname "t"
  :serial t
  :components
  ((:file "pty-package")
   (:file "pty-test")))
