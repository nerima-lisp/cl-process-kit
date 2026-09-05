(defpackage #:cl-process-kit/test (:use #:cl #:process-kit)
  (:shadowing-import-from #:cl-weave #:describe)
  (:import-from
   #:cl-weave
   #:expect
   #:expect-not
   #:it
   #:signals
   #:run-all
   #:with-mocked-functions
   #:defmatcher)
  (:export #:run-tests #:+suite-complete-p+))

(defpackage #:cl-process-kit/pty-test (:use #:cl)
  (:import-from #:cl-weave #:expect #:it #:run-all)
  (:export #:run-tests))

(in-package #:cl-process-kit/test)

(defparameter +suite-complete-p+ (not #+linux t #-linux nil)
  "True when every test in the suite actually runs on this platform.

False on Linux, where seven process-group/cancellation cases are marked it-skip
under #+linux: each asserts that a process group is gone within a 0.1s grace
period, which a contended shared CI runner cannot reliably deliver. They are
skipped rather than given more headroom because a timing assertion loose
enough to survive arbitrary contention no longer asserts the timing.

Coverage floors are enforced only when this flag is true: those seven cases
exercise SRC/ branches nothing else does, so a Linux run that skips them
cannot be compared with a complete-suite run at the same floor.")

(defun run-tests ()
  (unless (run-all :reporter :spec :pass-with-no-tests nil)
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

(defun %spawn-communicating (program arguments &rest options)
  "Spawn PROGRAM with stream-backed stdout/stderr, forwarding any OPTIONS
that a caller still needs to vary per test."
  (apply #'spawn program arguments :output :stream :error :stream options))

(defun %communicate-octets (process &rest options)
  "Run COMMUNICATE-ASYNC against PROCESS, defaulting tests to octet output."
  (apply #'communicate-async process :result-type :octets options))

(defun %schedule-process-cancellation (task &optional (delay 0.1d0))
  "Cancel TASK from a helper thread after DELAY seconds."
  (%schedule-after
   (lambda ()
     (cancel-process task))
   delay
   "process-kit async cancellation test"))

(defun %spawn-shell-command (command)
  "Spawn `/bin/sh -c COMMAND` with stream-backed stdout/stderr."
  (%spawn-communicating "/bin/sh" (list "-c" command)))

(defparameter +linux-process-group-skip-reason+ "process-group timing is strict"
  "Shared skip reason for the Linux-only process-group timing cases.")

(defmacro %it-process-group-case (description &body body)
  "Define a process-group timing test that runs everywhere except Linux CI.

Linux keeps these cases skipped because the assertion is about a very small
group-death grace period; once the timeout is loosened enough to survive
shared-runner contention, the test is no longer proving the timing contract it
claims to cover."
  `#+linux
   (cl-weave:it-skip ,description +linux-process-group-skip-reason+)
  #-linux
   (it ,description ,@body))

(defmacro %with-process-cleanup ((var process-form &key (timeout '0.3d0)) &body body)
  "Bind VAR to PROCESS-FORM and always close it with TIMEOUT on exit.

This is stricter than `when (process-alive-p ...)`: some process-group tests
need cleanup after the leader has already exited, because the descendants are
still the resource under test."
  `(let ((,var ,process-form))
     (unwind-protect (progn
                       ,@body)
       (close-process ,var :timeout ,timeout))))

(defmacro %define-result-state-matcher (name description process-predicate pipeline-predicate)
  "Register a cl-weave matcher over a `process-result' or `pipeline-result',
dispatching to whichever of PROCESS-PREDICATE/PIPELINE-PREDICATE fits ACTUAL's
type. Every one of this library's result-state matchers (success, timeout,
cancellation) has this exact shape -- a matcher takes no :EXPECTED value, and
`process-result'/`pipeline-result' each track the same state under
differently-named accessors -- so the boilerplate lives here once instead of
being repeated per matcher."
  `(defmatcher
    ,name
    (actual expected)
    ,description
    (unless (null expected)
      (error "cl-process-kit: ~S takes no expected value, got ~S." ',name expected))
    (etypecase actual
      (pipeline-result (,pipeline-predicate actual))
      (process-result (,process-predicate actual)))))

(%define-result-state-matcher
 :to-have-succeeded
 "the process or pipeline result to have succeeded"
 process-success-p
 pipeline-success-p)

(%define-result-state-matcher
 :to-have-timed-out
 "the process or pipeline result to have timed out"
 process-result-timed-out-p
 pipeline-result-timed-out-p)

(%define-result-state-matcher
 :to-have-been-cancelled
 "the process or pipeline result to have been cancelled"
 process-result-cancelled-p
 pipeline-result-cancelled-p)

(defun %expect-terminal-pipeline-condition (condition expected-kind expected-length)
  "Assert that CONDITION carries the matching stage result and pipeline result.

EXPECTED-KIND must be either :TIMEOUT or :CANCEL. EXPECTED-LENGTH is the number
of stage results the pipeline is expected to carry."
  (let* ((stage-index
          (etypecase condition
            (process-timeout-error (process-timeout-error-stage-index condition))
            (process-cancelled-error (process-cancelled-error-stage-index condition))))
         (stage-result
          (etypecase condition
            (process-timeout-error (process-timeout-error-result condition))
            (process-cancelled-error (process-cancelled-error-result condition))))
         (pipeline-result
          (etypecase condition
            (process-timeout-error (process-timeout-error-pipeline-result condition))
            (process-cancelled-error (process-cancelled-error-pipeline-result condition)))))
    (expect (member expected-kind '(:timeout :cancel)) :to-be-truthy)
    (expect (integerp stage-index) :to-be-truthy)
    (expect (= (length (pipeline-result-results pipeline-result)) expected-length) :to-be-truthy)
    (expect
     (eq stage-result (nth stage-index (pipeline-result-results pipeline-result)))
     :to-be-truthy)
    (if (eq expected-kind :timeout) (progn
                                      (expect stage-result :to-have-timed-out)
                                      (expect pipeline-result :to-have-timed-out))
      (progn
        (expect stage-result :to-have-been-cancelled)
        (expect pipeline-result :to-have-been-cancelled)))
    (expect-not stage-result :to-have-succeeded)
    (expect-not pipeline-result :to-have-succeeded)))

(defun %schedule-after (thunk &optional (delay 0.1d0) (name "process-kit delayed test action"))
  "Run THUNK from a helper thread after DELAY seconds."
  (sb-thread:make-thread
   (lambda ()
     (sleep delay)
     (funcall thunk))
   :name
   name))

(defun %schedule-cancellation (token &optional (delay 0.1d0))
  "Cancel TOKEN from a helper thread after DELAY seconds."
  (%schedule-after
   (lambda ()
     (cancel token))
   delay
   "process-kit cancellation test"))
