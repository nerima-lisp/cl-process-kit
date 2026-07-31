{
  description = "SBCL-only process execution toolkit for Common Lisp, built on the nerima-lisp boundary and logging kits";

  inputs = {
    # nixos-unstable, not nixpkgs-unstable: it advances only after the NixOS
    # release tests pass, so it is less likely to land a broken build.
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    # These four nerima-lisp packages are consumed as raw ASDF source trees
    # (cl-nix-forge `lispDerivation` `src`, or CL_SOURCE_REGISTRY at
    # runtime) -- this flake never touches any of their own
    # `packages`/`checks` outputs. `flake = false` fetches just the source
    # and skips evaluating each package's own flake.nix, so their
    # transitive dev-only inputs (e.g. cl-weave's treefmt-nix,
    # cl-boundary-kit/cl-log-kit's cl-json-kit) never enter this flake's
    # lock file.
    #
    # That is also why these four carry no `inputs.nixpkgs.follows`: the org
    # standard mandates it so an input cannot drag in a second nixpkgs, but a
    # `flake = false` input has no inputs of its own to redirect. Writing the
    # line here would resolve to nothing and only suggest to a reader that
    # something is being overridden. treefmt-nix and cl-nix-forge below are
    # the two real flake inputs, and they do carry it.
    #
    # Every sibling is pinned to a release tag, never a bare
    # `github:nerima-lisp/<name>`: a bare reference follows that repo's
    # default branch, so an upstream push to main would break this repo's CI
    # without warning.
    cl-weave = {
      url = "github:nerima-lisp/cl-weave/v1.1.0";
      flake = false;
    };
    cl-boundary-kit = {
      url = "github:nerima-lisp/cl-boundary-kit/v1.0.0";
      flake = false;
    };
    cl-log-kit = {
      url = "github:nerima-lisp/cl-log-kit/v1.0.0";
      flake = false;
    };
    cl-tty-kit = {
      # Plain github: (not git+https with submodules=1): cl-tty-kit no longer
      # vendors nerima-lisp/cl-prolog as a git submodule as of v1.0.0 -- it is
      # now a regular top-level nerima-lisp package that only :CL-TTY-KIT/TEST
      # depends on, never :CL-TTY-KIT itself. This flake only ever builds the
      # base :cl-tty-kit system (see the `cl-process-kit/pty` .asd system), so
      # cl-prolog is not part of this dependency graph at all.
      url = "github:nerima-lisp/cl-tty-kit/v1.0.2";
      flake = false;
    };

    treefmt-nix = {
      url = "github:numtide/treefmt-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # The org's shared Nix/ASDF-derivation library (cl-nix-forge.lib.<system>).
    # Builds every ASDF-based package/check below via its `lispDerivation`/
    # `mkScriptCheck` primitives instead of nixpkgs' own `sbcl.buildASDFSystem`
    # plus hand-rolled `pkgs.runCommand` test derivations. The custom checks
    # with no ASDF involvement at all (`noForbiddenMarkers`, `maxFileLength`,
    # `formatting`, `docs`) stay exactly as they were -- cl-nix-forge has
    # nothing to offer a plain grep/wc/treefmt/mkdocs derivation.
    cl-nix-forge = {
      url = "github:nerima-lisp/cl-nix-forge/v0.4.0";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    inputs@{
      self,
      nixpkgs,
      cl-weave,
      cl-boundary-kit,
      cl-log-kit,
      cl-tty-kit,
      treefmt-nix,
      cl-nix-forge,
      ...
    }:
    let
      # x86_64-linux only, per the 2026-08-01 revision of PACKAGE_STANDARD.md.
      # aarch64-darwin was dropped because the only thing verifying it was a
      # local `nix flake check` nobody is required to run; CI builds Linux and
      # nothing else. Consequence: `nix develop` and `nix build` no longer
      # resolve on macOS. Development happens on Linux.
      systems = [ "x86_64-linux" ];
      forAllSystems = nixpkgs.lib.genAttrs systems;

      # cl-nix-forge's dedicated .asd :version lexer, replacing this flake's
      # own hand-rolled line-by-line regex. `cl-nix-forge.lib` is per-system,
      # but `fromAsdSystem` itself is not -- it only reads a text file -- so
      # any one system's instance works, the same `builtins.head systems`
      # pattern cl-json-kit's and cl-weave's own flake.nix use for the same
      # reason. Strictly stronger than the regex it replaces: cl-process-kit.asd
      # declares FOUR systems (cl-process-kit, /test, /pty, /pty-test) sharing
      # one version, and fromAsdSystem fails the build loudly if any of them
      # ever disagreed, rather than silently reading whichever :version line
      # happened to come first in the file.
      cl = cl-nix-forge.lib.${builtins.head systems};

      # Single source of truth for the package version: the `:version` form in
      # cl-process-kit.asd. A release only ever edits the .asd file and every
      # Nix package (default, pty, docs) follows automatically.
      version = cl.fromAsdSystem ./cl-process-kit.asd;

      # Sibling versions are read out of each pinned source's own .asd for the
      # same reason. Hardcoding them here duplicates a fact that lives
      # upstream, and the copies go stale silently: this flake claimed
      # cl-log-kit 1.6.0 for a tag that never existed, and kept claiming it
      # after the input was corrected to v1.0.0, because nothing links the
      # string to the source it labels.
      clBoundaryKitVersion = cl.fromAsdSystem "${cl-boundary-kit}/cl-boundary-kit.asd";
      clLogKitVersion = cl.fromAsdSystem "${cl-log-kit}/cl-log-kit.asd";
      clTtyKitVersion = cl.fromAsdSystem "${cl-tty-kit}/cl-tty-kit.asd";
      clWeaveVersion = cl.fromAsdSystem "${cl-weave}/cl-weave.asd";

      # `native/` (C sources for the spawn trampoline and the PTY backend)
      # and `t/native-spawn-test.sh` (a non-Lisp check driven directly, not
      # through run-tests.lisp) are the only things this build reads beyond
      # `mkLispSource`'s `.asd`/`.lisp` allowlist default.
      lispSrc =
        pkgs:
        cl-nix-forge.lib.${pkgs.system}.mkLispSource {
          root = ./.;
          include = [
            ./native
            ./t/native-spawn-test.sh
          ];
        };

      # treefmt drives `nix fmt` and the `checks.<system>.formatting` gate.
      # Scope is Nix only: nixfmt is a low-diff, zero-footgun formatter,
      # whereas a YAML formatter mangles the GitHub Actions `on:` key and
      # Markdown reformatting would churn the whole docs tree.
      treefmtEval = forAllSystems (
        system:
        treefmt-nix.lib.evalModule nixpkgs.legacyPackages.${system} {
          projectRootFile = "flake.nix";
          programs.nixfmt.enable = true;
        }
      );

      mkDocs =
        pkgs:
        pkgs.stdenvNoCC.mkDerivation {
          pname = "cl-process-kit-docs";
          inherit version;
          src = pkgs.lib.fileset.toSource {
            root = ./.;
            fileset = pkgs.lib.fileset.unions [
              ./docs/mkdocs.yml
              ./docs/src
            ];
          };
          nativeBuildInputs = [ pkgs.python3Packages.mkdocs-material ];
          # Build fully offline: Material for MkDocs bundles all of its assets,
          # so no network access is required inside the Nix sandbox. --strict
          # promotes broken links and unlisted pages to build failures.
          buildPhase = ''
            runHook preBuild
            mkdocs build --strict --config-file docs/mkdocs.yml --site-dir "$out"
            runHook postBuild
          '';
          dontInstall = true;
          meta = {
            description = "Rendered MkDocs (Material) documentation for cl-process-kit";
            homepage = "https://github.com/nerima-lisp/cl-process-kit";
            license = pkgs.lib.licenses.mit;
          };
        };

      # Shared C compiler flags for both native artifacts, named once so the
      # checkout-tests check (which compiles spawn.c a second time, into a
      # throwaway build-sandbox path rather than $out, to get
      # CL_PROCESS_KIT_SPAWN pointed at a binary before run-tests.lisp starts)
      # cannot drift from what packages.cl-process-kit itself ships.
      spawnCflags = "-std=c11 -O2 -Wall -Wextra -Werror";

      # Every ASDF-based derivation for one `system`: the two nerima-lisp
      # runtime dependencies, the cl-weave check-time dependency, the two
      # native artifacts, and cl-process-kit's own two ASDF systems built on
      # top of them. Centralized so `packages` and `checks` build the exact
      # same derivations rather than two independently-evaluated copies that
      # could disagree.
      lispPackagesFor =
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          clForSystem = cl-nix-forge.lib.${system};
          src = lispSrc pkgs;

          # Raw flake-input source, not `mkLispSource`-filtered: these four
          # are external inputs this flake never builds `sbcl --script
          # run-tests.lisp` against locally, so there is no stray
          # `.fasl`/`coverage-report-*/` artifact to filter out the way
          # `lispSrc` above filters THIS repo's own working tree. `mkLispSource`
          # also only accepts a genuine Nix path for `root`, not a flake
          # input's own `outPath` attrset (only `self` is special-cased to
          # work directly) -- passing the input straight through as `src`,
          # the same way `pkgs.sbcl.buildASDFSystem` accepted it before this
          # migration, sidesteps that entirely.
          clBoundaryKit = clForSystem.lispDerivation {
            lispSystem = "cl-boundary-kit";
            version = clBoundaryKitVersion;
            src = cl-boundary-kit;
            lispDependencies = [ clLogKit ];
          };
          clLogKit = clForSystem.lispDerivation {
            lispSystem = "cl-log-kit";
            version = clLogKitVersion;
            src = cl-log-kit;
          };
          clTtyKit = clForSystem.lispDerivation {
            lispSystem = "cl-tty-kit";
            version = clTtyKitVersion;
            src = cl-tty-kit;
          };
          # Check-only: never enters packages.cl-process-kit's own
          # lispDependencies, only lispCheckDependencies below.
          clWeave = clForSystem.lispDerivation {
            lispSystem = "cl-weave";
            version = clWeaveVersion;
            src = cl-weave;
          };

          # native/pty.c as a plain stdenv.mkDerivation (no Lisp of its own),
          # marked so any lispDerivation naming it in `nativeLibraries` gets
          # LD_LIBRARY_PATH/DYLD_LIBRARY_PATH wired in automatically -- what
          # this flake used to hand-copy into three separate places
          # (packages.cl-process-kit-pty, checks.pty-tests, and nowhere for
          # `nix develop`, which could never load the PTY backend at all).
          ptyNativeLibrary = clForSystem.markNativeLibrary (
            pkgs.stdenv.mkDerivation {
              pname = "cl-process-kit-pty-native";
              inherit version;
              src = pkgs.lib.fileset.toSource {
                root = ./.;
                fileset = ./native;
              };
              nativeBuildInputs = [ pkgs.stdenv.cc ];
              buildPhase = ''
                runHook preBuild
                cc -O2 -fPIC -shared native/pty.c \
                  -o libcl_process_kit_pty${pkgs.stdenv.hostPlatform.extensions.sharedLibrary} \
                  ${pkgs.lib.optionalString pkgs.stdenv.isLinux "-lutil"}
                runHook postBuild
              '';
              installPhase = ''
                runHook preInstall
                mkdir -p "$out/lib"
                cp libcl_process_kit_pty${pkgs.stdenv.hostPlatform.extensions.sharedLibrary} "$out/lib/"
                runHook postInstall
              '';
            }
          );

          # The checked-out spawn binary lives at packages.cl-process-kit's
          # own $out/bin (below); this is the SAME compile, but into the
          # writable build sandbox rather than $out, so a check's `preCheck`
          # can point CL_PROCESS_KIT_SPAWN at it before run-tests.lisp/
          # t/native-spawn-test.sh ever run -- checking the packaged binary
          # itself would need it already built, which is exactly what the
          # check is trying to verify.
          compileSpawnToBuildTree = ''
            cc ${spawnCflags} native/spawn.c -o "$NIX_BUILD_TOP/cl-process-kit-spawn"
            export CL_PROCESS_KIT_SPAWN="$NIX_BUILD_TOP/cl-process-kit-spawn"
          '';

          clProcessKit = clForSystem.lispDerivation {
            lispSystem = "cl-process-kit";
            inherit version src;
            lispDependencies = [
              clBoundaryKit
              clLogKit
            ];
            lispCheckDependencies = [ clWeave ];
            # perl/coreutils are check-only (t/native-spawn-test.sh's own
            # shebang and its use of `perl -e` for a raw-mode/fd assertion),
            # but `nativeBuildInputs` is not itself doCheck-scoped, so they
            # ride along on the plain package build too rather than needing
            # a second, check-specific derivation to carry them.
            nativeBuildInputs = [
              pkgs.stdenv.cc
              pkgs.perl
              pkgs.coreutils
            ];
            # Ships the real trampoline binary in the distributed package;
            # the check derivation below additionally compiles its own copy
            # into the build sandbox (see compileSpawnToBuildTree) because a
            # check needs the binary to exist BEFORE its own build/install
            # phases -- which is what building it produces -- have run.
            postInstall = ''
              mkdir -p "$out/bin"
              cc ${spawnCflags} native/spawn.c -o "$out/bin/cl-process-kit-spawn"
            '';
            preCheck = ''
              ${compileSpawnToBuildTree}
              timeout 30 sh t/native-spawn-test.sh "$CL_PROCESS_KIT_SPAWN"
            '';
            # Coverage is a ratchet, not a one-off report: run-tests.lisp
            # fails the build itself if src/ coverage regresses below the
            # +minimum-*-coverage+ floors it tracks, so CI is the enforcement
            # point, not just a local opt-in convenience.
            # CL_PROCESS_KIT_COVERAGE_DAT redirects coverage.dat into this
            # derivation's own writable build sandbox rather than the
            # read-only Nix store path run-tests.lisp lives under -- this
            # env is doCheck-scoped, so it never touches the plain build.
            env = {
              CL_PROCESS_KIT_COVERAGE = "1";
              CL_PROCESS_KIT_COVERAGE_DAT = "coverage.dat";
            };
          };

          clProcessKitPty = clForSystem.lispDerivation {
            lispSystem = "cl-process-kit/pty";
            pname = "cl-process-kit-pty";
            inherit version src;
            lispDependencies = [
              clProcessKit
              clTtyKit
            ];
            lispCheckDependencies = [ clWeave ];
            # `nativeLibraries` alone is not enough here: src/pty.lisp reads
            # CL_PROCESS_KIT_PTY_LIBRARY explicitly (an SB-ALIEN
            # LOAD-SHARED-OBJECT call needs a real path, not a bare SONAME
            # resolved off LD_LIBRARY_PATH/DYLD_LIBRARY_PATH), and does so at
            # LOAD time -- defining the alien routine bindings needs the
            # library present during the build's own compile phase, not just
            # at eventual runtime. Kept `nativeLibraries` too since it is
            # harmless and is what any FUTURE consumer three hops away would
            # need if it only `dlopen`s the bare name.
            nativeLibraries = [ ptyNativeLibrary ];
            env = {
              CL_PROCESS_KIT_PTY_LIBRARY = "${ptyNativeLibrary}/lib/libcl_process_kit_pty${pkgs.stdenv.hostPlatform.extensions.sharedLibrary}";
            };
          };
        in
        {
          inherit
            clProcessKit
            clProcessKitPty
            ;
        };
    in
    {
      packages = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          lisp = lispPackagesFor system;
        in
        {
          cl-process-kit = lisp.clProcessKit;
          cl-process-kit-pty = lisp.clProcessKitPty;
          docs = mkDocs pkgs;
          default = lisp.clProcessKit;
        }
      );

      # `nix fmt` entry point.
      formatter = forAllSystems (system: treefmtEval.${system}.config.build.wrapper);

      # Granularity lives here, NOT in extra GitHub Actions jobs: `nix flake
      # check` evaluates each attribute as its own derivation, in parallel,
      # with build caching. Add a check here rather than a job in ci.yml.
      checks = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          clForSystem = cl-nix-forge.lib.${system};
          lisp = lispPackagesFor system;
        in
        rec {
          # run-tests.lisp, not asdf:test-system: it does more than load and
          # test cl-process-kit/test (coverage instrumentation toggling, the
          # +minimum-*-coverage+ ratchet, CL_SOURCE_REGISTRY bootstrap for a
          # bare `sbcl --script` invocation) that only this entry point
          # performs, matching the org's own PACKAGE_STANDARD.md convention
          # of a single canonical `run-tests.lisp` per repository.
          checkout-tests = clForSystem.mkScriptCheck {
            drv = lisp.clProcessKit;
            entryPoint = "run-tests.lisp";
            timeoutSeconds = 180;
          };

          pty-tests = clForSystem.mkScriptCheck {
            drv = lisp.clProcessKitPty;
            entryPoint = "run-pty-tests.lisp";
            timeoutSeconds = 60;
          };

          # Dead code, TODO/FIXME markers, adapter layers around a
          # nerima-lisp dependency, and backward-compatibility shims have all
          # been repeatedly verified absent by hand across many refactoring
          # passes -- this turns that one-off verification into a standing
          # invariant CI enforces on every push, the same way the coverage
          # ratchet in run-tests.lisp turns a coverage target into a gate
          # instead of a number checked once and left to drift.
          #
          # The scan covers src, t, docs and README.md only. It used to also
          # note that CHANGELOG.md was deliberately excluded, being a
          # historical record that legitimately describes fixing or preventing
          # exactly these things; that file no longer exists, and the release
          # history it held now lives in the GitHub Release description, which
          # is not in the tree and so is out of this check's reach either way.
          noForbiddenMarkers =
            pkgs.runCommand "cl-process-kit-no-forbidden-markers" { nativeBuildInputs = [ pkgs.gnugrep ]; }
              ''
                cd ${self}
                if grep -rniE 'TODO|FIXME|XXX|adapter|backward.?compat' \
                    --include='*.lisp' --include='*.asd' --include='*.md' \
                    src t docs README.md; then
                  echo "Forbidden marker found above -- this project keeps zero" >&2
                  echo "TODO/FIXME/XXX/adapter/backward-compat markers." >&2
                  exit 1
                fi
                touch "$out"
              '';

          # No src/ or t/ file has ever needed to exceed this: the largest
          # today is communicate.lisp at 295 lines. 500 is cl-weave's own
          # stated org guideline ("no source file exceeds 500 lines"),
          # adopted verbatim rather than
          # inventing a different number -- a file crossing it is exactly
          # the moment `paredit refactor split-file`/`move-form` should
          # split it, the way async-task.lisp and run-test.lisp already
          # were in earlier passes.
          maxFileLength = pkgs.runCommand "cl-process-kit-max-file-length" { } ''
            cd ${self}
            over=0
            for f in $(find src t -name '*.lisp'); do
              lines=$(wc -l < "$f")
              if [ "$lines" -gt 500 ]; then
                echo "$f has $lines lines, over the 500-line guideline." >&2
                over=1
              fi
            done
            if [ "$over" -ne 0 ]; then
              exit 1
            fi
            touch "$out"
          '';

          # 100 columns is the org's CODING_STANDARD.md line-length rule, and
          # src/ has held to it since an earlier pass wrapped every line
          # there -- but that pass's own commit message says "src", and t/
          # was never actually swept: 100 lines across 12 files exceeded it
          # until this pass fixed them by hand. Gated now so that gap cannot
          # reopen silently the way it did the first time.
          maxLineLength = pkgs.runCommand "cl-process-kit-max-line-length" { } ''
            cd ${self}
            over=0
            for f in $(find src t -name '*.lisp'); do
              long=$(awk 'length > 100 { print FNR": "length }' "$f")
              if [ -n "$long" ]; then
                echo "$f has lines over 100 columns:" >&2
                echo "$long" >&2
                over=1
              fi
            done
            if [ "$over" -ne 0 ]; then
              exit 1
            fi
            touch "$out"
          '';

          # Fails `nix flake check` when any tracked Nix file is unformatted,
          # turning the formatter into an enforced CI gate rather than a habit.
          formatting = treefmtEval.${system}.config.build.check self;

          # packages.docs runs `mkdocs build --strict`, so a broken link or a
          # page missing from the nav fails here. Without this check the site
          # is only ever built by docs.yml, which runs after a merge to main --
          # so a break would surface as a failed deploy rather than a failed
          # pull request.
          docs = self.packages.${system}.docs;

          default = checkout-tests;
        }
      );

      # apps/devShells stay on the original hand-rolled CL_SOURCE_REGISTRY
      # string, NOT a cl-nix-forge primitive: `lispScript`/`lispWithSystems`
      # are a real fit in principle, but this migration's own research did
      # not confirm their exact parameter shape (`lispScript`'s
      # `dependencies` argument in particular) against real usage the way
      # `lispDerivation`/`mkScriptCheck` were confirmed against cl-json-kit's
      # and cl-weave's own working flake.nix files above -- guessing an
      # unverified API here risks a broken `nix run`/`nix develop` for a
      # part of this migration that carries no correctness benefit over the
      # proven string this flake already had. Revisit once a sibling repo's
      # own flake.nix demonstrates the pattern.
      apps = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          sourceRegistry = "${cl-boundary-kit}//:${cl-log-kit}//:${cl-tty-kit}//:${cl-weave}//:${self}//";
          test = pkgs.writeShellApplication {
            name = "cl-process-kit-test";
            runtimeInputs = [
              pkgs.sbcl
              pkgs.stdenv.cc
              pkgs.perl
              pkgs.coreutils
            ];
            text = ''
              export CL_SOURCE_REGISTRY="${sourceRegistry}"
              native_tmpdir="''${TMPDIR:-/tmp}"
              cc ${spawnCflags} \
                ${self}/native/spawn.c -o "$native_tmpdir/cl-process-kit-spawn"
              export CL_PROCESS_KIT_SPAWN="$native_tmpdir/cl-process-kit-spawn"
              timeout 30 sh ${self}/t/native-spawn-test.sh "$CL_PROCESS_KIT_SPAWN"
              exec timeout 180 sbcl --script ${self}/run-tests.lisp
            '';
          };
        in
        {
          default = {
            type = "app";
            program = "${test}/bin/cl-process-kit-test";
          };
          test = {
            type = "app";
            program = "${test}/bin/cl-process-kit-test";
          };
        }
      );

      devShells = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          sourceRegistry = "${cl-boundary-kit}//:${cl-log-kit}//:${cl-tty-kit}//:${cl-weave}//:${self}//";
        in
        {
          default = pkgs.mkShell {
            packages = [
              pkgs.sbcl
              pkgs.stdenv.cc
            ];
            CL_SOURCE_REGISTRY = sourceRegistry;
          };
        }
      );
    };
}
