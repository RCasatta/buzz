# Nix flake

`flake.nix` at the repository root serves three roles:

| Output | Use |
|--------|-----|
| `devShells.<system>.default` | Desktop machine: build and run the native Tauri app with `just desktop-standalone` |
| `packages.<system>.buzz-relay` (also `default`) | Relay server: `buzz-relay`, `buzz-admin`, `buzz-pair-relay` |
| `nixosModules.buzz-relay` (also `default`) | Relay server: systemd service for the relay |
| `packages.<system>.sprig` | Agent host: `buzz-acp`, `buzz-agent`, `buzz-dev-mcp`, and the `buzz` CLI in one binary |
| `nixosModules.buzz-agent` | Agent host: systemd services for headless agents |
| `checks.<system>.{relay,sprig}`, `checks.<system>.{relay,sprig}-closure-has-no-gui` | Build both server packages and verify their runtime closures have no GUI libraries |

Systems: `x86_64-linux`, `aarch64-linux`. Only `x86_64-linux` has been built.

## Pinned inputs

- **nixpkgs** is locked to the same revision as `~/git/my_flakes/flake.lock`
  (`fbcf476f`, 2025-08-14, `nixos-unstable`). To follow that file again after
  it moves:

  ```bash
  nix flake lock --override-input nixpkgs github:nixos/nixpkgs/<rev from my_flakes>
  ```

  The lock keeps `nixos-unstable` as the original reference, so a plain
  `nix flake update nixpkgs` would move it to the latest unstable instead.
- **rust-overlay** supplies the Rust channel from `rust-toolchain.toml`
  (currently 1.95.0). That nixpkgs revision ships rustc 1.88, older than the
  repository pins for CI, Docker, and Hermit. Bumping `rust-toolchain.toml` is
  picked up automatically; `nix flake update rust-overlay` is needed only when
  the new release is newer than the locked overlay.
- **crane** builds the relay and Sprig. `Cargo.lock` contains `sqlx-core 0.9.0` from both
  crates.io and the patched sqlx git source; nixpkgs' `importCargoLock`,
  `fetchCargoVendor`, and `cargo vendor` all vendor into one directory keyed by
  name and version, so they cannot vendor this lockfile. Crane reads
  `Cargo.lock` directly, so no hash needs updating when it changes. It is
  pinned to v0.21.3 because crane 0.22+ targets newer nixpkgs.
- **pnpm** 11.4.0 is fetched from the npm registry (`nix/pnpm.nix`) to match
  `packageManager` in `package.json`; that nixpkgs has only pnpm 10, which
  ignores the pnpm 11 `allowBuilds` setting. Evaluation fails with a clear
  message when `packageManager` changes, until the version and hash in
  `nix/pnpm.nix` are updated.
- **Node.js** is nixpkgs' `nodejs_24` (24.5.0). Hermit pins 24.15.0; pnpm 11
  needs Node >= 22.13.

## Desktop development shell (NixOS desktop)

Hermit's `bin/` tools download generic Linux binaries that NixOS cannot run.
The shell provides the same toolchain from Nix: Rust (with clippy, rustfmt,
rust-src, rust-analyzer), Node.js, pnpm, `just`, `git`, `python3`, and
`pkg-config`, plus the native libraries the build links: GTK 3, WebKitGTK 4.1,
libsoup 3, ALSA, D-Bus, and opus. GStreamer (base, good, bad, libav) is there
for WebKit audio/video playback and voice-note recording.

CI also installs libayatana-appindicator and librsvg. Neither is linked, and
the tray icon that would load appindicator is only created on macOS, so the
shell leaves them out. Add `libayatana-appindicator` to `buildInputs` and to
`LD_LIBRARY_PATH` (it is loaded with `dlopen`) if the tray is enabled on Linux.

```bash
cd ~/git/buzz
nix develop                        # or: direnv with `use flake`
just desktop-standalone            # build sidecars, start Vite, launch the app
just fresh=1 desktop-standalone    # same, after resetting this instance's state
```

