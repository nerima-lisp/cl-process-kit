# Development

```sh
nix flake check
```

The Nix flake pins the tested `cl-weave`, `cl-boundary-kit`, and
`cl-log-kit` versions and configures the Common Lisp source registry, so
`nix flake check` is the preferred way to run the suite. Inside
`nix develop`, `sbcl --script run-tests.lisp` is also available with the
pinned dependencies.

Beyond example-based `describe`/`it`/`expect` tests, the suite uses
[`cl-weave`](https://github.com/nerima-lisp/cl-weave)'s `it-property` for
value-space invariants (for example: `run` reports exactly the requested
exit code for every code in `[0, 255]`) and `with-mocked-functions` for
isolating slow or non-deterministic collaborators.

## Testing the PTY backend

`nix flake check` runs `checks.pty-tests` alongside the core suite, so it
needs no separate invocation under Nix. Outside Nix, [build the native PTY
library](guide/pty.md#building-the-native-library), then run:

```sh
CL_PROCESS_KIT_PTY_LIBRARY=$PWD/libcl_process_kit_pty.so sbcl --script run-pty-tests.lisp
```

## Coverage

Set `CL_PROCESS_KIT_COVERAGE=1` to additionally recompile `src/` under
SB-COVER instrumentation and print an expression/branch coverage report
after the suite runs (and save the raw data to `coverage.dat`):

```sh
CL_PROCESS_KIT_COVERAGE=1 sbcl --script run-tests.lisp
```

It is off by default because instrumentation forces a full recompile and
adds per-form bookkeeping overhead that a normal `nix flake check` / CI run
shouldn't pay for.

Expression/branch coverage of `src/` sits in the mid-80s/mid-70s percent.
The untested remainder is essentially unreachable at runtime:
macro-definition and `defstruct` bodies run at macroexpansion/compile time
(so `conditions.lisp`, `logging.lisp`, and `types.lisp` read low even
though the code they expand into is covered), and a handful of defensive
arms only fire on OS syscall failures that a portable test cannot provoke.

## Source layout

`src/` is organized by concern rather than as one large file per public
entry point:

| File | Holds |
| --- | --- |
| `types.lisp`, `conditions.lisp` | Pure data shapes and the condition hierarchy |
| `parameters.lisp` | Tunable defaults and the `cl-boundary-kit` clock/sleeper boundary defaults |
| `logging.lisp` | The optional `cl-log-kit` observability hook |
| `command.lisp` | `command-spec`/cancellation validation and accessor logic |
| `spawn.lisp` | The low-level [`spawn`/`spawn-command`](guide/async.md#spawning-a-handle) primitive, wrapping `sb-ext:process` into a `process-handle`; `run` is built on top of it |
| `process-handle.lisp`, `process-group.lisp`, `communication-state.lisp` | The low-level `process-handle` lifecycle |
| `capture.lisp`, `copier.lisp` | Output capture and the stream-copier/feeder threads |
| `communicate.lisp` | The cancellation-aware `communicate` |
| `async-events.lisp` | The event-queue/dispatch machinery behind the asynchronous API (ring buffer, `process-event` submission, and the dispatcher) |
| `async-task.lisp` | The `process-task` accessors and `communicate-async`/`await-process`/`cancel-process` entry points that drive it |
| `run.lisp` | The synchronous `run`/`run-command` entry points |
| `pipeline.lisp` | `run-pipeline` |
| `native-spawn.lisp` | The [`spawn-native`](guide/native-spawn.md) trampoline: CLI-flag translation, the launch-error pipe protocol, and `native-process-launch-error` |

The optional `cl-process-kit/pty` system adds `pty-package.lisp` and
`pty.lisp` (the [PTY backend](guide/pty.md)'s alien routine declarations
and `pty-process` operations) as a separate `:pathname "src"` component
list in `cl-process-kit.asd`, kept out of the core system's
dependency/build footprint.

`t/` mirrors that split:

- `run-test.lisp` covers `run`/`run-command`/cancellation.
- `spawn-test.lisp` covers raw `spawn` process lifecycle, process-handle
  streams, `communicate` result caching, structured logging, process-group
  termination, input validation, and executable resolution.
- `process-handle-test.lisp` covers `process-handle` bookkeeping.
- `pipeline-test.lisp` covers `run-pipeline`.
- `async-task-test.lisp` covers `communicate-async`/`run-command-async`/the
  event cursor API.
- `conditions-test.lisp` asserts each condition's `:report` output.
- `logging-test.lisp` binds `*process-logger*` and checks the lifecycle
  records.
- `validation-test.lisp` drives every `make-command`/`spawn-native` guard
  clause from a data table plus the native decoders directly.
- `native-spawn-test.lisp` covers [`spawn-native`](guide/native-spawn.md)'s
  Lisp-level launch and typed-error paths; `native-spawn-test.sh` is a
  standalone shell script (invoked directly by `nix flake check`, not
  through `run-tests.lisp`) that drives the compiled trampoline binary's
  full CLI surface — fd mapping, fd passing, `--chdir`, `--session`,
  `--rlimit`, `--umask`, and the 8-byte launch-error record — without a
  Lisp process in the way.
- `pty-test.lisp` (in the separate `cl-process-kit/pty-test` system, run via
  `run-pty-tests.lisp`) covers the [PTY backend](guide/pty.md): controlling
  session/foreground process group, resize, raw octet transfer, EOF,
  foreground-only signaling, and timeout escalation.
- `edge-coverage-test.lisp` exercises the reachable branch edges the
  behavioral suites skip — stream-valued `:input`, `process-wait` timeout
  expiry, the at-most-once `communicate` contract, UTF-8
  surrogate/overlong replacement, and (via `cl-weave:with-mocked-functions`
  fault injection) copier-thread failure.
- `property-test.lisp` states value-space laws with `cl-weave:it-property`
  generators (an octet round trip through `cat`, argument preservation, the
  NUL-rejection guard, the success predicate), which cl-weave shrinks to a
  minimal counterexample on failure.

## Conventions

Argument validation across the library is written with the `%ensure` guard
macro (the `assert`-style `(%ensure test control-or-class ...)` counterpart
of a two-line `unless`/`error` pair), and `with-process` is thin syntax
over the exported continuation-passing `call-with-process`, so the
resource-cleanup contract lives once as a function.

## Building this documentation site

```sh
nix build .#docs
```

builds this MkDocs (Material) site in `--strict` mode offline, so a broken
internal link fails the build the same way CI would catch it. For local
iteration:

```sh
mkdocs serve -f docs/mkdocs.yml
```
