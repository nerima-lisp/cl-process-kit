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

;;; --- :FD-LIMIT ---------------------------------------------------------
;;;
;;; SB-POSIX has no RLIMIT bindings, so this is a direct SB-ALIEN FFI call
;;; to the system libc's GETRLIMIT/SETRLIMIT. RLIM_T is an unsigned long on
;;; every platform this library targets (macOS and Linux, both LP64), but
;;; RLIMIT_NOFILE's integer value is NOT portable (7 on Linux, 8 on Darwin
;;; -- see native/spawn.c's own PARSE_RESOURCE, which resolves the same
;;; symbolic constant at C compile time instead).
;;;
;;; Why this exists: SB-EXT:RUN-PROGRAM's forked child closes every
;;; inherited file descriptor up to RLIMIT_NOFILE one syscall at a time on
;;; Darwin (its fast /dev/fd/-listing path is dead code in this SBCL
;;; build). On a host with a very large NOFILE soft limit (routine under
;;; Nix/direnv shells -- 524288 was observed locally), that is hundreds of
;;; thousands of wasted CLOSE(2) calls per spawn, confirmed via SB-SPROF
;;; and direct measurement to account for roughly a third of per-call
;;; latency. Lowering the limit is inherited by the child through EXEC
;;; (rlimits survive exec) and therefore changes the child's own ulimit --
;;; a real behavioral difference, not just an internal optimization -- so
;;; SPAWN/RUN only apply it when a caller opts in via :FD-LIMIT.
(sb-alien:define-alien-type nil
  (sb-alien:struct %rlimit (cur sb-alien:unsigned-long) (max sb-alien:unsigned-long)))

(sb-alien:define-alien-routine ("getrlimit" %c-getrlimit) sb-alien:int
  (resource sb-alien:int) (limit (* (sb-alien:struct %rlimit))))

(sb-alien:define-alien-routine ("setrlimit" %c-setrlimit) sb-alien:int
  (resource sb-alien:int) (limit (* (sb-alien:struct %rlimit))))

(defconstant +rlimit-nofile+ #+darwin 8 #+linux 7
  "RLIMIT_NOFILE's <sys/resource.h> integer value. Not portable across
POSIX platforms in general; correct for the two this library targets.")

(defun %get-nofile-limit ()
  "(VALUES SOFT HARD) -- this process's current RLIMIT_NOFILE."
  (sb-alien:with-alien ((limit (sb-alien:struct %rlimit)))
    (%ensure (zerop (%c-getrlimit +rlimit-nofile+ (sb-alien:addr limit)))
             "getrlimit(RLIMIT_NOFILE) failed.")
    (values (sb-alien:slot limit 'cur) (sb-alien:slot limit 'max))))

(defun %set-nofile-limit (soft hard)
  (sb-alien:with-alien ((limit (sb-alien:struct %rlimit)))
    (setf (sb-alien:slot limit 'cur) soft (sb-alien:slot limit 'max) hard)
    (%ensure (zerop (%c-setrlimit +rlimit-nofile+ (sb-alien:addr limit)))
             "setrlimit(RLIMIT_NOFILE) failed.")))

(defun call-with-spawn-fd-limit (limit thunk)
  "Call THUNK with this process's RLIMIT_NOFILE soft limit temporarily
lowered to (MIN LIMIT its-hard-limit), restoring the original limit
afterward regardless of how THUNK exits. A NIL LIMIT calls THUNK directly,
leaving the ambient limit untouched -- SPAWN's default. A process THUNK
forks inherits the lowered limit and (rlimits surviving EXEC) keeps it for
its own lifetime; this process's own limit is back to normal by the time
this function returns."
  (if (null limit)
      (funcall thunk)
      (multiple-value-bind (original-soft original-hard) (%get-nofile-limit)
        (unwind-protect
             (progn (%set-nofile-limit (min limit original-hard) original-hard) (funcall thunk))
          (%set-nofile-limit original-soft original-hard)))))

(defun %string-contains-nul-p (value) (and (stringp value) (position #\Null value)))

(defun %validate-environment (environment)
  (when environment
    (%ensure (listp environment) "ENVIRONMENT must be a proper list of KEY=VALUE strings.")
    (let ((seen (make-hash-table :test #'equal)))
      (dolist (entry environment)
        (%ensure (stringp entry) "Environment entry must be a string: ~S" entry)
        (%ensure (not (%string-contains-nul-p entry)) "Environment entry contains NUL: ~S" entry)
        (%validate-environment-entry-shape entry "ENVIRONMENT" seen))))
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
    (dolist (stream (list (sb-ext:process-input raw) (sb-ext:process-output raw)
                          (sb-ext:process-error raw)))
      (when (streamp stream) (ignore-errors (close stream))))))

(defun spawn (command arguments &key (search nil) input output error environment directory
                                   (external-format :default) status-hook preserve-fds fd-limit)
  "Launch COMMAND with ARGUMENTS as its own process group and return a
PROCESS-HANDLE without waiting for it to produce output or exit -- the
low-level, asynchronous primitive RUN and COMMUNICATE are built on. Reach
for RUN or RUN-COMMAND instead unless driving the process's own streams or
job control by hand. :SEARCH resolves COMMAND through :ENVIRONMENT's PATH
rather than requiring an already-resolved path; :FD-LIMIT is documented on
RUN, which shares it."
  (let ((raw nil) (requested-command command))
    (flet ((abort-spawn (condition)
             "Both HANDLER-CASE clauses below reach this on any failure past
RAW's assignment: log it and clean up whatever RUN-PROGRAM already started
before re-signaling. What they re-signal AS differs, which is why only that
part stays in each clause."
             (%log :warn "process launch failed" :program requested-command :condition condition)
             (%cleanup-failed-spawn raw)))
      (handler-case
          (progn
            (%validate-spawn-inputs command arguments environment)
            (%ensure (not (eq input t)) "INPUT T cannot safely isolate the child process group.")
            (%ensure (or (null fd-limit) (and (integerp fd-limit) (plusp fd-limit)))
                     "FD-LIMIT must be NIL or a positive integer.")
            (when search
              (setf command (%resolve-executable command arguments environment directory)))
            (setf raw
                  (call-with-spawn-fd-limit
                   fd-limit
                   (lambda ()
                     (sb-ext:run-program
                      command arguments :search nil :input input :output output
                      :error error :environment environment :directory directory
                      :external-format external-format :status-hook status-hook
                      :preserve-fds preserve-fds :wait nil :use-posix-spawn nil))))
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
          (abort-spawn condition)
          (error condition))
        (error (condition)
          (abort-spawn condition)
          (error 'process-launch-error
                 :program requested-command :arguments (copy-list arguments)
                 :directory directory :cause condition))))))

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
  (uiop:ensure-directory-pathname (merge-pathnames (or directory #P"./")
                                                   *default-pathname-defaults*)))

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
