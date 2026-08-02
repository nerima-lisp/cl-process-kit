# cl-process-kit

[![CI](https://github.com/nerima-lisp/cl-process-kit/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/nerima-lisp/cl-process-kit/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Documentation](https://img.shields.io/badge/docs-MkDocs%20Material-3f51b5)](https://nerima-lisp.github.io/cl-process-kit/)

`cl-process-kit` is an SBCL-only process execution toolkit for Common Lisp. It
gives Common Lisp the same small, timeout-aware surface for launching external
commands that Python's `subprocess.run()` and Node.js's `child_process.spawn()`
give their own ecosystems: a synchronous `run` that captures output and enforces
a deadline with SIGTERM→SIGKILL escalation, a low-level asynchronous `spawn` for
callers who drive the process themselves, cooperative cancellation, and
multi-stage pipelines. Every child runs in its own process group, so a timeout
reaches everything the child forked rather than just the child. It is built on
the nerima-lisp [`cl-boundary-kit`](https://github.com/nerima-lisp/cl-boundary-kit)
(clock/sleeper boundaries) and [`cl-log-kit`](https://github.com/nerima-lisp/cl-log-kit)
(structured logging), and depends on nothing outside the org.

Full documentation is published at <https://nerima-lisp.github.io/cl-process-kit/>.
The source for that site lives in [docs/src/](docs/src/).

## Quick Start

```lisp
(asdf:load-system "cl-process-kit")

;; Capture a command's output.
(process-kit:run "printf" (list "%s\n" "hello, world"))
;; => a PROCESS-RESULT whose stdout is "hello, world\n"

;; A command that runs too long is escalated SIGTERM -> SIGKILL, then signals.
(handler-case
    (process-kit:run "sleep" (list "10") :timeout 1)
  (process-kit:process-timeout-error (e)
    (format t "timed out after ~a seconds~%"
            (process-kit:process-timeout-error-timeout e))))
;; => timed out after 1 seconds
```

## Install

```nix
# flake.nix
inputs.cl-process-kit = {
  url = "github:nerima-lisp/cl-process-kit/v2.0.0";
  inputs.nixpkgs.follows = "nixpkgs";
};
```

Note the pinned tag. Consumers inside this org pin a release tag rather than
follow the default branch.

For a local checkout, point `CL_SOURCE_REGISTRY` at it and
`(asdf:load-system "cl-process-kit")`. The optional native PTY backend needs an
extra build step; see
[Installation](https://nerima-lisp.github.io/cl-process-kit/installation/).

## Documentation

- [Quick Start](https://nerima-lisp.github.io/cl-process-kit/quick-start/) —
  cancellation, streaming output with `spawn`, and pipelines
- [Command Specifications](https://nerima-lisp.github.io/cl-process-kit/guide/command-specs/) —
  the full option reference behind every call
- [File-Descriptor Readiness](https://nerima-lisp.github.io/cl-process-kit/guide/fd-readiness/) —
  `select-fds` / `wait-for-input` for event loops over raw descriptors
- [Results and Conditions](https://nerima-lisp.github.io/cl-process-kit/reference/results-and-conditions/) —
  the `process-error` hierarchy and result accessors
- [Compatibility](https://nerima-lisp.github.io/cl-process-kit/reference/compatibility/) —
  supported implementation, platforms, and stability promises

## Development

```sh
nix develop          # SBCL and a C compiler with CL_SOURCE_REGISTRY set
nix run .#test       # run the test suite
nix flake check      # tests + PTY suite + formatting + docs, the gate CI uses
nix fmt              # format Nix sources (treefmt)
```

Tests live in `t/` and run under
[cl-weave](https://github.com/nerima-lisp/cl-weave), the org's test framework.
`src/` coverage is a ratchet that only moves up. See
[Development](https://nerima-lisp.github.io/cl-process-kit/development/) for the
suite's structure, coverage and mutation testing, and the source layout.

## Contributing

See the org-wide [CONTRIBUTING](https://github.com/nerima-lisp/.github/blob/main/CONTRIBUTING.md)
guide and the [package standard](https://github.com/nerima-lisp/.github/blob/main/PACKAGE_STANDARD.md).

## Support

See [SUPPORT](https://github.com/nerima-lisp/.github/blob/main/SUPPORT.md).
Report vulnerabilities privately through
[GitHub Security Advisories](https://github.com/nerima-lisp/cl-process-kit/security/advisories/new),
not as public issues.

## License

MIT. See [LICENSE](LICENSE).
