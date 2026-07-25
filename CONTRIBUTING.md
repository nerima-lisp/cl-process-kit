# Contributing

## Before you start

- Search [existing issues](https://github.com/nerima-lisp/cl-process-kit/issues)
  and [CHANGELOG.md](CHANGELOG.md)'s "Known Limitations" section first.
- For anything beyond a small fix, open an issue describing the change before
  writing code, so the approach can be discussed before the implementation is.

## Local setup

```sh
git clone https://github.com/nerima-lisp/cl-process-kit.git
cd cl-process-kit
nix develop        # SBCL + a C compiler, CL_SOURCE_REGISTRY preconfigured
nix flake check     # build the native trampoline, run the full test suite
```

`nix flake check` is the authoritative check -- it runs in the same
sandboxed environment CI uses. A change that only passes a local,
non-sandboxed `sbcl --script run-tests.lisp` is not fully verified; see
`CL_SOURCE_REGISTRY`/`CL_PROCESS_KIT_SPAWN` in [README.md](README.md) if you
need to run outside Nix.

## Making a change

- Keep behavior changes and pure refactors in separate commits.
- Add or update tests for any behavior change; `t/mutation-test.lisp` and
  `t/property-test.lisp` are good examples of testing a contract, not just
  an example.
- `src/` coverage is a ratchet (`run-tests.lisp`'s
  `+minimum-expression-coverage+`/`+minimum-branch-coverage+`): a
  `CL_PROCESS_KIT_COVERAGE=1` run that regresses below the current floor
  fails the build. It can only go up over time.
- Update [CHANGELOG.md](CHANGELOG.md)'s `[Unreleased]` section for any
  user-visible change.
- Prefer structural refactoring tools (e.g.
  [`paredit-cli`](https://github.com/nerima-lisp/paredit-cli)) over
  hand-editing balanced-parenthesis code when reshaping existing forms.

## Submitting

Open a pull request against `main`. CI runs `nix flake check`
(`.github/workflows/ci.yml`); it must pass before merge.