`just desktop-standalone` runs `pnpm install` when `node_modules/` is missing.
To install explicitly from the lockfile: `pnpm install --frozen-lockfile`.
No relay, Docker, or `.env` is needed; the app asks for a community on first
launch.

One-shot, without entering the shell:

```bash
nix develop --command just desktop-standalone
```

Environment the shell sets:

- `BUZZ_NIX_DEV_SHELL=1` — `just desktop-standalone` then keeps this shell's
  `PATH` instead of prepending Hermit's `bin/`.
- `GST_PLUGIN_SYSTEM_PATH_1_0` (GStreamer setup hook), `GIO_EXTRA_MODULES`
  (glib-networking TLS), and `XDG_DATA_DIRS` (GSettings schemas).
- It unsets `LD_LIBRARY_PATH`. A value inherited from the host session (for
  example a system `alsa-lib` from a newer nixpkgs) overrides the app's
  RUNPATH and loads libraries built against a different glibc. The app then
  exits at startup with `version 'GLIBC_ABI_…' not found`, while Vite and
  `just` keep running, so it looks launched but no window appears.

Runtime needs outside the shell:

- A Secret Service provider on the session bus (GNOME Keyring or KWallet) for
  the OS keyring the app stores its key in. Its default collection should be
  unlocked before launch. Startup migrations write to it during Tauri's
  `setup`, before any window exists. If the collection is locked, the app
  blocks waiting for the unlock prompt: no window appears, while Vite serves
  the page (which, opened in a browser, reports "Community connection failed"
  because a browser has no Tauri bridge). Check with
  `busctl --user get-property org.freedesktop.secrets /org/freedesktop/secrets/aliases/default org.freedesktop.Secret.Collection Locked`.
- For blank windows or rendering crashes, see
  [docs/linux-rendering-troubleshooting.md](../docs/linux-rendering-troubleshooting.md).

Limits:

- Only `just desktop-standalone` skips Hermit. Other recipes (`bootstrap`,
  `setup`, `dev`, `relay`, `staging`, `production`, `hooks`) still prepend
  Hermit's `bin/` and will not work on NixOS as written. The lefthook Git hooks
  also pin Hermit through `bin/.lefthookrc`.
- The `mesh=1` variant (llama.cpp native build) has not been tried in this
  shell and likely needs more native tools, such as CMake.
- The shell does not package the app (`tauri build`, `.deb`, AppImage).
- The sherpa-onnx build script downloads a prebuilt static library during
  `cargo build`, so the first build needs network access.

## Relay package (NixOS server)

```bash
nix build .#buzz-relay        # result/bin/{buzz-relay,buzz-admin,buzz-pair-relay}
nix flake check               # builds the relay and runs the closure check
```

The relay binary is wrapped with `git`, `bash`, coreutils, `sed`, `curl`, and
`openssl` on its `PATH`: the relay runs `git`, and git runs the relay's
pre-receive hook script, which uses the others. The Rust test suites are not
run in the Nix build because they need live Postgres, Redis, and S3.

The package does not include the `web/` or `admin-web/` bundles. The relay
runs without them, but then it serves neither the invite landing page nor the
admin dashboard. To serve them, build them in the dev shell
(`pnpm -C web build`, `pnpm -C admin-web build`), copy each `dist/` directory
to the server, and set `BUZZ_WEB_DIR` / `BUZZ_ADMIN_WEB_DIR`.

### Required external services

| Service | Notes |
|---------|-------|
| PostgreSQL | 17 in `deploy/compose`. Apply migrations with `BUZZ_AUTO_MIGRATE=true` or `buzz-admin migrate` before first start. |
| Redis | 7 in `deploy/compose`. Pub/sub, presence, rate limits. |
| S3-compatible object storage | Media and git objects. A bucket must exist. Use path-style addressing for MinIO. |

