//! `buzz agents provision`: mint a headless agent identity owned by the caller.
//!
//! Mirrors what Buzz Desktop does when it creates a managed agent — a fresh
//! keypair, a NIP-OA `auth` tag signed by the owner with empty conditions, and
//! a kind:0 profile carrying that tag, signed and published by the agent key —
//! and writes the result as an environment file for a non-desktop launcher
//! such as a systemd unit (see `docs/remote-agents.md`, §Launchers).

use std::io::Write;
use std::path::Path;

use nostr::{Keys, ToBech32};

use crate::client::{to_ws_url, BuzzClient};
use crate::error::CliError;

/// A freshly minted agent identity: its keys and the owner-signed auth tag.
struct AgentIdentity {
    keys: Keys,
    auth_tag_json: String,
}

/// Generate an agent keypair and sign its NIP-OA auth tag with `owner`.
///
/// Conditions are empty, matching the desktop's managed-agent tags.
fn mint_identity(owner: &Keys) -> Result<AgentIdentity, CliError> {
    let keys = Keys::generate();
    let auth_tag_json = buzz_sdk::nip_oa::compute_auth_tag(owner, &keys.public_key(), "")
        .map_err(|e| CliError::Other(format!("failed to sign NIP-OA auth tag: {e}")))?;
    Ok(AgentIdentity {
        keys,
        auth_tag_json,
    })
}

/// Render the launcher environment file.
///
/// Values are single-quoted: systemd's `EnvironmentFile=` removes unescaped
/// double quotes, which would turn the JSON auth tag into a string that
/// `buzz-acp` rejects and silently drops. Single quotes are honored by both
/// systemd and POSIX shells, and none of the values can contain one.
fn render_env_file(
    display_name: &str,
    nsec: &str,
    auth_tag_json: &str,
    relay_ws_url: &str,
) -> Result<String, CliError> {
    for (name, value) in [
        ("BUZZ_PRIVATE_KEY", nsec),
        ("BUZZ_AUTH_TAG", auth_tag_json),
        ("BUZZ_RELAY_URL", relay_ws_url),
    ] {
        if value.contains(['\'', '\n', '\r']) {
            return Err(CliError::Usage(format!(
                "{name} cannot be written to an environment file: it contains a quote or newline"
            )));
        }
    }
    let label: String = display_name
        .chars()
        .map(|c| if c.is_control() { ' ' } else { c })
        .collect();
    Ok(format!(
        "# Buzz agent identity for \"{label}\", created by `buzz agents provision`.\n\
         # Secret: anyone with this file can post as the agent. Keep it private.\n\
         BUZZ_PRIVATE_KEY='{nsec}'\n\
         BUZZ_AUTH_TAG='{auth_tag_json}'\n\
         BUZZ_RELAY_URL='{relay_ws_url}'\n"
    ))
}

/// Create `path` with owner-only permissions, refusing to replace a file.
fn write_new_secret_file(path: &Path, contents: &str) -> Result<(), CliError> {
    let mut options = std::fs::OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    let mut file = options.open(path).map_err(|e| {
        if e.kind() == std::io::ErrorKind::AlreadyExists {
            CliError::Conflict(format!(
                "{} already exists; choose another --env-file",
                path.display()
            ))
        } else {
            CliError::Other(format!("failed to create {}: {e}", path.display()))
        }
    })?;
    file.write_all(contents.as_bytes())
        .and_then(|()| file.sync_all())
        .map_err(|e| CliError::Other(format!("failed to write {}: {e}", path.display())))
}

