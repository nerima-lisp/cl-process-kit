;;;; run-benchmarks.lisp
;;;;
;;;; Bootstrap script: point ASDF's source-registry at this checkout and run
;;;; a fixed suite of latency/throughput/allocation benchmarks against
;;;; cl-process-kit. Companion to run-tests.lisp -- same CL_SOURCE_REGISTRY
;;;; bootstrap, same "point it at a nerima-lisp checkout" contract -- but
;;;; reports numbers instead of pass/fail.
;;;;
;;;; This exists to make "how fast is cl-process-kit" an answerable,
;;;; re-runnable question instead of an impression: every number below is
;;;; wall-clock milliseconds/iteration AND bytes consed/iteration (the
;;;; latter is the one worth trusting across runs -- SBCL's allocation
;;;; counter is exact and immune to machine load, unlike wall-clock time).
;;;;
;;;; Absolute numbers are platform-dependent -- in particular, per-call
;;;; latency here is dominated by SB-EXT:RUN-PROGRAM's own child-launch
;;;; cost, not this library's code (see the performance-floor memory
;;;; notes for the full breakdown, including why :FD-LIMIT below closes
;;;; part of that gap on hosts with a very large ambient RLIMIT_NOFILE).
;;;; Compare BEFORE/AFTER on the SAME machine, not this script's numbers
;;;; against numbers from a different machine or CI.
;;;;
;;;; Usage: sbcl --dynamic-space-size 2048 --script run-benchmarks.lisp

(require :asdf)

(defun script-directory ()
  (make-pathname :name nil
                 :type nil
                 :defaults (or *load-truename*
                               *compile-file-truename*
                               (error "Unable to determine the script location"))))

(let* ((root (script-directory))
       (registry-entry (format nil "~A//" (namestring root)))
       (existing (uiop:getenv "CL_SOURCE_REGISTRY")))
  (setf (uiop:getenv "CL_SOURCE_REGISTRY")
        (if (and existing (plusp (length existing)))
            (format nil "~A:~A" registry-entry existing)
            registry-entry))
  (asdf:initialize-source-registry)
  (asdf:load-system "cl-process-kit"))

(defun bench (label n thunk)
  (sb-ext:gc :full t)
  (let ((wall-start (get-internal-real-time))
        (consed-start (sb-ext:get-bytes-consed)))
    (dotimes (i n) (funcall thunk))
    (let* ((elapsed (/ (- (get-internal-real-time) wall-start) (float internal-time-units-per-second)))
           (consed (- (sb-ext:get-bytes-consed) consed-start)))
      (format t "~&~A~%  ~D iters, ~,3Fs wall (~,4Fms/iter), ~,1FMiB consed (~,1FKiB/iter)~%"
              label n elapsed (* 1000 (/ elapsed n))
              (/ consed 1048576.0) (/ consed n 1024.0)))))

(format t "~&== cl-process-kit benchmarks ==~%")
(format t "See performance-floor memory notes (or CHANGELOG.md) before~%")
(format t "interpreting absolute latency numbers -- they are dominated by~%")
(format t "SB-EXT:RUN-PROGRAM's own child-launch cost on this platform.~%~%")

(bench "spawn+communicate latency: run true" 100
       (lambda () (process-kit:run "true" nil :search t)))

(bench "spawn+communicate latency: run true, :fd-limit 1024" 100
       (lambda () (process-kit:run "true" nil :search t :fd-limit 1024)))

(bench "spawn+communicate latency: run echo hello" 100
       (lambda () (process-kit:run "echo" (list "hello") :search t)))

(let ((payload (sb-ext:string-to-octets (make-string (* 4 1024 1024) :initial-element #\x))))
  (bench "throughput: run cat 4MiB octets stdin->stdout" 20
         (lambda () (process-kit:run "cat" nil :input payload :result-type :octets
                                     :search t :max-output-characters nil))))

(bench "pipeline: 3-stage printf | tr | tr" 50
       (lambda ()
         (process-kit:run-pipeline
          (list (process-kit:make-command "printf" (list "hello world") :search t)
                (process-kit:make-command "tr" (list "a-z" "A-Z") :search t)
                (process-kit:make-command "tr" (list "A-Z" "a-z") :search t)))))

(uiop:quit 0)
