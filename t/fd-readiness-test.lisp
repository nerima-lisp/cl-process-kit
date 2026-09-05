(in-package #:cl-process-kit/test)

(defun %call-with-pipe (continuation)
  "Call CONTINUATION with a fresh pipe's (READ-FD WRITE-FD), closing both
afterwards whether or not it returns normally. Closing an already-closed
descriptor is ignored, so a test may close an end itself to reach EBADF."
  (multiple-value-bind (read-fd write-fd) (sb-unix:unix-pipe)
    (unwind-protect (funcall continuation read-fd write-fd)
      (ignore-errors (sb-unix:unix-close read-fd))
      (ignore-errors (sb-unix:unix-close write-fd)))))

(defmacro %with-pipe ((read-fd write-fd) &body body)
  `(%call-with-pipe (lambda (,read-fd ,write-fd)
                      (declare (ignorable ,read-fd ,write-fd))
                      ,@body)))

(defun %call-with-fd-at (source target continuation)
  "Duplicate SOURCE onto descriptor number TARGET, call CONTINUATION with
TARGET, and close TARGET afterwards. A test about the FD_SETSIZE boundary has
to place a descriptor there itself: the kernel hands out the lowest free
number, so no pipe will ever land near 1022 on its own. TARGET is high enough
that nothing in a test image holds it, which is what makes dup2's silent close
of an already-open TARGET safe here."
  (sb-posix:dup2 source target)
  (unwind-protect (funcall continuation target)
    (ignore-errors (sb-unix:unix-close target))))

(defmacro %with-fd-at ((var source target) &body body)
  `(%call-with-fd-at ,source ,target
                     (lambda (,var) (declare (ignorable ,var)) ,@body)))

(defun %poke-fd (fd)
  "Write one octet to FD, making its peer readable."
  (let ((buffer (make-array 1 :element-type '(unsigned-byte 8) :initial-element 65)))
    (sb-sys:with-pinned-objects (buffer)
      (sb-unix:unix-write fd (sb-sys:vector-sap buffer) 0 1))))

(defun %elapsed-seconds (thunk)
  "Call THUNK and return (VALUES ITS-PRIMARY-VALUE ELAPSED-SECONDS)."
  (let* ((start (get-internal-real-time))
         (value (funcall thunk)))
    (values value (/ (- (get-internal-real-time) start)
                     (float internal-time-units-per-second 1d0)))))

(describe "file-descriptor readiness"
  (it "reports a descriptor that has data waiting"
    (%with-pipe (read-fd write-fd)
      (%poke-fd write-fd)
      (expect (wait-for-input (list read-fd) :timeout 5) :to-equal (list read-fd))))

  (it "waits indefinitely until a descriptor becomes readable when timeout is nil"
    (%with-pipe (read-fd write-fd)
      (let ((poker (sb-thread:make-thread (lambda () (sleep 0.05) (%poke-fd write-fd))
                                          :name "cl-process-kit fd-readiness indefinite poker")))
        (unwind-protect
             (expect
              (handler-case
                  (sb-ext:with-timeout 5
                    (wait-for-input (list read-fd) :timeout nil))
                (sb-ext:timeout () :never-woken))
              :to-equal (list read-fd))
          (expect (sb-thread:join-thread poker :timeout 5 :default :poker-failed) :to-be 1)))))

  (it "returns the three ready sets in argument order"
    (%with-pipe (read-fd write-fd)
      (%poke-fd write-fd)
      (multiple-value-bind (readable writable exceptional)
          (select-fds :read-fds (list read-fd) :write-fds (list write-fd) :timeout 5)
        (expect readable :to-equal (list read-fd))
        (expect writable :to-equal (list write-fd))
        (expect exceptional :to-be nil))))

  (it "reports each ready descriptor once even when it is listed twice"
    (%with-pipe (first-read first-write)
      (%with-pipe (second-read second-write)
        (%poke-fd first-write)
        (%poke-fd second-write)
        (expect (wait-for-input (list second-read first-read second-read first-read) :timeout 5)
                :to-equal (list second-read first-read)))))

  (it "returns nothing once the timeout expires, having actually waited"
    (%with-pipe (read-fd write-fd)
      (multiple-value-bind (ready elapsed)
          (%elapsed-seconds (lambda () (wait-for-input (list read-fd) :timeout 0.2)))
        (expect ready :to-be nil)
        (expect (>= elapsed 0.15d0) :to-be-truthy))))

  (it "polls without blocking when the timeout is zero"
    (%with-pipe (read-fd write-fd)
      (multiple-value-bind (ready elapsed)
          (%elapsed-seconds (lambda () (wait-for-input (list read-fd) :timeout 0)))
        (expect ready :to-be nil)
        (expect (< elapsed 0.5d0) :to-be-truthy))
      (%poke-fd write-fd)
      (expect (wait-for-input (list read-fd) :timeout 0) :to-equal (list read-fd))))

  (it "returns immediately rather than blocking forever on an empty set"
    (multiple-value-bind (ready elapsed)
        (%elapsed-seconds (lambda () (wait-for-input '() :timeout nil)))
      (expect ready :to-be nil)
      (expect (< elapsed 0.5d0) :to-be-truthy))
    (expect (multiple-value-list (select-fds :timeout nil)) :to-equal (list nil nil nil)))

  (it "rejects a descriptor above the usable maximum instead of corrupting memory"
    (signals fd-set-overflow (wait-for-input (list +fd-set-size+) :timeout 0))
    (let ((condition (handler-case
                         (select-fds :write-fds (list (+ +fd-set-size+ 7)) :timeout 0)
                       (fd-set-overflow (condition) condition))))
      (expect (fd-set-overflow-fd condition) :to-be (+ +fd-set-size+ 7))
      (expect (fd-set-overflow-limit condition) :to-be +maximum-fd+)
      (expect (typep condition 'process-error) :to-be-truthy)))

  (it "accepts the highest usable descriptor and rejects the next one up"
    (%with-pipe (read-fd write-fd)
      (%with-fd-at (high read-fd +maximum-fd+)
        (expect (wait-for-input (list high) :timeout 0) :to-be nil)
        (%poke-fd write-fd)
        (expect (wait-for-input (list high) :timeout 0) :to-equal (list high))))
    (let ((condition (handler-case (wait-for-input (list (1+ +maximum-fd+)) :timeout 0)
                       (error (condition) condition))))
      (expect (typep condition 'fd-set-overflow) :to-be-truthy)
      (expect (fd-set-overflow-fd condition) :to-be (1+ +maximum-fd+))
      (expect (fd-set-overflow-limit condition) :to-be +maximum-fd+)))

  (it "waits out a timeout too large for one struct timeval rather than failing it"
    (%with-pipe (read-fd write-fd)
      (%poke-fd write-fd)
      (expect (wait-for-input (list read-fd) :timeout +maximum-fd-wait-seconds+)
              :to-equal (list read-fd)))
    (%with-pipe (read-fd write-fd)
      (let ((poker (sb-thread:make-thread (lambda () (sleep 0.2) (%poke-fd write-fd))
                                          :name "cl-process-kit fd-readiness late poker")))
        (multiple-value-bind (ready elapsed)
            (%elapsed-seconds
             (lambda ()
               (handler-case
                   (sb-ext:with-timeout 10
                     (wait-for-input (list read-fd) :timeout +maximum-fd-wait-seconds+))
                 (sb-ext:timeout () :never-woken))))
          (expect (sb-thread:join-thread poker :timeout 10 :default :poker-failed) :to-be 1)
          (expect ready :to-equal (list read-fd))
          (expect (>= elapsed 0.15d0) :to-be-truthy)))))

  (it "rejects a negative descriptor and an out-of-range timeout"
    (signals type-error (wait-for-input (list -1) :timeout 0))
    (signals type-error (wait-for-input (list 0) :timeout -1))
    (signals type-error (wait-for-input (list 0) :timeout (1+ +maximum-fd-wait-seconds+))))

  (it "signals fd-wait-failed with the errno when select itself fails"
    (%with-pipe (read-fd write-fd)
      (sb-unix:unix-close read-fd)
      (sb-unix:unix-close write-fd)
      (signals fd-wait-failed (wait-for-input (list read-fd) :timeout 0))
      (let ((condition (handler-case (wait-for-input (list read-fd) :timeout 0)
                         (fd-wait-failed (condition) condition))))
        (expect (fd-wait-failed-errno condition) :to-be sb-unix:ebadf)
        (expect (fd-wait-failed-read-fds condition) :to-equal (list read-fd))
        (expect (typep condition 'process-error) :to-be-truthy)
        (expect (search "errno" (princ-to-string condition)) :to-be-truthy))))

  (it "retries an interrupted wait against the original deadline"
    ;; SB-THREAD:INTERRUPT-THREAD delivers a signal, so the blocked
    ;; SB-UNIX:UNIX-FAST-SELECT returns EINTR. The three behaviours this has to
    ;; tell apart, for interrupts at 0.3s and 0.5s against a 0.6s timeout: no
    ;; retry at all ends the wait at the first interrupt, 0.3s; restarting the
    ;; timeout on each EINTR ends it 0.6s after the last one, 1.1s; resuming
    ;; against the deadline fixed up front ends it at 0.6s, where it belongs.
    ;; The bounds are placed to exclude the other two by 0.2s either side --
    ;; the interrupts were moved out from 0.1s/0.2s, where restarting landed at
    ;; exactly 0.8s and passed a 1.2s bound, so this case could not fail for
    ;; the regression it is named after.
    (%with-pipe (read-fd write-fd)
      (let ((waiter sb-thread:*current-thread*))
        (sb-thread:make-thread
         (lambda ()
           (sleep 0.3)
           (sb-thread:interrupt-thread waiter (lambda () nil))
           (sleep 0.2)
           (sb-thread:interrupt-thread waiter (lambda () nil)))
         :name "cl-process-kit fd-readiness interrupter"))
      (multiple-value-bind (ready elapsed)
          (%elapsed-seconds (lambda () (wait-for-input (list read-fd) :timeout 0.6)))
        (expect ready :to-be nil)
        (expect (>= elapsed 0.5d0) :to-be-truthy)
        (expect (< elapsed 0.9d0) :to-be-truthy))))

  (it "still reports data that arrives after an interruption"
    (%with-pipe (read-fd write-fd)
      (let ((waiter sb-thread:*current-thread*))
        (sb-thread:make-thread
         (lambda ()
           (sleep 0.05)
           (sb-thread:interrupt-thread waiter (lambda () nil))
           (sleep 0.05)
           (%poke-fd write-fd))
         :name "cl-process-kit fd-readiness poker"))
      (expect (wait-for-input (list read-fd) :timeout 5) :to-equal (list read-fd)))))
