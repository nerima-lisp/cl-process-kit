# Development

```sh
git clone https://github.com/nerima-lisp/cl-process-kit.git
cd cl-process-kit
nix develop        # SBCL + a C compiler, CL_SOURCE_REGISTRY preconfigured
nix flake check    # build the native trampoline, run the full test suite
```

The Nix flake pins the tested `cl-weave`, `cl-boundary-kit`, and
`cl-log-kit` versions and configures the Common Lisp source registry, so
`nix flake check` is the preferred way to run the suite. Inside
`nix develop`, `sbcl --script run-tests.lisp` is also available with the
pinned dependencies.

`nix flake check` is the authoritative gate: it runs in the same sandboxed
environment CI uses, and covers the test suite (`checks.default`), the PTY
integration suite (`checks.pty-tests`), Nix formatting (`checks.formatting`),
and the `mkdocs --strict` build (`checks.docs`). A change that only passes a
local, non-sandboxed `sbcl --script run-tests.lisp` is not fully verified.

```sh
nix run .#test     # the suite on its own
nix fmt            # format Nix sources (treefmt/nixfmt)
```

## Making a change

Beyond the org-wide
[CONTRIBUTING](https://github.com/nerima-lisp/.github/blob/main/CONTRIBUTING.md)
guide, three expectations are specific to this repository.

- Add or update tests for any behaviour change. `t/mutation-test.lisp` and
  `t/property-test.lisp` are the examples to follow: they test a contract
  rather than a single case.
- `src/` coverage is a ratchet, not a report. The
  `+minimum-expression-coverage+` / `+minimum-branch-coverage+` floors in
  `run-tests.lisp` fail the build on a regression, and are only ever raised —
  see [Coverage](#coverage) below.
- Prefer a structural refactoring tool such as
  [`paredit-cli`](https://github.com/nerima-lisp/paredit-cli) over
  hand-editing balanced-parenthesis code when reshaping existing forms.

Record user-visible changes under `## [Unreleased]` in `CHANGELOG.md`; the
release workflow extracts that version's section as the GitHub Release body.

Beyond example-based `describe`/`it`/`expect` tests, the suite uses
[`cl-weave`](https://github.com/nerima-lisp/cl-weave)'s `it-property` for
value-space invariants (for example: `run` reports exactly the requested
exit code for every code in `[0, 255]`), `with-mocked-functions` for
isolating slow or non-deterministic collaborators, `it-each` for
table-driven guard-clause tests (each malformed-input row is its own
independently-reported case, not one aggregate pass/fail), and
`run-mutations`/`assert-mutation-score` for mutation testing
(`process-success-p`/`pipeline-success-p`'s case battery must kill every
one-operator mutation of the live function body, not just execute every
line -- coverage alone cannot prove that).

## Running the suite on both platforms

The suite is 179 tests. All of them run on macOS; seven are `it-skip`ped on
Linux under `#+linux`, each a case asserting that a process group is gone
within a 0.1s grace period — timing a contended shared CI runner cannot
reliably deliver. `t/package.lisp`'s `+suite-complete-p+` records that, and
`run-tests.lisp` enforces its coverage ratchet only when it is true: a floor
set from a complete run is not a bound on a partial one, and holding the
Linux run to the macOS floor reported the skipped tests as a coverage
regression on every CI build before 1.0.0.

Running on both platforms is worth the effort, because process semantics
diverge exactly where this library works: signal delivery, process-group
reaping, and whether closing a descriptor interrupts a thread already blocked
reading it (macOS/BSD do; Linux does not). Two real defects shipped in 0.2.0
were invisible on macOS and obvious on Linux — see 1.0.0's `### Correctness`
notes in the [changelog](changelog.md).

Two habits follow. Never name a program a guard-clause test does not intend
to execute: `/bin/true` does not exist on macOS, so a
`(signals error (run "/bin/true" ... :bad-option))` there passes on the
launch failure whether or not the guard exists. Resolve fixtures through
`PATH` with the `%true-program`/`%spawn-sleeping` helpers in `t/package.lisp`
instead. And reach for a `#+linux it-skip` only for a test whose *assertion*
is unsound on that platform, never for one catching a real difference in the
library — skipping the latter hides the failure from CI without making the
library any less broken there.

CI runs Linux. To check locally before pushing, run the suite in a container:

```sh
docker run --rm -v "$PWD/..":/src -w /src/cl-process-kit \
  -e CL_SOURCE_REGISTRY="/src//" clfoundation/sbcl:2.6.1-bookworm \
  sh -c 'cc -O2 -o /tmp/spawn native/spawn.c &&
         CL_PROCESS_KIT_SPAWN=/tmp/spawn sbcl --script run-tests.lisp'
```

This assumes the sibling `nerima-lisp` dependency checkouts live alongside
this one, which is what mounting the parent directory as `/src` provides.

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

The optional `cl-process-kit/pty` system adds `package-pty.lisp` and
`pty.lisp` (the [PTY backend](guide/pty.md)'s alien routine declarations
and `pty-process` operations) as a separate `:pathname "src"` component
list in `cl-process-kit.asd`, kept out of the core system's
dependency/build footprint. Its `defpackage` stays out of
`src/package.lisp` so loading the core system never defines a package
whose symbols have no code behind them; the test-side package, which has
no such constraint, lives in `t/package.lisp` with the rest.

`t/` mirrors that split:

- `run-test.lisp` covers `run`/`run-command`'s non-timeout behavior
  (environment/directory, stdio, output capture and encoding).
- `run-timeout-test.lisp` covers timeout/SIGTERM->SIGKILL escalation and
  cancellation-token handling, split out of `run-test.lisp` once it grew
  past 380 lines across five thematically distinct suites.
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
  clause as a `cl-weave:it-each` table (one independently-reported case per
  malformed-input row) plus the native decoders directly.
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
- `mutation-test.lisp` mutation-tests `process-success-p`/
  `pipeline-success-p` with `cl-weave:run-mutations`, reading each `defun`
  body live from `src/command.lisp` on every run so the case battery can
  never silently drift out of sync with the implementation it is checking.

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
