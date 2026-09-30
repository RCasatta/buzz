# Agent-host output: Sprig, the multicall binary behind the `buzz-acp`
# harness, the `buzz-agent` ACP agent, the `buzz-dev-mcp` tool server, and the
# `buzz` CLI. Mirrors Dockerfile.sprig: the `sprig` Cargo profile and the same
# personality links.
{
  lib,
  craneLib,
}:

let
  commonArgs = {
    pname = "sprig";
    # Sprig is versioned independently of the workspace.
    version = (lib.importTOML ../crates/sprig/Cargo.toml).package.version;
    src = import ./rust-workspace-src.nix { inherit lib; };

    strictDeps = true;
    CARGO_PROFILE = "sprig";
    cargoExtraArgs = "--locked --package=sprig";
    doCheck = false;
  };

  cargoArtifacts = craneLib.buildDepsOnly commonArgs;
in
craneLib.buildPackage (
  commonArgs
  // {
    inherit cargoArtifacts;

    # Personalities dispatch on argv[0]; keep in sync with Dockerfile.sprig.
    postInstall = ''
      for name in buzz-acp buzz-agent buzz-dev-mcp rg tree buzz \
          git-credential-nostr git-sign-nostr; do
        ln -s sprig "$out/bin/$name"
      done
    '';

    meta = {
      description = "Buzz ACP harness, agent, developer MCP server, and CLI in one binary";
      homepage = "https://github.com/block/buzz";
      license = lib.licenses.asl20;
      mainProgram = "buzz-acp";
      platforms = lib.platforms.linux;
    };
  }
)
