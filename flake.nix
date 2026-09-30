{
  description = "Buzz: relay package + NixOS module, and a native desktop development shell";

  inputs = {
    # Locked to the same revision as the maintainer's system flake; see nix/README.md.
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    # nixpkgs ships an older rustc than rust-toolchain.toml pins; rust-overlay
    # provides the exact channel.
    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # v0.21 is the last crane series that supports this nixpkgs; 0.22+ warns.
    crane.url = "github:ipetkov/crane/v0.21.3";
  };

  outputs =
    {
      self,
      nixpkgs,
      rust-overlay,
      crane,
    }:
    let
      lib = nixpkgs.lib;
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems =
        f:
        lib.genAttrs systems (
          system:
          f (
            import nixpkgs {
              inherit system;
              overlays = [ rust-overlay.overlays.default ];
            }
          )
        );

      rustChannel = (lib.importTOML ./rust-toolchain.toml).toolchain.channel;
    in
    {
      packages = forAllSystems (
        pkgs:
        let
          rustMinimal = pkgs.rust-bin.stable.${rustChannel}.minimal;
          craneLib = (crane.mkLib pkgs).overrideToolchain rustMinimal;
        in
        rec {
          buzz-relay = pkgs.callPackage ./nix/buzz-relay.nix {
            inherit craneLib;
            sourceSha = self.rev or "unknown";
          };
          sprig = pkgs.callPackage ./nix/sprig.nix { inherit craneLib; };
          default = buzz-relay;
        }
      );

      devShells = forAllSystems (pkgs: {
        default = pkgs.callPackage ./nix/desktop-shell.nix {
          rustToolchain = pkgs.rust-bin.stable.${rustChannel}.default.override {
            extensions = [
              "rust-src"
              "rust-analyzer"
            ];
          };
          pnpm = pkgs.callPackage ./nix/pnpm.nix { };
        };
      });

      nixosModules = rec {
        buzz-relay = import ./nix/nixos-module.nix self;
        buzz-agent = import ./nix/nixos-agent-module.nix self;
        default = buzz-relay;
      };

      checks = forAllSystems (
        pkgs:
        let
          packages = self.packages.${pkgs.stdenv.hostPlatform.system};
          # Server outputs must not drag desktop GUI libraries into their closure.
          closureHasNoGui =
            name: package:
            pkgs.runCommand "${name}-closure-has-no-gui"
              { closure = pkgs.closureInfo { rootPaths = [ package ]; }; }
              ''
                if grep -E -- '-(gtk\+?3?|webkitgtk|gstreamer|libsoup|libayatana|cairo|pango|mesa|libX11|wayland)-[0-9]' \
                    "$closure/store-paths"; then
                  echo "${name} closure contains GUI dependencies (listed above)" >&2
                  exit 1
                fi
                touch "$out"
              '';
        in
        {
          relay = packages.buzz-relay;
          sprig = packages.sprig;
          relay-closure-has-no-gui = closureHasNoGui "buzz-relay" packages.buzz-relay;
          sprig-closure-has-no-gui = closureHasNoGui "sprig" packages.sprig;
        }
      );
    };
}
