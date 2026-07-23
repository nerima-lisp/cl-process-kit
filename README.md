# cl-process-kit

[![CI](https://github.com/nerima-lisp/cl-process-kit/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/nerima-lisp/cl-process-kit/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

`cl-process-kit` is a dependency-free, SBCL-only process execution toolkit
for Common Lisp. It provides a small, timeout-aware surface for launching
external commands, modeled on the design of Python's `subprocess.run()` and
Node.js's `child_process.spawn()`: a high-level synchronous `run` that
captures output and enforces a deadline, and a low-level asynchronous
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
  captures stdout/stderr as strings, and raises (or reports) a timeout after
  escalating from SIGTERM to SIGKILL.
- **`spawn`** mirrors Node's `child_process.spawn()`: fire-and-forget,
  returns a handle immediately, and leaves streaming/job-control to the
  caller.
- Both put the child process in its own process group, so a timeout kills
  not just the immediate child but anything it has forked (a shell running
  a pipeline, for example) -- no orphaned processes left behind after a
  deadline.
- `run`'s polling loop takes `clock` and `sleep-fn` as explicit arguments,
  so tests can replace real time with a deterministic fake and exercise the
  timeout/escalation branches without waiting on the wall clock.

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
(process-kit:run "echo" (list "hello, world"))
;; => #S(PROCESS-KIT:PROCESS-RESULT :EXIT-CODE 0
;;                                  :STDOUT "hello, world
"
;;                                  :STDERR ""
;;                                  :TIMED-OUT-P NIL
;;                                  :SIGNAL NIL)

;; A command that runs too long is escalated SIGTERM -> SIGKILL and, by
;; default, signals a condition:
(handler-case
    (process-kit:run "sleep" (list "10") :timeout-seconds 1)
  (process-kit:process-timeout-error (e)
    (format t "timed out after ~a seconds~%"
            (process-kit:process-timeout-error-timeout-seconds e))))

;; Or ask for a result instead of a condition:
(let ((result (process-kit:run "sleep" (list "10")
                                :timeout-seconds 1
                                :on-timeout :return)))
  (process-kit:process-result-timed-out-p result)) ;; => T

;; Low-level async primitive when you want to stream output yourself:
(let ((process (process-kit:spawn "tail" (list "-f" "/var/log/system.log")
                                   :output :stream)))
  (unwind-protect
      (loop while (process-kit:process-alive-p process)
            do (print (read-line (sb-ext:process-output process))))
    (process-kit:process-terminate process)))
```

## API

- `run (command args &key input search timeout-seconds on-timeout grace-period-seconds kill-signal clock sleep-fn)`
  -> `process-result`
- `spawn (command args &key input output error search)` -> `sb-ext:process`
- `process-alive-p (process)`, `process-wait (process)`,
  `process-terminate (process)` (SIGTERM), `process-kill (process)` (SIGKILL)
- `process-result` struct: `exit-code`, `stdout`, `stderr`, `timed-out-p`,
  `signal`
- `process-timeout-error` condition: `command`, `args`, `timeout-seconds`

## Development

```sh
nix develop
sbcl --script run-tests.lisp
```

## License

MIT. See [LICENSE](LICENSE).
