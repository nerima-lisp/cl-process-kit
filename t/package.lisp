;;;; t/package.lisp

(defpackage #:cl-process-kit/test
  (:use #:cl #:process-kit)
  (:shadowing-import-from #:cl-weave #:describe)
  (:import-from #:cl-weave
   #:expect #:expect-not #:it #:signals #:run-all #:with-mocked-functions #:defmatcher)
  (:export #:run-tests #:+suite-complete-p+))

;;; The cl-process-kit/pty-test system's package. It lives here rather than in
;;; a second manifest because CODING_STANDARD.md keeps defpackage forms in one
;;; file per directory, and because t/ has no other name reserved for a
;;; manifest -- `package.lisp` and `suite.lisp` are the only two exempt from
;;; the `<source>-test.lisp` rule. Loading this file from the pty-test system
;;; costs only the fixtures above, which need nothing the pty system lacks.
(defpackage #:cl-process-kit/pty-test
  (:use #:cl)
  (:import-from #:cl-weave #:expect #:it #:run-all)
  (:export #:run-tests))

(in-package #:cl-process-kit/test)

(defparameter +suite-complete-p+
  (not #+linux t #-linux nil)
  "True when every test in the suite actually runs on this platform.

False on Linux, where seven process-group/cancellation cases are `it-skip`ped
under `#+linux`: each asserts that a process group is gone within a 0.1s grace
period, which a contended shared CI runner cannot reliably deliver. They are
skipped rather than given more headroom because a timing assertion loose
enough to survive arbitrary contention no longer asserts the timing.

`run-tests.lisp` consults this before enforcing its coverage ratchet. A floor
set from a complete run is not a meaningful bound on a run that skipped part
of the suite -- comparing the two is a category error, and it is what failed
CI on every Linux build before 1.0.0: the floor tracked the macOS figure
while CI measured the reduced Linux one and reported a \"regression\" that was
only ever the missing tests.")

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

(defmacro %define-result-state-matcher (name description process-predicate pipeline-predicate)
  "Register a cl-weave matcher over a `process-result' or `pipeline-result',
dispatching to whichever of PROCESS-PREDICATE/PIPELINE-PREDICATE fits ACTUAL's
type. Every one of this library's result-state matchers (success, timeout,
cancellation) has this exact shape -- a matcher takes no :EXPECTED value, and
`process-result'/`pipeline-result' each track the same state under
differently-named accessors -- so the boilerplate lives here once instead of
being repeated per matcher."
  `(defmatcher ,name (actual expected)
     ,description
     (unless (null expected)
       (error "cl-process-kit: ~S takes no expected value, got ~S." ',name expected))
     (etypecase actual
       (pipeline-result (,pipeline-predicate actual))
       (process-result (,process-predicate actual)))))

(%define-result-state-matcher :to-have-succeeded
  "the process or pipeline result to have succeeded"
  process-success-p pipeline-success-p)

(%define-result-state-matcher :to-have-timed-out
  "the process or pipeline result to have timed out"
  process-result-timed-out-p pipeline-result-timed-out-p)

(%define-result-state-matcher :to-have-been-cancelled
  "the process or pipeline result to have been cancelled"
  process-result-cancelled-p pipeline-result-cancelled-p)
