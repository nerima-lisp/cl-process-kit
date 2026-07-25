# Security Considerations

This page describes the security-relevant surface of the library. For the org's
vulnerability reporting process, see
[SECURITY](https://github.com/nerima-lisp/.github/blob/main/SECURITY.md).

## What this library exposes

`cl-process-kit` launches external processes and builds their argument lists,
environment, and working directory from caller-supplied data. That makes the
following classes of defect security-relevant rather than merely incorrect.

**Argument and shell injection.** Arguments given to
[`make-command`](../guide/command-specs.md) and
[`run-command`](../guide/execution.md) are passed directly to `exec`, never
through a shell, so untrusted data in an argument stays an argument. A case
where untrusted data nevertheless reaches a shell unintentionally is a
vulnerability.

**Process-group isolation.** Every child is placed in its own process group so
that a timeout or cancellation reaches everything it forked. A failure that
leaves descendants running after a deadline, or that delivers a signal to the
wrong process group, defeats that guarantee — see
[Cancellation](../guide/cancellation.md).

**Credential handling in the native trampoline.** `spawn-native`'s `uid`,
`gid`, `groups`, and `resource-limits` support is implemented in
`native/spawn.c`. Defects in dropping privileges or applying limits there are
in scope — see [Native Spawn Trampoline](../guide/native-spawn.md).

**Descriptor leaks.** File-descriptor and resource-limit handling that could
leak a sensitive descriptor from the parent into a spawned child is in scope.

## What is not a defect

`run-shell` is documented as `/bin/sh -c`, the equivalent of C's `system()`.
Passing an attacker-controlled string to it does what it says on the tin. The
correctness of arbitrary shell commands handed to `run-shell` by design is not
a vulnerability in this library; use `run` or `run-command` with an explicit
argument list when any part of the command comes from untrusted input.

```lisp
;; Untrusted input as an argument: safe, never reaches a shell.
(process-kit:run "grep" (list "--" user-supplied-pattern "/etc/hosts"))

;; Untrusted input spliced into a shell command: not safe, and not a
;; library defect.
(process-kit:run-shell (format nil "grep ~a /etc/hosts" user-supplied-pattern))
```
