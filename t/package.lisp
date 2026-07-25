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

(defun %true-program ()
  "The absolute path of `true`, resolved through the ambient PATH -- the generic
\"a program that exists and exits 0 immediately\" fixture for guard-clause tests.

A guard-clause test is only worth anything if the call reaches the guard it
claims to cover, which means the program it names has to exist. Hardcoding
/bin/true does not clear that bar: macOS ships `true` in /usr/bin only, so
there every `(signals error (run \"/bin/true\" ... :bad-option))` passed on the
PROCESS-LAUNCH-ERROR for the missing file -- identically, and just as green,
whether or not the guard under test existed at all. That is precisely how RUN's
unvalidated :ON-TIMEOUT sat behind a passing macOS suite until the same suite
was first run on Linux, where /bin/true does exist and the assertion finally
had to mean something."
  (namestring (process-kit::%resolve-executable "true" nil (sb-ext:posix-environ) nil)))

(defun %spawn-sleeping (&optional (seconds "5"))
  "Spawn a long-lived `sleep SECONDS` child via the ambient PATH -- the
generic 'give me a process that stays alive until I signal/kill/time it
out' fixture every timeout/cancellation/process-group edge-case test needs."
  (spawn "sleep" (list seconds) :search t :environment (sb-ext:posix-environ)))