Listening ports (defaults): `3000` WebSocket/HTTP (`BUZZ_BIND_ADDR`), `8080`
`/_liveness` and `/_readiness` (`BUZZ_HEALTH_PORT`), `9102` `/metrics`
(`BUZZ_METRICS_PORT`). Put TLS in front of port 3000 with a reverse proxy.

### Configuration

The relay reads only environment variables. The complete reference is
`.env.example` (development) and `deploy/compose/.env.example` (production).
Most relay settings have development defaults (for example `localhost`
databases and `buzz_dev` S3 credentials), so set these explicitly on a server:

| Variable | Secret | Purpose |
|----------|--------|---------|
| `DATABASE_URL` | if it has a password | Postgres connection |
| `REDIS_URL` | if it has a password | Redis connection |
| `RELAY_URL` | no | Public `wss://` URL, used in NIP-42 challenges |
| `BUZZ_RELAY_PRIVATE_KEY` | yes | Stable relay signing key, 64 hex characters |
| `BUZZ_GIT_HOOK_HMAC_SECRET` | yes | Stable secret, at least 32 characters; generated per start if unset |
| `BUZZ_S3_ENDPOINT`, `BUZZ_S3_BUCKET`, `BUZZ_S3_REGION`, `BUZZ_S3_ADDRESSING_STYLE` | no | Object storage |
| `BUZZ_S3_ACCESS_KEY`, `BUZZ_S3_SECRET_KEY` | yes | Object storage credentials |
| `BUZZ_GIT_REPO_PATH` | no | Git workspace directory (the module sets it under the state directory) |
| `RELAY_OWNER_PUBKEY` | no | Owner's 64-hex pubkey; required with `BUZZ_REQUIRE_RELAY_MEMBERSHIP=true` |
| `BUZZ_REQUIRE_AUTH_TOKEN`, `BUZZ_REQUIRE_RELAY_MEMBERSHIP` | no | Closed-relay production defaults in `deploy/compose/.env.example` |
| `BUZZ_MEDIA_BASE_URL`, `BUZZ_CORS_ORIGINS` | no | Public media URL and browser origins |
| `BUZZ_AUTO_MIGRATE` | no | `true` to apply migrations at startup |

Generate a key or secret with `openssl rand -hex 32`. Keep every secret out of
the Nix store: use the module's `environmentFile` (for example a file managed
by sops-nix or agenix).

### Running it by hand

```bash
set -a; . /path/to/relay.env; set +a    # file with the variables above
nix run .#buzz-relay
nix shell .#buzz-relay --command buzz-admin migrate
```

### NixOS module

`services.buzz-relay` runs the relay as a `DynamicUser` systemd service with
its state (git workspaces) in `/var/lib/buzz-relay`. It does not provision
Postgres, Redis, or storage. A single-host example:

