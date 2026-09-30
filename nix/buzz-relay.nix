# Server output: buzz-relay plus the buzz-admin (migrations, operator tasks)
# and buzz-pair-relay binaries, matching the Dockerfile's runtime image.
#
# Built with crane rather than nixpkgs' rustPlatform: Cargo.lock holds
# sqlx-core 0.9.0 from both crates.io and the patched sqlx git source, which
# single-directory vendoring (importCargoLock, fetchCargoVendor, cargo vendor)
# cannot represent. Crane vendors each source separately from Cargo.lock, and
# pins git dependencies by the revisions recorded there.
{
  lib,
  craneLib,
  makeWrapper,
  bash,
  coreutils,
  curl,
  gitMinimal,
  gnused,
  openssl,
  sourceSha ? "unknown",
}:

let
  commonArgs = {
    pname = "buzz-relay";
    # buzz-relay is versioned independently of the workspace.
    version = (lib.importTOML ../crates/buzz-relay/Cargo.toml).package.version;

    src = import ./rust-workspace-src.nix { inherit lib; };

    strictDeps = true;
    cargoExtraArgs = "--locked --package=buzz-relay --package=buzz-admin --package=buzz-pair-relay";
    # The test suites need live Postgres, Redis, and S3 services.
    doCheck = false;
  };

  # Dependencies build once and are reused while only workspace sources change.
  cargoArtifacts = craneLib.buildDepsOnly commonArgs;
in
craneLib.buildPackage (
  commonArgs
  // {
    inherit cargoArtifacts;

    nativeBuildInputs = [ makeWrapper ];

    env.BUZZ_SOURCE_SHA = sourceSha;

    # The relay shells out to git, and git runs the relay's bash pre-receive
    # hook, which uses coreutils, sed, curl, and openssl.
    postInstall = ''
      wrapProgram $out/bin/buzz-relay \
        --prefix PATH : ${
          lib.makeBinPath [
            bash
            coreutils
            curl
            gitMinimal
            gnused
            openssl
          ]
        }
    '';

    meta = {
      description = "Buzz WebSocket relay (NIP-29) with git and media endpoints";
      homepage = "https://github.com/block/buzz";
      license = lib.licenses.asl20;
      mainProgram = "buzz-relay";
      platforms = lib.platforms.linux;
    };
  }
)
