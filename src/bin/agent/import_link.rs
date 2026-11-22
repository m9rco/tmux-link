use anyhow::{Context, Result, ensure};
use percent_encoding::{AsciiSet, NON_ALPHANUMERIC, utf8_percent_encode};
use std::{collections::HashMap, process::Command};

const USAGE: &str = "tmux-link-agent import-link --center HOST [--route NAME] [--port PORT] [--name DISPLAY_NAME] [--user SSH_USER] [--host-key PUBLIC_KEY_FILE]";
const QUERY_VALUE: &AsciiSet = &NON_ALPHANUMERIC
    .remove(b'-')
    .remove(b'.')
    .remove(b'_')
    .remove(b'~');

fn read_command(program: &str, args: &[&str]) -> Result<String> {
    let result = Command::new(program)
        .args(args)
        .output()
        .with_context(|| format!("run {program}"))?;
    ensure!(
        result.status.success(),
        "{program} failed: {}",
        String::from_utf8_lossy(&result.stderr).trim()
    );
    Ok(String::from_utf8(result.stdout)?.trim().to_owned())
}

fn valid_center(host: &str) -> bool {
    !host.is_empty()
        && host.len() <= 253
        && host.split('.').all(|label| {
            !label.is_empty()
                && label.len() <= 63
                && !label.starts_with('-')
                && !label.ends_with('-')
                && label
                    .bytes()
                    .all(|b| b.is_ascii_alphanumeric() || b == b'-')
        })
}

pub(super) fn print(args: &[String]) -> Result<()> {
    if args == ["--help"] || args == ["-h"] {
        println!(
            "{USAGE}\nPrint an iPhone import link for this tmux host. Defaults to port 443, route primary and the current user. Run as the tmux owner."
        );
        return Ok(());
    }
    let mut options = HashMap::new();
    let mut args = args.iter();
    while let Some(option) = args.next() {
        ensure!(
            matches!(
                option.as_str(),
                "--center" | "--port" | "--route" | "--name" | "--user" | "--host-key"
            ),
            "unknown option {option}. Usage: {USAGE}"
        );
        let value = args
            .next()
            .filter(|v| !v.starts_with("--") && !v.is_empty())
            .with_context(|| format!("missing value for {option}"))?;
        ensure!(
            options.insert(option.as_str(), value.as_str()).is_none(),
            "duplicate option {option}"
        );
    }

    let host = options.get("--center").context(USAGE)?;
    ensure!(
        valid_center(host),
        "--center must be the public WSS hostname (supply the port separately)"
    );
    let port: u16 = options
        .get("--port")
        .unwrap_or(&"443")
        .parse()
        .context("invalid WSS port")?;
    ensure!(port != 0, "port must be nonzero");
    let route = options.get("--route").copied().unwrap_or("primary");
    ensure!(
        route.len() <= 64
            && route
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-'),
        "invalid center route"
    );
    let user = match options.get("--user") {
        Some(value) => value.to_string(),
        None => read_command("id", &["-un"])?,
    };
    let name = match options.get("--name") {
        Some(value) => value.to_string(),
        None => read_command("hostname", &[])?,
    };
    ensure!(
        !user.is_empty()
            && user.len() <= 128
            && !user.chars().any(|c| c.is_whitespace() || c.is_control()),
        "invalid SSH username"
    );
    ensure!(
        !name.trim().is_empty() && name.len() <= 128 && !name.chars().any(char::is_control),
        "invalid display name"
    );

    let default_key = if cfg!(target_os = "macos") {
        "/etc/ssh/ssh_host_ed25519_key.pub"
    } else {
        "/etc/tmux-link/host_ed25519.pub"
    };
    let key = options.get("--host-key").copied().unwrap_or(default_key);
    let fingerprint = read_command("ssh-keygen", &["-E", "sha256", "-l", "-f", key])
        .with_context(|| format!("cannot fingerprint the inner sshd public host key {key}; use --host-key to specify its path"))?;
    ensure!(
        fingerprint.lines().count() == 1,
        "expected exactly one inner SSH host key"
    );
    let pin = fingerprint
        .split_whitespace()
        .nth(1)
        .filter(|p| p.starts_with("SHA256:"))
        .context("ssh-keygen did not return a SHA256 host fingerprint")?;
    let encode = |s: &str| utf8_percent_encode(s, QUERY_VALUE).to_string();
    println!(
        "tmuxlink://client?host={}&port={port}&route={}&user={}&pin={}&name={}&requireMTLS=true",
        encode(host),
        encode(route),
        encode(&user),
        encode(pin),
        encode(&name)
    );
    Ok(())
}
