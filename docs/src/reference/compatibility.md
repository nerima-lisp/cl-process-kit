# Compatibility

## Implementation

`cl-process-kit` targets SBCL only. It is not portable Common Lisp and does
not aim to be: `sb-ext`, `sb-posix`, `sb-thread`, and `sb-alien` are used
throughout, and the native spawn and PTY backends under `native/` are
POSIX-specific C. Other Common Lisp implementations are out of scope.

## Platforms

| Platform | Status |
| --- | --- |
| `x86_64-linux` | Verified on every push and pull request by CI |
| `aarch64-darwin` | Declared by the flake and exercised locally; not covered by CI |

Both platforms are declared in `flake.nix`'s `systems`, but the `check` job in
`.github/workflows/ci.yml` runs on `ubuntu-latest` and does not pass
`--all-systems`, so only `x86_64-linux` is verified automatically. A change
that only builds on macOS can therefore still break Linux, and the reverse is
caught only when someone runs the suite on a Mac.

Running on both is worth the effort, because process semantics diverge exactly
where this library works: signal delivery, process-group reaping, and whether
closing a descriptor interrupts a thread already blocked reading it (macOS and
the BSDs do; Linux does not). Two defects shipped in 0.2.0 were invisible on
macOS and obvious on Linux — see 1.0.0's `### Correctness` notes in the
[changelog](../changelog.md).

Seven process-group tests are `it-skip`ped under `#+linux`; see
[Development](../development.md#running-the-suite-on-both-platforms) for why,
and for how to run the Linux suite locally in a container.

## Stability

From 1.0.0 onward the exported API follows semantic versioning. The exported
surface is unchanged from 0.2.0; what 1.0.0 added was evidence about behaviour
on the platforms above rather than new API.

Symbols that are not exported from the `process-kit` package are internal and
may change in any release, including the `%`-prefixed helpers that appear in
backtraces.

The optional `cl-process-kit/pty` system depends on `cl-tty-kit` and on a
native shared library that is not built by default. It is versioned with the
core system but its API is younger and correspondingly less settled.