```nix
# flake.nix of the server configuration
{
  inputs.buzz.url = "github:block/buzz";   # or "path:/home/you/git/buzz"

  outputs = { nixpkgs, buzz, ... }: {
    nixosConfigurations.relay-host = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        buzz.nixosModules.buzz-relay
        ({ pkgs, ... }: {
          services.buzz-relay = {
            enable = true;
            settings = {
              RELAY_URL = "wss://buzz.example.com";
              BUZZ_BIND_ADDR = "127.0.0.1:3000";
              # Peer authentication over the Unix socket, as the service user.
              DATABASE_URL = "postgres:///buzz-relay?host=/run/postgresql&user=buzz-relay";
              REDIS_URL = "redis://127.0.0.1:6379";
              BUZZ_S3_ENDPOINT = "http://127.0.0.1:9000";
              BUZZ_S3_BUCKET = "buzz-media";
              BUZZ_S3_REGION = "us-east-1";
              BUZZ_S3_ADDRESSING_STYLE = "path";
              BUZZ_MEDIA_BASE_URL = "https://buzz.example.com/media";
              BUZZ_CORS_ORIGINS = "https://buzz.example.com";
              RELAY_OWNER_PUBKEY = "<64-hex owner pubkey>";
              BUZZ_REQUIRE_AUTH_TOKEN = true;
              BUZZ_REQUIRE_RELAY_MEMBERSHIP = true;
              # Admits headless agents (see "Headless agent") through their
              # owner's membership, via the NIP-OA tag in their profile.
              BUZZ_ALLOW_NIP_OA_AUTH = true;
              BUZZ_AUTO_MIGRATE = true;
              RUST_LOG = "buzz_relay=info,buzz_db=info,buzz_auth=info,buzz_pubsub=info,tower_http=info";
            };
            # BUZZ_RELAY_PRIVATE_KEY, BUZZ_GIT_HOOK_HMAC_SECRET,
            # BUZZ_S3_ACCESS_KEY, BUZZ_S3_SECRET_KEY
            environmentFile = "/run/secrets/buzz-relay.env";
          };

          systemd.services.buzz-relay = {
            requires = [ "postgresql.service" "redis-buzz.service" ];
            after = [ "postgresql.service" "redis-buzz.service" "minio.service" ];
          };

          services.postgresql = {
            enable = true;
            package = pkgs.postgresql_17;
            ensureDatabases = [ "buzz-relay" ];
            ensureUsers = [{ name = "buzz-relay"; ensureDBOwnership = true; }];
          };

          services.redis.servers.buzz = {
            enable = true;
            port = 6379;
          };

          # Or point BUZZ_S3_* at an external provider instead.
          services.minio = {
            enable = true;
            listenAddress = "127.0.0.1:9000";
            consoleAddress = "127.0.0.1:9001";
            rootCredentialsFile = "/run/secrets/minio-root.env";
          };
        })
      ];
    };
  };
}
```

With MinIO, create the bucket once and keep it private
(`mc mb local/buzz-media && mc anonymous set none local/buzz-media`), and use
the MinIO root credentials, or a MinIO user limited to that bucket, as
`BUZZ_S3_ACCESS_KEY` / `BUZZ_S3_SECRET_KEY`. Terminate TLS for
`buzz.example.com` in front of `127.0.0.1:3000`, for example with
`services.caddy` or `services.nginx` (WebSocket upgrades must pass through).

`buzz-admin` is added to the system `PATH` and reads `DATABASE_URL` from its
environment. With the peer-authenticated socket above, only the service's own
`buzz-relay` user can connect as the owning role, so this example relies on
`BUZZ_AUTO_MIGRATE=true`. To run `buzz-admin migrate` by hand instead, give the
`buzz-relay` role a password and use a TCP `DATABASE_URL`, so the migrated
tables stay owned by the role the relay connects as.

## Headless agent (NixOS agent host)

A headless agent is the `buzz-acp` harness driving `buzz-agent`, with
`buzz-dev-mcp` providing its shell and file tools. It only connects out to the
relay, so the agent host needs no public exposure. `buzz-agent` can use any
OpenAI-compatible endpoint (llama.cpp server, vLLM, Ollama, and similar), such
as a local inference server. The model must handle tool calls: the agent
answers by running `buzz messages send` through its shell tool.

### 1. Mint the agent's identity (on the owner's machine)

An agent needs its own keypair, a NIP-OA auth tag signed by its owner, and a
profile that carries the tag. `buzz agents provision` creates all three, the
same way Buzz Desktop does for managed agents. Run it with **your** key:

```bash
nix shell .#sprig --command env \
  BUZZ_RELAY_URL=https://buzz.example.com \
  BUZZ_PRIVATE_KEY='<your nsec or hex key>' \
  buzz agents provision --display-name Ripper --about "Local inference agent" \
    --env-file ./ripper-agent.env
```

