;;;; src/fd-readiness.lisp
;;;;
;;;; Waiting until raw file descriptors become ready, via select(2).
;;;;
;;;; This is the one primitive an event loop cannot build out of the rest of
;;;; this library: PROCESS-WAIT and COMMUNICATE each drive a single child, but
;;;; a program that multiplexes several PTY masters, a unix socket and stdin in
;;;; one thread needs to block on all of them at once and be told which woke
;;;; it. SBCL ships that syscall as SB-UNIX:UNIX-FAST-SELECT, so this file is a
;;;; contract and a retry loop over it -- no C, no foreign-function library,
;;;; and no dependency on the optional native PTY shared object, which is why
;;;; it lives here in the base system rather than beside src/pty.lisp.

(in-package #:process-kit)

(defconstant +fd-set-size+ sb-unix:fd-setsize
  "How wide one select(2) fd_set is: FD_SETSIZE, 1024 on Linux and Darwin. The
bitmap is a fixed-width array, so a descriptor numbered at or above this cannot
be named in it at all -- setting its bit writes past the end of the structure.

This is the width of the bitmap, NOT the largest descriptor SELECT-FDS accepts.
That is +MAXIMUM-FD+, which is two lower; read the ceiling off that constant
rather than off this one.")

(defconstant +maximum-fd+ (- sb-unix:fd-setsize 2)
  "Largest file descriptor SELECT-FDS and WAIT-FOR-INPUT accept: 1022 where
FD_SETSIZE is 1024. Anything above it is refused with FD-SET-OVERFLOW.

Two below FD_SETSIZE rather than one, because select(2)'s first argument is one
PAST the highest descriptor watched, and SB-UNIX:UNIX-FAST-SELECT requires that
argument to be strictly below FD_SETSIZE -- watching fd 1023 would mean passing
1024, which it refuses with a bare SIMPLE-ERROR naming neither of this library's
conditions. Rejecting fd 1023 here keeps the ceiling a single documented
condition instead of two, one of them undocumented.

A program that expects to hold more descriptors open than this wants
poll(2)/kqueue, not this.")

(defconstant +maximum-fd-wait-seconds+ (1- (expt 2 31))
  "Largest :TIMEOUT SELECT-FDS accepts, in seconds -- roughly 68 years, the
range of the (UNSIGNED-BYTE 31) seconds field SB-UNIX:UNIX-FAST-SELECT
declares. A caller wanting to wait longer than this means NIL.

Every value up to and including this one blocks for the time it names. A kernel
that will not take so large a tv_sec in one call does not make the wait fail or
return early: SELECT-FDS splits it into +MAXIMUM-TIMEVAL-SECONDS+ chunks and
resumes against its own deadline.")

(defconstant +maximum-timeval-seconds+ 100000000
  "Largest tv_sec SELECT-FDS will place in one struct timeval: 1e8 seconds,
about 3.17 years. Internal to the timeout contract, not a bound on it.

Darwin's select(2) rejects a larger tv_sec outright with EINVAL rather than
clamping it -- measured on this machine, where tv_sec 100000000 waits and
100000001 fails immediately. Linux's select(2) saturates instead of failing and
so takes far more, which makes 1e8 the value both kernels accept and the reason
this is one plain constant rather than a read-time platform conditional.

The consequence of getting this wrong is not a slow wait but a hot one: a
caller that maps FD-WAIT-FAILED back to \"nothing ready\" -- as an event loop
polling descriptors a peer may close underneath it must -- would see its long
block become an immediate return, and spin.")

(deftype fd-wait-timeout ()
  "SELECT-FDS's :TIMEOUT: NIL to block indefinitely, or a non-negative real
number of seconds up to +MAXIMUM-FD-WAIT-SECONDS+."
  `(or null (real 0 ,+maximum-fd-wait-seconds+)))

(defun %monotonic-seconds ()
  "Current INTERNAL-REAL-TIME as an exact rational number of seconds. Rational
rather than float so that repeatedly subtracting an elapsed interval from a
deadline across EINTR retries cannot accumulate rounding error."
  (/ (get-internal-real-time) internal-time-units-per-second))

(defun %timeval-parts (seconds)
  "Split SECONDS into the (VALUES WHOLE-SECONDS MICROSECONDS) pair struct
timeval holds. The total is rounded UP to the next microsecond: struct timeval
has no finer resolution, and rounding a small positive timeout down to zero
would silently turn a caller's brief wait into a non-blocking poll.

Anything beyond +MAXIMUM-TIMEVAL-SECONDS+ is clamped, so the result is always a
timeval every supported kernel accepts. The clamp lives here, at the one point
where a Lisp number becomes a timeval, so no future caller can route around it;
SELECT-FDS's loop is what turns a clamped wait back into the full one."
  (floor (ceiling (* (rational (min seconds +maximum-timeval-seconds+)) 1000000)) 1000000))

(defun %validate-fds (fds)
  "Return FDS with duplicates removed, first occurrence kept, after checking
that select(2) can WATCH every one of them. An fd repeated in the argument
would otherwise be reported ready more than once, since readiness is read back
by filtering the caller's own list.

Watchable, not merely representable: the bound is +MAXIMUM-FD+ rather than
+FD-SET-SIZE+ because fd 1022 is the last one an nfds below FD_SETSIZE can
reach, even though fd 1023 still has a bit in the map. Checking the looser
bound here is what once let 1023 through to be rejected further down by
SB-UNIX:UNIX-FAST-SELECT, as an error this library never promised.

The type check is an explicit (ERROR 'TYPE-ERROR ...) rather than CHECK-TYPE,
matching %VALIDATE-SIGNAL in process-group.lisp: both validate a raw integer
that arrived from outside the library, and neither wants CHECK-TYPE's
STORE-VALUE restart offered for a descriptor number no interactive caller
could sensibly supply a replacement for."
  (let ((unique (remove-duplicates fds :from-end t)))
    (dolist (fd unique unique)
      (%ensure (typep fd '(integer 0)) 'type-error :datum fd :expected-type '(integer 0))
      (%ensure (<= fd +maximum-fd+) 'fd-set-overflow :fd fd :limit +maximum-fd+))))

(defun %descriptor-count (&rest fd-lists)
  "The nfds argument select(2) wants: one past the highest descriptor named in
any of FD-LISTS, or 0 when they are all empty."
  (1+ (reduce #'max (mapcar (lambda (fds) (reduce #'max fds :initial-value -1)) fd-lists)
              :initial-value -1)))

(defun %select-once (read-fds write-fds except-fds descriptor-count seconds microseconds)
  "One select(2) call, returning (VALUES READY-READ READY-WRITE READY-EXCEPT
ERRNO) with ERRNO 0 on success or timeout expiry. The fd_set bitmaps never
escape this function: select(2) leaves them undefined on failure, so the only
safe discipline is to build them, read them back on a positive count, and
discard them within a single call."
  (sb-alien:with-alien ((readable (sb-alien:struct sb-unix:fd-set))
                        (writable (sb-alien:struct sb-unix:fd-set))
                        (exceptional (sb-alien:struct sb-unix:fd-set)))
    (macrolet ((fill-set (fds set)
                 ;; MACROLET, not FLET: SET names a local alien whose storage
                 ;; is on the stack, and taking its address has to happen in
                 ;; the lexical scope that declared it.
                 `(progn
                    (sb-unix:fd-zero ,set)
                    (dolist (fd ,fds) (sb-unix:fd-set fd ,set))
                    (when ,fds (sb-alien:addr ,set))))
               (ready-in (fds set)
                 `(loop for fd in ,fds when (sb-unix:fd-isset fd ,set) collect fd)))
      (let ((read-pointer (fill-set read-fds readable))
            (write-pointer (fill-set write-fds writable))
            (except-pointer (fill-set except-fds exceptional)))
        (multiple-value-bind (count errno)
            (sb-unix:unix-fast-select descriptor-count
                                      read-pointer write-pointer except-pointer
                                      seconds microseconds)
          (cond
            ((null count) (values nil nil nil errno))
            ((zerop count) (values nil nil nil 0))
            (t (values (ready-in read-fds readable)
                       (ready-in write-fds writable)
                       (ready-in except-fds exceptional)
                       0))))))))

(defun select-fds (&key read-fds write-fds except-fds timeout)
  "Block until one of the given file descriptors is ready, and return which.

READ-FDS, WRITE-FDS and EXCEPT-FDS are lists of file descriptors -- plain
non-negative integers no greater than +MAXIMUM-FD+, not streams -- to watch for
readability, writability, and exceptional conditions respectively.

TIMEOUT is a number of SECONDS: NIL blocks indefinitely, 0 polls without
blocking, and any other non-negative real up to +MAXIMUM-FD-WAIT-SECONDS+
bounds the wait. The resolution is one microsecond, the width of struct
timeval; a smaller positive timeout is rounded up to one microsecond rather
than down to a poll. A timeout too large for one struct timeval is waited out
in chunks rather than refused, so the whole documented range blocks for the
time it names on every supported kernel.

Returns three values -- the ready read, write and exceptional descriptors --
each a sub-list of the corresponding argument in its original order, with
duplicates removed. All three are NIL when the timeout expired. Passing no
descriptors at all returns three NILs immediately, whatever TIMEOUT says: a
select(2) with an empty descriptor set and no timeout would block forever with
nothing able to wake it, which is never what the caller meant.

A signal arriving mid-wait (EINTR) is retried, not reported. The deadline is
computed once, up front, and each retry gets only the time still left on it,
so an interrupted wait resumes rather than restarting and the total never
exceeds TIMEOUT. This matters in an event loop under a periodic signal --
SIGWINCH on a resizing terminal, SIGCHLD on a reaped child -- where surfacing
EINTR would turn every such signal into either a spurious error or a
spurious \"nothing is ready\".

Signals FD-SET-OVERFLOW for every descriptor select(2) cannot watch -- that is,
every one above +MAXIMUM-FD+ -- and FD-WAIT-FAILED for any other failing errno
(EBADF on a closed descriptor, say). Those two are the only failures a caller
has to plan for; no descriptor and no TIMEOUT in the documented range reaches
SB-UNIX:UNIX-FAST-SELECT's own argument checks."
  (%ensure (typep timeout 'fd-wait-timeout)
           'type-error :datum timeout :expected-type 'fd-wait-timeout)
  (let* ((read-fds (%validate-fds read-fds))
         (write-fds (%validate-fds write-fds))
         (except-fds (%validate-fds except-fds))
         (descriptor-count (%descriptor-count read-fds write-fds except-fds)))
    (if (zerop descriptor-count)
        (values nil nil nil)
        (let ((deadline (and timeout (+ (%monotonic-seconds) (rational timeout)))))
          (loop
            (multiple-value-bind (seconds microseconds)
                (if deadline
                    (%timeval-parts (max 0 (- deadline (%monotonic-seconds))))
                    (values nil nil))
              (multiple-value-bind (readable writable exceptional errno)
                  (%select-once read-fds write-fds except-fds
                                descriptor-count seconds microseconds)
                (cond
                  ((zerop errno)
                   ;; An expiry with nothing ready is only OUR expiry once the
                   ;; deadline has actually passed. %TIMEVAL-PARTS clamps, so a
                   ;; TIMEOUT longer than one struct timeval can hold arrives
                   ;; back here with time still to run; looping is what keeps
                   ;; such a wait a block rather than an early return.
                   (when (or readable writable exceptional
                             (null deadline)
                             (>= (%monotonic-seconds) deadline))
                     (return (values readable writable exceptional))))
                  ((/= errno sb-unix:eintr)
                   (error 'fd-wait-failed :errno errno :read-fds read-fds
                                          :write-fds write-fds :except-fds except-fds))
                  ((and deadline (>= (%monotonic-seconds) deadline))
                   (return (values nil nil nil)))))))))))

(defun wait-for-input (fds &key timeout)
  "Block until one of FDS is readable and return the sub-list that is.

The read-only case of SELECT-FDS, which an event loop wants far more often
than the full three-set form, reduced to one argument and one return value.
FDS, TIMEOUT, the empty-list case, the EINTR retry and the signalled
conditions are all exactly as SELECT-FDS documents them; NIL means the timeout
expired with nothing readable, never end-of-file."
  (values (select-fds :read-fds fds :timeout timeout)))
