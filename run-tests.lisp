;;;; run-tests.lisp
;;;;
;;;; Bootstrap script: point ASDF's source-registry at this checkout, load
;;;; the test system, and run it. cl-weave itself must already be reachable
;;;; through CL_SOURCE_REGISTRY (the Nix flake's devShell/checks export this;
;;;; a manual invocation should too) -- this script does not guess at a
;;;; sibling checkout path, but it does bootstrap native/spawn.c into tmp/
;;;; when CL_PROCESS_KIT_SPAWN is unset.
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
;;;; The coverage floors below are enforced only after the complete suite has
;;;; run. Platforms that skip tests cannot produce a comparable coverage
;;;; figure, so the suite-complete marker controls whether the floors apply.
;;;;
;;;; Usage: sbcl --script run-tests.lisp
;;;;        CL_PROCESS_KIT_COVERAGE=1 sbcl --script run-tests.lisp
(require :asdf)

(defparameter +minimum-expression-coverage+ 87.9
  "Percentage floor for src/ expression coverage; see the coverage-ratchet note above.")

(defparameter +minimum-branch-coverage+ 82.1
  "Percentage floor for src/ branch coverage; see the coverage-ratchet note above.")

(defun script-directory ()
  (make-pathname
   :name
   nil
   :type
   nil
   :defaults
   (or *load-truename* *compile-file-truename* (error "Unable to determine the script location"))))

(defun native-spawn-source-path (root)
  (merge-pathnames "native/spawn.c" root))

(defun native-spawn-build-path (root)
  (merge-pathnames "tmp/cl-process-kit-spawn" root))

(defun native-spawn-build-required-p (source output)
  (let ((source-file (probe-file source))
        (output-file (probe-file output)))
    (and
     source-file
     (or
      (null output-file)
      (< (or (file-write-date output-file) 0) (or (file-write-date source-file) 0))))))

(defun ensure-native-spawn-program (root)
  (let ((existing (uiop:getenv "CL_PROCESS_KIT_SPAWN")))
    (unless (and existing (plusp (length existing)))
      (let* ((source (native-spawn-source-path root))
             (output (native-spawn-build-path root)))
        (when (native-spawn-build-required-p source output)
          (ensure-directories-exist output)
          (uiop:run-program
           (list
            "cc"
            "-std=c11"
            "-O2"
            "-Wall"
            "-Wextra"
            "-Werror"
            (namestring source)
            "-o"
            (namestring output))
           :ignore-error-status
           nil
           :output
           *standard-output*
           :error-output
           *error-output*))
        (when (probe-file output)
          (setf (uiop:getenv "CL_PROCESS_KIT_SPAWN") (namestring output)))))))

(defun cl-weave-symbol (name)
  (find-symbol name "CL-WEAVE"))

(defun sb-cover-symbol (name)
  (find-symbol name "SB-COVER"))

(defun set-coverage-instrumentation (level)
  (proclaim (list 'optimize (list (sb-cover-symbol "STORE-COVERAGE-DATA") level))))

(defun coverage-percentage (covered total)
  (if (zerop total) 100.0
    (* 100.0 (/ covered total))))

(defun suite-complete-p ()
  "Whether every test ran, per CL-PROCESS-KIT/TEST:+SUITE-COMPLETE-P+."
  (symbol-value (find-symbol "+SUITE-COMPLETE-P+" "CL-PROCESS-KIT/TEST")))

(defun check-coverage-floor (kind actual minimum)
  (when (< actual minimum)
    (format
     *error-output*
     "~&Coverage regression: ~A ~,1F% is below the ~,1F% floor.~%"
     kind
     actual
     minimum)
    (uiop:quit 1)))

(defun coverage-data-path (root)
  "Where to write coverage.dat: ROOT-relative for a normal checkout, but
CL_PROCESS_KIT_COVERAGE_DAT overrides that when ROOT isn't writable -- e.g.
`nix flake check`'s checkout-tests derivation runs this script straight out
of the read-only Nix store and must redirect it into its build sandbox."
  (let ((override (uiop:getenv "CL_PROCESS_KIT_COVERAGE_DAT")))
    (if (and override (plusp (length override))) (pathname override)
      (merge-pathnames "coverage.dat" root))))

(defun print-coverage-report (root)
  (let* ((statistics
          (funcall
           (cl-weave-symbol "COVERAGE-STATISTICS")
           :include-pathnames
           (list (merge-pathnames "src/" root))))
         (expression-covered (getf statistics :expression-covered))
         (expression-total (getf statistics :expression-total))
         (branch-covered (getf statistics :branch-covered))
         (branch-total (getf statistics :branch-total))
         (expression-percentage (coverage-percentage expression-covered expression-total))
         (branch-percentage (coverage-percentage branch-covered branch-total)))
    (format
     t
     "~&~%Coverage (src/):~%  expression ~,1F% (~D/~D)~%  branch     ~,1F% (~D/~D)~%"
     expression-percentage
     expression-covered
     expression-total
     branch-percentage
     branch-covered
     branch-total)
    (funcall (cl-weave-symbol "SAVE-COVERAGE") (coverage-data-path root))
    (cond
      ((suite-complete-p)
       (check-coverage-floor :expression expression-percentage +minimum-expression-coverage+)
       (check-coverage-floor :branch branch-percentage +minimum-branch-coverage+))
      (t
       (format
        t
        "~&  ratchet not enforced: this platform skips part of the suite, so these~%")
       (format
        t
        "  figures are not comparable to the ~,1F%/~,1F% floors.~%"
        +minimum-expression-coverage+
        +minimum-branch-coverage+)))))

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
  (ensure-native-spawn-program root)
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
Set CL_SOURCE_REGISTRY to cl-weave, or run under nix develop and retry.~%"
              condition)
      (uiop:quit 1)))
  (when track-coverage-p (funcall (cl-weave-symbol "RESET-COVERAGE")))
  ;; A per-test ceiling, not a whole-suite one: `nix flake check`'s
  ;; `timeout 180 sbcl --script run-tests.lisp` (and CI's job-level
  ;; `timeout-minutes`) already bound the WHOLE run, but a single hung test
  ;; still burns that entire budget before failing, with nothing naming which
  ;; test hung. 30s is generous headroom above every observed test (the
  ;; slowest today, a SIGKILL escalation test, is ~1.1s) while staying far
  ;; below the suite-level ceiling, so a genuine deadlock fails fast with a
  ;; CL-WEAVE:TEST-TIMEOUT naming the specific test instead of a bare process
  ;; kill naming nothing. Set via SET rather than a literal
  ;; CL-WEAVE:*DEFAULT-TIMEOUT-MS* token for the same reason SB-COVER symbols
  ;; above go through FIND-SYMBOL: CL-WEAVE is not necessarily loaded until
  ;; the ASDF:LOAD-SYSTEM calls above ran, so the reader must not need to
  ;; resolve the token before that.
  (set (find-symbol "*DEFAULT-TIMEOUT-MS*" "CL-WEAVE") 30000)
  (unless (funcall (symbol-function (find-symbol "RUN-TESTS" "CL-PROCESS-KIT/TEST")))
    (uiop:quit 1))
  (when track-coverage-p (print-coverage-report root))
  (uiop:quit 0))