It prints the agent's pubkey and writes `ripper-agent.env` (mode 0600, never
overwriting an existing file) with `BUZZ_PRIVATE_KEY`, `BUZZ_AUTH_TAG`, and
`BUZZ_RELAY_URL`. If the relay rejects the profile, the file is removed again.

The owner key is your own Buzz identity. In Buzz Desktop, the **Private key**
row in Settings reveals it ("Reveal private key"). Prefer
reading it from a file over typing it on the command line, for example
`BUZZ_PRIVATE_KEY="$(cat ~/.config/buzz-owner.key)"`, and do not run this on
the agent host.

Then:

- Copy `ripper-agent.env` to the agent host, outside the Nix store (for
  example `/run/secrets/`, managed by sops-nix or agenix).
- Add the LLM key to a second secret file:
  `OPENAI_COMPAT_API_KEY='…'`. A local server that ignores the key still
  needs a non-empty value.
- Add the agent to channels from the desktop app or with
  `buzz channels add-member --channel <UUID> --pubkey <agent pubkey> --role bot`.

### 2. Run it (on the agent host)

```nix
{
  inputs.buzz.url = "github:block/buzz";   # or "path:/home/you/git/buzz"

  outputs = { nixpkgs, buzz, ... }: {
    nixosConfigurations.ripper = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        buzz.nixosModules.buzz-agent
        {
          services.buzz-agents.ripper = {
            environmentFiles = [
              "/run/secrets/ripper-agent.env"      # from `buzz agents provision`
              "/run/secrets/ripper-agent-llm.env"  # OPENAI_COMPAT_API_KEY
            ];
            settings = {
              BUZZ_AGENT_PROVIDER = "openai-compat";
              OPENAI_COMPAT_BASE_URL = "http://127.0.0.1:8080/v1";
              OPENAI_COMPAT_MODEL = "<model id your server exposes>";
            };
          };
          # Start after the inference server, if it runs on this host.
          systemd.services.buzz-agent-ripper.after = [ "llama-cpp.service" ];
        }
      ];
    };
  };
}
```

The module runs `buzz-agent-<name>.service` as a `DynamicUser`, with
`/var/lib/buzz-agent-<name>` as its home and working directory:

- **Harness wiring.** It runs `buzz-acp` with `BUZZ_ACP_AGENT_COMMAND=buzz-agent` and
  `BUZZ_ACP_MCP_COMMAND=buzz-dev-mcp`, the same wiring the desktop and the
  Kubernetes provider use.
- **Who it answers.** Only its owner, the key that signed the auth tag. Set
  `BUZZ_ACP_RESPOND_TO` (`owner-only`, `allowlist` with
  `BUZZ_ACP_RESPOND_TO_ALLOWLIST`, `anyone`, `nobody`) to change that. The agent
  runs shell commands on the host, so widen this deliberately.
- **Restarts.** `Restart=on-failure`, never `always`: a clean exit, such as the
  owner's `!shutdown`, stays final (docs/remote-agents.md, invariant I5).
- **Evaluation guards.** Evaluation fails if `settings` contains a secret
  (`BUZZ_PRIVATE_KEY`, `BUZZ_AUTH_TAG`, `OPENAI_COMPAT_API_KEY`,
  `ANTHROPIC_API_KEY`), since those would land in the world-readable Nix store.
  It also fails on `BUZZ_ACP_NO_PRESENCE`, because presence is the owner's only
  liveness signal.
- **Tools on `PATH`.** The agent's shell tool finds bash, coreutils, findutils,
  grep, sed, git, curl, and Sprig's `rg`, `tree`, and `buzz`. Add more with
  `extraPackages`.
- **Other hosts.** Run each agent key on one host only. The harness does not
  stop a second launcher of the same key.

Stop the agent with `systemctl stop buzz-agent-ripper`, or send it `!shutdown`
from the owner's account. To retire the identity, delete the env file and
archive the agent: `buzz agents archive <agent pubkey> --reason retired`.

## Validation record

