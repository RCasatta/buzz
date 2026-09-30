# NixOS module running buzz-relay as a hardened systemd service.
#
# The relay needs Postgres, Redis, and S3-compatible storage; this module does
# not provision them. See nix/README.md for a complete host example.
self:
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.buzz-relay;
  stateDir = "/var/lib/buzz-relay";
  toEnv = value: if lib.isBool value then lib.boolToString value else toString value;
in
{
  options.services.buzz-relay = {
    enable = lib.mkEnableOption "the Buzz relay";

    package = lib.mkOption {
      type = lib.types.package;
      default = self.packages.${pkgs.stdenv.hostPlatform.system}.buzz-relay;
      defaultText = lib.literalExpression "buzz.packages.\${system}.buzz-relay";
      description = "Package providing `buzz-relay` and `buzz-admin`.";
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
        RELAY_URL = "wss://buzz.example.com";
        DATABASE_URL = "postgres:///buzz-relay?host=/run/postgresql&user=buzz-relay";
        REDIS_URL = "redis://127.0.0.1:6379";
        BUZZ_AUTO_MIGRATE = true;
      };
      description = ''
        Non-secret environment variables for the relay. These end up in the
        world-readable Nix store; put secrets in `environmentFile`. See
        `.env.example` and `deploy/compose/.env.example` for every variable.
      '';
    };

    environmentFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      example = "/run/secrets/buzz-relay.env";
      description = ''
        File of `KEY=value` lines loaded by systemd, kept outside the Nix
        store. Use it for `BUZZ_RELAY_PRIVATE_KEY`, `BUZZ_GIT_HOOK_HMAC_SECRET`,
        `BUZZ_S3_ACCESS_KEY`, `BUZZ_S3_SECRET_KEY`, and any URL that embeds a
        password.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    services.buzz-relay.settings = {
      BUZZ_GIT_REPO_PATH = lib.mkDefault "${stateDir}/git";
    };

    environment.systemPackages = [ cfg.package ];

    systemd.services.buzz-relay = {
      description = "Buzz relay";
      wantedBy = [ "multi-user.target" ];
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];

      environment = lib.mapAttrs (_: toEnv) cfg.settings // {
        HOME = stateDir;
      };

      serviceConfig = {
        ExecStart = lib.getExe cfg.package;
        EnvironmentFile = lib.optional (cfg.environmentFile != null) cfg.environmentFile;
        DynamicUser = true;
        StateDirectory = "buzz-relay";
        StateDirectoryMode = "0700";
        WorkingDirectory = stateDir;
        Restart = "on-failure";
        RestartSec = 5;

        CapabilityBoundingSet = "";
        LockPersonality = true;
        NoNewPrivileges = true;
        PrivateDevices = true;
        PrivateTmp = true;
        ProtectClock = true;
        ProtectControlGroups = true;
        ProtectHome = true;
        ProtectHostname = true;
        ProtectKernelLogs = true;
        ProtectKernelModules = true;
        ProtectKernelTunables = true;
        ProtectSystem = "strict";
        RestrictAddressFamilies = [
          "AF_INET"
          "AF_INET6"
          "AF_UNIX"
        ];
        RestrictNamespaces = true;
        RestrictRealtime = true;
        SystemCallArchitectures = "native";
      };
    };
  };
}
