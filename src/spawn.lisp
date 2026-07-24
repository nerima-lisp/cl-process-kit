;;;; src/spawn.lisp
;;;;
;;;; SPAWN is the low-level, asynchronous primitive. It hands back a
;;;; PROCESS-HANDLE wrapping SB-EXT:PROCESS so callers can do their own
;;;; streaming I/O or job control; RUN (in run.lisp) is built on top of it.
;;;; SPAWN-COMMAND is the COMMAND-SPEC-driven convenience wrapper around it.
;;;;
;;;; (SB-POSIX is required by src/package.lisp, the first-loaded file --
;;;; process-group.lisp needs it before this file does.)

(in-package #:process-kit)

(defun %string-contains-nul-p (value) (and (stringp value) (position #\Null value)))

(defun %validate-environment (environment)
  (when environment
    (%ensure (listp environment) "ENVIRONMENT must be a proper list of KEY=VALUE strings.")
    (let ((seen (make-hash-table :test #'equal)))
      (dolist (entry environment)
        (%ensure (stringp entry) "Environment entry must be a string: ~S" entry)
        (%ensure (not (%string-contains-nul-p entry)) "Environment entry contains NUL: ~S" entry)
        (let ((separator (position #\= entry)))
          (%ensure (and separator (plusp separator))
                   "Environment entry must contain a non-empty key followed by =: ~S" entry)
          (let ((key (subseq entry 0 separator)))
            (%ensure (not (gethash key seen)) "Duplicate environment key: ~S" key)
            (setf (gethash key seen) t))))))
  environment)

(defun %validate-spawn-inputs (command arguments environment)
  (%ensure (or (stringp command) (pathnamep command)) "PROGRAM must be a string or pathname.")
  (%ensure (not (%string-contains-nul-p (namestring command))) "PROGRAM contains NUL.")
  (%ensure (listp arguments) "ARGUMENTS must be a proper list of strings.")
  (dolist (argument arguments)
    (%ensure (stringp argument) "Process argument must be a string: ~S" argument)
    (%ensure (not (%string-contains-nul-p argument)) "Process argument contains NUL."))
  (%validate-environment environment))

(defun %cleanup-failed-spawn (raw)
  (when raw
    (let ((pid (ignore-errors (sb-ext:process-pid raw))))
      (when (and pid (handler-case (= (sb-posix:getpgid pid) pid) (sb-posix:syscall-error () nil)))
        (ignore-errors (sb-posix:kill (- pid) 9))))
    (ignore-errors (sb-ext:process-kill raw 9))
    (ignore-errors (sb-ext:process-wait raw))
    (dolist (stream (list (sb-ext:process-input raw) (sb-ext:process-output raw) (sb-ext:process-error raw)))
      (when (streamp stream) (ignore-errors (close stream))))))

(defun spawn (command arguments &key (search nil) input output error environment directory
                                   (external-format :default) status-hook preserve-fds)
  (let ((raw nil) (requested-command command))
    (handler-case
        (progn
          (%validate-spawn-inputs command arguments environment)
          (%ensure (not (eq input t)) "INPUT T cannot safely isolate the child process group.")
          (when search
            (setf command (%resolve-executable command arguments environment directory)))
          (setf raw
                (sb-ext:run-program
                 command arguments :search nil :input input :output output
                 :error error :environment environment :directory directory
                 :external-format external-format :status-hook status-hook
                 :preserve-fds preserve-fds :wait nil :use-posix-spawn nil))
          (let* ((pid (sb-ext:process-pid raw))
                 (pgid (with-posix-errno-case (sb-posix:getpgid pid)
                         (sb-posix:esrch pid))))
            (unless (= pid pgid)
              (error 'process-group-isolation-error :pid pid :pgid pgid))
            (%log :info "process spawned" :program command :pid pid :pgid pgid)
            (%make-process-handle
             :raw-process raw :pid pid :pgid pgid :program command
             :arguments (copy-list arguments) :directory directory
             :started-at (coerce (get-internal-real-time) 'double-float))))
      (process-error (condition)
        (%log :warn "process launch failed" :program requested-command :condition condition)
        (%cleanup-failed-spawn raw)
        (error condition))
      (error (condition)
        (%log :warn "process launch failed" :program requested-command :condition condition)
        (%cleanup-failed-spawn raw)
        (error 'process-launch-error
               :program requested-command :arguments (copy-list arguments)
               :directory directory :cause condition)))))

(defun %environment-key (entry)
  (let ((position (position #\= entry)))
    (if position (subseq entry 0 position) entry)))

(defun %environment-value (name environment)
  (let ((entry (find name environment :key #'%environment-key :test #'string=)))
    (and entry (subseq entry (1+ (position #\= entry))))))

(defun %path-components (path)
  (loop with start = 0
        for end = (position #\: path :start start)
        collect (subseq path start end)
        while end
        do (setf start (1+ end))))

(defun %effective-directory (directory)
  (uiop:ensure-directory-pathname (merge-pathnames (or directory #P"./") *default-pathname-defaults*)))

(defun %executable-file-p (pathname)
  (and (uiop:file-exists-p pathname)
       (not (uiop:directory-exists-p pathname))
       (eql 0 (ignore-errors (sb-posix:access (namestring pathname) sb-posix:x-ok)))))

(defun %resolve-executable (program arguments environment directory)
  (let* ((program-name (namestring program))
         (base-directory (%effective-directory directory))
         (path (%environment-value "PATH" environment))
         (candidates
           (if (position #\/ program-name)
               (list (merge-pathnames program-name base-directory))
               (loop for component in (%path-components (or path ""))
                     when path
                       collect (merge-pathnames
                                program-name
                                (if (string= component "")
                                    base-directory
                                    (uiop:ensure-directory-pathname
                                     (merge-pathnames component base-directory))))))))
    (or (loop for candidate in candidates when (%executable-file-p candidate) return candidate)
        (error 'process-launch-error
               :program program :arguments (copy-list arguments) :directory directory
               :cause (make-condition
                       'simple-error
                       :format-control "Executable ~S was not found in the effective PATH."
                       :format-arguments (list program))))))

(defun %command-environment (command)
  (let ((environment (if (eq (command-environment-policy command) :inherit)
                          (copy-list (sb-ext:posix-environ))
                          (copy-list (command-environment-policy command)))))
    (dolist (update (command-environment-update command) environment)
      (setf environment (delete (car update) environment :key #'%environment-key :test #'string=))
      (when (cdr update)
        (push (concatenate 'string (car update) "=" (cdr update)) environment)))))

(defun %command-stdio (policy stream)
  (case policy
    ((:pipe :capture) :stream)
    (:null nil)
    (:inherit (if (eq stream :stdin)
                  (sb-sys:make-fd-stream (sb-posix:dup 0) :input t :element-type 'character
                                                          :external-format :default :auto-close t)
                  t))
    (:stdout :output)
    (otherwise policy)))

(defun spawn-command (command &key stdin stdout stderr)
  (check-type command command-spec)
  (let* ((environment (%command-environment command))
         (program (command-program command))
         (arguments (command-arguments command))
         (input-policy (or stdin (command-stdin command)))
         (input-stream (%command-stdio input-policy :stdin)))
    (unwind-protect
         (spawn program arguments
                :search (command-search command)
                :input input-stream
                :output (%command-stdio (or stdout (command-stdout command)) :stdout)
                :error (%command-stdio (or stderr (command-stderr command)) :stderr)
                :environment environment
                :directory (command-directory command)
                :external-format (if (eq (command-result-type command) :octets)
                                      :latin-1
                                      (command-external-format command)))
      (when (and (eq input-policy :inherit) (streamp input-stream))
        (close input-stream)))))
