{
  description = "Dependency-free, SBCL-only process execution toolkit for Common Lisp";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    cl-weave = {
      url = "github:nerima-lisp/cl-weave/v0.8.0";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    inputs@{
      self,
      nixpkgs,
      cl-weave,
      ...
    }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-darwin"
      ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
      sourceRegistry = "${cl-weave}//:${self}//";
    in
    {
      packages = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        rec {
          cl-process-kit = pkgs.sbcl.buildASDFSystem {
            pname = "cl-process-kit";
            version = "0.1.0";
            src = self;
            systems = [ "cl-process-kit" ];
          };
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
                nativeBuildInputs = [ pkgs.sbcl ];
                CL_SOURCE_REGISTRY = sourceRegistry;
              }
              ''
                export HOME="$TMPDIR/home"
                mkdir -p "$HOME" "$out"
                sbcl --script ${self}/run-tests.lisp
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
            runtimeInputs = [ pkgs.sbcl ];
            text = ''
              export CL_SOURCE_REGISTRY="${sourceRegistry}"
              exec sbcl --script ${self}/run-tests.lisp
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
            ];
            CL_SOURCE_REGISTRY = sourceRegistry;
          };
        }
      );
    };
}
