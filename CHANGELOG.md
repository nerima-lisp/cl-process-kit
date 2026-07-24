# Changelog

All notable changes to this project will be documented in this file.

## [0.1.0]

First release. The initial `sb-ext:run-program`-only prototype was rebuilt
into a full process execution toolkit on top of `cl-boundary-kit` and
`cl-log-kit`; nothing prior to this was ever tagged, so there is no
compatibility surface to preserve.

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

### Added

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
