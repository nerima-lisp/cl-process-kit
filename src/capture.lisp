;;;; src/capture.lisp
;;;;
;;;; %CAPTURE accumulates one output stream's bytes up to MAX-OUTPUT-CHARACTERS,
;;;; decoding to text on the fly when RESULT-TYPE is :STRING. Decoding never
;;;; splits a multibyte character across a read boundary: %DECODE-COMPLETE-PREFIX
;;;; only decodes as many octets as form complete characters and leaves the rest
;;;; pending for the next chunk.

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

(defun %capture-append-decoded (capture decoded)
  (let* ((limit (%capture-limit capture))
         (remaining (and limit (max 0 (- limit (%capture-count capture)))))
         (accepted (if remaining (min (length decoded) remaining) (length decoded))))
    (when (plusp accepted)
      (push (subseq decoded 0 accepted) (%capture-data capture))
      (incf (%capture-count capture) accepted))
    (when (< accepted (length decoded))
      (setf (%capture-truncated-p capture) t))))

(defun %utf8-external-format-p (external-format)
  (let ((name (if (consp external-format) (first external-format) external-format)))
    (member name '(:default :utf-8) :test #'eq)))

(defun %utf8-complete-prefix-end (octets)
  (let ((length (length octets))
        (index 0))
    (labels ((continuation-p (byte) (<= #x80 byte #xBF))
             (valid-second-p (lead byte)
               (and (continuation-p byte)
                    (case lead
                      (#xE0 (>= byte #xA0))
                      (#xED (<= byte #x9F))
                      (#xF0 (>= byte #x90))
                      (#xF4 (<= byte #x8F))
                      (otherwise t)))))
      (loop while (< index length)
            for lead = (aref octets index)
            for width = (cond
                          ((<= lead #x7F) 1)
                          ((<= #xC2 lead #xDF) 2)
                          ((<= #xE0 lead #xEF) 3)
                          ((<= #xF0 lead #xF4) 4)
                          (t 1))
            do (cond
                 ((= width 1) (incf index))
                 ((>= index (1- length)) (return-from %utf8-complete-prefix-end index))
                 ((not (valid-second-p lead (aref octets (1+ index)))) (incf index))
                 ((< (- length index) width)
                  (if (loop for offset from 2 below (- length index)
                            always (continuation-p (aref octets (+ index offset))))
                      (return-from %utf8-complete-prefix-end index)
                      (incf index)))
                 ((loop for offset from 2 below width
                        always (continuation-p (aref octets (+ index offset))))
                  (incf index width))
                 (t (incf index))))
      length)))

(defun %replacement-external-format (external-format)
  (append (if (consp external-format) external-format (list external-format))
          (list :replacement #\Replacement_Character)))

(defun %decode-complete-prefix (octets external-format decoding-error-policy)
  (if (and (eq decoding-error-policy :replace) (%utf8-external-format-p external-format))
      (let ((end (%utf8-complete-prefix-end octets)))
        (values (sb-ext:octets-to-string
                 octets :end end :external-format (%replacement-external-format external-format))
                end))
      (loop for end from (length octets) downto 0
            do (handler-case
                   (return (values (sb-ext:octets-to-string octets :end end :external-format external-format)
                                   end))
                 (sb-int:character-decoding-error ())))))

(defun %capture-append (capture buffer count)
  (if (eq (%capture-result-type capture) :octets)
      (let* ((limit (%capture-limit capture))
             (remaining (and limit (max 0 (- limit (%capture-count capture)))))
             (accepted (if remaining (min count remaining) count)))
        (when (plusp accepted)
          (push (subseq buffer 0 accepted) (%capture-data capture))
          (incf (%capture-count capture) accepted))
        (when (< accepted count) (setf (%capture-truncated-p capture) t)))
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
             (if (and (%capture-limit capture) (>= (%capture-count capture) (%capture-limit capture)))
                 (progn
                   (when (< end (length octets)) (setf (%capture-truncated-p capture) t))
                   (setf (%capture-pending-octets capture) (make-array 0 :element-type '(unsigned-byte 8))))
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
               (sb-ext:octets-to-string
                (%capture-pending-octets capture)
                :external-format (if (eq (%capture-decoding-error-policy capture) :replace)
                                      (%replacement-external-format (%capture-external-format capture))
                                      (%capture-external-format capture))))
            (sb-int:character-decoding-error (condition)
              (error 'process-io-error :stream stream-name :cause condition)))
          (setf (%capture-pending-octets capture) (make-array 0 :element-type '(unsigned-byte 8))))
        (apply #'concatenate 'string (nreverse (%capture-data capture))))))
