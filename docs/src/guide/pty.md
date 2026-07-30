# PTY Backend

`sb-ext:run-program :pty t` supplies a bidirectional PTY stream but does not
establish a controlling terminal, which makes it insufficient for shell job
control. The `cl-process-kit/pty` system (package `process-kit/pty`) adds a
native trampoline that creates a session, acquires the slave as controlling
terminal, sets the initial window size, and execs — giving `isatty` and
foreground-process-group signaling their usual meaning inside the child.

```lisp
(process-kit/pty:spawn-pty (process-kit:make-command "/bin/sh" nil) :rows 24 :cols 80)
  => pty-process
```

`rows`/`cols` default to the caller's own controlling terminal size (via
[`cl-tty-kit`](https://github.com/nerima-lisp/cl-tty-kit)'s
`cl-tty-kit:terminal-size`), falling back to 24x80 when standard input is
not a terminal.

## Inspecting a `pty-process`

`spawn-pty` returns an opaque `pty-process` handle. `pty-process-pid`
reads its PID. `process-pty` reads the raw master-side file descriptor
backing the bidirectional stream operations below — most callers won't
need it directly, since `pty-read-octets`/`pty-write-octets` and friends
already operate on the handle.

`pty-process-result` reads the cached `process-result` once `pty-wait`,
`pty-cancel`, or `pty-close` has populated it (each of those calls also
returns the same result directly); it is `nil` beforehand.

## I/O and control operations

- `pty-read-octets`/`pty-read-string` and `pty-write-octets`/
  `pty-write-string` transfer over the single bidirectional master stream
  (stdout and stderr are merged, and there is no independent stdin
  half-close).
- `pty-resize` updates the window size.
- `pty-send-eof` sends the terminal's canonical VEOF character rather than
  closing a stream.
- `pty-foreground-pgid` reports the session's current foreground process
  group, and `pty-signal-foreground` signals only that group after
  validating it belongs to the session — the PTY analogue of
  `process-send-group-signal`.
- `pty-wait` accepts `timeout` and `cancellation-token` and escalates to
  session-wide SIGTERM/SIGKILL the same way `communicate` does (see
  [Cancellation](cancellation.md)).
- `pty-cancel` and `pty-close` are idempotent cleanup entry points.
- `with-pty-process` binds a variable to a `spawn-pty` result for a body,
  then closes it via `pty-close` on the way out, success or error --
  the PTY analogue of [`with-process`](async.md#spawning-a-handle)'s
  continuation-passing cleanup contract, backed by the exported
  `call-with-pty-process` for callers that need the plain function.

```lisp
(process-kit/pty:with-pty-process
    (process (process-kit/pty:spawn-pty (process-kit:make-command "/bin/sh" nil)))
  (process-kit/pty:pty-write-string process (format nil "echo hi~%")))
```

!!! info "Independent of the event/task model"

    This subsystem does not go through `communicate`/`communicate-async`,
    so its event/backpressure model is unrelated to
    [`process-event`/`process-task`](async.md#event-driven-communication).

## Building the native library

Building `cl-process-kit/pty` requires compiling `native/pty.c` into a
shared library and pointing `CL_PROCESS_KIT_PTY_LIBRARY` at it:

```sh
cc -O2 -fPIC -shared native/pty.c -o libcl_process_kit_pty.so   # add -lutil on Linux
export CL_PROCESS_KIT_PTY_LIBRARY=$PWD/libcl_process_kit_pty.so
```

The Nix flake's `cl-process-kit-pty` package and `pty-tests` check do this
automatically — see [Installation](../installation.md#nix-flake) and
[Development](../development.md).
