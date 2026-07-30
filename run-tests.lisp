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
;;;; Literal 100% coverage is not attainable here: SB-COVER only instruments
;;;; RUNTIME execution, but DEFMACRO/DEFSTRUCT/DEFPARAMETER bodies run once
;;;; at macro-expansion or load time -- exercising every call site of a
;;;; macro still leaves its *definition* reading as "not executed". Since
;;;; this library pushes validation and accessors through DEFMACRO
;;;; wherever possible, the honest, sustainable form of "aim for 100%" is a
;;;; ratchet: +MINIMUM-*-COVERAGE+ below fail the run if coverage regresses
;;;; below the best level so far reached, so it only ever climbs. Bump
;;;; these constants up (never down) whenever a change legitimately raises
;;;; coverage; a drop means a genuinely-reachable branch lost its test.
;;;;
;;;; The floors are only enforced when the whole suite ran -- see
;;;; CL-PROCESS-KIT/TEST:+SUITE-COMPLETE-P+. A platform that skips part of the
;;;; suite produces a coverage figure that is not comparable to a floor set
;;;; from a complete run, and holding it to that floor reports the skipped
;;;; tests as a "regression".
;;;;
;;;; Usage: sbcl --script run-tests.lisp
;;;;        CL_PROCESS_KIT_COVERAGE=1 sbcl --script run-tests.lisp

(require :asdf)

(defparameter +minimum-expression-coverage+ 87.4
  "Percentage floor for src/ expression coverage; see the coverage-ratchet note above.")

;; 81.5 -> 81.4: unifying %WAIT-UNTIL-TERMINAL/%WAIT-UNTIL-GROUP-GONE/
;; %TERMINATE-PROCESSES's three hand-written "poll until DONE or DEADLINE"
;; loops into one shared %POLL-UNTIL (src/communicate.lisp, src/pipeline.lisp)
;; removed 4 branch points that could only ever be redundant copies of each
;; other, not 4 newly-uncovered ones: covered branches dropped from 548 to
;; 544 and the total dropped from 672 to 668 by the exact same amount, so
;; uncovered branches -- 124 -- did not change at all. A smaller, fully-
;; deduplicated denominator producing a lower percentage against an unchanged
;; numerator is the intended, harmless shape of a DRY-up, not "a genuinely-
;; reachable branch lost its test" the note above warns about; confirmed by
;; the arithmetic above before lowering this floor, not assumed from the
;; refactor's intent alone.
(defparameter +minimum-branch-coverage+ 81.4
  "Percentage floor for src/ branch coverage; see the coverage-ratchet note above.")

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

(defun suite-complete-p ()
  "Whether every test ran, per CL-PROCESS-KIT/TEST:+SUITE-COMPLETE-P+."
  (symbol-value (find-symbol "+SUITE-COMPLETE-P+" "CL-PROCESS-KIT/TEST")))

(defun check-coverage-floor (kind actual minimum)
  (when (< actual minimum)
    (format *error-output* "~&Coverage regression: ~A ~,1F% is below the ~,1F% floor.~%" kind actual minimum)
    (uiop:quit 1)))

(defun coverage-data-path (root)
  "Where to write coverage.dat: ROOT-relative for a normal checkout, but
CL_PROCESS_KIT_COVERAGE_DAT overrides that when ROOT isn't writable -- e.g.
`nix flake check`'s checkout-tests derivation runs this script straight out
of the read-only Nix store and must redirect it into its build sandbox."
  (let ((override (uiop:getenv "CL_PROCESS_KIT_COVERAGE_DAT")))
    (if (and override (plusp (length override))) (pathname override) (merge-pathnames "coverage.dat" root))))

(defun print-coverage-report (root)
  (let* ((statistics (funcall (cl-weave-symbol "COVERAGE-STATISTICS")
                              :include-pathnames (list (merge-pathnames "src/" root))))
         (expression-covered (getf statistics :expression-covered))
         (expression-total (getf statistics :expression-total))
         (branch-covered (getf statistics :branch-covered))
         (branch-total (getf statistics :branch-total))
         (expression-percentage (coverage-percentage expression-covered expression-total))
         (branch-percentage (coverage-percentage branch-covered branch-total)))
    (format t "~&~%Coverage (src/):~%  expression ~,1F% (~D/~D)~%  branch     ~,1F% (~D/~D)~%"
            expression-percentage expression-covered expression-total
            branch-percentage branch-covered branch-total)
    (funcall (cl-weave-symbol "SAVE-COVERAGE") (coverage-data-path root))
    (cond
      ((suite-complete-p)
       (check-coverage-floor :expression expression-percentage +minimum-expression-coverage+)
       (check-coverage-floor :branch branch-percentage +minimum-branch-coverage+))
      (t
       (format t "~&  ratchet not enforced: this platform skips part of the suite, so these~%")
       (format t "  figures are not comparable to the ~,1F%/~,1F% floors.~%"
               +minimum-expression-coverage+ +minimum-branch-coverage+)))))

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
