# File-Descriptor Readiness

`process-wait` and `communicate` each drive one child. A program that
multiplexes several descriptors in a single thread — a few PTY masters, a unix
socket, standard input — needs the opposite shape: block on all of them at
once, and be told which one woke it. That is `select(2)`, and cl-process-kit
exposes it as `select-fds` and `wait-for-input`.

Both are pure SBCL: they call `sb-unix:unix-fast-select` through `sb-alien`,
with no foreign-function library and no C of this project's own. In
particular they do **not** need the optional native PTY shared object that
`cl-process-kit/pty` links, so they are available from the base system alone.

## `wait-for-input`

```lisp
(process-kit:wait-for-input fds &key timeout) ; => list of readable fds
```

The read-only case, which is what an event loop wants most of the time.

```lisp
;; Wait up to 50 ms for either the pty master or the client socket to speak.
(let ((ready (process-kit:wait-for-input (list master-fd socket-fd 0)
                                         :timeout 0.05)))
  (dolist (fd ready)
    (drain fd)))
```

`fds` are plain non-negative integers — raw descriptors, not Lisp streams. The
result is a sub-list of `fds` in the same order, with duplicates removed. `nil`
means the timeout expired with nothing readable; it never means end of file,
which at this layer is a *readable* descriptor whose next read returns zero
octets.

## `select-fds`

```lisp
(process-kit:select-fds &key read-fds write-fds except-fds timeout)
;; => (values ready-read ready-write ready-except)
```

The full three-set form. Each returned value is a sub-list of the
corresponding argument, in argument order, duplicates removed; all three are
`nil` when the timeout expired.

```lisp
(multiple-value-bind (readable writable) 
    (process-kit:select-fds :read-fds (list master-fd)
                            :write-fds (list master-fd)
                            :timeout nil)
  (when readable (drain master-fd))
  (when writable (flush-pending-input master-fd)))
```

## Timeouts

`:timeout` is a number of **seconds**:

| Value | Meaning |
|---|---|
| `nil` | Block indefinitely. |
| `0` | Poll: look at the descriptors and return without ever blocking. |
| a positive real | Wait at most that long. |

The resolution is one microsecond, the width of `struct timeval`. A positive
timeout smaller than that is rounded **up** to one microsecond rather than
down to zero, so a brief wait never silently degenerates into a poll. The
upper bound is `process-kit:+maximum-fd-wait-seconds+`, about 68 years; a
caller wanting longer means `nil`. A timeout above the bound is a
`cl:type-error`, not a silently shortened wait.

Every value up to that bound blocks for the time it names, on both supported
kernels. They do not agree on how large a single `tv_sec` may be: Darwin's
`select(2)` rejects anything above 10<sup>8</sup> seconds (about 3.17 years)
outright with `EINVAL`, while Linux's saturates instead of failing. `select-fds`
therefore waits in chunks no longer than the value both accept and resumes
against its own deadline, so the platform difference stays out of the contract.

That chunking is not a nicety. The failure it prevents is a *hot* loop, not a
slow one: a caller that maps `fd-wait-failed` back to "nothing is ready" — which
an event loop polling descriptors a peer may close underneath it has to do —
would see a multi-year block return instantly and spin.

Passing no descriptors at all returns empty sets immediately, whatever
`:timeout` says. A `select(2)` over an empty descriptor set with no timeout
would block forever with nothing able to wake it, which is never what the
caller meant; neither function is a `sleep`.

## Interruption (EINTR)

A signal arriving mid-wait makes `select(2)` fail with `EINTR`. Both functions
**retry** rather than report it. The deadline is computed once, up front, and
each retry receives only the time still remaining on it — so an interrupted
wait resumes instead of restarting, and the total never exceeds `:timeout`.

This is the behaviour an event loop needs. Under a periodic signal — SIGWINCH
from a terminal being resized, SIGCHLD from a child being reaped — surfacing
`EINTR` would turn every such signal into either a spurious error or a
spurious "nothing is ready", and the naive fix of restarting the full timeout
would let a fast enough signal stream stretch a bounded wait without limit.

## The descriptor ceiling

`select(2)`'s `fd_set` is a fixed-width bitmap: a descriptor numbered at or
above `FD_SETSIZE` cannot be named in it at all, and setting its bit writes past
the end of the structure. `process-kit:+fd-set-size+` reports that width (1024
on Linux and Darwin).

The **highest descriptor either function accepts** is
`process-kit:+maximum-fd+`, which is *two* lower — 1022, not 1023:

| Constant | Value | Meaning |
|---|---|---|
| `+fd-set-size+` | 1024 | `FD_SETSIZE`: how many bits the bitmap holds. |
| `+maximum-fd+` | 1022 | The largest descriptor that can actually be watched. |

The gap is `select(2)`'s first argument, which is one *past* the highest
descriptor being watched. `sb-unix:unix-fast-select` requires that argument to
be strictly below `FD_SETSIZE`, so watching fd 1023 would mean passing 1024,
which it refuses. Read the ceiling off `+maximum-fd+`; `+fd-set-size+` describes
the bitmap, not the contract.

Both functions check every descriptor before touching any memory and signal
`fd-set-overflow` for anything above `+maximum-fd+`, so the ceiling is one
documented condition across its whole range rather than corruption below it and
an undocumented error at the top of it.

A program that genuinely holds more than a thousand descriptors open wants
`poll(2)` or `kqueue`, which have no such ceiling. This library does not wrap
them.

## Conditions

Both functions signal subtypes of `process-kit:process-error`, so a caller can
catch the whole library's failures in one clause.

| Condition | Signalled when | Readers |
|---|---|---|
| `fd-set-overflow` | A descriptor is above `+maximum-fd+`. | `fd-set-overflow-fd`, `fd-set-overflow-limit` |
| `fd-wait-failed` | `select(2)` failed for any reason other than `EINTR` — `EBADF` on a closed descriptor, say. | `fd-wait-failed-errno`, `fd-wait-failed-read-fds`, `fd-wait-failed-write-fds`, `fd-wait-failed-except-fds` |

`fd-set-overflow-limit` returns `+maximum-fd+`: the highest *accepted*
descriptor, not the first rejected one.

A negative descriptor, a non-integer descriptor, or a timeout outside
`0 .. +maximum-fd-wait-seconds+` is a `cl:type-error`.

```lisp
(handler-case (process-kit:wait-for-input fds :timeout 1)
  (process-kit:fd-wait-failed (condition)
    (format t "select failed with errno ~D~%"
            (process-kit:fd-wait-failed-errno condition))
    nil))
```

## Reading once a descriptor is ready

These functions report readiness; they do not transfer octets. Reading the
descriptor is
[`cl-tty-kit`](https://github.com/nerima-lisp/cl-tty-kit)'s `fd-read-octets`
and `fd-write-octets`, which are byte-transparent and already handle the
short-read and `EAGAIN` cases. Pairing the two — readiness here, transfer
there — is the whole of a select-driven loop over raw descriptors.
