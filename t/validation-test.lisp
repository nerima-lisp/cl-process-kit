;;;; t/validation-test.lisp
;;;;
;;;; MAKE-COMMAND and SPAWN-NATIVE are almost entirely guard clauses -- one
;;;; (UNLESS ok (ERROR ...)) per malformed-input shape -- and the native
;;;; trampoline decodes a fixed-layout error record through a handful of pure
;;;; helpers. The behavioral suites exercise the happy path; this file drives
;;;; the rejection arm of every guard and every branch of the pure decoders,
;;;; data-first: *INVALID-COMMANDS* is a table of (label . thunk) rows, and one
;;;; example walks it so a new guard is covered by adding a row, not a test.

(in-package #:cl-process-kit/test)

(defun raises-error-p (thunk)
  "True when calling THUNK signals a CL:ERROR."
  (handler-case (progn (funcall thunk) nil)
    (error () t)))

(defmacro command-thunk (&rest make-command-args)
  "A (LABEL . THUNK) row whose THUNK calls MAKE-COMMAND with MAKE-COMMAND-ARGS."
  `(cons ',make-command-args (lambda () (make-command ,@make-command-args))))

(defparameter +nul+ (code-char 0))

(defparameter *invalid-commands*
  (list
   ;; program
   (command-thunk "" nil)
   (command-thunk 42 nil)
   (cons "program-with-nul" (lambda () (make-command (format nil "a~Cb" +nul+) nil)))
   ;; arguments
   (command-thunk "/bin/true" "not-a-list")
   (command-thunk "/bin/true" (list "ok" 5))
   (command-thunk "/bin/true" (cons "a" "b"))
   (cons "argument-with-nul" (lambda () (make-command "/bin/true" (list (format nil "a~Cb" +nul+)))))
   ;; search
   (command-thunk "/bin/true" nil :search 7)
   ;; environment-policy
   (command-thunk "/bin/true" nil :environment-policy 42)
   (command-thunk "/bin/true" nil :environment-policy (list "NO-EQUALS-SIGN"))
   (command-thunk "/bin/true" nil :environment-policy (list "=leading-equals"))
   (command-thunk "/bin/true" nil :environment-policy (list "A=1" "A=2"))
   (cons "env-policy-nul"
         (lambda () (make-command "/bin/true" nil :environment-policy (list (format nil "A=~C" +nul+)))))
   ;; environment-update
   (command-thunk "/bin/true" nil :environment-update (list (cons "A" 1)))
   (command-thunk "/bin/true" nil :environment-update (list (cons "A=B" "1")))
   (command-thunk "/bin/true" nil :environment-update (list (cons "" "1")))
   (command-thunk "/bin/true" nil :environment-update (list (cons "A" "1") (cons "A" "2")))
   ;; stdio policies
   (command-thunk "/bin/true" nil :stdin :bogus)
   (command-thunk "/bin/true" nil :stdin :stdout)   ; :stdout is only valid for stderr
   (command-thunk "/bin/true" nil :stdout :nope)
   ;; result / decoding
   (command-thunk "/bin/true" nil :result-type :bogus)
   (command-thunk "/bin/true" nil :decoding-error-policy :bogus)))

(describe "make-command guard clauses"
  (it "rejects every malformed command specification in the table"
    (dolist (row *invalid-commands*)
      (expect (raises-error-p (cdr row)) :to-be-truthy)))

  (it "accepts a fully-specified valid command, deep-copying mutable slots"
    (let* ((args (list "a" "b"))
           (command (make-command "/bin/echo" args
                                  :environment-policy (list "LANG=C")
                                  :environment-update (list (cons "X" "1") (cons "Y" nil))
                                  :stderr :stdout :result-type :octets)))
      (expect (command-p command) :to-be-truthy)
      (expect (command-arguments command) :to-equal '("a" "b"))
      ;; Mutating the caller's list must not reach into the spec.
      (setf (car args) "mutated")
      (expect (command-arguments command) :to-equal '("a" "b")))))

(describe "native-spawn pure helpers"
  (it "maps every phase code to its keyword, unknown codes included"
    (expect (mapcar #'process-kit::%native-spawn-phase '(1 2 3 4 5 6 7 8 0 99))
            :to-equal '(:argument :fd-setup :chdir :session :process-group
                        :credentials :resource-limit :exec :unknown :unknown)))

  (it "translates fd-source keywords and passes integers through"
    (expect (process-kit::%native-fd-source 5) :to-equal 5)
    (expect (process-kit::%native-fd-source :close) :to-equal -1)
    (expect (process-kit::%native-fd-source :null) :to-equal -2))

  (it "decodes little-endian uint32/int32, including the high-bit sign"
    (let ((octets (make-array 8 :element-type '(unsigned-byte 8)
                                :initial-contents '(1 0 0 0 255 255 255 255))))
      (expect (process-kit::%native-uint32 octets 0) :to-equal 1)
      (expect (process-kit::%native-uint32 octets 4) :to-equal 4294967295)
      (expect (process-kit::%native-int32 octets 4) :to-equal -1)
      (expect (process-kit::%native-int32 octets 0) :to-equal 1))))

(defclass %impostor-boundary () ()
  (:documentation "A standard-object that implements neither the clock nor the
sleeper boundary protocol -- used to drive the 'is a standard-object but has no
applicable protocol method' arm of %PROTOCOL-OBJECT-P."))

(describe "boundary-protocol validation"
  (it "rejects a standard-object that satisfies no cl-boundary-kit protocol"
    (let ((impostor (make-instance '%impostor-boundary)))
      (expect (raises-error-p (lambda () (run "/bin/true" nil :clock impostor))) :to-be-truthy)
      (expect (raises-error-p (lambda () (run "/bin/true" nil :sleeper impostor))) :to-be-truthy))))

(describe "spawn-native argument validation"
  (it "rejects a structurally invalid fd mapping"
    (expect (raises-error-p (lambda () (process-kit::spawn-native "/bin/true" nil
                                                                  :fd-mappings (list (cons 'x 'y)))))
            :to-be-truthy))
  (it "rejects duplicate fd targets"
    (expect (raises-error-p (lambda () (process-kit::spawn-native "/bin/true" nil
                                                                  :fd-mappings (list (cons 1 2) (cons 1 3)))))
            :to-be-truthy))
  (it "rejects joining a pre-existing process group"
    (expect (raises-error-p (lambda () (process-kit::spawn-native "/bin/true" nil :process-group 42)))
            :to-be-truthy)))
