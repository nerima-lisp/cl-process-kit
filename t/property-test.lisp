;;;; t/property-test.lisp
;;;;
;;;; Value-space invariants driven by CL-WEAVE:IT-PROPERTY generators, rather
;;;; than hand-picked examples. Each property states a law that must hold for
;;;; every generated input -- an octet round trip through cat, argument
;;;; preservation, the NUL-rejection guard, the success predicate -- and
;;;; cl-weave shrinks any counterexample to a minimal failing case. This is
;;;; the highest-abstraction layer of the suite: laws, not cases.
;;;;
;;;; CL-WEAVE:IT-FUZZ below states a weaker but broader claim than
;;;; IT-PROPERTY: not "the result equals X" but "this never signals an ERROR"
;;;; -- the right shape for :REPLACE decoding, whose whole contract is that no
;;;; input, however malformed, ever reaches the caller as a condition.
;;;; t/edge-coverage-test.lisp's "UTF-8 decoding edge arms" hand-picks three
;;;; known-malformed byte sequences (a surrogate, an overlong encoding, an
;;;; out-of-range lead byte); this generalizes that same claim across the
;;;; full byte space instead of only the cases someone thought to name.

(in-package #:cl-process-kit/test)

(defun no-nul-p (string) (not (find (code-char 0) string)))

(describe "value-space properties"
  (cl-weave:it-property "cat echoes any octet vector unchanged (feeder/capture round trip)"
      ((bytes (cl-weave:gen-vector (cl-weave:gen-integer :min 0 :max 255) :max-length 48)))
    (let* ((input (coerce bytes '(vector (unsigned-byte 8))))
           (result (run "cat" nil :input input :result-type :octets :search t)))
      (expect result :to-have-succeeded)
      (expect (coerce (process-result-stdout result) 'list) :to-equal (coerce bytes 'list))))

  (cl-weave:it-property "make-command preserves and deep-copies NUL-free string arguments"
      ((args (cl-weave:gen-list (cl-weave:gen-such-that #'no-nul-p (cl-weave:gen-string))
                                :max-length 6)))
    (let ((command (make-command "/bin/true" args)))
      (expect (command-arguments command) :to-equal args)))

  (cl-weave:it-property "make-command rejects any program ending in a NUL byte"
      ((prefix (cl-weave:gen-string)))
    (let ((program (concatenate 'string prefix (string (code-char 0)))))
      (expect (raises-error-p (lambda () (make-command program nil))) :to-be-truthy)))

  (cl-weave:it-property "process-success-p holds exactly for exit code 0"
      ((code (cl-weave:gen-integer :min 0 :max 255)))
    (let ((result (run "/bin/sh" (list "-c" (format nil "exit ~D" code)))))
      (expect (process-success-p result) :to-equal (zerop code))))

  (cl-weave:it-fuzz "run never signals on arbitrary octets decoded as UTF-8 with :replace"
      ((bytes (cl-weave:gen-vector (cl-weave:gen-integer :min 0 :max 255) :max-length 64)))
      (:trials 100)
    (let ((input (coerce bytes '(vector (unsigned-byte 8)))))
      (run "cat" nil :input input :result-type :string :external-format :utf-8
                     :decoding-error-policy :replace :search t))))