/// Mint an agent identity owned by the caller, write its launcher environment
/// file, and publish the agent's kind:0 profile.
///
/// The environment file is written before the profile is published so the
/// key is never lost to a failed write after the relay accepted the profile.
/// If publishing fails, the file is removed again: an agent without a
/// published profile is not recognizable as the owner's, so leaving the file
/// would hand the operator a half-provisioned identity.
pub async fn cmd_provision(
    client: &BuzzClient,
    display_name: &str,
    about: Option<&str>,
    env_file: &Path,
) -> Result<(), CliError> {
    if client.auth_tag_owner_hex().is_some() {
        return Err(CliError::Usage(
            "run `agents provision` with the owner's key, not an agent key (unset BUZZ_AUTH_TAG)"
                .into(),
        ));
    }
    let display_name = display_name.trim();
    if display_name.is_empty() {
        return Err(CliError::Usage("--display-name must not be empty".into()));
    }

    let identity = mint_identity(client.keys())?;
    let nsec = identity
        .keys
        .secret_key()
        .to_bech32()
        .map_err(|e| CliError::Key(format!("failed to encode agent key: {e}")))?;
    let contents = render_env_file(
        display_name,
        &nsec,
        &identity.auth_tag_json,
        &to_ws_url(client.relay_url()),
    )?;
    write_new_secret_file(env_file, &contents)?;

    match publish_profile(client, &identity, display_name, about).await {
        Ok(response) => {
            let mut output: serde_json::Value = serde_json::from_str(&response)
                .map_err(|e| CliError::Other(format!("invalid relay response: {e}")))?;
            if let Some(obj) = output.as_object_mut() {
                obj.insert(
                    "agent_pubkey".into(),
                    identity.keys.public_key().to_hex().into(),
                );
                obj.insert("env_file".into(), env_file.display().to_string().into());
            }
            println!("{output}");
            Ok(())
        }
        Err(publish_error) => match std::fs::remove_file(env_file) {
            Ok(()) => Err(publish_error),
            Err(e) => Err(CliError::Other(format!(
                "{publish_error}; additionally failed to remove {}: {e}",
                env_file.display()
            ))),
        },
    }
}

