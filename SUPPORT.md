# Support

- Report reproducible defects, documentation gaps, and concrete feature
  requests through
  [GitHub Issues](https://github.com/nerima-lisp/cl-process-kit/issues/new).
- Send fixes that can be described and validated locally as pull requests;
  see [CONTRIBUTING.md](CONTRIBUTING.md).
- Report security vulnerabilities privately through
  [GitHub Security Advisories](https://github.com/nerima-lisp/cl-process-kit/security/advisories/new)
  -- see [SECURITY.md](SECURITY.md).

Do not include vulnerability details in public issues or discussions.

## Scope

`cl-process-kit` targets SBCL on Linux and macOS; both are exercised in CI
(`.github/workflows/ci.yml`) via `nix flake check`. Other Common Lisp
implementations and platforms are out of scope: the library depends on
`sb-ext`, `sb-posix`, `sb-thread`, and `sb-alien` throughout, and the native
spawn/PTY backends (`native/`) are POSIX-specific C.
