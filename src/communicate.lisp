;;;; src/communicate.lisp
;;;;
;;;; COMMUNICATE drains a spawned process's stdout/stderr, optionally feeds
;;;; stdin, waits for it to exit (escalating SIGTERM -> SIGKILL past a
;;;; deadline), and returns a PROCESS-RESULT. COMMUNICATE itself is a thin
;;;; cancellation-aware wrapper around %COMMUNICATE-BASE that races the
;;;; process against a caller-supplied CANCELLATION-TOKEN using a watcher
;;;; thread.

(in-package #:process-kit)

(defun %validate-communication-options
    (input timeout grace-period poll-interval timeout-signal kill-signal on-timeout
     max-output-characters drain-timeout-seconds result-type decoding-error-policy
     clock sleeper)
  (%ensure (not (eq input t)) "INPUT T cannot safely isolate the child process group.")
  (dolist (entry `((,timeout . timeout)
                    (,grace-period . grace-period)
                    (,drain-timeout-seconds . drain-timeout-seconds)))
    (%ensure (or (null (car entry)) (and (realp (car entry)) (not (minusp (car entry)))))
             "~A must be NIL or a non-negative real." (cdr entry)))
  (%ensure (and (realp poll-interval) (plusp poll-interval)) "POLL-INTERVAL must be a positive real.")
  (%ensure (and (integerp timeout-signal) (<= 1 timeout-signal 31)
                (integerp kill-signal) (<= 1 kill-signal 31))
           "Signals must be integers between 1 and 31.")
  (%ensure (member on-timeout '(:return :error) :test #'eq) "ON-TIMEOUT must be :RETURN or :ERROR.")
  (%ensure (or (null max-output-characters)
               (and (integerp max-output-characters) (not (minusp max-output-characters))))
           "MAX-OUTPUT-CHARACTERS must be NIL or a non-negative integer.")
  (%ensure (member result-type '(:string :octets) :test #'eq) "RESULT-TYPE must be :STRING or :OCTETS.")
  (%ensure (member decoding-error-policy '(:replace :error) :test #'eq)
           "DECODING-ERROR-POLICY must be :REPLACE or :ERROR.")
  (%ensure (%clock-p clock)
           "CLOCK must be a CL-BOUNDARY-KIT clock boundary (see CL-BOUNDARY-KIT:MAKE-CLOCK).")
  (%ensure (%sleeper-p sleeper)
           "SLEEPER must be a CL-BOUNDARY-KIT sleeper boundary (see CL-BOUNDARY-KIT:MAKE-SLEEPER)."))

(defun %wait-until-terminal (process deadline poll clock-fn sleep-fn)
  (loop
    (unless (process-alive-p process) (return t))
    (let ((remaining (- deadline (funcall clock-fn))))
      (when (<= remaining 0) (return nil))
      (funcall sleep-fn (min remaining poll)))))

(defun %wait-until-group-gone (process deadline poll clock-fn sleep-fn)
  (loop
    (process-try-wait process)
    (unless (%process-group-alive-p process) (return t))
    (let ((remaining (- deadline (funcall clock-fn))))
      (when (<= remaining 0) (return nil))
      (funcall sleep-fn (min remaining poll)))))

(defun %raw-process-result (process stdout-capture stderr-capture timed-out-p started clock-fn)
  (let* ((raw (%handle-raw-process process))
         (status (sb-ext:process-status raw))
         (code (sb-ext:process-exit-code raw)))
    (make-process-result
     :program nil :arguments nil :pid (process-id process) :status status
     :duration-seconds (- (funcall clock-fn) started)
     :exit-code (and (eq status :exited) code)
     :signal (and (eq status :signaled) code)
     :stdout (%capture-value stdout-capture :stdout)
     :stderr (%capture-value stderr-capture :stderr)
     :timed-out-p timed-out-p
     :stdout-truncated-p (%capture-truncated-p stdout-capture)
     :stderr-truncated-p (%capture-truncated-p stderr-capture))))

(defun %communicate-base
    (process &key input timeout (grace-period 1.0d0) (timeout-signal 15) (kill-signal 9)
               (on-timeout :error) (max-output-characters +default-output-limit+)
               (drain-timeout-seconds +default-drain-timeout-seconds+) (result-type :string)
               (external-format :default) (decoding-error-policy :replace)
               (clock +default-clock+) (sleeper +default-sleeper+)
               (poll-interval +default-poll-interval+))
  (declare (ignorable external-format))
  (%validate-communication-options
   input timeout grace-period poll-interval timeout-signal kill-signal on-timeout
   max-output-characters drain-timeout-seconds result-type decoding-error-policy
   clock sleeper)
  (let ((cached-result
          (%begin-communication
           process :input input :timeout timeout :grace-period grace-period
                   :timeout-signal timeout-signal :kill-signal kill-signal :on-timeout on-timeout
                   :max-output-characters max-output-characters :drain-timeout-seconds drain-timeout-seconds
                   :result-type result-type :external-format external-format
                   :decoding-error-policy decoding-error-policy :clock clock
                   :sleeper sleeper :poll-interval poll-interval)))
    (when cached-result (return-from %communicate-base cached-result)))
  (let* ((clock-fn (lambda () (cl-boundary-kit:clock-monotonic clock)))
         (sleep-fn (lambda (seconds) (cl-boundary-kit:sleeper-sleep sleeper seconds)))
         (started (funcall clock-fn))
         (deadline (and timeout (+ started timeout)))
         (stdin-stream (process-stdin process))
         (stdout-stream (process-output process))
         (stderr-stream (let ((stream (process-stderr process))) (unless (eq stream stdout-stream) stream)))
         (stdout-capture (%make-capture max-output-characters result-type external-format decoding-error-policy))
         (stderr-capture (%make-capture max-output-characters result-type external-format decoding-error-policy))
         (stdout-copier (%start-copier stdout-stream stdout-capture :stdout))
         (stderr-copier (%start-copier stderr-stream stderr-capture :stderr))
         (stdin-feeder (%start-feeder process input external-format))
         (copier-entries (list (cons stdin-stream stdin-feeder)
                               (cons stdout-stream stdout-copier)
                               (cons stderr-stream stderr-copier)))
         (timed-out-p nil)
         (completed-p nil))
    (labels ((signal-group (signal)
               (if (process-alive-p process)
                   (%signal-process-group process signal :allow-terminal-leader t)
                   (%signal-process-group-after-leader-exit process signal)))
             (escalate-unless-gone (on-timeout)
               "Wait up to GRACE-PERIOD for PROCESS's group to exit; call the
ON-TIMEOUT continuation only if it is still alive afterward. What happens
next -- a harsher signal, or nothing further -- is the caller's choice,
passed in rather than hard-coded here."
               (unless (%wait-until-group-gone process (+ (funcall clock-fn) grace-period)
                                                poll-interval clock-fn sleep-fn)
                 (funcall on-timeout)))
             (terminate-and-reap ()
               (when (%process-group-alive-p process)
                 (ignore-errors (signal-group timeout-signal))
                 (escalate-unless-gone
                  (lambda () (ignore-errors (%signal-process-group-after-leader-exit process kill-signal)))))
               (ignore-errors (process-wait process :timeout grace-period))))
      (unwind-protect
           (progn
             (when deadline
               (unless (%wait-until-terminal process deadline poll-interval clock-fn sleep-fn)
                 (setf timed-out-p t)
                 (%log :warn "process timed out, escalating"
                       :pid (process-id process) :timeout-signal timeout-signal)
                 (signal-group timeout-signal)
                 (escalate-unless-gone
                  (lambda () (%signal-process-group-after-leader-exit process kill-signal)))))
             (when timed-out-p
               (ignore-errors (%close-stream-for-copier stdin-stream stdin-feeder)))
             (unless (process-handle-reaped-p process)
               (sb-ext:process-wait (%handle-raw-process process)))
             (when (and (boundp '*current-cancellation-token*)
                        (symbol-value '*current-cancellation-token*)
                        (cancellation-requested-p (symbol-value '*current-cancellation-token*)))
               (ignore-errors (%close-stream-for-copier stdin-stream stdin-feeder))
               (when stdin-feeder (setf (%copier-condition-after-forced-close-p stdin-feeder) t)))
             (%drain-copiers copier-entries drain-timeout-seconds clock-fn)
             (let* ((result (%raw-process-result process stdout-capture stderr-capture timed-out-p started clock-fn))
                    (cached-result (%cache-process-result process result)))
               (setf completed-p t)
               (when (and timed-out-p (eq on-timeout :error))
                 (error 'process-timeout-error :command nil :arguments nil :timeout timeout :result cached-result))
               cached-result))
        (unless completed-p (%abort-communication process) (terminate-and-reap))
        (ignore-errors (close-process-streams process))
        (dolist (entry copier-entries) (ignore-errors (%close-stream-for-copier (car entry) (cdr entry))))
        (ignore-errors (%drain-copiers copier-entries drain-timeout-seconds clock-fn))))))

(defvar *current-cancellation-token* nil)
(defvar *current-on-cancel* :error)
(defparameter *communicate-without-cancellation* #'%communicate-base)

(defun %plist-without (plist keys)
  (loop for (key value) on plist by #'cddr
        unless (member key keys :test #'eq)
          append (list key value)))

(defun communicate (process &rest options)
  "Drain PROCESS's output, optionally feed :INPUT, and wait for it to exit.
Races the process against :CANCELLATION-TOKEN (default: the token RUN or
COMMUNICATE-ASYNC bound around this call, if any) using a watcher thread
that escalates SIGTERM -> SIGKILL on cancellation, mirroring the timeout
escalation %COMMUNICATE-BASE already performs."
  (let* ((token (or (getf options :cancellation-token) *current-cancellation-token*))
         (on-cancel (if (member :on-cancel options :test #'eq) (getf options :on-cancel) *current-on-cancel*))
         (grace-period (or (getf options :grace-period) 1.0d0))
         (state-lock (sb-thread:make-mutex :name "process-kit cancellation state"))
         (done-p nil)
         (cancelled-p nil)
         (watcher-error nil)
         (terminal-at-entry-p (process-handle-reaped-p process))
         (watcher nil))
    (flet ((clock () (cl-boundary-kit:clock-monotonic +default-clock+))
           (sleep-seconds (seconds) (cl-boundary-kit:sleeper-sleep +default-sleeper+ seconds)))
      (labels ((finished-p () (sb-thread:with-mutex (state-lock) done-p))
               (mark-finished () (sb-thread:with-mutex (state-lock) (setf done-p t)))
               (mark-cancelled () (sb-thread:with-mutex (state-lock) (setf cancelled-p t)))
               (cancelled-p () (sb-thread:with-mutex (state-lock) cancelled-p))
               (record-watcher-error (condition) (sb-thread:with-mutex (state-lock) (setf watcher-error condition)))
               (watcher-error () (sb-thread:with-mutex (state-lock) watcher-error))
               (signal-owned-group (signal) (%signal-process-group process signal :allow-terminal-leader t))
               (wait-for-group (seconds)
                 (%wait-until-group-gone
                  process (+ (clock) (max seconds +default-poll-interval+))
                  +default-poll-interval+ #'clock #'sleep-seconds))
               (escalate-unless-gone (seconds on-timeout)
                 "Wait up to SECONDS for PROCESS's owned group to exit; call
the ON-TIMEOUT continuation only if it is still alive afterward. Expresses
the watcher's SIGTERM -> SIGKILL -> give-up escalation as a chain of
continuations instead of nested UNLESS forms."
                 (unless (wait-for-group seconds) (funcall on-timeout)))
               (run-cancellation-watcher ()
                 "The cancellation watcher thread's body: block until TOKEN is
cancelled (or COMMUNICATE finishes first), then escalate SIGTERM -> SIGKILL
against PROCESS's owned group exactly like %COMMUNICATE-BASE's own timeout
escalation, recording any signalling failure for the main thread to re-raise."
                 (loop until (or (finished-p) (cancellation-requested-p token))
                       do (sleep +default-poll-interval+))
                 (when (and (not (finished-p)) (cancellation-requested-p token))
                   (mark-cancelled)
                   (%log :warn "process cancelled, escalating" :pid (process-id process))
                   (handler-case
                       (when (%process-group-alive-p process)
                         (signal-owned-group 15)
                         (escalate-unless-gone
                          grace-period
                          (lambda ()
                            (signal-owned-group 9)
                            (escalate-unless-gone
                             grace-period
                             (lambda () (error "Owned process group remained alive after SIGKILL."))))))
                     (error (condition)
                       (record-watcher-error
                        (make-condition 'process-io-error :stream :cleanup :cause condition)))))))
        (setf watcher
              (and token (not terminal-at-entry-p)
                   (sb-thread:make-thread #'run-cancellation-watcher
                                          :name "process-kit cancellation watcher")))
        (unwind-protect
             (let ((*current-cancellation-token* token))
               (let ((result (apply *communicate-without-cancellation* process
                                     (%plist-without options '(:cancellation-token :on-cancel)))))
                 (when (and (not terminal-at-entry-p) token (cancellation-requested-p token))
                   (mark-cancelled))
                 (when (and (not terminal-at-entry-p) (cancelled-p))
                   (setf (process-result-cancelled-p result) t))
                 (when (and (not terminal-at-entry-p) (cancelled-p) (eq on-cancel :error))
                   (error 'process-cancelled-error :result result))
                 result))
          (mark-finished)
          (when watcher
            (when (eq (sb-thread:join-thread
                       watcher :timeout (+ (* 2 grace-period) (* 3 +default-poll-interval+)) :default :timed-out)
                      :timed-out)
              (error 'process-io-error
                     :stream :cleanup
                     :cause (make-condition 'simple-error
                                            :format-control "Cancellation watcher did not terminate.")))
            (let ((condition (watcher-error)))
              (when condition (error condition)))))))))