/// Publish the agent's kind:0 profile, signed by the agent and carrying the
/// owner's auth tag. Returns the relay's write response only if it was
/// accepted.
async fn publish_profile(
    owner_client: &BuzzClient,
    identity: &AgentIdentity,
    display_name: &str,
    about: Option<&str>,
) -> Result<String, CliError> {
    let auth_tag = buzz_sdk::nip_oa::parse_auth_tag(&identity.auth_tag_json)
        .map_err(|e| CliError::Other(format!("minted auth tag is malformed: {e}")))?;
    let agent_client = BuzzClient::new(
        owner_client.relay_url().to_owned(),
        identity.keys.clone(),
        Some(auth_tag),
        Some(identity.auth_tag_json.clone()),
    )?;
    let builder = buzz_sdk::builders::build_profile(Some(display_name), None, None, about, None)
        .map_err(|e| CliError::Other(format!("failed to build profile: {e}")))?;
    let event = agent_client.sign_event(builder)?;
    let response = agent_client.submit_event(event).await?;
    let accepted = serde_json::from_str::<serde_json::Value>(&response)
        .ok()
        .and_then(|v| v.get("accepted").and_then(serde_json::Value::as_bool));
    if accepted == Some(true) {
        Ok(response)
    } else {
        Err(CliError::Other(format!(
            "relay did not accept the agent profile: {response}"
        )))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn minted_tag_verifies_for_the_agent_and_names_the_owner() {
        let owner = Keys::generate();
        let identity = mint_identity(&owner).expect("mint");
        buzz_sdk::nip_oa::verify_auth_tag(&identity.auth_tag_json, &identity.keys.public_key())
            .expect("tag verifies for the minted agent key");
        let tag: Vec<String> = serde_json::from_str(&identity.auth_tag_json).expect("json array");
        assert_eq!(tag[1], owner.public_key().to_hex());
        assert_eq!(
            tag[2], "",
            "conditions match the desktop's empty conditions"
        );
        assert!(
            buzz_sdk::nip_oa::verify_auth_tag(
                &identity.auth_tag_json,
                &Keys::generate().public_key()
            )
            .is_err(),
            "tag must not verify for any other key"
        );
    }

    /// Parse the rendered file the way systemd's `EnvironmentFile=` and a
    /// POSIX shell do for single-quoted values, then feed the auth tag to the
    /// same strict parser `buzz-acp` uses.
    #[test]
    fn env_file_round_trips_the_auth_tag_strictly() {
        let owner = Keys::generate();
        let identity = mint_identity(&owner).expect("mint");
        let nsec = identity.keys.secret_key().to_bech32().expect("nsec");
        let rendered = render_env_file(
            "Ripper",
            &nsec,
            &identity.auth_tag_json,
            "wss://buzz.example.com",
        )
        .expect("render");

        let value_of = |name: &str| -> String {
            let line = rendered
                .lines()
                .find(|l| l.starts_with(&format!("{name}=")))
                .unwrap_or_else(|| panic!("{name} missing"));
            let raw = &line[name.len() + 1..];
            assert!(
                raw.starts_with('\'') && raw.ends_with('\''),
                "{name} is single-quoted"
            );
            raw[1..raw.len() - 1].to_owned()
        };

        let tag = value_of("BUZZ_AUTH_TAG");
        buzz_sdk::nip_oa::parse_auth_tag(&tag).expect("strict JSON survives the env file");
        buzz_sdk::nip_oa::verify_auth_tag(&tag, &identity.keys.public_key()).expect("verifies");
        assert_eq!(
            Keys::parse(&value_of("BUZZ_PRIVATE_KEY"))
                .expect("key parses")
                .public_key(),
            identity.keys.public_key()
        );
        assert_eq!(value_of("BUZZ_RELAY_URL"), "wss://buzz.example.com");
    }

    #[test]
    fn env_file_rejects_values_that_would_break_quoting() {
        assert!(render_env_file("a", "nsec1x", "[\"auth\"]", "wss://x'y").is_err());
        assert!(render_env_file("a", "nsec1x\nEVIL=1", "[\"auth\"]", "wss://x").is_err());
    }

    #[test]
    fn env_file_comment_cannot_inject_lines() {
        let rendered = render_env_file(
            "evil\nBUZZ_PRIVATE_KEY=x",
            "nsec1x",
            "[\"auth\"]",
            "wss://x",
        )
        .expect("render");
        assert_eq!(
            rendered
                .lines()
                .filter(|l| l.starts_with("BUZZ_PRIVATE_KEY="))
                .count(),
            1
        );
    }

    #[test]
    fn secret_file_is_owner_only_and_never_replaced() {
        let dir = tempfile::tempdir().expect("tempdir");
        let path = dir.path().join("agent.env");
        write_new_secret_file(&path, "A=1\n").expect("first write");
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mode = std::fs::metadata(&path).expect("meta").permissions().mode();
            assert_eq!(mode & 0o777, 0o600);
        }
        let err = write_new_secret_file(&path, "B=2\n").expect_err("second write refused");
        assert!(matches!(err, CliError::Conflict(_)), "{err:?}");
        assert_eq!(std::fs::read_to_string(&path).expect("read"), "A=1\n");
    }

    #[tokio::test]
    async fn agent_key_callers_are_refused_before_anything_is_written() {
        let owner = Keys::generate();
        let identity = mint_identity(&owner).expect("mint");
        let tag = buzz_sdk::nip_oa::parse_auth_tag(&identity.auth_tag_json).expect("tag");
        let agent_client = BuzzClient::new(
            "http://127.0.0.1:9".into(),
            identity.keys,
            Some(tag),
            Some(identity.auth_tag_json),
        )
        .expect("client");
        let dir = tempfile::tempdir().expect("tempdir");
        let path = dir.path().join("agent.env");
        let err = cmd_provision(&agent_client, "Sub", None, &path)
            .await
            .expect_err("agent keys cannot provision agents");
        assert!(matches!(err, CliError::Usage(_)), "{err:?}");
        assert!(!path.exists());
    }

    #[tokio::test]
    async fn failed_publish_removes_the_env_file() {
        // Port 9 (discard) on loopback: connection refused, so publishing fails.
        let owner_client =
            BuzzClient::new("http://127.0.0.1:9".into(), Keys::generate(), None, None)
                .expect("client");
        let dir = tempfile::tempdir().expect("tempdir");
        let path = dir.path().join("agent.env");
        cmd_provision(&owner_client, "Ripper", None, &path)
            .await
            .expect_err("publish must fail without a relay");
        assert!(
            !path.exists(),
            "no half-provisioned identity is left behind"
        );
    }
}
