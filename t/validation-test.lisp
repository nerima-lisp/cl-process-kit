;;;; t/validation-test.lisp
;;;;
;;;; MAKE-COMMAND and SPAWN-NATIVE are almost entirely guard clauses -- one
;;;; (UNLESS ok (ERROR ...)) per malformed-input shape -- and the native
;;;; trampoline decodes a fixed-layout error record through a handful of pure
;;;; helpers. The behavioral suites exercise the happy path; this file drives
;;;; the rejection arm of every guard and every branch of the pure decoders,
;;;; data-first: CL-WEAVE:IT-EACH expands each (label program arguments
;;;; keyword-plist) row below into its own independently-reported test case
;;;; at macro-expansion time, so a new guard is covered by adding a row, not
;;;; a test, and a failing row's label shows up directly in the report.

(in-package #:cl-process-kit/test)

(defun raises-error-p (thunk)
  "True when calling THUNK signals a CL:ERROR."
  (handler-case (progn (funcall thunk) nil)
    (error () t)))

(describe "make-command guard clauses"
  (cl-weave:it-each
      (("an empty program" "" nil ())
       ("a program that is not a string" 42 nil ())
       ("a program containing a NUL byte" #.(format nil "a~Cb" (code-char 0)) nil ())
       ("arguments that are not a list" "/bin/true" "not-a-list" ())
       ("a non-string argument" "/bin/true" ("ok" 5) ())
       ("a dotted (improper) arguments list" "/bin/true" ("a" . "b") ())
       ("an argument containing a NUL byte" "/bin/true" (#.(format nil "a~Cb" (code-char 0))) ())
       ("a non-integer :search" "/bin/true" nil (:search 7))
       ("a non-list :environment-policy" "/bin/true" nil (:environment-policy 42))
       ("an :environment-policy entry without an = sign" "/bin/true" nil
        (:environment-policy ("NO-EQUALS-SIGN")))
       ("an :environment-policy entry with a leading =" "/bin/true" nil
        (:environment-policy ("=leading-equals")))
       ("a duplicate :environment-policy key" "/bin/true" nil (:environment-policy ("A=1" "A=2")))
       ("an :environment-policy entry containing a NUL byte" "/bin/true" nil
        (:environment-policy (#.(format nil "A=~C" (code-char 0)))))
       ("a non-string :environment-update value" "/bin/true" nil (:environment-update (("A" . 1))))
       ("an :environment-update key containing =" "/bin/true" nil (:environment-update (("A=B" . "1"))))
       ("an empty :environment-update key" "/bin/true" nil (:environment-update (("" . "1"))))
       ("a duplicate :environment-update key" "/bin/true" nil
        (:environment-update (("A" . "1") ("A" . "2"))))
       ("a dotted (improper) :environment-update list" "/bin/true" nil
        (:environment-update (("A" . "1") . "not-a-list")))
       ("an unknown :stdin policy" "/bin/true" nil (:stdin :bogus))
       ("a :stdin policy of :stdout, which is only valid for :stderr" "/bin/true" nil (:stdin :stdout))
       ("an unknown :stdout policy" "/bin/true" nil (:stdout :nope))
       ("an unknown :result-type" "/bin/true" nil (:result-type :bogus))
       ("an unknown :decoding-error-policy" "/bin/true" nil (:decoding-error-policy :bogus)))
      "rejects ~A"
      (label program arguments keyword-plist)
    (declare (ignore label))
    (expect (raises-error-p (lambda () (apply #'make-command program arguments keyword-plist)))
            :to-be-truthy))

  (it "accepts a fully-specified valid command, deep-copying mutable slots"
    (let* ((args (list "a" "b"))
           (command (make-command "echo" args
                                  :environment-policy (list "LANG=C")
                                  :environment-update (list (cons "X" "1") (cons "Y" nil))
                                  :stderr :stdout :result-type :octets :search t)))
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
  (cl-weave:it-each (("a structurally invalid fd mapping" (:fd-mappings ((x . y))))
                     ("duplicate fd targets" (:fd-mappings ((1 . 2) (1 . 3))))
                     ("joining a pre-existing process group" (:process-group 42)))
      "rejects ~A"
      (label spawn-native-options)
    (declare (ignore label))
    (expect (raises-error-p (lambda () (apply #'process-kit::spawn-native "/bin/true" nil spawn-native-options)))
            :to-be-truthy)))
