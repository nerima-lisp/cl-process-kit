# cl-process-kit

[![CI](https://github.com/nerima-lisp/cl-process-kit/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/nerima-lisp/cl-process-kit/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Documentation](https://img.shields.io/badge/docs-MkDocs%20Material-3f51b5)](https://nerima-lisp.github.io/cl-process-kit/)

`cl-process-kit` is an SBCL-only process execution toolkit for Common Lisp,
built on the [nerima-lisp](https://github.com/orgs/nerima-lisp/repositories)
[`cl-boundary-kit`](https://github.com/nerima-lisp/cl-boundary-kit) (clock/
sleeper boundaries) and [`cl-log-kit`](https://github.com/nerima-lisp/cl-log-kit)
(structured logging). It gives Common Lisp the same small, timeout-aware
surface for launching external commands that Python's `subprocess.run()` and
Node.js's `child_process.spawn()` give their own ecosystems: a high-level
synchronous `run`/`run-command` that captures output and can enforce a
deadline with SIGTERM→SIGKILL escalation, a low-level asynchronous `spawn`
for callers who want to drive the process themselves, cooperative
cancellation, and multi-stage pipelines -- all isolated in their own process
group so a timeout or cancellation reaches everything a child forked, not
just the child itself.

**Full documentation** -- installation, the command/execution/async/pipeline
guide, the native spawn and PTY backends, and the results/conditions
reference -- is published at
<https://nerima-lisp.github.io/cl-process-kit/>. The source for that site
lives in [docs/src/](docs/src/README.md).

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

See [Installation](https://nerima-lisp.github.io/cl-process-kit/installation/)
for the optional native PTY backend's extra build step.

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
```

See [Quick Start](https://nerima-lisp.github.io/cl-process-kit/quick-start/)
for cancellation, streaming output yourself with `spawn`, and pipelines, and
the [Guide](https://nerima-lisp.github.io/cl-process-kit/guide/command-specs/)
for the full option reference behind every call.

## Development

```sh
nix flake check
```

The Nix flake pins the tested `cl-weave`, `cl-boundary-kit`, and `cl-log-kit`
versions and configures the Common Lisp source registry, so `nix flake check`
is the preferred way to run the suite. See
[Development](https://nerima-lisp.github.io/cl-process-kit/development/) for
the test suite's structure, coverage/mutation testing, and the source layout.

## License

MIT. See [LICENSE](LICENSE).
