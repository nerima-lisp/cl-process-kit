# Changelog

All notable changes to this project will be documented in this file.

## [0.1.0] - Unreleased

### Added

- Initial implementation: `process-kit:run` (synchronous, timeout-aware,
  output-capturing) and `process-kit:spawn` (asynchronous primitive), built
  on `sb-ext:run-program`.
- `process-result` struct and `process-timeout-error` condition.
- `process-alive-p`, `process-wait`, `process-terminate`, `process-kill`.
- Process-group isolation so a timeout kill reaches descendants spawned by
  the child (e.g. a shell running an external command), not just the
  immediate child process.
- Test suite (`cl-process-kit/test`) using `cl-weave`, covering successful
  execution, exit codes, stdout/stderr capture, stdin forwarding,
  SIGTERM/SIGKILL timeout escalation, `process-timeout-error` signalling,
  and deterministic polling via injected `clock`/`sleep-fn`.
- Nix flake (`flake.nix`) with package, dev shell, and `nix flake check`
  test target; GitHub Actions CI running `nix flake check`.