Desktop and relay, on x86_64-linux (NixOS, Wayland session), 2026-09-29:

- `nix flake check`: relay build and `relay-closure-has-no-gui` pass. The
  closure check matches 8 paths in a WebKitGTK closure and 0 in the relay's
  227 MiB closure.
- The relay package ran against throwaway, user-level Postgres 17, Redis, and
  MinIO from the pinned nixpkgs, started with an empty `PATH`: migrations
  applied at startup through a Unix-socket `DATABASE_URL`, `/_readiness`
  returned 200, `/_status` reported Postgres and Redis healthy, NIP-11 was
  served, and `buzz-admin migrate` re-ran cleanly.
- The NixOS module evaluated with the example above (service environment,
  `EnvironmentFile`, `ExecStart`, and unit derivation).
- `nix develop`: Rust 1.95.0 with clippy and rust-analyzer, pnpm 11.4.0,
  Node 24.5.0, and pkg-config resolves every native library.
  `pnpm install --frozen-lockfile` succeeded.
- `nix develop --command just desktop-standalone` built the sidecars and the
  Tauri app and launched it. The process used Nix's WebKitGTK and GStreamer,
  its WebKit processes started, and the webview loaded the Vite page.
- `cargo clippy --manifest-path desktop/src-tauri/Cargo.toml --workspace
  --all-targets -- -D warnings` passes in the shell.
- The desktop app ran natively with a human at the screen, after two
  startup fixes: clearing a host `LD_LIBRARY_PATH`, and unlocking the login
  keyring (see "Runtime needs").

Agent host, on 2026-09-30:

- `nix flake check` passes all four checks. Sprig builds with the `sprig` Cargo
  profile, and its closure has no GUI libraries.
- `buzz-cli`: `cargo test -p buzz-cli` (500 tests, including 7 for
  `agents provision`), `cargo clippy -p buzz-cli --all-targets -- -D warnings`,
  and `cargo fmt --all -- --check` pass.
- End to end, against a throwaway relay closed like production
  (`BUZZ_REQUIRE_RELAY_MEMBERSHIP=true`, `BUZZ_ALLOW_NIP_OA_AUTH=true`,
  `RELAY_OWNER_PUBKEY` set):
  - `buzz agents provision` wrote a 0600 env file and published the agent's
    profile.
  - `systemd-run --user -p EnvironmentFile=` kept the auth tag as strict JSON.
  - `buzz-acp` from the Nix-built Sprig connected and resolved its owner from
    the tag. The relay admitted it through NIP-OA without adding it as a relay
    member.
  - The owner's mention reached the agent. `buzz-agent` called a mock
    OpenAI-compatible server over `/v1/chat/completions`, ran the returned
    `shell` tool call through `buzz-dev-mcp`, and its
    `buzz messages send` reply appeared in the channel.
- The agent module evaluated with the example above (unit, environment,
  `EnvironmentFile`, `Restart=on-failure`). Both guards fire: a secret in
  `settings`, and `BUZZ_ACP_NO_PRESENCE`.

Not validated:

- A deployment on a NixOS server, or a NixOS VM test of the module: this
  covers systemd hardening, `ensureUsers` peer auth, and MinIO provisioning.
- Pushing to a hosted git repository through the relay. Git, the pre-receive
  hook, and its tools are on the wrapper's `PATH`, but no push was made.
- Media playback and voice-note recording in the desktop app (the GStreamer
  plugins), beyond the app starting and working for its user.
- `just mesh=1 desktop-standalone`, `aarch64-linux`, and the other Justfile
  recipes, which still use Hermit.
- The agent module as a real systemd service on a NixOS host (DynamicUser,
  hardening, and the shell tool under `ProtectSystem=strict`). The end-to-end
  run used the same binary and environment, but outside systemd.
- A real local model. Tool-call reliability depends on the model and on the
  inference server's chat template.
- The agent answering only its owner. `owner-only` is the harness default and
  was not exercised against a second user.
