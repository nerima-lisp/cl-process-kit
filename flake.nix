{
  description = "SBCL-only process execution toolkit for Common Lisp, built on the nerima-lisp boundary and logging kits";

  inputs = {
    # nixos-unstable, not nixpkgs-unstable: it advances only after the NixOS
    # release tests pass, so it is less likely to land a broken build.
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    # These four nerima-lisp packages are consumed purely as raw ASDF source
    # trees (buildASDFSystem `src`, or CL_SOURCE_REGISTRY at runtime) --
    # this flake never touches any of their own `packages`/`checks` outputs.
    # `flake = false` fetches just the source and skips evaluating each
    # package's own flake.nix, so their transitive dev-only inputs (e.g.
    # cl-weave's treefmt-nix, cl-boundary-kit/cl-log-kit's cl-json-kit) never
    # enter this flake's lock file.
    #
    # That is also why these four carry no `inputs.nixpkgs.follows`: the org
    # standard mandates it so an input cannot drag in a second nixpkgs, but a
    # `flake = false` input has no inputs of its own to redirect. Writing the
    # line here would resolve to nothing and only suggest to a reader that
    # something is being overridden. treefmt-nix below is the one real flake
    # input, and it does carry it.
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
      ...
    }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-darwin"
      ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
      sourceRegistry = "${cl-boundary-kit}//:${cl-log-kit}//:${cl-tty-kit}//:${cl-weave}//:${self}//";

      # Reads the first `:version` form out of an ASDF system definition.
      # Nix regexes are whole-string anchored and `.` never spans newlines, so
      # the file is split into lines and matched line-by-line rather than with
      # one multi-line match. The anchoring is also what keeps a
      # `:depends-on ((:version "asdf" "3.3.1"))` line from being mistaken for
      # the system's own version: such a line does not match end to end.
      asdVersion =
        asd:
        let
          lines = nixpkgs.lib.splitString "\n" (builtins.readFile asd);
          versionLine = builtins.head (
            builtins.filter (line: builtins.match "[[:space:]]*:version \"[^\"]*\"" line != null) lines
          );
        in
        builtins.head (builtins.match "[[:space:]]*:version \"([^\"]*)\"" versionLine);

      # Single source of truth for the package version: the `:version` form in
      # cl-process-kit.asd. A release only ever edits the .asd file and every
      # Nix package (default, pty, docs) follows automatically.
      version = asdVersion ./cl-process-kit.asd;

      # Sibling versions are read out of each pinned source's own .asd for the
      # same reason. Hardcoding them here duplicates a fact that lives
      # upstream, and the copies go stale silently: this flake claimed
      # cl-log-kit 1.6.0 for a tag that never existed, and kept claiming it
      # after the input was corrected to v1.0.0, because nothing links the
      # string to the source it labels.
      clBoundaryKitVersion = asdVersion "${cl-boundary-kit}/cl-boundary-kit.asd";
      clLogKitVersion = asdVersion "${cl-log-kit}/cl-log-kit.asd";

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
              ./CHANGELOG.md
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
    in
    {
      packages = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          clBoundaryKit = pkgs.sbcl.buildASDFSystem {
            pname = "cl-boundary-kit";
            version = clBoundaryKitVersion;
            src = cl-boundary-kit;
            systems = [ "cl-boundary-kit" ];
            lispLibs = [ clLogKit ];
          };
          clLogKit = pkgs.sbcl.buildASDFSystem {
            pname = "cl-log-kit";
            version = clLogKitVersion;
            src = cl-log-kit;
            systems = [ "cl-log-kit" ];
          };
        in
        rec {
          cl-process-kit = pkgs.sbcl.buildASDFSystem {
            pname = "cl-process-kit";
            inherit version;
            src = self;
            systems = [ "cl-process-kit" ];
            lispLibs = [
              clBoundaryKit
              clLogKit
            ];
            nativeBuildInputs = [ pkgs.stdenv.cc ];
            postInstall = ''
              mkdir -p "$out/bin"
              cc -std=c11 -O2 -Wall -Wextra -Werror \
                "$src/native/spawn.c" -o "$out/bin/cl-process-kit-spawn"
            '';
          };
          cl-process-kit-pty = pkgs.stdenv.mkDerivation {
            pname = "cl-process-kit-pty";
            inherit version;
            src = self;
            nativeBuildInputs = [ pkgs.sbcl ];
            buildPhase = ''
              cc -O2 -fPIC -shared native/pty.c \
                -o libcl_process_kit_pty${pkgs.stdenv.hostPlatform.extensions.sharedLibrary} \
                ${pkgs.lib.optionalString pkgs.stdenv.isLinux "-lutil"}
            '';
            installPhase = ''
              mkdir -p "$out/lib" "$out/share/common-lisp/source/cl-process-kit"
              cp libcl_process_kit_pty${pkgs.stdenv.hostPlatform.extensions.sharedLibrary} "$out/lib/"
              cp -R cl-process-kit.asd src "$out/share/common-lisp/source/cl-process-kit/"
            '';
          };
          docs = mkDocs pkgs;
          default = cl-process-kit;
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
        in
        rec {
          checkout-tests =
            pkgs.runCommand "cl-process-kit-checkout-tests"
              {
                nativeBuildInputs = [
                  pkgs.sbcl
                  pkgs.stdenv.cc
                  pkgs.perl
                  pkgs.coreutils
                ];
                CL_SOURCE_REGISTRY = sourceRegistry;
                # Coverage is a ratchet, not a one-off report: run-tests.lisp
                # fails the build itself if src/ coverage regresses below the
                # +minimum-*-coverage+ floors it tracks, so CI is the
                # enforcement point, not just a local opt-in convenience.
                # CL_PROCESS_KIT_COVERAGE_DAT redirects coverage.dat away from
                # $self (the read-only Nix store path run-tests.lisp itself
                # lives under) into this derivation's writable build sandbox.
                CL_PROCESS_KIT_COVERAGE = "1";
                CL_PROCESS_KIT_COVERAGE_DAT = "coverage.dat";
              }
              ''
                export HOME="$TMPDIR/home"
                mkdir -p "$HOME" "$out"
                cc -std=c11 -O2 -Wall -Wextra -Werror \
                  ${self}/native/spawn.c -o "$TMPDIR/cl-process-kit-spawn"
                export CL_PROCESS_KIT_SPAWN="$TMPDIR/cl-process-kit-spawn"
                timeout 30 sh ${self}/t/native-spawn-test.sh "$CL_PROCESS_KIT_SPAWN"
                timeout 180 sbcl --script ${self}/run-tests.lisp
                touch "$out/passed"
              '';
          pty-tests =
            pkgs.runCommand "cl-process-kit-pty-tests"
              {
                nativeBuildInputs = [
                  pkgs.sbcl
                  pkgs.stdenv.cc
                  pkgs.coreutils
                ];
                CL_SOURCE_REGISTRY = sourceRegistry;
              }
              ''
                export HOME="$TMPDIR/home"
                mkdir -p "$HOME" "$out"
                cc -O2 -fPIC -shared ${self}/native/pty.c \
                  -o "$TMPDIR/libcl_process_kit_pty${pkgs.stdenv.hostPlatform.extensions.sharedLibrary}" \
                  ${pkgs.lib.optionalString pkgs.stdenv.isLinux "-lutil"}
                export CL_PROCESS_KIT_PTY_LIBRARY="$TMPDIR/libcl_process_kit_pty${pkgs.stdenv.hostPlatform.extensions.sharedLibrary}"
                timeout 60 sbcl --script ${self}/run-pty-tests.lisp
                touch "$out/passed"
              '';

          # Dead code, TODO/FIXME markers, adapter layers around a
          # nerima-lisp dependency, and backward-compatibility shims have all
          # been repeatedly verified absent by hand across many refactoring
          # passes -- this turns that one-off verification into a standing
          # invariant CI enforces on every push, the same way the coverage
          # ratchet in run-tests.lisp turns a coverage target into a gate
          # instead of a number checked once and left to drift.
          noForbiddenMarkers =
            pkgs.runCommand "cl-process-kit-no-forbidden-markers" { nativeBuildInputs = [ pkgs.gnugrep ]; }
              ''
                cd ${self}
                if grep -rniE 'TODO|FIXME|XXX|adapter|backward.?compat' \
                    --include='*.lisp' --include='*.asd' --include='*.md' \
                    src t docs README.md CHANGELOG.md; then
                  echo "Forbidden marker found above -- this project keeps zero" >&2
                  echo "TODO/FIXME/XXX/adapter/backward-compat markers." >&2
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

      apps = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
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
              cc -std=c11 -O2 -Wall -Wextra -Werror \
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
