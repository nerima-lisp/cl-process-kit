# Synchronous Execution

The synchronous entry points block the calling thread until the command
finishes (or its deadline fires) and hand back a `process-result`.

| Function | Input | Signature |
| --- | --- | --- |
| `run` | program + argument list | `(command arguments &key search input environment directory output error timeout grace-period poll-interval timeout-signal kill-signal on-timeout max-output-characters drain-timeout-seconds result-type external-format decoding-error-policy clock sleeper cancellation-token on-cancel fd-limit)` → `process-result` |
| `run/checked` | program + argument list | `(command arguments &rest options)` → `process-result`, same options as `run` |
| `run-shell` | shell command string | `(command &rest options)` → `process-result`, runs through `/bin/sh -c`, same options as `run` |
| `run-command` | `command-spec` | `(command-spec &key input timeout grace-period on-timeout cancellation-token on-cancel max-output-characters drain-timeout-seconds)` → `process-result` |
| `run-command/checked` | `command-spec` | `(command-spec &rest options)` → `process-result`, same options as `run-command` |

`run/checked` signals `process-cancelled-error` for a returned cancelled
result and `process-exit-error` for any other unsuccessful result;
`run-command/checked` signals `process-exit-error` unless the process exits
successfully. Non-zero exits are returned normally by the unchecked
variants — use the checked ones when a failing exit code should raise
instead of being inspected on the result.

!!! tip "The command-spec-driven async entry point"

    `run-command-async (command-spec &rest options)` → `process-task` is the
    `command-spec`-driven counterpart of `communicate-async`. It lives next
    to `run-command` in the source but returns a task rather than blocking
    — see [Asynchronous Execution](async.md#run-command-async).

## Timeout and cleanup deadlines

Omit `timeout` to run without a deadline. With one, a child that outlives it
is escalated against rather than merely abandoned, and every stage of that
escalation is bounded:

| Option | Default | Bounds |
| --- | --- | --- |
| `timeout` | `nil` | How long the child may run before escalation begins. |
| `timeout-signal` | `15` (`SIGTERM`) | The signal sent to the child's **process group** when `timeout` expires. |
| `grace-period` | `1.0` | How long the group has to exit under `timeout-signal` before `kill-signal` follows. |
| `kill-signal` | `9` (`SIGKILL`) | The signal that ends the escalation. |
| `drain-timeout-seconds` | `1.0` | How long output is still drained after the child is reaped. |
| `poll-interval` | `0.01` | How often the deadline and liveness loops wake. |

Signals go to the whole process group, not just the child, which is why a
timeout reaches everything the child forked. `drain-timeout-seconds` is a
separate deadline because reaping the child does not necessarily close its
output: a descendant that outlives it — `sh -c "worker & exit 0"` — inherits
the same pipe and holds it open. Draining stops when that deadline passes,
with whatever was captured by then; the alternative is waiting on a
descendant that may never exit. Both deadlines hold on every supported
platform, and the suite asserts it on macOS and Linux alike.

`on-timeout` decides what a timeout produces: `:error` (the default) signals
[`process-timeout-error`](../reference/results-and-conditions.md), while
`:return` returns the partial `process-result` with
`process-result-timed-out-p` set. Any other value is rejected — it is not
silently taken as `:return`.

## Options shared across the family

`output` controls where stdout goes: `:capture` (the default) collects it
into the `process-result`, `:inherit` lets the child write straight to this
process's own stdout for live, uncaptured output, and a stream sends it
there. `error` accepts the same three values for stderr, plus `:output`,
which merges stderr into wherever stdout goes.

`fd-limit`, if given, temporarily lowers this process's own `RLIMIT_NOFILE`
soft limit around the spawn (restored immediately afterward) — the spawned
child inherits the lower limit through `exec`. On hosts with a very large
ambient file-descriptor limit (routine under Nix/direnv shells), this
measurably cuts spawn latency: the forked child otherwise closes every
inherited descriptor up to that limit one syscall at a time. `nil` (the
default) leaves the ambient limit untouched.

`clock` and `sleeper` are `cl-boundary-kit` boundary objects (see
`cl-boundary-kit:make-clock` and `cl-boundary-kit:make-sleeper`) that default
to `+default-clock+`/`+default-sleeper+` — the real system monotonic clock
and a real, blocking sleep. Pass
`cl-boundary-kit:make-fake-clock`/`make-test-sleeper` instead to drive the
timeout/escalation polling loop deterministically in tests, without waiting
on the wall clock.

`input` accepts a string, an `(unsigned-byte 8)` vector, or a
character/binary stream. Strings and character streams are encoded using
`external-format`; octet vectors and binary streams are transferred without
text conversion.

`result-type` is `:string` by default and may be `:octets` for byte vectors.
`max-output-characters` bounds each captured output stream. For string
results it counts decoded characters and preserves characters split across
read boundaries; for octet results it counts bytes. The corresponding
truncation flag in the result records discarded output. Set the limit to
`nil` for unbounded capture.

`decoding-error-policy` governs malformed-text handling when `result-type`
is `:string` — see [Decoding errors](command-specs.md#decoding-errors) for
the `:replace`/`:error` semantics shared with `make-command`.

## Cancellation options

`cancellation-token` and `on-cancel` are shared with the async API — see
[Cancellation](cancellation.md) for escalation timing and `on-cancel`
semantics.

## Choosing between `run` and `run-command`

`run` takes a program and argument list directly, mirroring
`subprocess.run(...)`. `run-command` takes a pre-built, validated
`command-spec` (see [Command Specifications](command-specs.md)), which is
the better fit when you construct the same command repeatedly, need to
inspect/reuse it, or are composing it into a [pipeline](pipelines.md).

Both put the child process in its own process group, so a timeout or
cancellation kills the entire group — including anything the child itself
forked, such as a shell running a pipeline — rather than leaving orphaned
descendants behind.
