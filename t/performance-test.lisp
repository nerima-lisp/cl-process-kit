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
      (expect (< consed (* 8 size)) :to-be-truthy))))
