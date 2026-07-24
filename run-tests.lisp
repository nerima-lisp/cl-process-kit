;;;; run-tests.lisp
;;;;
;;;; Bootstrap script: point ASDF's source-registry at this checkout, load
;;;; the test system, and run it. cl-weave itself must already be reachable
;;;; through CL_SOURCE_REGISTRY (the Nix flake's devShell/checks export this;
;;;; a manual invocation should too) -- this script does not guess at a
;;;; sibling checkout path.
;;;;
;;;; Set CL_PROCESS_KIT_COVERAGE=1 to additionally recompile src/ under
;;;; SB-COVER instrumentation and print an expression/branch coverage
;;;; report after the suite runs. Off by default: instrumentation forces a
;;;; full recompile and adds per-form bookkeeping overhead that a normal
;;;; `nix flake check` / CI run shouldn't pay for. SB-COVER isn't loaded
;;;; until CL-WEAVE:COVERAGE-SUPPORT-AVAILABLE-P requires it, so every
;;;; SB-COVER reference below goes through FIND-SYMBOL/PROCLAIM data
;;;; instead of a literal SB-COVER:... token, which the reader would
;;;; otherwise have to resolve before that require ever runs.
;;;;
;;;; Usage: sbcl --script run-tests.lisp
;;;;        CL_PROCESS_KIT_COVERAGE=1 sbcl --script run-tests.lisp

(require :asdf)

(defun script-directory ()
  (make-pathname :name nil
                 :type nil
                 :defaults (or *load-truename*
                               *compile-file-truename*
                               (error "Unable to determine the script location"))))

(defun cl-weave-symbol (name) (find-symbol name "CL-WEAVE"))
(defun sb-cover-symbol (name) (find-symbol name "SB-COVER"))

(defun set-coverage-instrumentation (level)
  (proclaim (list 'optimize (list (sb-cover-symbol "STORE-COVERAGE-DATA") level))))

(defun coverage-percentage (covered total)
  (if (zerop total) 100.0 (* 100.0 (/ covered total))))

(defun print-coverage-report (root)
  (let* ((statistics (funcall (cl-weave-symbol "COVERAGE-STATISTICS")
                              :include-pathnames (list (merge-pathnames "src/" root))))
         (expression-covered (getf statistics :expression-covered))
         (expression-total (getf statistics :expression-total))
         (branch-covered (getf statistics :branch-covered))
         (branch-total (getf statistics :branch-total)))
    (format t "~&~%Coverage (src/):~%  expression ~,1F% (~D/~D)~%  branch     ~,1F% (~D/~D)~%"
            (coverage-percentage expression-covered expression-total) expression-covered expression-total
            (coverage-percentage branch-covered branch-total) branch-covered branch-total)
    (funcall (cl-weave-symbol "SAVE-COVERAGE") (merge-pathnames "coverage.dat" root))))

(let* ((root (script-directory))
       (registry-entry (format nil "~A//" (namestring root)))
       (existing (uiop:getenv "CL_SOURCE_REGISTRY"))
       (track-coverage-p (let ((flag (uiop:getenv "CL_PROCESS_KIT_COVERAGE")))
                           (and flag (plusp (length flag))))))
  (setf (uiop:getenv "CL_SOURCE_REGISTRY")
        (if (and existing (plusp (length existing)))
            (format nil "~A:~A" registry-entry existing)
            registry-entry))
  (asdf:initialize-source-registry)
  (handler-case
      (progn
        (when track-coverage-p
          ;; Requiring SB-COVER here, before ASDF loads CL-WEAVE, sidesteps an
          ;; ASDF/PLAN:SYSTEM-OUT-OF-DATE condition that CL-WEAVE's own
          ;; internal (REQUIRE :SB-COVER) can otherwise hit on a cold FASL
          ;; cache and have no handler positioned to recover from.
          (require :sb-cover)
          (asdf:load-system "cl-weave")
          (setf track-coverage-p (funcall (cl-weave-symbol "COVERAGE-SUPPORT-AVAILABLE-P"))))
        (when track-coverage-p (set-coverage-instrumentation 3))
        (asdf:load-system "cl-process-kit" :force track-coverage-p)
        (when track-coverage-p (set-coverage-instrumentation 0))
        (asdf:load-system "cl-process-kit/test"))
    (asdf:missing-dependency (condition)
      (format *error-output*
              "~&Unable to load cl-process-kit/test: ~A~%~
Point CL_SOURCE_REGISTRY at a cl-weave checkout (or run under `nix develop` / `nix flake check`, which do this for you) and retry.~%"
              condition)
      (uiop:quit 1)))
  (when track-coverage-p (funcall (cl-weave-symbol "RESET-COVERAGE")))
  (unless (funcall (symbol-function (find-symbol "RUN-TESTS" "CL-PROCESS-KIT/TEST")))
    (uiop:quit 1))
  (when track-coverage-p (print-coverage-report root))
  (uiop:quit 0))
