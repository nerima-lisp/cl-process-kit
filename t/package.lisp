;;;; t/package.lisp

(defpackage #:cl-process-kit/test
  (:use #:cl #:process-kit)
  (:shadowing-import-from #:cl-weave #:describe)
  (:import-from #:cl-weave #:expect #:it #:signals #:run-all #:with-mocked-functions)
  (:export #:run-tests))

(in-package #:cl-process-kit/test)

(defun run-tests ()
  (unless (run-all :reporter :spec)
    (error "cl-process-kit test suite failed"))
  (format t "~&cl-process-kit/test: successful completion with 0 failures~%")
  t)

(defun %spawn-sleeping (&optional (seconds "5"))
  "Spawn a long-lived `sleep SECONDS` child via the ambient PATH -- the
generic 'give me a process that stays alive until I signal/kill/time it
out' fixture every timeout/cancellation/process-group edge-case test needs."
  (spawn "sleep" (list seconds) :search t :environment (sb-ext:posix-environ)))
