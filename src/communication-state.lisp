;;;; src/communication-state.lisp
;;;;
;;;; COMMUNICATE (src/communicate.lisp) may run at most once per
;;;; PROCESS-HANDLE: a second concurrent call is rejected, and repeating it
;;;; with the same options after completion replays the cached result. This
;;;; file is the state machine and option-equality logic behind that
;;;; contract: :IDLE -> :RESERVED -> :COMMUNICATING -> :COMMUNICATED.

(in-package #:process-kit)

(defvar *communication-reservation-owner* nil)

(defun %snapshot-communication-input (input)
  (if (typep input '(or string vector)) (copy-seq input) input))

(defun %normalize-communication-duration (value)
  (if (realp value) (coerce value 'double-float) value))

(defun %make-communication-contract
    (&key input timeout grace-period timeout-signal kill-signal on-timeout
       max-output-characters drain-timeout-seconds result-type external-format
       decoding-error-policy clock sleeper poll-interval)
  (list :input (%snapshot-communication-input input)
        :timeout (%normalize-communication-duration timeout)
        :grace-period (%normalize-communication-duration grace-period)
        :timeout-signal timeout-signal
        :kill-signal kill-signal
        :on-timeout on-timeout
        :max-output-characters max-output-characters
        :drain-timeout-seconds (%normalize-communication-duration drain-timeout-seconds)
        :result-type result-type
        :external-format external-format
        :decoding-error-policy decoding-error-policy
        :clock clock
        :sleeper sleeper
        :poll-interval (%normalize-communication-duration poll-interval)))

(defun %communication-option-value-equal-p (left right)
  (if (and (vectorp left) (vectorp right))
      (and (= (length left) (length right))
           (loop for index below (length left) always (eql (aref left index) (aref right index))))
      (equal left right)))

(defun %communication-contract-equal-p (left right)
  (loop for (left-key left-value) on left by #'cddr
        for (right-key right-value) on right by #'cddr
        always (and (eq left-key right-key)
                    (%communication-option-value-equal-p left-value right-value))))

(defmacro build-communication-contract (&rest keys)
  "Build a communication contract from KEYS' current lexical bindings --
expands (BUILD-COMMUNICATION-CONTRACT INPUT TIMEOUT ...) into
(%MAKE-COMMUNICATION-CONTRACT :INPUT INPUT :TIMEOUT TIMEOUT ...), so each of
the contract's fourteen fields is named once per call site instead of
twice. %BEGIN-COMMUNICATION and %ASYNC-CONTRACT both build the same
contract shape from identically-named local variables; this macro is why
neither has to spell out fourteen keyword/variable pairs by hand."
  `(%make-communication-contract
    ,@(loop for key in keys append (list (intern (string key) :keyword) key))))

(defmacro %check-contract-match (process expected actual)
  "Signal COMMUNICATE-OPTIONS-MISMATCH for PROCESS unless EXPECTED and
ACTUAL -- communication contracts built by %MAKE-COMMUNICATION-CONTRACT --
are equal. The recurring guard behind COMMUNICATE's at-most-once-with-
consistent-options contract, used by both %RESERVE-COMMUNICATION and
%BEGIN-COMMUNICATION."
  `(unless (%communication-contract-equal-p ,expected ,actual)
     (error 'communicate-options-mismatch :process ,process :expected-options ,expected :actual-options ,actual)))

(defun %reserve-communication (process contract owner)
  (with-locked-process-state (state process)
    (let ((expected (%process-state-communication-contract state)))
      (case (%process-state-communication-status state)
        (:communicated
         (%check-contract-match process expected contract)
         :cached)
        (:idle
         (setf (%process-state-communication-contract state) contract
               (%process-state-communication-reservation-owner state) owner
               (%process-state-communication-status state) :reserved)
         :reserved)
        (otherwise
         (%check-contract-match process expected contract)
         (error "COMMUNICATE is already in progress for this process."))))))

(defun %release-communication-reservation (process owner)
  (with-locked-process-state (state process)
    (when (and (eq (%process-state-communication-status state) :reserved)
               (eq (%process-state-communication-reservation-owner state) owner))
      (setf (%process-state-communication-status state) :idle
            (%process-state-communication-contract state) nil
            (%process-state-communication-reservation-owner state) nil)
      t)))

(defun %begin-communication
    (process &rest options &key input timeout grace-period timeout-signal kill-signal on-timeout
                              max-output-characters drain-timeout-seconds result-type external-format
                              decoding-error-policy clock sleeper poll-interval)
  (declare (ignore options))
  (let ((actual-contract
          (build-communication-contract
           input timeout grace-period timeout-signal kill-signal on-timeout
           max-output-characters drain-timeout-seconds result-type external-format
           decoding-error-policy clock sleeper poll-interval)))
    (with-locked-process-state (state process)
      (let ((expected-contract (%process-state-communication-contract state)))
        (case (%process-state-communication-status state)
          (:communicated
           (%check-contract-match process expected-contract actual-contract)
           (%process-state-communication-result state))
          (:reserved
           (%check-contract-match process expected-contract actual-contract)
           (unless (eq (%process-state-communication-reservation-owner state)
                       *communication-reservation-owner*)
             (error "COMMUNICATE is already reserved for this process."))
           (setf (%process-state-communication-status state) :communicating
                 (%process-state-communication-reservation-owner state) nil)
           nil)
          (:communicating
           (%check-contract-match process expected-contract actual-contract)
           (error "COMMUNICATE is already in progress for this process."))
          (otherwise
           (setf (%process-state-communication-contract state) actual-contract
                 (%process-state-communication-status state) :communicating)
           nil))))))

(defun %abort-communication (process)
  (with-locked-process-state (state process)
    (when (eq (%process-state-communication-status state) :communicating)
      (setf (%process-state-communication-status state) :idle
            (%process-state-communication-contract state) nil))))

(defun %cache-process-result (process result)
  (check-type process process-handle)
  (check-type result process-result)
  (with-locked-process-state (state process)
    (or (%process-state-communication-result state)
        (progn
          (setf (%process-state-communication-result state) result
                (%process-state-communication-status state) :communicated
                (%process-state-result state) result
                (%process-state-status state) (process-result-status result)
                (%process-state-group-ownership state) :leader-terminal)
          result))))
