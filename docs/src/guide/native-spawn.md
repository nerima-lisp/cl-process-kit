# Native Spawn Trampoline

`spawn`/`run` launch through `sb-ext:run-program`, which is enough for the
process-group isolation the rest of the library relies on but doesn't
expose lower-level POSIX setup: dropping privileges, joining a new session,
remapping arbitrary file descriptors, or setting resource limits before
`exec`. `spawn-native` covers that gap through a small `posix_spawn`-based
C trampoline (`native/spawn.c`, packaged as the `cl-process-kit-spawn`
binary) that performs the requested setup and then `exec`s the real
program — with typed, synchronous failure reporting for every setup phase
that can fail.

```lisp
(process-kit:spawn-native "/bin/sh" (list "-c" "printf native") :output :stream)
  => process-handle
```

The returned `process-handle` is the same type `spawn` returns, and
supports [the same operations](async.md#process-handle-operations) —
`spawn-native` is a drop-in alternative launch path, not a separate
process-handle type. Because the trampoline `exec`s the target program in
place, the handle's PID is the final target process's PID; there is no
lingering wrapper process.

## Locating the trampoline binary

`*native-spawn-program*` defaults to the `CL_PROCESS_KIT_SPAWN` environment
variable, or `"cl-process-kit-spawn"` resolved via `PATH` if that variable
is unset. The Nix package builds and installs this binary automatically
(`$out/bin/cl-process-kit-spawn`); building it by hand is a plain C11
compile:

```sh
cc -std=c11 -O2 -Wall -Wextra -Werror native/spawn.c -o cl-process-kit-spawn
export CL_PROCESS_KIT_SPAWN=$PWD/cl-process-kit-spawn
```

## Setup options

```lisp
spawn-native (program arguments &key search fd-mappings pass-fds session
              process-group detached uid gid groups umask resource-limits
              directory environment input output error external-format
              status-hook) -> process-handle
```

- `search` resolves `program` against `PATH` using the same rules as
  [`make-command`'s executable search](command-specs.md#executable-search).
- `fd-mappings` is a list of `(target . source)` conses: `target` is the
  file descriptor number the child sees; `source` is either an existing
  file descriptor number to duplicate onto it, or `:close`/`:null`.
- `pass-fds` is a list of file descriptor numbers to leave open (not
  close-on-exec) across the `exec`.
- `session` (boolean) starts a new session (`setsid`) before `exec`.
- `process-group` must be `nil` or `0`; joining an *existing* process
  group is unsupported by this backend — only creating the child as its
  own new group leader is.
- `detached` (boolean) fully detaches the child from the caller's
  controlling terminal.
- `uid`, `gid`, and `groups` (a list of supplementary group IDs) set the
  child's credentials before `exec`; `umask` sets its file-creation mask.
- `resource-limits` is a list of `(resource soft hard)` triples (e.g.
  `(:nofile 256 1024)`) applied via `setrlimit` before `exec`.
- `directory`, `environment`, `input`, `output`, `error`, `external-format`,
  and `status-hook` mirror [`spawn`](async.md#spawning-a-handle)'s options
  for the launched process.

## Typed launch failures

Every setup phase that can fail is reported synchronously and precisely,
instead of surfacing as an opaque non-zero exit:

```lisp
(handler-case
    (process-kit:spawn-native "/definitely/missing-program" nil)
  (process-kit:native-process-launch-error (condition)
    (list (process-kit:native-process-launch-error-phase condition)
          (process-kit:native-process-launch-error-errno condition))))
;; => (:EXEC <errno>)
```

`native-process-launch-error` is a `process-launch-error` subclass (so it
carries `program`/`arguments`/`directory`/`cause` too — see
[Results and Conditions](../reference/results-and-conditions.md)) with two
additional readers:

| Reader | Meaning |
| --- | --- |
| `native-process-launch-error-phase` | One of `:argument`, `:fd-setup`, `:chdir`, `:session`, `:process-group`, `:credentials`, `:resource-limit`, or `:exec` — which setup step failed. |
| `native-process-launch-error-errno` | The C `errno` value from that step. |

Internally, the trampoline reports failure by writing a small phase/errno
record down a pipe held open only until a successful `exec` closes it;
`spawn-native` reads that pipe synchronously before returning, so a launch
failure is always reported as a condition from the `spawn-native` call
itself rather than discovered later through `process-wait`/`communicate`.
