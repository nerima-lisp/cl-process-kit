;;;; run-tests.lisp
;;;;
;;;; Bootstrap script: point ASDF's source-registry at this checkout and at
;;;; the local cl-weave checkout, load the test system, and run it.
;;;;
;;;; Usage: sbcl --script run-tests.lisp

(require :asdf)

(defparameter +cl-weave-directory+
  #P"/Users/take/ghq/github.com/nerima-lisp/cl-weave/")

(defun script-directory ()
  (make-pathname :name nil
                 :type nil
                 :defaults (or *load-truename*
                               *compile-file-truename*
                               (error "Unable to determine the script location"))))

(defun source-registry-entry (directory)
  (format nil "~A//" (namestring directory)))

(defun configure-source-registry (directories)
  (let* ((local-registry (format nil "~{~A~^:~}"
                                 (mapcar #'source-registry-entry directories)))
         (existing-registry (uiop:getenv "CL_SOURCE_REGISTRY"))
         (source-registry (if (and existing-registry
                                   (plusp (length existing-registry)))
                              (format nil "~A:~A" local-registry existing-registry)
                              local-registry)))
    (setf (uiop:getenv "CL_SOURCE_REGISTRY") source-registry)
    (asdf:initialize-source-registry)
    source-registry))

(let ((root (script-directory)))
  (configure-source-registry (list root +cl-weave-directory+))
  (asdf:load-asd (merge-pathnames "cl-process-kit.asd" root))
  (asdf:load-system "cl-process-kit/test")
  (unless (funcall (symbol-function
                    (find-symbol "RUN-TESTS" "CL-PROCESS-KIT/TEST")))
    (uiop:quit 1))
  (uiop:quit 0))
