;;;; t/run-timeout-test.lisp
;;;;
;;;; RUN's timeout/SIGTERM->SIGKILL escalation and cancellation-token
;;;; handling, split out of run-test.lisp (which otherwise covers
;;;; run-command/run's non-timeout behavior) once it grew past 380 lines
;;;; across five thematically distinct DESCRIBE blocks -- this is the
;;;; largest of the two halves by test count, and %MAKE-JUMP-CLOCK/
;;;; %COUNTING-SLEEPER are used only here.

(in-package #:cl-process-kit/test)

(defun %make-jump-clock ()
  "A CL-BOUNDARY-KIT clock boundary whose CLOCK-MONOTONIC reads 0 seconds on
its first call and then jumps 1000 simulated seconds further into the future
on every subsequent call. Each %POLL-UNTIL round-trip therefore observes its
deadline as already passed -- whether that deadline was computed from an
earlier or a later call -- so RUN never has to really wait out
TIMEOUT-SECONDS or GRACE-PERIOD-SECONDS."
  (let ((calls 0))
    (cl-boundary-kit:make-clock
     :monotonic-fn (lambda () (incf calls) (if (= calls 1) 0 (* calls 1000))))))

(defun %counting-sleeper (counter)
  "A CL-BOUNDARY-KIT sleeper boundary that never really sleeps, incrementing
the car of COUNTER on every SLEEPER-SLEEP call instead."
  (cl-boundary-kit:make-sleeper
   :sleep-fn (lambda (seconds) (declare (ignore seconds)) (incf (car counter)) nil)))

(describe "run timeout and signal escalation"
  (it "run with on-timeout :return sets timed-out-p on a real timeout"
    (let ((result (run "/bin/sh" (list "-c" "sleep 5")
                       :timeout 0.2 :grace-period 0.1 :on-timeout :return)))
      (expect result :to-have-timed-out)
      (expect-not result :to-have-succeeded)))

  (it "run with on-timeout :error signals process-timeout-error with the right slots"
    (signals process-timeout-error
      (run "/bin/sh" (list "-c" "sleep 5") :timeout 0.2 :grace-period 0.1 :on-timeout :error))
    (handler-case
        (run "/bin/sh" (list "-c" "sleep 5") :timeout 0.2 :grace-period 0.1 :on-timeout :error)
      (process-timeout-error (e)
        (expect (string= (process-timeout-error-command e) "/bin/sh") :to-be-truthy)
        (expect (= (process-timeout-error-timeout e) 0.2) :to-be-truthy))))

  (it "run escalates to SIGKILL when the child ignores SIGTERM"
    (let ((result (run "/bin/sh" (list "-c" "trap '' TERM; sleep 5")
                       :timeout 0.2 :grace-period 0.2 :on-timeout :return)))
      (expect result :to-have-timed-out)
      (expect (= (process-result-signal result) 9) :to-be-truthy)))

  (it "run's polling loop honors an injected CLOCK/SLEEPER without consuming real time"
    (let* ((sleep-calls (list 0))
           (started (get-internal-real-time))
           (result (run "/bin/sh" (list "-c" "sleep 5")
                       :timeout 1 :grace-period 1 :on-timeout :return
                       :clock (%make-jump-clock)
                       :sleeper (%counting-sleeper sleep-calls)))
           (elapsed-seconds (/ (- (get-internal-real-time) started)
                               internal-time-units-per-second)))
      (expect result :to-have-timed-out)
      ;; The fake clock reports the deadline as already passed on the very
      ;; first check, so the sleeper is never invoked and no real waiting for
      ;; TIMEOUT-SECONDS/GRACE-PERIOD-SECONDS happens.
      (expect (= (car sleep-calls) 0) :to-be-truthy)
      (expect (< elapsed-seconds 2) :to-be-truthy)))

  (it "run times out a stopped child instead of waiting forever"
    (let* ((started (get-internal-real-time))
           (result (run "/bin/sh" (list "-c" "kill -STOP $$")
                       :timeout 0.1 :grace-period 0.1 :on-timeout :return))
           (elapsed (/ (- (get-internal-real-time) started) internal-time-units-per-second)))
      (expect result :to-have-timed-out)
      (expect (< elapsed 2) :to-be-truthy)))

  (it "run cleans up the child when CLOCK signals an error"
    (let ((started (get-internal-real-time)))
      (signals error
        (run "/bin/sh" (list "-c" "sleep 5") :timeout 1
             :clock (cl-boundary-kit:make-clock :monotonic-fn (lambda () (error "clock failed")))))
      (expect (< (/ (- (get-internal-real-time) started) internal-time-units-per-second) 2)
              :to-be-truthy)))

  (it "run rejects invalid timeout controls before spawning"
    (signals error (run (%true-program) nil :on-timeout :invalid))
    (signals error (run (%true-program) nil :poll-interval 0))
    (signals error (run (%true-program) nil :poll-interval -1))
    (signals error (run (%true-program) nil :timeout -1))
    (signals error (run (%true-program) nil :grace-period -1))
    (signals error (run (%true-program) nil :drain-timeout-seconds -1))
    (signals error (run (%true-program) nil :timeout-signal 0))
    (signals error (run (%true-program) nil :timeout-signal 999))
    (signals error (run (%true-program) nil :kill-signal 0))
    (signals error (run (%true-program) nil :kill-signal 999)))

  ;; Every entry point resolves these two policies by comparing against :ERROR
  ;; and treating anything else as :RETURN, so an unguarded typo does not fail
  ;; loudly -- it downgrades the call to "return the result quietly" and
  ;; swallows the timeout or cancellation the caller asked to have signalled.
  ;; RUN, RUN-COMMAND and RUN-PIPELINE also hand COMMUNICATE a hardcoded
  ;; :ON-TIMEOUT :RETURN, so COMMUNICATE's own guard never sees the value the
  ;; caller passed and cannot catch this for them.
  (it "every entry point rejects an unrecognised outcome policy rather than reading it as :return"
    (let ((true-command (make-command (%true-program) nil)))
      (signals error (run (%true-program) nil :on-cancel :invalid))
      (signals error (run-command true-command :on-timeout :invalid))
      (signals error (run-command true-command :on-cancel :invalid))
      (signals error (run-pipeline (list true-command) :on-timeout :invalid))
      (signals error (run-pipeline (list true-command) :on-cancel :invalid))
      (with-process (process (spawn (%true-program) nil :output :stream :error :stream))
        (signals error (communicate process :on-cancel :invalid)))))

  (it "timeout errors retain a partial result without printing arguments"
    (handler-case
        (run "/bin/sh" (list "-c" "printf partial; sleep 5" "secret-argument")
            :timeout 0.1 :grace-period 0.1 :on-timeout :error)
      (process-timeout-error (condition)
        (let ((result (process-timeout-error-result condition))
              (report (princ-to-string condition)))
          (expect (search "secret-argument" report) :to-be nil)
          (expect result :to-have-timed-out)
          (expect (string= (process-result-stdout result) "partial") :to-be-truthy)))))

  ;; The copier read loop waits via poll(2) and checks %DRAIN-COPIERS' stop
  ;; flag between turns, so the drain deadline is enforced by the reader
  ;; itself. This used to be skipped on Linux, back when the drain instead
  ;; force-closed the stream and relied on that waking a thread already parked
  ;; in read() -- which macOS/BSD do and Linux does not, leaving the reader
  ;; parked until the backgrounded descendant below finally released the pipe.
  ;; Nothing platform-specific is left to interrupt, so this runs everywhere.
  (it "run returns boundedly when an exited leader leaves a pipe-holding descendant"
    (let* ((started (get-internal-real-time))
           (result (run "/bin/sh" (list "-c" "sleep 5 & exit 0") :drain-timeout-seconds 0.1))
           (elapsed (/ (- (get-internal-real-time) started) internal-time-units-per-second)))
      (expect (= (process-result-exit-code result) 0) :to-be-truthy)
      (expect (< elapsed 2) :to-be-truthy)))

  (it "times out blocked large input and joins the stdin feeder"
    (let* ((input (make-string (* 1024 1024) :initial-element #\x))
           (started (get-internal-real-time))
           (result (run "/bin/sh" (list "-c" "trap \"\" TERM; sleep 5")
                       :input input :timeout 0.1 :grace-period 0.1 :on-timeout :return))
           (elapsed (/ (- (get-internal-real-time) started) internal-time-units-per-second)))
      (expect result :to-have-timed-out)
      (expect (= (process-result-signal result) 9) :to-be-truthy)
      (expect (< elapsed 2) :to-be-truthy))))

(describe "cancellation"
  (it "does not cancel an already cached process result"
    (with-process (process (spawn "/bin/sh" (list "-c" "printf stable")
                                  :input :stream :output :stream :error :stream))
      (let* ((first (communicate process))
             (token (make-cancellation-token)))
        (cancel token)
        (let ((second (communicate process :cancellation-token token :on-cancel :return)))
          (expect (eq second first) :to-be-truthy)
          (expect-not second :to-have-been-cancelled)
          (expect (cancellation-requested-p token) :to-be-truthy)))))

  (it "cancels a pipe-holding descendant after its leader exits"
    (let* ((token (make-cancellation-token))
           (canceller (sb-thread:make-thread (lambda () (sleep 0.1d0) (cancel token))
                                             :name "process-kit cancellation test"))
           (started (get-internal-real-time))
           (result (run "/bin/sh" (list "-c" "(trap \"\" TERM; sleep 5) & printf leader")
                        :cancellation-token token :grace-period 0.1d0 :on-cancel :return))
           (elapsed (/ (- (get-internal-real-time) started) internal-time-units-per-second)))
      (sb-thread:join-thread canceller)
      (expect result :to-have-been-cancelled)
      (expect (string= (process-result-stdout result) "leader") :to-be-truthy)
      (expect (< elapsed 2) :to-be-truthy)))

  (it "signals process-io-error when the cancellation watcher does not report joining in time"
    ;; Force JOIN-THREAD to report :TIMED-OUT for the watcher specifically
    ;; (matched by name, so copier/feeder threads elsewhere in the same call
    ;; still join for real) -- the watcher's own escalation logic never runs
    ;; here; this drives COMMUNICATE's own "did the watcher actually stop"
    ;; check, not the watcher's cancellation behavior.
    (let ((original-join (function sb-thread:join-thread)))
      (sb-ext:without-package-locks
        (with-mocked-functions
            (((symbol-function 'sb-thread:join-thread)
              (lambda (thread &rest args)
                (if (string= (sb-thread:thread-name thread) "process-kit cancellation watcher")
                    :timed-out
                    (apply original-join thread args)))))
          (signals process-io-error
            (communicate (spawn "/bin/sh" (list "-c" "printf ok") :output :stream :error :stream)
                         :cancellation-token (make-cancellation-token))))))))
