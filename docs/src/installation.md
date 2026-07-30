# Installation

`cl-process-kit` targets SBCL only (it relies on `sb-ext:run-program` and
SBCL-specific FFI for process-group/PTY handling). Two install paths are
supported: the Nix flake, and a plain ASDF/local checkout.

## Nix flake

=== "Ad hoc check/build"

    ```sh
    nix flake check github:nerima-lisp/cl-process-kit   # run the test suite
    nix build github:nerima-lisp/cl-process-kit          # build the ASDF system
    ```

=== "As a flake input"

    ```nix
    {
      inputs.cl-process-kit = {
        url = "github:nerima-lisp/cl-process-kit/v2.0.0";
        inputs.nixpkgs.follows = "nixpkgs";
      };
    }
    ```

    Pin a release tag rather than following the default branch, the same way
    this project pins its own `cl-boundary-kit`/`cl-log-kit`/`cl-tty-kit`/
    `cl-weave` inputs in `flake.nix` -- an unpinned `github:` reference tracks
    whatever is on `main`, which can change under a consumer without warning.

    Pull the packaged system or devShell from
    `cl-process-kit.packages.<system>.cl-process-kit` /
    `cl-process-kit.devShells.<system>.default`. The optional native PTY
    backend is available as `cl-process-kit.packages.<system>.cl-process-kit-pty`.

The flake pins its own `cl-boundary-kit`, `cl-log-kit`, `cl-tty-kit`, and
`cl-weave` (test-only) dependency versions, so `nix flake check` /
`nix build` are the most reproducible way to consume the library.

## ASDF / local checkout

```sh
git clone https://github.com/nerima-lisp/cl-process-kit.git
```

Point `CL_SOURCE_REGISTRY` (or a file under
`~/.config/common-lisp/source-registry.conf.d/`) at the checkout — and at
your own [`cl-boundary-kit`](https://github.com/nerima-lisp/cl-boundary-kit)
and [`cl-log-kit`](https://github.com/nerima-lisp/cl-log-kit) checkouts, its
two required dependencies — then load it:

```lisp
(asdf:load-system "cl-process-kit")
```

!!! note "The optional PTY system"

    `cl-process-kit/pty` (package `process-kit/pty`) additionally depends on
    [`cl-tty-kit`](https://github.com/nerima-lisp/cl-tty-kit) and a compiled
    native trampoline; see [PTY Backend](guide/pty.md) for the build step and
    the `CL_PROCESS_KIT_PTY_LIBRARY` environment variable it requires.

## Verifying the install

```lisp
(process-kit:run "/bin/echo" (list "cl-process-kit is installed"))
;; => a PROCESS-RESULT whose stdout is "cl-process-kit is installed\n"
```

Continue with [Quick Start](quick-start.md) for a tour of the synchronous,
asynchronous, cancellation, and pipeline APIs.
