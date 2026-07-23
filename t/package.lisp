;;;; t/package.lisp

(defpackage #:cl-process-kit/test
  (:use #:cl #:process-kit)
  (:shadowing-import-from #:cl-weave #:describe)
  (:import-from #:cl-weave #:expect #:it #:signals #:run-all)
  (:export #:run-tests))

(in-package #:cl-process-kit/test)

(defun run-tests ()
  (unless (run-all :reporter :spec)
    (error "cl-process-kit test suite failed"))
  (format t "~&cl-process-kit/test: successful completion with 0 failures~%")
  t)
