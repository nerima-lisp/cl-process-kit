;;;; cl-process-kit.asd

(asdf:defsystem "cl-process-kit"
  :description "Dependency-free, SBCL-only process execution toolkit"
  :long-description "A timeout-aware subprocess runner for SBCL, inspired by
Python's subprocess.run() and Node.js's child_process.spawn(). Consolidates
the ad-hoc \"timeout-guarded process launch\" logic previously reimplemented
across several sister projects into a single, reusable library."
  :version "0.1.0"
  :author "takeokunn <bararararatty@gmail.com>"
  :maintainer "takeokunn <bararararatty@gmail.com>"
  :license "MIT"
  :homepage "https://github.com/nerima-lisp/cl-process-kit"
  :bug-tracker "https://github.com/nerima-lisp/cl-process-kit/issues"
  :source-control (:git "https://github.com/nerima-lisp/cl-process-kit.git")
  :depends-on (:asdf)
  :pathname "src"
  :serial t
  :components
  ((:file "package")
   (:file "result")
   (:file "spawn")
   (:file "run")))

(asdf:defsystem "cl-process-kit/test"
  :description "Test system for cl-process-kit"
  :version "0.1.0"
  :author "takeokunn <bararararatty@gmail.com>"
  :maintainer "takeokunn <bararararatty@gmail.com>"
  :license "MIT"
  :homepage "https://github.com/nerima-lisp/cl-process-kit"
  :bug-tracker "https://github.com/nerima-lisp/cl-process-kit/issues"
  :source-control (:git "https://github.com/nerima-lisp/cl-process-kit.git")
  :depends-on ("cl-process-kit" "cl-weave")
  :pathname "t"
  :serial t
  :components
  ((:file "package")
   (:file "spawn-test")
   (:file "run-test")))
