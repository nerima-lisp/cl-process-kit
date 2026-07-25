# cl-process-kit

`cl-process-kit` is an SBCL-only process execution toolkit for Common Lisp,
built on the [nerima-lisp](https://github.com/orgs/nerima-lisp/repositories)
[`cl-boundary-kit`](https://github.com/nerima-lisp/cl-boundary-kit) (clock/
sleeper boundaries) and [`cl-log-kit`](https://github.com/nerima-lisp/cl-log-kit)
(structured logging). It gives Common Lisp the same small, timeout-aware
surface for launching external commands that Python's `subprocess.run()` and
Node.js's `child_process.spawn()` give their own ecosystems.

!!! tip "New to cl-process-kit?"

    Add it to your source registry, then run your first timeout-guarded
    command in a few lines:

    ```sh
    nix flake check github:nerima-lisp/cl-process-kit   # run the test suite
    ```

    Continue with [Installation](installation.md) →
    [Quick Start](quick-start.md) → [Command Specifications](guide/command-specs.md).

## Explore the docs

<div class="grid cards" markdown>

-   :material-rocket-launch:{ .lg .middle } &nbsp; **Getting Started**

    ---

    Nix flake and ASDF/local-checkout install paths, plus a first
    timeout-guarded `run` call.

    [:octicons-arrow-right-24: Installation](installation.md) ·
    [Quick Start](quick-start.md)

-   :material-cog-play-outline:{ .lg .middle } &nbsp; **Running Commands**

    ---

    `command-spec` construction, the synchronous `run` / `run-command` /
    `run-shell` family, and the checked variants that signal on failure.

    [:octicons-arrow-right-24: Command Specifications](guide/command-specs.md) ·
    [Synchronous Execution](guide/execution.md)

-   :material-timer-sand:{ .lg .middle } &nbsp; **Async, Cancellation & Pipelines**

    ---

    Low-level `spawn`/`communicate`, the event-driven `process-task` API,
    cooperative cancellation tokens, and multi-stage `run-pipeline`.

    [:octicons-arrow-right-24: Asynchronous Execution](guide/async.md) ·
    [Cancellation](guide/cancellation.md) ·
    [Pipelines](guide/pipelines.md)

-   :material-console-line:{ .lg .middle } &nbsp; **Native Backends & Observability**

    ---

    The `posix_spawn`-based native trampoline for low-level process setup,
    the optional native PTY backend for interactive/job-control programs,
    and structured `cl-log-kit` observability hooks.

    [:octicons-arrow-right-24: Native Spawn Trampoline](guide/native-spawn.md) ·
    [PTY Backend](guide/pty.md) ·
    [Structured Logging](guide/logging.md)

</div>

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
  a pipeline, for example) — no orphaned processes left behind after a
  deadline.
- `run`'s polling loop takes `clock` and `sleeper` — `cl-boundary-kit` clock
  and sleeper boundary objects — as explicit arguments, so tests can replace
  real time with `cl-boundary-kit:make-fake-clock`/`make-test-sleeper` and
  exercise the timeout/escalation branches without waiting on the wall clock.
- Process lifecycle events (launch, timeout/cancellation escalation,
  pipeline stage failure) are optionally observable as `cl-log-kit`
  structured log records by binding `*process-logger*`; the default `nil`
  logger keeps the library silent, exactly as before.

It exists to consolidate the "timeout-guarded process launch" logic that had
been reimplemented ad hoc across several sister projects (`nshell`,
`cl-tmux`, `private-trade-fx`, ...) into one reusable, tested library.

## Capability map

- `command-spec` construction with validated stdio/environment/directory
  policies — see [Command Specifications](guide/command-specs.md).
- Synchronous `run`, `run/checked`, `run-shell`, `run-command`,
  `run-command/checked` — see [Synchronous Execution](guide/execution.md).
- Low-level `spawn`/`spawn-command`, blocking `communicate`, and the
  event-driven `communicate-async`/`process-task`/`await-process` API — see
  [Asynchronous Execution](guide/async.md).
- Cooperative `cancellation-token`s that terminate a command's whole process
  group — see [Cancellation](guide/cancellation.md).
- Multi-stage `run-pipeline`/`run-pipeline/checked` with per-stage results —
  see [Pipelines](guide/pipelines.md).
- A `posix_spawn`-based native trampoline (`spawn-native`) for session/
  process-group/credential/resource-limit setup with typed launch-failure
  reporting — see [Native Spawn Trampoline](guide/native-spawn.md).
- An optional native controlling-terminal PTY backend
  (`cl-process-kit/pty`) — see [PTY Backend](guide/pty.md).
- Optional `cl-log-kit` structured observability via `*process-logger*` —
  see [Structured Logging](guide/logging.md).
- A full `process-error` condition hierarchy and `process-result`/
  `pipeline-result` accessors — see
  [Results and Conditions](reference/results-and-conditions.md).

## Nix workflow

The [flake.nix](https://github.com/nerima-lisp/cl-process-kit/blob/main/flake.nix)
at the repository root packages `cl-process-kit` as a Nix flake:

- `nix develop` — a devShell with SBCL and a C compiler on `CL_SOURCE_REGISTRY`,
  pinned to the tested `cl-weave`, `cl-boundary-kit`, `cl-log-kit`, and
  `cl-tty-kit` versions.
- `nix build` — the `cl-process-kit` ASDF-system package (`packages.default`)
  and the optional native `cl-process-kit-pty` shared library
  (`packages.cl-process-kit-pty`).
- `nix flake check` — the full checkout test suite (`checks.checkout-tests`)
  and the PTY integration suite (`checks.pty-tests`) as reproducible
  derivations.
- `nix run .` / `nix run .#test` — runs `run-tests.lisp` against the pinned
  dependency set.
- `nix build .#docs` — builds this documentation site with MkDocs (Material)
  in `--strict` mode, so broken links fail the build.

## License

MIT. See [LICENSE](https://github.com/nerima-lisp/cl-process-kit/blob/main/LICENSE).
