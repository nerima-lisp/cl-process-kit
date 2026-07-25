;;;; t/performance-test.lisp
;;;;
;;;; A performance regression guard, deliberately built on SB-EXT:GET-BYTES-
;;;; CONSED rather than wall-clock timing. SBCL's allocation counter is exact
;;;; and immune to machine load/CI noise; asserting on elapsed milliseconds
;;;; here would be flaky by construction. See run-benchmarks.lisp for the
;;;; (informational, not asserted) wall-clock + allocation benchmark suite,
;;;; and the performance-floor memory notes for why per-call latency itself
;;;; is dominated by SB-EXT:RUN-PROGRAM's own fork() cost and not something
;;;; a test in this file could meaningfully bound.

(in-package #:cl-process-kit/test)

(defun %bytes-consed (thunk)
  "Run THUNK after a full GC and return bytes SBCL consed during it."
  (sb-ext:gc :full t)
  (let ((before (sb-ext:get-bytes-consed)))
    (funcall thunk)
    (- (sb-ext:get-bytes-consed) before)))

(describe "octet capture allocation"
  (it "round-trips a large payload consing at most a small constant multiple of it"
    (let* ((size (* 16 1024 1024))
           (payload (make-array size :element-type '(unsigned-byte 8) :initial-element 120))
           (result nil)
           (consed (%bytes-consed
                    (lambda ()
                      (setf result (run "cat" nil :input payload :result-type :octets
                                        :search t :max-output-characters nil))))))
      (expect (equalp (process-result-stdout result) payload) :to-be-truthy)
      ;; A coarse safety net, not a precise regression detector: the current
      ;; chunked-copier design measures ~3-4x the payload consed (collecting
      ;; read chunks once, assembling the final result once, plus fixed
      ;; per-call overhead -- see the performance-floor memory notes). A
      ;; geometric-growth buffer that re-copies already-accumulated data on
      ;; every growth step measured ~4-5.6x -- close enough to the current
      ;; design's range that THIS bound would not have caught that specific
      ;; regression (it was caught by direct A/B measurement instead, not by
      ;; a test). 8x is set to catch a qualitatively worse mistake -- e.g.
      ;; accidental quadratic blowup -- without flaking on ordinary
      ;; GC/environment noise; tighten it only after collecting enough CI
      ;; history to know the real noise floor.
      (expect (< consed (* 8 size)) :to-be-truthy))))
