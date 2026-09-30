# NixOS module running headless Buzz agents: the `buzz-acp` harness driving
# `buzz-agent`, with `buzz-dev-mcp` as its tool server. This is a
# "hand-launched" agent in the sense of docs/remote-agents.md §Launchers: the
# unit only assembles the environment and execs the harness.
#
# Each agent's identity comes from `buzz agents provision`, run by the owner;
# see nix/README.md.
self:
{
  config,
  lib,
  pkgs,
  ...
}:

let
  enabled = lib.filterAttrs (_: agent: agent.enable) config.services.buzz-agents;
  toEnv = value: if lib.isBool value then lib.boolToString value else toString value;
  # Identity secrets must only arrive through environment files; anything in
  # `settings` is copied into the world-readable Nix store.
  secretSettings = [
    "BUZZ_PRIVATE_KEY"
    "BUZZ_AUTH_TAG"
    "OPENAI_COMPAT_API_KEY"
    "ANTHROPIC_API_KEY"
  ];

  agentOptions =
    { name, ... }:
    {
      options = {
        enable = lib.mkEnableOption "this Buzz agent" // {
          default = true;
        };

        package = lib.mkOption {
          type = lib.types.package;
          default = self.packages.${pkgs.stdenv.hostPlatform.system}.sprig;
          defaultText = lib.literalExpression "buzz.packages.\${system}.sprig";
          description = "Package providing `buzz-acp`, `buzz-agent`, and `buzz-dev-mcp`.";
        };

        environmentFiles = lib.mkOption {
          type = lib.types.nonEmptyListOf lib.types.path;
          example = [
            "/run/secrets/buzz-agent-${name}.env"
            "/run/secrets/buzz-agent-${name}-llm.env"
          ];
          description = ''
            Files of `KEY=value` lines loaded by systemd, kept outside the Nix
            store. One must be the file written by `buzz agents provision`
            (`BUZZ_PRIVATE_KEY`, `BUZZ_AUTH_TAG`, `BUZZ_RELAY_URL`); put LLM
            credentials such as `OPENAI_COMPAT_API_KEY` in one as well.
          '';
        };

        settings = lib.mkOption {
          type =
            with lib.types;
            attrsOf (oneOf [
              str
              int
              bool
            ]);
          default = { };
          example = {
            BUZZ_AGENT_PROVIDER = "openai-compat";
            OPENAI_COMPAT_BASE_URL = "http://127.0.0.1:8080/v1";
            OPENAI_COMPAT_MODEL = "qwen3-coder";
          };
          description = ''
            Non-secret environment for the harness (`BUZZ_ACP_*`) and the agent
            (`BUZZ_AGENT_*`, `OPENAI_COMPAT_*`). See `.env.example` and
            `buzz-acp --help`. The harness answers only its owner unless
            `BUZZ_ACP_RESPOND_TO` says otherwise.
          '';
        };

        extraPackages = lib.mkOption {
          type = lib.types.listOf lib.types.package;
          default = [ ];
          example = lib.literalExpression "[ pkgs.python3 pkgs.nodejs ]";
          description = "Extra tools on the agent's `PATH` for its shell tool.";
        };
      };
    };
in
{
  options.services.buzz-agents = lib.mkOption {
    type = lib.types.attrsOf (lib.types.submodule agentOptions);
    default = { };
    description = "Headless Buzz agents, keyed by name. Each runs as `buzz-agent-<name>.service`.";
  };

  config = lib.mkIf (enabled != { }) {
    assertions = lib.flatten (
      lib.mapAttrsToList (name: agent: [
        {
          assertion = lib.all (key: !(agent.settings ? ${key})) secretSettings;
          message = "services.buzz-agents.${name}.settings must not contain secrets (${lib.concatStringsSep ", " secretSettings}); use environmentFiles.";
        }
        {
          # Presence is the only liveness signal owners see (docs/remote-agents.md, I3).
          assertion = !(agent.settings ? BUZZ_ACP_NO_PRESENCE);
          message = "services.buzz-agents.${name}.settings must not set BUZZ_ACP_NO_PRESENCE.";
        }
      ]) enabled
    );

    systemd.services = lib.mapAttrs' (
      name: agent:
      let
        stateDir = "/var/lib/buzz-agent-${name}";
      in
      lib.nameValuePair "buzz-agent-${name}" {
        description = "Buzz agent ${name}";
        wantedBy = [ "multi-user.target" ];
        wants = [ "network-online.target" ];
        after = [ "network-online.target" ];

        # The harness spawns buzz-agent and buzz-dev-mcp by name, and the
        # agent's shell tool runs arbitrary commands.
        path = [
          agent.package
          pkgs.bash
          pkgs.coreutils
          pkgs.findutils
          pkgs.gnugrep
          pkgs.gnused
          pkgs.gitMinimal
          pkgs.curl
        ]
        ++ agent.extraPackages;

        environment = {
          BUZZ_ACP_AGENT_COMMAND = "buzz-agent";
          BUZZ_ACP_MCP_COMMAND = "buzz-dev-mcp";
        }
        // lib.mapAttrs (_: toEnv) agent.settings
        // {
          HOME = stateDir;
        };

        serviceConfig = {
          ExecStart = "${agent.package}/bin/buzz-acp";
          EnvironmentFile = agent.environmentFiles;
          DynamicUser = true;
          StateDirectory = "buzz-agent-${name}";
          StateDirectoryMode = "0700";
          WorkingDirectory = stateDir;
          # A clean exit (for example the owner's `!shutdown`) is final;
          # only failures restart (docs/remote-agents.md, I5).
          Restart = "on-failure";
          RestartSec = 10;
          KillMode = "control-group";

          # The agent runs shell commands, so keep it confined to its state
          # directory rather than dropping every capability a tool may need.
          NoNewPrivileges = true;
          PrivateTmp = true;
          PrivateDevices = true;
          ProtectHome = true;
          ProtectSystem = "strict";
          ProtectKernelTunables = true;
          ProtectKernelModules = true;
          ProtectControlGroups = true;
          RestrictSUIDSGID = true;
        };
      }
    ) enabled;
  };
}
