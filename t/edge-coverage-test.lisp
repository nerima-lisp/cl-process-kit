;;;; t/edge-coverage-test.lisp
;;;;
;;;; Branch-level edge cases the behavior-focused suites skip: feeding a child
;;;; from a live stream object (both binary and character), the timeout-expiry
;;;; and "wrong terminal kind" return paths of the PROCESS-HANDLE queries, and
;;;; -- via CL-WEAVE:WITH-MOCKED-FUNCTIONS fault injection -- the copier
;;;; thread's error-capture path. These are the reachable arms of COPIER and
;;;; PROCESS-HANDLE that string/octet inputs and blocking waits never take.

(in-package #:cl-process-kit/test)

;;; --- stream-valued :input -------------------------------------------------
;;;
;;; RUN accepts a string or an octet vector directly; it also accepts an open
;;; STREAM, which %WRITE-PROCESS-INPUT drains through a distinct binary- vs
;;; character-stream arm. WITH-STREAMED-INPUT abstracts "materialize DATA as a
;;; stream of ELEMENT-TYPE, feed it to cat, and hand back the round-tripped
;;; output" so each example asserts only the round trip.

(defun call-with-streamed-input (element-type writer result-type continuation)
  (uiop:with-temporary-file (:pathname path :type "in")
    (with-open-file (out path :direction :output :element-type element-type :if-exists :supersede)
      (funcall writer out))
    (with-open-file (in path :element-type element-type)
      (funcall continuation (run "/bin/cat" nil :input in :result-type result-type)))))

(describe "stream-valued :input"
  (it "feeds a child from a character-stream input, encoding at the boundary"
    (call-with-streamed-input
     'character (lambda (out) (write-string "streamed-chars" out)) :string
     (lambda (result)
       (expect (process-success-p result) :to-be-truthy)
       (expect (process-result-stdout result) :to-equal "streamed-chars"))))

  (it "feeds a child from a binary-stream input without re-encoding"
    (let ((bytes (sb-ext:string-to-octets "streamed-bytes" :external-format :utf-8)))
      (call-with-streamed-input
       '(unsigned-byte 8) (lambda (out) (write-sequence bytes out)) :octets
       (lambda (result)
         (expect (process-success-p result) :to-be-truthy)
         (expect (coerce (process-result-stdout result) 'list) :to-equal (coerce bytes 'list)))))))

;;; --- PROCESS-HANDLE query edge arms --------------------------------------

(describe "process-handle query edge arms"
  (it "process-wait returns NIL once its own timeout expires on a live child"
    (with-process (process (spawn "/bin/sleep" (list "5")))
      (expect (process-wait process :timeout 0.05d0) :to-be-null)))

  (it "process-signal is NIL for a normally exited child and process-exit-code is NIL for a signaled one"
    ;; A clean exit: exit-code is present, signal is absent.
    (with-process (exited (spawn "/bin/sh" (list "-c" "exit 0")))
      (process-wait exited)
      (expect (process-exit-code exited) :to-equal 0)
      (expect (process-signal exited) :to-be-null))
    ;; A SIGKILL: signal is present, exit-code is absent.
    (with-process (killed (spawn "/bin/sleep" (list "5")))
      (process-kill killed)
      (process-wait killed)
      (expect (process-signal killed) :to-equal 9)
      (expect (process-exit-code killed) :to-be-null))))

;;; --- UTF-8 decoding edge arms --------------------------------------------
;;;
;;; %UTF8-COMPLETE-PREFIX-END validates each multibyte lead byte's range
;;; (rejecting overlong forms and UTF-16 surrogates) before decoding. Feeding
;;; the child raw, structurally-invalid sequences drives those rejection arms;
;;; with :REPLACE they surface as replacement characters, never a decode error.

(defun run-raw-bytes (octal-escapes)
  "Run a shell that prints OCTAL-ESCAPES verbatim and capture it as a
:REPLACE-decoded UTF-8 string."
  (run "/bin/sh" (list "-c" (format nil "printf '~A'" octal-escapes))
       :result-type :string :external-format :utf-8 :decoding-error-policy :replace))

(describe "UTF-8 decoding edge arms"
  (it "replaces a UTF-16 surrogate three-byte sequence rather than decoding it"
    (let ((result (run-raw-bytes "\\355\\240\\200")))   ; ED A0 80 -> surrogate D800
      (expect (process-success-p result) :to-be-truthy)
      (expect (find #\Replacement_Character (process-result-stdout result)) :to-be-truthy)))

  (it "replaces an overlong three-byte sequence rather than decoding it"
    (let ((result (run-raw-bytes "\\340\\200\\200")))   ; E0 80 80 -> overlong NUL
      (expect (process-success-p result) :to-be-truthy)
      (expect (find #\Replacement_Character (process-result-stdout result)) :to-be-truthy)))

  (it "replaces an out-of-range four-byte lead rather than decoding it"
    (let ((result (run-raw-bytes "\\364\\220\\200\\200"))) ; F4 90 80 80 -> > U+10FFFF
      (expect (process-success-p result) :to-be-truthy)
      (expect (find #\Replacement_Character (process-result-stdout result)) :to-be-truthy))))

;;; --- copier fault injection ----------------------------------------------
;;;
;;; A copier thread that dies mid-drain must surface its failure as a
;;; PROCESS-IO-ERROR when the streams are drained, not swallow it. The failure
;;; is normally an OS-level read fault; WITH-MOCKED-FUNCTIONS injects it
;;; deterministically by making the capture-append step throw.

;;; --- communicate's at-most-once contract ---------------------------------
;;;
;;; COMMUNICATE reserves a handle and either replays its cached result for an
;;; identical option set or signals COMMUNICATE-OPTIONS-MISMATCH. Option
;;; equality compares octet-vector inputs by contents, not identity -- these
;;; drive the reserved-state contract-comparison arms of communication-state.

(describe "communicate at-most-once contract"
  (it "replays the cached result for identical options and rejects a mismatch"
    (with-process (process (spawn "/bin/sh" (list "-c" "printf x")
                                  :input :stream :output :stream :error :stream))
      (let ((first (communicate process :timeout 5)))
        (expect (eq (communicate process :timeout 5) first) :to-be-truthy)
        (signals communicate-options-mismatch (communicate process :timeout 1)))))

  (it "treats a fresh but content-equal octet-vector input as the same options"
    (with-process (process (spawn "/bin/cat" nil :input :stream :output :stream :error :stream))
      (let* ((bytes (sb-ext:string-to-octets "abc" :external-format :utf-8))
             (first (communicate process :input bytes :result-type :octets)))
        (expect (eq (communicate process :input (copy-seq bytes) :result-type :octets) first)
                :to-be-truthy)))))

(describe "copier error propagation"
  (it "re-signals a copier thread's failure as process-io-error when draining"
    (with-mocked-functions
        (((symbol-function 'process-kit::%capture-append)
          (lambda (&rest _) (declare (ignore _)) (error "injected copier fault"))))
      (signals process-io-error
        (run "/bin/sh" (list "-c" "printf payload")))))

  (it "signals a cleanup process-io-error when a copier will not join even after its stream is closed"
    ;; Force every join to time out: draining must give up and report a
    ;; :cleanup process-io-error rather than hang.
    (with-mocked-functions
        (((symbol-function 'process-kit::%join-copier)
          (lambda (&rest _) (declare (ignore _)) :timed-out)))
      (signals process-io-error
        (run "/bin/sh" (list "-c" "printf payload"))))))

;;; --- process-group signaling edges ---------------------------------------

(describe "process-group signaling"
  (it "rejects an out-of-range signal number"
    (with-process (process (spawn "/bin/sleep" (list "5")))
      (expect (raises-error-p (lambda () (process-terminate process 99))) :to-be-truthy)
      (expect (raises-error-p (lambda () (process-send-leader-signal process 0))) :to-be-truthy)))

  (it "signals the owned process group directly"
    (with-process (process (spawn "/bin/sleep" (list "5")))
      (expect (process-send-group-signal process 15) :to-be-truthy)))

  (it "signals the live group leader directly"
    (with-process (process (spawn "/bin/sleep" (list "5")))
      (expect (process-send-leader-signal process 15) :to-be-truthy))))
