# cl-process-kit

[![CI](https://github.com/nerima-lisp/cl-process-kit/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/nerima-lisp/cl-process-kit/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Documentation](https://img.shields.io/badge/docs-MkDocs%20Material-3f51b5)](https://nerima-lisp.github.io/cl-process-kit/)

Full documentation — installation, the command/execution/async/pipeline
guide, the PTY backend, and the results/conditions reference — is published
at <https://nerima-lisp.github.io/cl-process-kit/>. The source for that site
lives in [docs/src/](docs/src/README.md).

`cl-process-kit` is an SBCL-only process execution toolkit for Common Lisp,
built on the [nerima-lisp](https://github.com/orgs/nerima-lisp/repositories)
[`cl-boundary-kit`](https://github.com/nerima-lisp/cl-boundary-kit) (clock/
sleeper boundaries) and [`cl-log-kit`](https://github.com/nerima-lisp/cl-log-kit)
(structured logging). It provides a small, timeout-aware surface for launching
external commands, modeled on the design of Python's `subprocess.run()` and
Node.js's `child_process.spawn()`: a high-level synchronous `run` that
captures output and can enforce a deadline, and a low-level asynchronous
`spawn` for callers who want to drive the process themselves.

It exists to consolidate the "timeout-guarded process launch" logic that had
been reimplemented ad hoc across several sister projects (`nshell`,
`cl-tmux`, `private-trade-fx`, ...) into one reusable, tested library.

## Design intent

Most Common Lisp code that shells out reaches straight for
`sb-ext:run-program` and then hand-rolls timeout polling, SIGTERM/SIGKILL
escalation, and output capture every time. `cl-process-kit` extracts that
pattern once, the way modern languages ship it in their standard library:

- **`run`** mirrors Python's `subprocess.run(..., timeout=...)`: synchronous,
  captures stdout/stderr as strings or octet vectors, and can raise (or
  report) a timeout after escalating from SIGTERM to SIGKILL.
- **`spawn`** mirrors Node's `child_process.spawn()`: fire-and-forget,
  returns a handle immediately, and leaves streaming/job-control to the
  caller.
- Both put the child process in its own process group, so a timeout kills
  not just the immediate child but anything it has forked (a shell running
  a pipeline, for example) -- no orphaned processes left behind after a
  deadline.
- `run`'s polling loop takes `clock` and `sleeper` -- CL-BOUNDARY-KIT clock
  and sleeper boundary objects -- as explicit arguments, so tests can replace
  real time with `cl-boundary-kit:make-fake-clock`/`make-test-sleeper` and
  exercise the timeout/escalation branches without waiting on the wall clock.
- Process lifecycle events (launch, timeout/cancellation escalation,
  pipeline stage failure) are optionally observable as CL-LOG-KIT structured
  log records by binding `*process-logger*`; the default `nil` logger keeps
  the library silent, exactly as before.

## Installation

### Nix flake

```sh
nix flake check github:nerima-lisp/cl-process-kit   # run the test suite
nix build github:nerima-lisp/cl-process-kit          # build the ASDF system
```

Or add it as a flake input and pull the `cl-process-kit` package/dev shell
from `packages.<system>.cl-process-kit`.

### ASDF / local checkout

```sh
git clone https://github.com/nerima-lisp/cl-process-kit.git
```

Point `CL_SOURCE_REGISTRY` (or `~/.config/common-lisp/source-registry.conf.d/`)
at the checkout, then:

```lisp
(asdf:load-system "cl-process-kit")
```

## Usage

```lisp
(let ((command (process-kit:make-command
                "/usr/bin/printf" (list "%s\n" "hello, world")
                :stdout :capture
                :stderr :capture)))
  (process-kit:run-command command))
;; => a PROCESS-RESULT whose stdout is "hello, world\n"

;; A command that runs too long is escalated SIGTERM -> SIGKILL and, by
;; default, signals a condition:
(handler-case
    (process-kit:run "sleep" (list "10") :timeout 1)
  (process-kit:process-timeout-error (e)
    (format t "timed out after ~a seconds~%"
            (process-kit:process-timeout-error-timeout e))))

;; Or ask for a result instead of a condition:
(let ((result (process-kit:run "sleep" (list "10")
                                :timeout 1
                                :on-timeout :return)))
  (process-kit:process-result-timed-out-p result)) ;; => T

;; Cancellation is cooperative at the API boundary and terminates the
;; command's process group:
(let ((token (process-kit:make-cancellation-token)))
  (process-kit:cancel token)
  (process-kit:run-command
   (process-kit:make-command "/bin/sleep" (list "10"))
   :cancellation-token token
   :on-cancel :return))
;; => a PROCESS-RESULT whose cancelled-p is true

;; Low-level async primitive when you want to stream output yourself.
;; WITH-PROCESS terminates/reaps the child and closes its streams on exit:
(process-kit:with-process
    (process (process-kit:spawn-command
              (process-kit:make-command
               "/usr/bin/printf" (list "hello\n")
               :stdout :pipe)))
  (read-line (process-kit:process-output process)))

;; A pipeline captures the final stage's stdout and every stage's stderr:
(process-kit:run-pipeline
 (list (process-kit:make-command "/usr/bin/printf" (list "c\nb\na\n"))
       (process-kit:make-command "/usr/bin/sort" nil)))
;; => a PIPELINE-RESULT whose stdout is "a\nb\nc\n"
```

## API

### Command specifications

`make-command` creates an immutable-by-interface `command-spec`:

```lisp
(process-kit:make-command
 "/usr/bin/env" nil
 :search nil
 :environment-policy :inherit
 :environment-update (list (cons "LANG" "C")
                           (cons "DEBUG" nil))
 :directory #P"/tmp/"
 :stdin :inherit
 :stdout :capture
 :stderr :capture
 :result-type :string
 :external-format :utf-8)
```

Its positional arguments are `program` and a proper list of string
`arguments`. `environment-policy` is either `:inherit` or a complete list of
`"KEY=VALUE"` strings; an empty list requests an empty environment.
`environment-update` is an ordered alist: a string value sets a variable and
`nil` deletes it. Updates are applied after the base policy.

Executable search is disabled by default. With `search` (or `:search`) true,
cl-process-kit resolves the executable before launching it, using only the
`PATH` in the effective environment. `:inherit` therefore uses a copied parent
`PATH` when present, while a replacement environment without `PATH` performs
no search and signals `process-launch-error`. Programs containing a slash
bypass `PATH` lookup. Relative programs and `PATH` components, including empty
components, are resolved against the effective working directory. A candidate
that is missing, is a directory, or is not executable signals
`process-launch-error`.

The `stdin`, `stdout`, and `stderr` policies accept `:inherit`, `:null`,
`:pipe`, `:capture`, a stream, or a pathname; `stderr` additionally accepts
`:stdout`. `result-type` is `:string` or `:octets`. Accessors are named
`command-program`, `command-arguments`, `command-search`,
`command-environment-policy`, `command-environment-update`,
`command-directory`, `command-stdin`, `command-stdout`, `command-stderr`,
`command-result-type`, and `command-external-format`. `command-p` tests the
type.

### High-level execution

- `run (command arguments &key search input environment directory
  error timeout grace-period poll-interval timeout-signal kill-signal
  on-timeout max-output-characters drain-timeout-seconds result-type
  external-format clock sleeper cancellation-token on-cancel fd-limit)`
  -> `process-result`. `fd-limit`, if given, temporarily lowers this
  process's own `RLIMIT_NOFILE` soft limit around the spawn (restored
  immediately afterward) -- the spawned child inherits the lower limit
  through `exec`. On hosts with a very large ambient file-descriptor limit
  (routine under Nix/direnv shells), this measurably cuts spawn latency: the
  forked child otherwise closes every inherited descriptor up to that limit
  one syscall at a time. `NIL` (the default) leaves the ambient limit
  untouched.
- `run/checked (command arguments &rest options)` -> `process-result`.
  Accepts the same options as `run`. It signals `process-cancelled-error` for
  a returned cancelled result and `process-exit-error` for any other
  unsuccessful result.
- `run-shell (command &rest options)` -> `process-result`. Runs `command`
  through `/bin/sh -c` and accepts the same options as `run`.
- `run-command (command-spec &key input timeout grace-period on-timeout
  cancellation-token on-cancel max-output-characters drain-timeout-seconds)`
  -> `process-result`
- `run-command/checked (command-spec &rest options)` -> `process-result`.
  Accepts the same options as `run-command` and signals `process-exit-error`
  unless the process exits successfully.
- `run-command-async (command-spec &rest options)` -> `process-task`. The
  `command-spec`-driven counterpart of `communicate-async`: spawns
  `command-spec`, forwards its `result-type`/`external-format`/
  `decoding-error-policy` into `communicate-async`, and closes the process's
  streams once the task's terminal event is delivered. Accepts the same
  options as `communicate-async` and, like it, owns its cancellation token --
  passing `cancellation-token` signals an error.

Omit `timeout` to run without a deadline.
`error` is either `:capture` (separate stderr) or `:output` (merge stderr
into stdout). `on-timeout` is `:error` or `:return`.

`clock` and `sleeper` are `cl-boundary-kit` boundary objects (see
`cl-boundary-kit:make-clock` and `cl-boundary-kit:make-sleeper`) that default
to the real system clock and a real, blocking sleep. Pass
`cl-boundary-kit:make-fake-clock`/`make-test-sleeper` instead to drive the
timeout/escalation polling loop deterministically in tests, without waiting
on the wall clock.

`input` accepts a string, an `(unsigned-byte 8)` vector, or a character/binary
stream. Strings and character streams are encoded using `external-format`;
octet vectors and binary streams are transferred without text conversion.

`result-type` is `:string` by default and may be `:octets` for byte vectors.
`max-output-characters` bounds each captured output stream. For string results
it counts decoded characters and preserves characters split across read
boundaries; for octet results it counts bytes. The corresponding truncation
flag in the result records discarded output. Set the limit to `nil` for
unbounded capture.

Prefer `make-command` plus `run-command` for untrusted data: arguments are
passed directly without shell interpolation. `run-shell` invokes
`/bin/sh -c`; never concatenate untrusted input into its command string.

### Asynchronous execution

- `spawn (command arguments &key search input output error environment
  directory external-format status-hook preserve-fds fd-limit)` ->
  `process-handle`
- `spawn-command (command-spec &key stdin stdout stderr)` -> `process-handle`
- `communicate (process &key input timeout grace-period timeout-signal
  kill-signal on-timeout max-output-characters drain-timeout-seconds
  result-type external-format clock sleeper
  poll-interval cancellation-token on-cancel)` -> `process-result`

`communicate` sends optional input, drains stdout and stderr concurrently,
waits for the process, and supports the same timeout, bounded-capture, and
result-type behavior as `run`. It owns communication for that handle: a
second concurrent call is rejected. After completion, the same normalized
options return the identical cached result object; different options signal
`communicate-options-mismatch`. Its
`communicate-options-mismatch-process`,
`communicate-options-mismatch-expected-options`, and
`communicate-options-mismatch-actual-options` readers describe the conflict.
Input strings and octet vectors are snapshotted when communication is
reserved.

Asynchronous communication uses a `process-task` and an ordered event stream:

```lisp
(communicate-async process &rest options)
  => process-task

(await-process task &key timeout)
  => process-result, completed-p

(cancel-process task)
  => task
```

`communicate-async` accepts the `communicate` options except
`cancellation-token`, because the task owns its cancellation token. Its
additional options are `event-callback`, `event-queue-capacity` (a positive
integer, default 64), and `event-overflow-policy` (`:drop-newest` by default,
or `:block`). `event-history-capacity` is a non-negative integer that limits
retained events and callback errors; it defaults to `event-queue-capacity`,
and zero disables history retention. It reserves the process synchronously,
so reservation and option errors are reported before the task is returned.
`await-process` returns `(values nil nil)` if its own non-negative timeout
expires; otherwise it returns `(values result t)` or re-signals the task's
terminal condition. `cancel-process` requests cancellation and returns the
same task. With the default `:on-cancel :return` behavior, the eventual result
is marked cancelled. Explicitly selecting `:on-cancel :error` instead makes
cancellation the task's terminal condition.

`task-state` is one of `:reserved`, `:running`, `:completed`, `:cancelled`, or
`:failed`. `task-result`, `task-condition`, `process-events`,
`callback-errors`, and `dropped-event-count` expose the task outcome and event
history. `process-events` and `callback-errors` return chronological list
copies containing at most the newest `event-history-capacity` entries. Queue
overflow and retained-history eviction are independent; a terminal event can
evict the oldest retained event. `process-task-first-event-sequence` and
`process-task-last-event-sequence` report the sequence range currently
retained (`nil` before the first event); `process-task-history-evicted-count`
counts events evicted from that retained window.

Independent consumers that cannot poll `process-events` -- for example, a
second thread watching the same task -- can instead stream events with a
caller-owned cursor:

```lisp
(next-process-event task &key cursor timeout)
  => event, next-cursor, status, gap-count
```

`cursor` is `nil` (start at the oldest retained event) or a positive sequence
number; `status` is `:event`, `:gap` (the cursor fell behind the retained
history -- resume from `next-cursor`, and `gap-count` is the exact number of
events skipped), `:terminal` (the task has finished and no further events
remain), or `:timeout` (the call's own non-negative `timeout` expired first).
Because cursors are plain integers owned by the caller, multiple independent
consumers can each stream the same task's events at their own pace without
mutating shared task state.

Events have monotonically increasing `process-event-sequence` values and are
inspected with `process-event-kind`, `process-event-octets`,
`process-event-result`, `process-event-condition`, and
`process-event-dropped-count`. `process-event-octets` returns a fresh copy.
`:stdout` and `:stderr` events always contain raw octets. When the bounded
event queue is full, `:drop-newest` drops new output events; `:block` applies
backpressure to the output producer. Dropped output is summarized by an
`:overflow` event when space becomes available, and its cumulative count is
available through `dropped-event-count`.

The callback is invoked serially in event order. A condition signalled by the
callback is captured in `callback-errors` and does not fail the task or stop
later events. Exactly one `:terminal` event is delivered after all queued
output and overflow events. It is outside the bounded queue, cannot be
dropped, and contains either the final result or terminal condition. Task
completion is published only after this terminal callback returns, so a
completed `await-process` also means terminal-event dispatch has finished.

The public `process-handle` operations are:

- `process-id`, `process-status`, `process-stdin`, `process-output`, and
  `process-stderr`
- `process-alive-p`, `process-try-wait`, and `process-wait`. `process-wait`
  accepts `timeout`, `poll-interval`, and `clock` (a `cl-boundary-kit` clock
  boundary; see `run`'s `clock`/`sleeper` above), and returns `nil` if its
  timeout expires.
- `process-exit-code` and `process-signal`
- `process-send-leader-signal`, which signals the live process-group leader
  only
- `process-send-group-signal`, which signals the live owned process group
- `process-terminate` (SIGTERM) and `process-kill` (SIGKILL)
- `close-process-streams`, and `close-process` with optional `terminate` and
  `timeout`. Use `close-process` in cleanup paths to terminate and reap a
  live child before closing its streams.
- `call-with-process` (process continuation &key terminate timeout), which
  calls `continuation` with the process and applies that cleanup with
  `unwind-protect` on the way out, and `with-process`, the macro sugar over it

Streams exposed by `spawn` or `spawn-command` are the caller's responsibility
until ownership is handed to `communicate`. `communicate`, `run-command`, and
`run-pipeline` drain and close the process streams they manage.

### Cancellation

`make-cancellation-token` creates a thread-safe token. `cancel` is idempotent,
and `cancellation-requested-p` observes its state. Pass the token as
`cancellation-token` to `run`, `communicate`, `run-command`, or
`run-pipeline`. Cancellation sends SIGTERM to the process group, waits the
grace period, and sends SIGKILL if needed. `on-cancel :error` (the default)
signals `process-cancelled-error`; `:return` returns a result with
`process-result-cancelled-p` true.

### Pipelines

- `run-pipeline (commands &key input timeout grace-period cancellation-token
  on-timeout on-cancel max-output-characters)` -> `pipeline-result`
- `run-pipeline/checked (commands &rest options)` -> `pipeline-result`.
  Accepts the same options as `run-pipeline` and signals
  `pipeline-exit-error` for the first unsuccessful stage.
- `pipeline-success-p (pipeline-result)` reports whether every stage
  succeeded without timeout or cancellation.

`commands` must be a non-empty list of `command-spec` objects. The final
stage's stdout is available through `pipeline-result-stdout`; per-stage
`process-result` objects are available through `pipeline-result-results`.
`pipeline-result-stderr` contains each stage's captured stderr.
`pipeline-result-timed-out-p`, `pipeline-result-cancelled-p`, and
`pipeline-result-duration-seconds` report aggregate pipeline status.
`pipeline-exit-error` retains the full pipeline result, the zero-based index
of the first unsuccessful stage, and that stage's `process-result`.
Pipeline timeout and cancellation conditions retain the same diagnostic
context. Their `result` readers refer to the actual affected stage, their
`stage-index` readers identify that stage, and their `pipeline-result` readers
retain every stage result.
Pipeline wiring overrides the commands' stdin/stdout/stderr policies as
needed. Inter-stage pipes carry octets, so arbitrary binary data passes through
the pipeline without text decoding.

### Optional PTY backend

`sb-ext:run-program :pty t` supplies a bidirectional PTY stream but does not
establish a controlling terminal, which makes it insufficient for shell job
control. The `cl-process-kit/pty` system (package `process-kit/pty`) adds a
native trampoline that creates a session, acquires the slave as controlling
terminal, sets the initial window size, and execs -- giving `isatty` and
foreground-process-group signaling their usual meaning inside the child.

```lisp
(process-kit/pty:spawn-pty (process-kit:make-command "/bin/sh" nil) :rows 24 :cols 80)
  => pty-process
```

`rows`/`cols` default to the caller's own controlling terminal size (via
[`cl-tty-kit`](https://github.com/nerima-lisp/cl-tty-kit)'s
`cl-tty-kit:terminal-size`), falling back to 24x80 when standard input is
not a terminal.

`pty-read-octets`/`pty-read-string` and `pty-write-octets`/`pty-write-string`
transfer over the single bidirectional master stream (stdout and stderr are
merged, and there is no independent stdin half-close). `pty-resize` updates
the window size; `pty-send-eof` sends the terminal's canonical VEOF character
rather than closing a stream. `pty-foreground-pgid` reports the session's
current foreground process group, and `pty-signal-foreground` signals only
that group after validating it belongs to the session -- the PTY analogue of
`process-send-group-signal`. `pty-wait` accepts `timeout` and
`cancellation-token` and escalates to session-wide SIGTERM/SIGKILL the same
way `communicate` does; `pty-cancel` and `pty-close` are idempotent cleanup
entry points. This subsystem does not go through `communicate`/
`communicate-async`, so its event/backpressure model is unrelated to
`process-event`/`process-task`.

Building `cl-process-kit/pty` requires compiling `native/pty.c` into a shared
library and pointing `CL_PROCESS_KIT_PTY_LIBRARY` at it; the Nix flake's
`cl-process-kit-pty` package and `pty-tests` check do this automatically.

### Results and conditions

`process-result` has accessors for `program`, `arguments`, `pid`, `status`,
`duration-seconds`, `exit-code`, `stdout`, `stderr`, `timed-out-p`,
`cancelled-p`, `signal`, `stdout-truncated-p`, and `stderr-truncated-p`.
`process-success-p` is true only for a normal status-0 exit that neither
timed out nor was cancelled.

Timeout and cancellation terminate the entire isolated process group using
SIGTERM followed by SIGKILL after the grace period. For both,
`on-timeout`/`on-cancel` selects either a condition (`:error`) or a returned
result (`:return`). Non-zero exits are returned normally by `run` and
`run-command`; use `run/checked` or `run-command/checked` when they should
signal `process-exit-error`. Use `run-pipeline/checked` to signal
`pipeline-exit-error` for the first unsuccessful pipeline stage.

All library conditions inherit from `process-error`:

- `process-launch-error`: `program`, `arguments`, `directory`, and `cause`
- `process-exit-error`: `result`
- `pipeline-exit-error`: `result`, `stage-index`, and `stage-result`
- `process-timeout-error`: `command`, `args`, `timeout`, `result`,
  `stage-index`, and `pipeline-result`
- `process-cancelled-error`: `result`, `stage-index`, and `pipeline-result`
- `communicate-options-mismatch`: `process`, `expected-options`, and
  `actual-options`
- `process-group-isolation-error`: `pid` and `pgid`
- `process-io-error`: `stream` and `cause`

### Structured logging

Bind `*process-logger*` to a `log-kit` logger (see
[`cl-log-kit`](https://github.com/nerima-lisp/cl-log-kit)'s
`log-kit:make-logger`) to observe process launch outcomes, timeout/
cancellation signal escalation, and pipeline stage failures as structured
log records:

```lisp
(let ((process-kit:*process-logger*
        (log-kit:make-logger :name "my-app" :handler (make-instance 'log-kit:json-handler))))
  (run "sleep" (list "10") :timeout 1))
```

`*process-logger*` defaults to `nil`, which keeps the library silent exactly
as before observability was added.

Most lifecycle records -- launch outcomes, timeout escalation, pipeline stage
failure -- are emitted on the calling thread, so a thread-local `let` binding
of `*process-logger*` observes them. The *cancellation* escalation record,
however, is emitted from an internal watcher thread, and an SBCL thread reads
a special variable's global value rather than the spawning thread's dynamic
binding. To observe every record, including cancellation escalation, install
the logger globally (`(setf process-kit:*process-logger* logger)`) rather than
binding it dynamically around a single call.

## Development

```sh
nix flake check
```

The Nix flake pins the tested `cl-weave`, `cl-boundary-kit`, and `cl-log-kit`
versions and configures the Common Lisp source registry, so `nix flake check`
is the preferred way to run the suite. Inside `nix develop`,
`sbcl --script run-tests.lisp` is also available with the pinned
dependencies.

Beyond example-based `describe`/`it`/`expect` tests, the suite uses
`cl-weave:it-property` for value-space invariants (for example: `run`
reports exactly the requested exit code for every code in `[0, 255]`),
`cl-weave:with-mocked-functions` for isolating slow or non-deterministic
collaborators, `cl-weave:it-each` for table-driven guard-clause tests
(each malformed-input row is its own independently-reported case, not one
aggregate pass/fail), and `cl-weave:run-mutations`/`assert-mutation-score`
for mutation testing (`process-success-p`/`pipeline-success-p`'s case
battery must kill every one-operator mutation of the live function body,
not just execute every line -- coverage alone cannot prove that).

Set `CL_PROCESS_KIT_COVERAGE=1` to additionally recompile `src/` under
SB-COVER instrumentation and print an expression/branch coverage report
after the suite runs (and save the raw data to `coverage.dat`):

```sh
CL_PROCESS_KIT_COVERAGE=1 sbcl --script run-tests.lisp
```

It is off by default because instrumentation forces a full recompile and
adds per-form bookkeeping overhead that a normal `nix flake check` / CI run
shouldn't pay for.

`src/` is organized by concern rather than as one large file per public
entry point: `types.lisp` and `conditions.lisp` hold pure data shapes and
the condition hierarchy; `parameters.lisp` holds tunable defaults and the
`cl-boundary-kit` clock/sleeper boundary defaults; `logging.lisp` holds the
optional `cl-log-kit` observability hook; `command.lisp` holds
`command-spec`/cancellation validation and accessor logic;
`process-handle.lisp`, `process-group.lisp`, and `communication-state.lisp`
hold the low-level `process-handle` lifecycle; `capture.lisp` and
`copier.lisp` hold output capture and the stream-copier/feeder threads;
`communicate.lisp`, `async-events.lisp`, `async-task.lisp`, `run.lisp`, and
`pipeline.lisp` hold, respectively, the cancellation-aware `communicate`, the
event-queue/dispatch machinery behind the asynchronous API (ring buffer,
`process-event` submission, and the dispatcher), the `process-task` accessors
and `communicate-async`/`await-process`/`cancel-process` entry points that
drive it, the synchronous `run`/`run-command` entry points, and
`run-pipeline`.

`t/` mirrors that split: `run-test.lisp` covers `run`/`run-command`/
cancellation, `process-handle-test.lisp` covers `process-handle` bookkeeping,
`pipeline-test.lisp` covers `run-pipeline`, and `async-task-test.lisp`
covers `communicate-async`/`run-command-async`/the event cursor API.
`conditions-test.lisp` asserts each condition's `:report` output;
`logging-test.lisp` binds `*process-logger*` and checks the lifecycle records;
`validation-test.lisp` drives every `make-command`/`spawn-native` guard clause
as a `cl-weave:it-each` table (one independently-reported case per
malformed-input row) plus the native decoders directly;
`edge-coverage-test.lisp` exercises the reachable branch edges the behavioral
suites skip -- stream-valued `:input`, `process-wait` timeout expiry, the
at-most-once `communicate` contract, UTF-8 surrogate/overlong replacement, and
(via `cl-weave:with-mocked-functions` fault injection) copier-thread failure;
`property-test.lisp` states value-space laws with `cl-weave:it-property`
generators (an octet round trip through `cat`, argument preservation, the
NUL-rejection guard, the success predicate), which cl-weave shrinks to a
minimal counterexample on failure; and `mutation-test.lisp` mutation-tests
`process-success-p`/`pipeline-success-p` with `cl-weave:run-mutations`,
reading each `defun` body live from `src/command.lisp` on every run so the
case battery can never silently drift out of sync with the implementation
it is checking.

Argument validation across the library is written with the `%ensure` guard
macro (the `assert`-style `(%ensure test control-or-class ...)` counterpart of
a two-line `unless`/`error` pair), and `with-process` is thin syntax over the
exported continuation-passing `call-with-process`, so the resource-cleanup
contract lives once as a function.

Expression/branch coverage of `src/` sits in the mid-80s/mid-70s percent. The
untested remainder is essentially unreachable at runtime: macro-definition and
`defstruct` bodies run at macroexpansion/compile time (so `conditions.lisp`,
`logging.lisp`, and `types.lisp` read low even though the code they expand into
is covered), and a handful of defensive arms only fire on OS syscall failures
that a portable test cannot provoke.

## License

MIT. See [LICENSE](LICENSE).
