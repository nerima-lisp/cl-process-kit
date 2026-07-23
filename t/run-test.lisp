;;;; t/run-test.lisp

(in-package #:cl-process-kit/test)

(defun %make-jump-clock ()
  "A CLOCK replacement that returns 0 on its first call and then jumps 1000
simulated seconds further into the future on every subsequent call. Each
%POLL-UNTIL round-trip therefore observes its deadline as already passed --
whether that deadline was computed from an earlier or a later call -- so RUN
never has to really wait out TIMEOUT-SECONDS or GRACE-PERIOD-SECONDS."
  (let ((calls 0))
    (lambda ()
      (incf calls)
      (if (= calls 1)
          0
          (* calls 1000 internal-time-units-per-second)))))

(defun %counting-sleep-fn (counter)
  (lambda (seconds)
    (declare (ignore seconds))
    (incf (car counter))
    nil))

(it "run captures stdout and a zero exit-code on success"
  (let ((result (run "/bin/echo" (list "hello"))))
    (expect (= (process-result-exit-code result) 0) :to-be-truthy)
    (expect (string= (process-result-stdout result) (format nil "hello~%"))
           :to-be-truthy)
    (expect (process-result-timed-out-p result) :to-be nil)
    (expect (process-result-signal result) :to-be nil)))

(it "run reports a non-zero exit-code"
  (let ((result (run "/bin/sh" (list "-c" "exit 3"))))
    (expect (= (process-result-exit-code result) 3) :to-be-truthy)))

(it "run captures stderr separately from stdout"
  (let ((result (run "/bin/sh" (list "-c" "echo out; echo err 1>&2"))))
    (expect (string= (process-result-stdout result) (format nil "out~%")) :to-be-truthy)
    (expect (string= (process-result-stderr result) (format nil "err~%")) :to-be-truthy)))

(it "run forwards a string INPUT to the child's standard input"
  (let ((result (run "/bin/cat" nil :input "piped-in")))
    (expect (string= (process-result-stdout result) "piped-in") :to-be-truthy)))

(it "run with on-timeout :return sets timed-out-p on a real timeout"
  (let ((result (run "/bin/sh" (list "-c" "sleep 5")
                     :timeout-seconds 0.2
                     :grace-period-seconds 0.1
                     :on-timeout :return)))
    (expect (process-result-timed-out-p result) :to-be-truthy)))

(it "run with on-timeout :error signals process-timeout-error with the right slots"
  (signals process-timeout-error
    (run "/bin/sh" (list "-c" "sleep 5")
        :timeout-seconds 0.2
        :grace-period-seconds 0.1
        :on-timeout :error))
  (handler-case
      (run "/bin/sh" (list "-c" "sleep 5")
          :timeout-seconds 0.2
          :grace-period-seconds 0.1
          :on-timeout :error)
    (process-timeout-error (e)
      (expect (string= (process-timeout-error-command e) "/bin/sh") :to-be-truthy)
      (expect (= (process-timeout-error-timeout-seconds e) 0.2) :to-be-truthy))))

(it "run escalates to SIGKILL when the child ignores SIGTERM"
  (let ((result (run "/bin/sh" (list "-c" "trap '' TERM; sleep 5")
                     :timeout-seconds 0.2
                     :grace-period-seconds 0.2
                     :on-timeout :return)))
    (expect (process-result-timed-out-p result) :to-be-truthy)
    (expect (= (process-result-signal result) 9) :to-be-truthy)))

(it "run's polling loop honors an injected CLOCK/SLEEP-FN without consuming real time"
  (let* ((sleep-calls (list 0))
         (started (get-internal-real-time))
         (result (run "/bin/sh" (list "-c" "sleep 5")
                     :timeout-seconds 1
                     :grace-period-seconds 1
                     :on-timeout :return
                     :clock (%make-jump-clock)
                     :sleep-fn (%counting-sleep-fn sleep-calls)))
         (elapsed-seconds (/ (- (get-internal-real-time) started)
                             internal-time-units-per-second)))
    (expect (process-result-timed-out-p result) :to-be-truthy)
    ;; The fake clock reports the deadline as already passed on the very
    ;; first check, so SLEEP-FN is never invoked and no real waiting for
    ;; TIMEOUT-SECONDS/GRACE-PERIOD-SECONDS happens.
    (expect (= (car sleep-calls) 0) :to-be-truthy)
    (expect (< elapsed-seconds 2) :to-be-truthy)))
