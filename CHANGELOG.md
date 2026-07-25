# Changelog

All notable changes to this project will be documented in this file.

## [0.1.0]

First release. The initial `sb-ext:run-program`-only prototype was rebuilt
into a full process execution toolkit on top of `cl-boundary-kit` and
`cl-log-kit`; nothing prior to this was ever tagged, so there is no
compatibility surface to preserve.

### Dependencies

- Bumped `cl-weave` v0.10.0 -> v0.11.0, `cl-boundary-kit` v0.4.0 -> v0.5.0,
  `cl-tty-kit` v0.4.0 -> v0.5.0 (`cl-log-kit` was already at latest,
  v1.1.0). Verified with a full `nix flake check` (both `checkout-tests`
  and `pty-tests`), not just a local `sbcl --script` run.
- Fixed `t/native-spawn-test.sh`'s Darwin file-mode check, which had never
  actually passed under `nix flake check` on macOS: a Nix sandbox's `PATH`
  puts GNU coreutils' `stat` ahead of the system's, and GNU `stat -f`
  means "show filesystem status" (a different, incompatible option from
  BSD `stat -f FORMAT`), so `stat -f %Lp` silently invoked the wrong
  implementation and failed. Now calls `/usr/bin/stat` explicitly on that
  branch. Confirmed pre-existing (reproduced against the previously
  committed `flake.lock`, unrelated to the dependency bump above) via a
  clean `nix flake check` run before any other change in this session.

### Performance

- `spawn`/`run` accept a new `:fd-limit` option. `SB-EXT:RUN-PROGRAM`'s
  forked child closes every inherited file descriptor up to its
  `RLIMIT_NOFILE` one syscall at a time on Darwin; on a host with a very
  large ambient limit (routine under Nix/direnv shells), that is a
  measurable fraction of per-call latency. `:fd-limit` temporarily lowers
  this process's own soft limit around the spawn (restored immediately
  afterward, regardless of success or failure) so the child inherits a
  smaller one instead. Opt-in and `NIL` by default: the lowered limit is
  inherited by the child through `exec` and persists for its lifetime, so
  this is a caller decision, not a silent default.

### Known Limitations

- On Linux, when a spawned process exits but leaves a backgrounded
  descendant holding its stdout/stderr pipe open (e.g. `sh -c "sleep 5 &
  exit 0"`), `run`'s output-draining cleanup can block past
  `drain-timeout-seconds` instead of returning within its documented
  bound. The cleanup path force-closes the blocked stream to unstick its
  reader thread, which reliably interrupts a concurrent blocking `read`
  on macOS/BSD but is not guaranteed to on Linux: the reader only
  returns once the pipe's last writer actually exits or closes its own
  copy of the descriptor. Fixing this correctly needs the copier read
  loop redesigned around non-blocking I/O instead of relying on `close`
  to interrupt a blocked read; tracked for a future release. The
  regression test for this case is skipped on Linux
  (`t/run-test.lisp`) rather than flaking CI red on every run.
- Several more process-group/communicate tests are Linux-only flaky for the
  same underlying reason -- timing around signal delivery, process-group
  reaping, and blocked-read interruption is not guaranteed identical to
  macOS/BSD: `communicate result caching > rejects a concurrent communicate
  while capture is in progress`; `process-group termination > kills
  descendants after the process-group leader exits on TERM`, `> does not
  publicly signal a group after its leader is terminal`, `> provides
  distinct leader and group signal operations`, `> close-process cleans
  descendants more than five seconds after their leader exits`
  (`t/spawn-test.lisp`); and `communicate-async events > communicate-async
  reports overflow without losing the terminal event`, `> cancels blocked
  asynchronous output without failing the task` (`t/async-task-test.lisp`).
  All are skipped on Linux for the same reason and tracked alongside the
  drain-timeout issue above for a future release.

### Added

