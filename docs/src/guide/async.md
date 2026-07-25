# Asynchronous Execution

Two layers sit below the synchronous `run`/`run-command` family: the raw
`spawn`/`spawn-command` primitive for callers who want to drive a process
themselves, and the event-driven `communicate-async`/`process-task` API for
callers who want structured async completion without managing streams by
hand.

## Spawning a handle

```lisp
spawn (command arguments &key search input output error environment
       directory external-format status-hook preserve-fds fd-limit) -> process-handle

spawn-command (command-spec &key stdin stdout stderr) -> process-handle
```

`fd-limit`, if given, temporarily lowers this process's own `RLIMIT_NOFILE`
soft limit around the spawn (restored immediately afterward) — the spawned
child inherits the lower limit through `exec`. See [Synchronous
Execution](execution.md#options-shared-across-the-family) for why this
matters.

Streams exposed by `spawn` or `spawn-command` are the caller's
responsibility until ownership is handed to `communicate`. `communicate`,
`run-command`, and `run-pipeline` drain and close the process streams they
manage.

### `process-handle` operations

- `process-id`, `process-status`, `process-stdin`, `process-output`, and
  `process-stderr`
- `process-alive-p`, `process-try-wait`, and `process-wait`. `process-wait`
  accepts `timeout`, `poll-interval`, and `clock` (a `cl-boundary-kit` clock
  boundary — see [Synchronous Execution](execution.md)), and returns `nil`
  if its timeout expires.
- `process-exit-code` and `process-signal`
- `process-send-leader-signal`, which signals the live process-group leader
  only
- `process-send-group-signal`, which signals the live owned process group
- `process-terminate` (SIGTERM) and `process-kill` (SIGKILL)
- `close-process-streams`, and `close-process` with optional `terminate` and
  `timeout`. Use `close-process` in cleanup paths to terminate and reap a
  live child before closing its streams.
- `call-with-process (process continuation &key terminate timeout)`, which
  calls `continuation` with the process and applies that cleanup with
  `unwind-protect` on the way out, and `with-process`, the macro sugar over
  it.

```lisp
(process-kit:with-process
    (process (process-kit:spawn-command
              (process-kit:make-command
               "/usr/bin/printf" (list "hello\n")
               :stdout :pipe)))
  (read-line (process-kit:process-output process)))
```

## Blocking communication

```lisp
communicate (process &key input timeout grace-period timeout-signal
             kill-signal on-timeout max-output-characters drain-timeout-seconds
             result-type external-format decoding-error-policy clock sleeper
             poll-interval cancellation-token on-cancel) -> process-result
```

`communicate` sends optional input, drains stdout and stderr concurrently,
waits for the process, and supports the same timeout, bounded-capture,
result-type, and [decoding-error-policy](command-specs.md#decoding-errors)
behavior as `run`. It owns communication for that handle: a
second concurrent call is rejected. After completion, the same normalized
options return the identical cached result object; different options signal
`communicate-options-mismatch` (readers: `communicate-options-mismatch-process`,
`communicate-options-mismatch-expected-options`,
`communicate-options-mismatch-actual-options`). Input strings and octet
vectors are snapshotted when communication is reserved.

## Event-driven communication

```lisp
communicate-async (process &rest options) -> process-task

await-process (task &key timeout) -> process-result, completed-p

cancel-process (task) -> task
```

`communicate-async` accepts the `communicate` options except
`cancellation-token`, because the task owns its cancellation token. Its
additional options are `event-callback`, `event-queue-capacity` (a positive
integer, default 64), and `event-overflow-policy` (`:drop-newest` by
default, or `:block`). `event-history-capacity` is a non-negative integer
that limits retained events and callback errors; it defaults to
`event-queue-capacity`, and zero disables history retention. It reserves the
process synchronously, so reservation and option errors are reported before
the task is returned.

`await-process` returns `(values nil nil)` if its own non-negative timeout
expires; otherwise it returns `(values result t)` or re-signals the task's
terminal condition. `cancel-process` requests cancellation and returns the
same task — see [Cancellation](cancellation.md) for `on-cancel` semantics.

`task-state` is one of `:reserved`, `:running`, `:completed`, `:cancelled`,
or `:failed`. `task-result`, `task-condition`, `process-events`,
`callback-errors`, and `dropped-event-count` expose the task outcome and
event history. `process-events` and `callback-errors` return chronological
list copies containing at most the newest `event-history-capacity` entries.
Queue overflow and retained-history eviction are independent; a terminal
event can evict the oldest retained event.
`process-task-first-event-sequence` and `process-task-last-event-sequence`
report the sequence range currently retained (`nil` before the first
event); `process-task-history-evicted-count` counts events evicted from
that retained window.

### `run-command-async`

```lisp
run-command-async (command-spec &rest options) -> process-task
```

The `command-spec`-driven counterpart of `communicate-async`: spawns
`command-spec`, forwards its `result-type`/`external-format`/
`decoding-error-policy` into `communicate-async`, and closes the process's
streams once the task's terminal event is delivered. Accepts the same
options as `communicate-async` and, like it, owns its cancellation token —
passing `cancellation-token` signals an error.

### Streaming events with a cursor

Independent consumers that cannot poll `process-events` — for example, a
second thread watching the same task — can instead stream events with a
caller-owned cursor:

```lisp
(next-process-event task &key cursor timeout)
  => event, next-cursor, status, gap-count
```

`cursor` is `nil` (start at the oldest retained event) or a positive
sequence number; `status` is:

| Status | Meaning |
| --- | --- |
| `:event` | An event was returned; use `next-cursor` for the following call. |
| `:gap` | The cursor fell behind the retained history — resume from `next-cursor`; `gap-count` is the exact number of events skipped. |
| `:terminal` | The task has finished and no further events remain. |
| `:timeout` | The call's own non-negative `timeout` expired first. |

Because cursors are plain integers owned by the caller, multiple
independent consumers can each stream the same task's events at their own
pace without mutating shared task state.

### Event structure

Events have monotonically increasing `process-event-sequence` values and
are inspected with `process-event-kind`, `process-event-octets`,
`process-event-result`, `process-event-condition`, and
`process-event-dropped-count`. `process-event-octets` returns a fresh copy.
`:stdout` and `:stderr` events always contain raw octets. When the bounded
event queue is full, `:drop-newest` drops new output events; `:block`
applies backpressure to the output producer. Dropped output is summarized
by an `:overflow` event when space becomes available, and its cumulative
count is available through `dropped-event-count`.

The callback is invoked serially in event order. A condition signalled by
the callback is captured in `callback-errors` and does not fail the task or
stop later events. Exactly one `:terminal` event is delivered after all
queued output and overflow events. It is outside the bounded queue, cannot
be dropped, and contains either the final result or terminal condition.
Task completion is published only after this terminal callback returns, so
a completed `await-process` also means terminal-event dispatch has
finished.
