;;;; src/parameters.lisp
;;;;
;;;; Tunable defaults shared by capture, communicate, and pipeline logic, plus
;;;; the CL-BOUNDARY-KIT clock/sleeper boundary objects RUN, COMMUNICATE, and
;;;; PROCESS-WAIT accept in place of raw clock/sleep functions -- a real
;;;; clock/sleeper by default, swappable for a deterministic fake in tests.
;;;; Kept as plain data, separate from the logic that consumes it.

(in-package #:process-kit)

(defparameter +default-poll-interval+ 0.01d0
  "Default interval, in seconds, between deadline/liveness polls.")

(defparameter +copier-poll-interval-milliseconds+
  (round (* 1000 +default-poll-interval+))
  "POLL(2) timeout, in milliseconds, for one turn of a copier thread's read
loop -- +DEFAULT-POLL-INTERVAL+ in the unit POLL(2) takes. It bounds how long
a copier can stay parked before it notices %DRAIN-COPIERS has asked it to
stop, so it is also the granularity of DRAIN-TIMEOUT-SECONDS. Deliberately
the same cadence COMMUNICATE's own deadline loop already wakes at, so an
interruptible copier costs no wakeup rate the library was not already paying.")

(defparameter +copier-stop-grace-seconds+ 0.25d0
  "How long %DRAIN-COPIERS waits for a copier to honour a cooperative stop
before escalating to force-closing its stream. Generous against
+COPIER-POLL-INTERVAL-MILLISECONDS+ (one poll turn plus the one bounded
READ(2) that may follow it), because reaching the force-close stage trades a
clean stop for a descriptor closed under a live reader.")

(defparameter +default-output-limit+ 1048576
  "Default MAX-OUTPUT-CHARACTERS: 1 MiB of captured output per stream.")

(defparameter +default-drain-timeout-seconds+ 1.0d0
  "Default deadline for draining copier/feeder threads during cleanup.")

(defparameter +default-copy-buffer-size+ 65536
  "Size, in octets/characters, of each COPIER/FEEDER read-write chunk. Larger
than a single 4 KiB page: fewer, larger READ(2)/WRITE(2) calls per byte
transferred, which SB-SPROF confirms dominates large-transfer wall time
(measured well above the fork/thread-creation cost RUN otherwise pays per
call). Still small enough that one chunk's ENCODING/EMIT work stays a bounded,
short critical section.")

(defun %monotonic-seconds ()
  "The real monotonic clock, in seconds, used as +DEFAULT-CLOCK+'s reading."
  (/ (get-internal-real-time) internal-time-units-per-second))

(defparameter +default-clock+
  (cl-boundary-kit:make-clock :monotonic-fn #'%monotonic-seconds)
  "The real clock boundary: CLOCK-MONOTONIC reads seconds off the system's
monotonic clock. Tests substitute CL-BOUNDARY-KIT:MAKE-FAKE-CLOCK instead.")

(defparameter +default-sleeper+ (cl-boundary-kit:make-sleeper)
  "The real sleeper boundary: SLEEPER-SLEEP blocks the calling thread via
CL:SLEEP. Tests substitute CL-BOUNDARY-KIT:MAKE-TEST-SLEEPER instead.")

(defun %protocol-object-p (generic-function sample-arguments)
  "True when SAMPLE-ARGUMENTS -- a full, arity-matching call shape for
GENERIC-FUNCTION with the candidate boundary object first -- has an
applicable method. A duck-typed conformance check for CL-BOUNDARY-KIT
boundary protocols, whose concrete classes (CLOCK, SLEEPER, ...) are
deliberately not exported."
  (and (typep (first sample-arguments) 'standard-object)
       (not (null (compute-applicable-methods generic-function sample-arguments)))))

(defun %clock-p (value) (%protocol-object-p #'cl-boundary-kit:clock-monotonic (list value)))
(defun %sleeper-p (value) (%protocol-object-p #'cl-boundary-kit:sleeper-sleep (list value 0)))