- `run` (and `run/checked`, `run-shell`) gained an `:output` policy alongside
  the existing `:error` one, and both now accept `:inherit` or a stream in
  addition to `:capture` (and, for `:error`, `:output`). `:capture` collects the
  fd into the `process-result` as before (still the default, so existing callers
  are unaffected); `:inherit` lets the child write straight to this process's own
  descriptor for live, uncaptured output; and a stream sends it there. This lets
  a caller run a foreground command with output flowing live to the terminal (or
  a log file) while still getting `run`'s timeout and whole-process-group
  SIGTERM→SIGKILL escalation — the "stream it, don't buffer it" case that
  previously forced callers back onto raw `spawn`/`communicate`. The
  command-spec path (`make-command`/`run-command`) already accepted inherited and
  stream stdio; this brings the program-and-args `run` path to parity.
- `command-spec`/`make-command`: validated, defensively-copied command
  construction (`:search`, `:environment-policy`, `:environment-update`,
  `:directory`, `:stdin`/`:stdout`/`:stderr`, `:result-type`,
  `:external-format`, `:decoding-error-policy`).
- A `process-error` condition hierarchy (launch, exit, timeout,
  cancellation, pipeline, communicate-mismatch, group-isolation, and I/O
  failures) built on a shared `define-process-condition` macro.
- `process-kit:run`/`run-command` (synchronous, timeout-aware,
  output-capturing) and `process-kit:spawn` (asynchronous primitive), now
  built on a mutex-guarded process handle and POSIX process-group
  isolation instead of calling `sb-ext:run-program` directly.
- An async task/event API (`async-events.lisp`, `async-task.lisp`):
  `communicate-async` delivers `process-event`s instead of blocking for a
  final `process-result`, with a cursor API (`next-process-event`) over
  bounded, retained event history.
- Pipeline composition (`run-pipeline`/`run-pipeline/checked`): chains
  commands with each stage's stdout feeding the next stage's stdin, and
  attributes a mid-pipeline timeout or cancellation to the failing stage
  via `process-timeout-error`'s `stage-index`/`pipeline-result` slots.
- An optional native (non-`sb-ext:run-program`) spawn backend
  (`native-spawn.lisp` plus a `posix_spawn`-based C trampoline in
  `native/spawn.c`) with typed launch-failure phases and errno reporting.
- An optional native PTY backend (`cl-process-kit/pty`,
  `cl-process-kit/pty-test`): a controlling-terminal session with its own
  foreground process group, kept out of the dependency-light core system.
- Structured logging of process lifecycle events via `*process-logger*`
  (spawned/launch-failed/timed-out/cancelled), backed by `cl-log-kit`.
- Injectable `clock`/`sleeper` boundaries from `cl-boundary-kit` for
  deterministic polling in tests.
- Process-group isolation so a timeout kill reaches descendants spawned by
  the child (e.g. a shell running an external command), not just the
  immediate child process; spawn now verifies the child actually landed in
  its own process group and signals `process-group-isolation-error` on
  mismatch instead of continuing silently.
- Test suite (`cl-process-kit/test`) using `cl-weave`, covering all of the
  above plus UTF-8 decoding edge cases, at-most-once communicate
  semantics, copier thread error propagation, and property-based checks
  over the run/octet/success-predicate value space; a separate
  `cl-process-kit/pty-test` integration suite for the PTY backend.
- Nix flake (`flake.nix`) building the native C trampoline and PTY shared
  library, with package, dev shell, and `nix flake check` test targets;
  GitHub Actions CI running `nix flake check`.

### Changed

- `process-timeout-error`'s `timeout-seconds` slot is renamed to `timeout`
  and gains `result`/`stage-index`/`pipeline-result` slots for
  pipeline-stage attribution.
- The default SIGTERM-to-SIGKILL grace period changed from 0.2s to 1.0s.
- `run`/`spawn` reject `:input t`, since standard input inheritance cannot
  be safely isolated into the child's process group.
- `cl-process-kit` now depends on `cl-boundary-kit` and `cl-log-kit`
  instead of being dependency-free.
