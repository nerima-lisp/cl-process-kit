{
  description = "SBCL-only process execution toolkit for Common Lisp, built on the nerima-lisp boundary and logging kits";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    # These four nerima-lisp packages are consumed purely as raw ASDF source
    # trees (buildASDFSystem `src`, or CL_SOURCE_REGISTRY at runtime) --
    # this flake never touches any of their own `packages`/`checks` outputs.
    # `flake = false` fetches just the source and skips evaluating each
    # package's own flake.nix, so their transitive dev-only inputs (e.g.
    # cl-weave's treefmt-nix, cl-boundary-kit/cl-log-kit's cl-json-kit) never
    # enter this flake's lock file.
    cl-weave = {
      url = "github:nerima-lisp/cl-weave/v1.0.0";
      flake = false;
    };
    cl-boundary-kit = {
      url = "github:nerima-lisp/cl-boundary-kit/v0.6.0";
      flake = false;
    };
    cl-log-kit = {
      url = "github:nerima-lisp/cl-log-kit/v1.6.0";
      flake = false;
    };
    cl-tty-kit = {
      # git+https with submodules=1 (NOT github:, which uses GitHub's tarball
      # API and silently drops submodules regardless of the query string) --
      # cl-tty-kit v0.6.0 vendors nerima-lisp/cl-prolog as a git submodule
      # (vendor/cl-prolog), and its own .asd self-registers that path, so a
      # submodule-less fetch leaves ASDF unable to resolve the "cl-tty-kit"
      # system's :cl-prolog dependency.
      url = "git+https://github.com/nerima-lisp/cl-tty-kit?ref=refs/tags/v0.6.0&submodules=1";
      flake = false;
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
      ...
    }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-darwin"
      ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
      sourceRegistry = "${cl-boundary-kit}//:${cl-log-kit}//:${cl-tty-kit}//:${cl-weave}//:${self}//";

      mkDocs =
        pkgs:
        pkgs.stdenvNoCC.mkDerivation {
          pname = "cl-process-kit-docs";
          version = "0.2.0";
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
            version = "0.6.0";
            src = cl-boundary-kit;
            systems = [ "cl-boundary-kit" ];
            lispLibs = [ clLogKit ];
          };
          clLogKit = pkgs.sbcl.buildASDFSystem {
            pname = "cl-log-kit";
            version = "1.6.0";
            src = cl-log-kit;
            systems = [ "cl-log-kit" ];
          };
        in
        rec {
          cl-process-kit = pkgs.sbcl.buildASDFSystem {
            pname = "cl-process-kit";
            version = "0.2.0";
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
            version = "0.2.0";
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

      checks = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        rec {
          checkout-tests =
            pkgs.runCommand "cl-process-kit-checkout-tests"
              {
                nativeBuildInputs = [ pkgs.sbcl pkgs.stdenv.cc pkgs.perl pkgs.coreutils ];
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
                nativeBuildInputs = [ pkgs.sbcl pkgs.stdenv.cc pkgs.coreutils ];
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
          default = checkout-tests;
        }
      );

      apps = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          test = pkgs.writeShellApplication {
            name = "cl-process-kit-test";
            runtimeInputs = [ pkgs.sbcl pkgs.stdenv.cc pkgs.perl pkgs.coreutils ];
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
