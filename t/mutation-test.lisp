;;;; t/mutation-test.lisp
;;;;
;;;; Mutation testing: CL-WEAVE systematically mutates a pure function's body
;;;; (flipping arithmetic/comparison operators, boolean literals, and
;;;; conditional branches) and re-checks each variant against the same case
;;;; battery a unit test would use. A mutation the battery fails to notice
;;;; ("survived") marks a gap SB-COVER's line/branch coverage cannot see:
;;;; coverage proves a line executed, not that a wrong result there would be
;;;; caught. The body is read live from src/ on every run (never copied into
;;;; this file), so there is nothing here to fall out of sync with the real
;;;; implementation.

(in-package #:cl-process-kit/test)

(defun %read-defun-forms (pathname)
  "Return every top-level DEFUN form read from PATHNAME.
Read with *PACKAGE* bound to PROCESS-KIT so every symbol in the returned
forms -- the function name, parameters, and any PROCESS-KIT function it
calls -- resolves to the same symbol the real, loaded definition uses."
  (let ((*package* (find-package "PROCESS-KIT")))
    (with-open-file (stream pathname)
      (loop for form = (read stream nil :eof)
            until (eq form :eof)
            when (and (consp form) (eq (first form) 'cl:defun))
              collect form))))

(defun %find-defun-form (relative-path name)
  "Read RELATIVE-PATH's DEFUN named NAME, matching by symbol name (not
identity) since READ interns the file's symbols into *PACKAGE* at read time,
not the target file's own package."
  (let ((pathname (asdf:system-relative-pathname :cl-process-kit relative-path))
        (target-name (string name)))
    (or (find target-name (%read-defun-forms pathname)
              :key (lambda (form) (string (second form)))
              :test #'string=)
        (error "No DEFUN ~A found in ~A." name pathname))))

(defun %defun-lambda-list (defun-form)
  (third defun-form))

(defun %defun-body-form (defun-form)
  "Return DEFUN-FORM's body as a single form, skipping a leading docstring and
wrapping multiple body forms in a PROGN."
  (let ((body (cdddr defun-form)))
    (when (and (stringp (first body)) (rest body))
      (setf body (rest body)))
    (if (rest body) (cons 'cl:progn body) (first body))))

(defun %eval-with-bindings (form lambda-list argument-forms)
  (eval `(let ,(mapcar #'list lambda-list argument-forms) ,form)))

(defun %mutation-oracle (lambda-list cases)
  "Return a CL-WEAVE:RUN-MUTATIONS test function asserting MUTATED-FORM still
satisfies every (ARGUMENT-FORMS . EXPECTED) entry in CASES. A mismatch
signals ASSERTION-FAILURE via EXPECT, which RUN-MUTATIONS reports as a
killed mutation; matching every case leaves the mutation looking survived."
  (lambda (mutated-form mutation)
    (declare (ignore mutation))
    (dolist (case cases t)
      (destructuring-bind (argument-forms expected) case
        (expect (%eval-with-bindings mutated-form lambda-list argument-forms)
                :to-equal expected)))))

(defun %assert-full-mutation-kill (relative-path name cases)
  "Mutate the DEFUN named NAME in RELATIVE-PATH and assert CASES kills every
mutation (a mutation score of 1.0), i.e. the case battery is strong enough to
notice every one-operator change to the real implementation."
  (let* ((defun-form (%find-defun-form relative-path name))
         (lambda-list (%defun-lambda-list defun-form))
         (body (%defun-body-form defun-form))
         (results (cl-weave:run-mutations body (%mutation-oracle lambda-list cases))))
    (cl-weave:assert-mutation-score results 1.0)))

(describe "src/command.lisp: PROCESS-SUCCESS-P mutation coverage"
  (it "the case battery matches the live function on every case"
    (cl-weave:with-soft-assertions
      (dolist (case '((((make-process-result :status :exited :exit-code 0)) t)
                       (((make-process-result :status :exited :exit-code 0 :timed-out-p t)) nil)
                       (((make-process-result :status :exited :exit-code 0 :cancelled-p t)) nil)
                       (((make-process-result :status :signaled :exit-code 0)) nil)
                       (((make-process-result :status :exited :exit-code 1)) nil)))
        (destructuring-bind (argument-forms expected) case
          (expect (process-success-p (eval (first argument-forms))) :to-equal expected)))))
  (it "every mutation of PROCESS-SUCCESS-P's body is killed by the case battery"
    (%assert-full-mutation-kill
     "src/command.lisp" 'process-success-p
     '((((make-process-result :status :exited :exit-code 0)) t)
       (((make-process-result :status :exited :exit-code 0 :timed-out-p t)) nil)
       (((make-process-result :status :exited :exit-code 0 :cancelled-p t)) nil)
       (((make-process-result :status :signaled :exit-code 0)) nil)
       (((make-process-result :status :exited :exit-code 1)) nil)))))

(describe "src/command.lisp: PIPELINE-SUCCESS-P mutation coverage"
  (it "the case battery matches the live function on every case"
    (cl-weave:with-soft-assertions
      (dolist (case '(((42) nil)
                       (((process-kit::make-pipeline-result :results nil)) t)
                       (((process-kit::make-pipeline-result :results nil :timed-out-p t)) nil)
                       (((process-kit::make-pipeline-result :results nil :cancelled-p t)) nil)
                       (((process-kit::make-pipeline-result
                          :results (list (make-process-result :status :exited :exit-code 0))))
                        t)
                       (((process-kit::make-pipeline-result
                          :results (list (make-process-result :status :exited :exit-code 1))))
                        nil)))
        (destructuring-bind (argument-forms expected) case
          (expect (pipeline-success-p (eval (first argument-forms))) :to-equal expected)))))
  (it "every mutation of PIPELINE-SUCCESS-P's body is killed by the case battery"
    (%assert-full-mutation-kill
     "src/command.lisp" 'pipeline-success-p
     '(((42) nil)
       (((process-kit::make-pipeline-result :results nil)) t)
       (((process-kit::make-pipeline-result :results nil :timed-out-p t)) nil)
       (((process-kit::make-pipeline-result :results nil :cancelled-p t)) nil)
       (((process-kit::make-pipeline-result
          :results (list (make-process-result :status :exited :exit-code 0))))
        t)
       (((process-kit::make-pipeline-result
          :results (list (make-process-result :status :exited :exit-code 1))))
        nil)))))
