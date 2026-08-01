;;;; src/capture.lisp
;;;;
;;;; %CAPTURE accumulates one output stream's bytes up to MAX-OUTPUT-CHARACTERS,
;;;; decoding to text on the fly when RESULT-TYPE is :STRING. Decoding never
;;;; splits a multibyte character across a read boundary: %DECODE-COMPLETE-PREFIX
;;;; only decodes as many octets as form complete characters and leaves the rest
;;;; pending for the next chunk -- delegated to CL-CODEC-KIT:DECODE-PREFIX and
;;;; CL-CODEC-KIT:LENIENT-DECODE-PREFIX, which generalize the same primitive
;;;; this file used to hand-roll for UTF-8 alone.

(in-package #:process-kit)

(defstruct (%capture
            (:constructor %make-capture (limit result-type external-format decoding-error-policy)))
  limit
  result-type
  external-format
  decoding-error-policy
  (data nil)
  (pending-octets (make-array 0 :element-type '(unsigned-byte 8)))
  (count 0 :type integer)
  (truncated-p nil :type boolean))

(defun %capture-accept-bounded (capture available push)
  "Accept as much of an AVAILABLE-length chunk as CAPTURE's limit still has
room for: call the continuation PUSH with the accepted count if that's
positive, advance CAPTURE's running COUNT by it, and mark CAPTURE truncated
if fewer than AVAILABLE were accepted. Shared by %CAPTURE-APPEND-DECODED
(string mode) and %CAPTURE-APPEND's octets branch, which differ only in
what a chunk IS -- a decoded string or a raw octet buffer -- not in this
accept/truncate accounting."
  (let* ((limit (%capture-limit capture))
         (remaining (and limit (max 0 (- limit (%capture-count capture)))))
         (accepted (if remaining (min available remaining) available)))
    (when (plusp accepted)
      (funcall push accepted)
      (incf (%capture-count capture) accepted))
    (when (< accepted available) (setf (%capture-truncated-p capture) t))))

(defun %capture-append-decoded (capture decoded)
  (%capture-accept-bounded
   capture (length decoded)
   (lambda (accepted) (push (subseq decoded 0 accepted) (%capture-data capture)))))

(defun %decode-complete-prefix (octets external-format decoding-error-policy)
  "Decode as much of OCTETS as forms complete characters under
EXTERNAL-FORMAT, returning (VALUES STRING END) -- END an index into OCTETS,
matching this function's callers, whereas CL-CODEC-KIT's own primitives
return a leftover octet vector instead; END is derived from its length since
both always return OCTETS' own trailing subsequence. Delegates to
CL-CODEC-KIT:LENIENT-DECODE-PREFIX for :REPLACE (replacing an invalid
sequence with U+FFFD, matching this project's own prior
:REPLACEMENT-CHARACTER default rather than CL-CODEC-KIT's babel-matching
#x1A) and CL-CODEC-KIT:DECODE-PREFIX for :ERROR (an invalid sequence
propagates as a CL-CODEC-KIT-ERROR; %CAPTURE-APPEND's caller chain --
%RUN-COPIER-THREAD -- already wraps any ERROR into PROCESS-IO-ERROR, so no
explicit HANDLER-CASE is needed here)."
  (let ((encoding (%codec-kit-encoding external-format)))
    (multiple-value-bind (string leftover)
        (if (eq decoding-error-policy :replace)
            (cl-codec-kit:lenient-decode-prefix
             octets :encoding encoding :replacement #\Replacement_Character)
            (cl-codec-kit:decode-prefix octets :encoding encoding))
      (values string (- (length octets) (length leftover))))))

(defun %capture-append (capture buffer count)
  (if (eq (%capture-result-type capture) :octets)
      (%capture-accept-bounded
       capture count
       (lambda (accepted) (push (subseq buffer 0 accepted) (%capture-data capture))))
      (cond
        ((and (%capture-limit capture) (>= (%capture-count capture) (%capture-limit capture)))
         (when (plusp count) (setf (%capture-truncated-p capture) t)))
        (t
         (let* ((pending (%capture-pending-octets capture))
                (octets (concatenate '(vector (unsigned-byte 8)) pending (subseq buffer 0 count))))
           (multiple-value-bind (decoded end)
               (%decode-complete-prefix
                octets (%capture-external-format capture) (%capture-decoding-error-policy capture))
             (%capture-append-decoded capture decoded)
             (if (and (%capture-limit capture)
                      (>= (%capture-count capture) (%capture-limit capture)))
                 (progn
                   (when (< end (length octets)) (setf (%capture-truncated-p capture) t))
                   (setf (%capture-pending-octets capture)
                         (make-array 0 :element-type '(unsigned-byte 8))))
                 (setf (%capture-pending-octets capture) (subseq octets end)))))))))

(defun %capture-value (capture stream-name)
  (if (eq (%capture-result-type capture) :octets)
      (let ((result (make-array (%capture-count capture) :element-type '(unsigned-byte 8)))
            (offset 0))
        (dolist (chunk (nreverse (%capture-data capture)))
          (replace result chunk :start1 offset)
          (incf offset (length chunk)))
        result)
      (progn
        (when (plusp (length (%capture-pending-octets capture)))
          (handler-case
              (%capture-append-decoded
               capture
               (cl-codec-kit:octets-to-string
                (%capture-pending-octets capture)
                :encoding (%codec-kit-encoding (%capture-external-format capture))
                :errorp (eq (%capture-decoding-error-policy capture) :error)
                :replacement #\Replacement_Character))
            (cl-codec-kit:cl-codec-kit-error (condition)
              (error 'process-io-error :stream stream-name :cause condition)))
          (setf (%capture-pending-octets capture) (make-array 0 :element-type '(unsigned-byte 8))))
        (apply #'concatenate 'string (nreverse (%capture-data capture))))))
