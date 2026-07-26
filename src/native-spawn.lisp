(in-package #:process-kit)

(progn
  (define-condition native-process-launch-error (process-launch-error)
    ((phase :initarg :phase :reader native-process-launch-error-phase)
     (errno :initarg :errno :reader native-process-launch-error-errno))
    (:report
     (lambda (condition stream)
       (format stream "Native subprocess launch failed during ~S (errno ~D)."
               (native-process-launch-error-phase condition)
               (native-process-launch-error-errno condition)))))

  (defparameter *native-spawn-program*
    (or (sb-ext:posix-getenv "CL_PROCESS_KIT_SPAWN")
        "cl-process-kit-spawn"))

  (defparameter +native-spawn-phases+
    (list (cons 1 :argument) (cons 2 :fd-setup) (cons 3 :chdir) (cons 4 :session)
          (cons 5 :process-group) (cons 6 :credentials) (cons 7 :resource-limit) (cons 8 :exec))
    "Maps the native spawn trampoline's (native/spawn.c) phase byte codes to
the keyword PROCESS-KIT reports a NATIVE-PROCESS-LAUNCH-ERROR failed during.")

  (defun %native-spawn-phase (number)
    (or (cdr (assoc number +native-spawn-phases+)) :unknown))

  (defun %native-uint32 (octets offset)
    (logior (aref octets offset)
            (ash (aref octets (+ offset 1)) 8)
            (ash (aref octets (+ offset 2)) 16)
            (ash (aref octets (+ offset 3)) 24)))

  (defun %native-int32 (octets offset)
    (let ((unsigned (%native-uint32 octets offset)))
      (if (logbitp 31 unsigned)
          (- unsigned #x100000000)
          unsigned)))

  (defun %native-option (name value)
    (list name (princ-to-string value)))

  (defun %native-fd-source (source)
    (etypecase source
      (integer source)
      (keyword
       (ecase source
         (:close -1)
         (:null -2)))))

  (defun %native-spawn-arguments
      (program arguments error-fd fd-mappings pass-fds session process-group
       detached uid gid groups mask resource-limits directory)
    (append
     (%native-option "--error-fd" error-fd)
     (loop for (target . source) in fd-mappings
           append (%native-option
                   "--map"
                   (format nil "~D:~D" target (%native-fd-source source))))
     (loop for fd in pass-fds append (%native-option "--pass" fd))
     (when session (%native-option "--session" 1))
     (when process-group (%native-option "--pgroup" process-group))
     (when detached (%native-option "--detached" 1))
     (when uid (%native-option "--uid" uid))
     (when gid (%native-option "--gid" gid))
     (when groups
       (%native-option "--groups" (format nil "~{~D~^,~}" groups)))
     (when mask (%native-option "--umask" mask))
     (loop for (resource soft hard) in resource-limits
           append (%native-option
                   "--rlimit"
                   (format nil "~(~A~):~A:~A" resource soft hard)))
     (when directory (%native-option "--chdir" (namestring directory)))
     (list "--" (namestring program))
     arguments))

  (defun %native-check-fd-mappings (fd-mappings)
    (let ((targets (make-hash-table)))
      (dolist (mapping fd-mappings)
        (%ensure (and (consp mapping)
                      (typep (car mapping) '(integer 0))
                      (or (typep (cdr mapping) '(integer 0))
                          (member (cdr mapping) '(:close :null))))
                 "Invalid native FD mapping ~S." mapping)
        (%ensure (not (gethash (car mapping) targets))
                 "Duplicate native FD target ~D." (car mapping))
        (setf (gethash (car mapping) targets) t))))

  (defun spawn-native
      (program arguments
       &key (search nil) fd-mappings pass-fds session process-group detached
         uid gid groups umask resource-limits directory environment
         input output error (external-format :default) status-hook)
    "Launch PROGRAM through the native trampoline and synchronously report setup errors."
    (setf program (if search
                      (%resolve-executable program arguments environment directory)
                      (namestring program)))
    (%native-check-fd-mappings fd-mappings)
    (%ensure (or (null process-group) (eql process-group 0))
             "Joining an existing process group is unsupported by this backend.")
    (multiple-value-bind (read-fd write-fd) (sb-posix:pipe)
      (let ((process nil)
            (read-stream nil))
        (unwind-protect
             (progn
               (%ensure (not (or (member write-fd pass-fds)
                                 (find write-fd fd-mappings :key #'car)
                                 (find write-fd fd-mappings :key #'cdr)))
                        "The reserved launch-error FD ~D collides with an FD option."
                        write-fd)
               (setf read-stream
                     (sb-sys:make-fd-stream
                      read-fd :input t :element-type '(unsigned-byte 8)
                      :buffering :none :auto-close t))
               (setf process
                     (spawn
                      *native-spawn-program*
                      (%native-spawn-arguments
                       program arguments write-fd fd-mappings pass-fds
                       session process-group detached uid gid groups umask
                       resource-limits directory)
                      :search t :input input :output output :error error
                      :environment environment :external-format external-format
                      :status-hook status-hook
                      :preserve-fds
                      (remove-duplicates
                       (append (list write-fd) pass-fds
                               (remove-if-not #'integerp
                                              (mapcar #'cdr fd-mappings))))))
               (sb-posix:close write-fd)
               (setf write-fd nil)
               (let ((record (make-array 8 :element-type '(unsigned-byte 8)))
                     (count 0))
                 (loop while (< count 8)
                       for next = (read-sequence record read-stream :start count)
                       do (if (= next count) (return) (setf count next)))
                 (unless (zerop count)
                   (unless (= count 8)
                     (error "Truncated native launch-error record (~D bytes)." count))
                   (let ((phase (%native-spawn-phase (%native-uint32 record 0)))
                         (errno (%native-int32 record 4)))
                     (process-wait process)
                     (error 'native-process-launch-error
                            :program program :arguments (copy-list arguments)
                            :directory directory :cause errno
                            :phase phase :errno errno))))
               process)
          (when write-fd
            (ignore-errors (sb-posix:close write-fd)))
          (when read-stream
            (ignore-errors (close read-stream)))
          (when (and process
                     (not (process-handle-reaped-p process))
                     (not (process-alive-p process)))
            (ignore-errors (process-try-wait process))))))))
