//! Run as the tmux owner. OpenSSH provides authentication, PTYs and resize.
use anyhow::{Context, Result, bail, ensure};
use std::{
    env,
    io::{self, Read, Write},
    os::unix::process::CommandExt,
    process::Command,
};

#[path = "agent/import_link.rs"]
mod import_link;

#[path = "agent/codemaker.rs"]
mod codemaker;
#[path = "agent/codemaker_export.rs"]
mod codemaker_export;
#[path = "agent/codemaker_status.rs"]
mod codemaker_status;
#[path = "agent/managed.rs"]
mod managed;
#[path = "agent/managed_decision.rs"]
mod managed_decision;
#[path = "agent/snapshot.rs"]
mod snapshot;

#[cfg(all(feature = "tls", feature = "ssh-probe"))]
#[path = "agent/pair.rs"]
mod pair;

// A swipe targets tmux itself. Inspect the live pane at gesture time so opening
// a pager, switching windows, or changing the tmux prefix needs no phone update.
fn page(request: &str) -> Result<()> {
    let (id, direction) = request.split_once(' ').context("invalid page request")?;
    let id: u64 = id.parse()?;
    let older = match direction {
        "up" => true,
        "down" => false,
        _ => bail!("invalid page direction"),
    };
    let target = format!("${id}:");
    let key = if older { "PPage" } else { "NPage" };
    let page = format!("send-keys -t '{target}' {key}");
    let shell = if older {
        // -e returns to the live shell when page-down reaches the bottom.
        format!("if-shell -F -t '{target}' '#{{history_size}}' \"copy-mode -eu -t '{target}'\"")
    } else {
        String::new()
    };
    let status = Command::new("tmux")
        .args([
            "if-shell",
            "-F",
            "-t",
            &target,
            "#{||:#{pane_in_mode},#{alternate_on}}",
            &page,
            &shell,
        ])
        .status()?;
    ensure!(status.success(), "tmux page request failed");
    Ok(())
}

fn print_snapshot(request: &str, detailed: bool) -> Result<()> {
    ensure!(
        !request.is_empty() && request.bytes().all(|b| b.is_ascii_digit()),
        "invalid snapshot ID"
    );
    let id = request.parse()?;
    let json = if detailed {
        serde_json::to_string(&snapshot::read_v2(id)?)?
    } else {
        serde_json::to_string(&snapshot::read(id)?)?
    };
    println!("{json}");
    Ok(())
}

fn manage(action: &str, id: &str, instance: Option<&str>) -> Result<()> {
    ensure!(
        tmux_link::valid_managed_action(action),
        "invalid managed action"
    );
    ensure!(
        !id.is_empty() && id.bytes().all(|b| b.is_ascii_digit()),
        "invalid managed session ID"
    );
    managed::control(action, id.parse()?, instance)
}

fn phone_advice(request: &str) -> Result<()> {
    let mut words = request.split(' ');
    let action = words.next().context("invalid advisor request")?;
    let id = words.next().context("missing session ID")?;
    ensure!(
        !id.is_empty() && id.bytes().all(|b| b.is_ascii_digit()),
        "invalid session ID"
    );
    let id = id.parse()?;
    let instance = words.next().context("missing session instance")?;
    ensure!(
        tmux_link::valid_managed_instance(instance),
        "invalid session instance"
    );
    match (action, words.next(), words.next()) {
        ("claim", None, None) => managed::claim(id, instance),
        ("finish", Some(ticket), None) if tmux_link::valid_advice_ticket(ticket) => {
            let mut response = Vec::new();
            io::stdin()
                .take(tmux_link::MAX_ADVICE_RESPONSE as u64 + 1)
                .read_to_end(&mut response)?;
            ensure!(
                !response.is_empty() && response.len() <= tmux_link::MAX_ADVICE_RESPONSE,
                "invalid advice response size"
            );
            let envelope = (response != b"null").then_some(response.as_slice());
            managed::finish(id, instance, ticket, envelope)
        }
        _ => bail!("invalid advisor request"),
    }
}

// Both the session list and mobile PTY use UTF-8 even when sshd supplies no locale.
fn attach() -> Result<()> {
    let command = env::var_os("SSH_ORIGINAL_COMMAND");
    let command = command
        .as_deref()
        .map(|v| v.to_str().context("invalid request"))
        .transpose()?;
    if let Some(request) = command.and_then(|c| c.strip_prefix("tmux-link-advisor-v2 ")) {
        return phone_advice(request);
    }
    if let Some(request) = command.and_then(|c| c.strip_prefix("tmux-link-managed-v1 ")) {
        let (action, id) = request.split_once(' ').context("invalid managed request")?;
        let (action, instance) =
            tmux_link::managed_remote_action(action).context("invalid managed request")?;
        return manage(action, id, instance);
    }
    if let Some(request) = command.and_then(|c| c.strip_prefix("tmux-link-page ")) {
        return page(request);
    }
    if let Some((snapshot, request)) = command.and_then(|c| c.split_once(' '))
        && matches!(snapshot, "tmux-link-snapshot" | "tmux-link-snapshot-v2")
    {
        return print_snapshot(request, snapshot == "tmux-link-snapshot-v2");
    }
    if let Some(id) = command.and_then(|c| c.strip_prefix("tmux-link-attach ")) {
        let id: u64 = id.parse()?;
        return Err(Command::new("tmux")
            .args(["-u", "attach-session", "-t", &format!("${id}")])
            .exec()
            .into());
    }
    ensure!(
        matches!(command, None | Some("tmux-link-list")),
        "unsupported request"
    );
    let list = Command::new("tmux")
        .args(["-u", "list-sessions", "-F", "#{session_id}|#{session_name}"])
        .output()?;
    if command == Some("tmux-link-list") && !list.status.success() {
        let reason = String::from_utf8_lossy(&list.stderr);
        if reason.contains("no server running")
            || reason.contains("No such file or directory")
            || reason.contains("no sessions")
        {
            println!("[]");
            return Ok(());
        }
    }
    ensure!(
        list.status.success(),
        "no tmux sessions available for this account"
    );
    let listing = String::from_utf8(list.stdout)?;
    let sessions: Vec<_> = listing
        .lines()
        .filter_map(|line| line.split_once('|'))
        .collect();
    if command == Some("tmux-link-list") {
        let items = sessions
            .iter()
            .map(|(id, name)| -> Result<_> {
                let id: u64 = id.strip_prefix('$').context("invalid tmux ID")?.parse()?;
                let details = Command::new("tmux")
                    .args(["-u", "display-message", "-p", "-t", &format!("${id}:"), "#{pid}-#{session_created}-#{pane_id}-#{pane_pid}\n#{pane_current_path}"])
                    .output()?;
                let fields = String::from_utf8_lossy(&details.stdout);
                let (instance, directory) = details.status.success()
                    .then(|| fields.strip_suffix('\n').and_then(|s| s.split_once('\n'))).flatten().unzip();
                Ok(serde_json::json!({"id": id, "name": name, "touchPaging": true, "directory": directory.filter(|s| !s.is_empty()), "snapshot": true, "snapshotVersion": 2, "managedVersion": 2, "managedInstance": instance}))
            })
            .collect::<Result<Vec<_>>>()?;
        println!("{}", serde_json::to_string(&items)?);
        return Ok(());
    }
    ensure!(!sessions.is_empty(), "no sessions");
    let index = if sessions.len() == 1 {
        0
    } else {
        for (i, (_, name)) in sessions.iter().enumerate() {
            println!(
                "{}  {}",
                i + 1,
                name.chars()
                    .filter(|ch| !ch.is_control())
                    .collect::<String>()
            );
        }
        print!("Session number: ");
        io::stdout().flush()?;
        let mut line = String::new();
        io::stdin().read_line(&mut line)?;
        line.trim()
            .parse::<usize>()?
            .checked_sub(1)
            .context("invalid selection")?
    };
    let (target, _) = sessions.get(index).context("invalid session number")?;
    Err(Command::new("tmux")
        .args(["-u", "attach-session", "-t", target])
        .exec()
        .into())
}

fn main() -> Result<()> {
    let args: Vec<_> = env::args().skip(1).collect();
    match args.as_slice() {
        [op] if matches!(op.as_str(), "--version" | "-V") => {
            println!("tmux-link-agent {}", env!("CARGO_PKG_VERSION"));
            Ok(())
        }
        [op] if op == "attach" => attach(),
        [op] if op == "migrate-managed" && env::var_os("SSH_ORIGINAL_COMMAND").is_none() => {
            managed::retire_legacy()
        }
        [op, action, id] if op == "managed" => manage(action, id, None),
        [op] if op == "managed-key" && env::var_os("SSH_ORIGINAL_COMMAND").is_none() => {
            bail!("请在 iPhone 的 Tmux Link 中设置模型 API Key。节点不接收模型密钥。")
        }
        [op, rest @ ..] if op == "bind-session" || op == "unbind-session" => {
            codemaker::configure(op, rest)
        }
        [op, flag] if op == "snapshot" && matches!(flag.as_str(), "--help" | "-h") => {
            println!(
                "tmux-link-agent snapshot SESSION_ID\nPrint the active pane, compacted tmux history and any bound CodeMaker transcript (newest messages first). Use the numeric tmux ID without '$'. See bind-session --help."
            );
            Ok(())
        }
        [op, id] if op == "snapshot" => print_snapshot(id, true),
        [op, options @ ..] if op == "import-link" => import_link::print(options),
        #[cfg(all(feature = "tls", feature = "ssh-probe"))]
        [op, options @ ..] if op == "pair" => pair::command(options),
        #[cfg(all(feature = "tls", feature = "ssh-probe"))]
        [op, state] if op == "serve-paired" => pair::serve(std::path::Path::new(state)),
        [op, host, socket, port] if op == "tunnel" => {
            ensure!(
                !host.starts_with('-') && socket.starts_with('/') && !socket.contains(':'),
                "invalid host or socket"
            );
            let port: u16 = port.parse()?;
            let forward = format!("{socket}:127.0.0.1:{port}");
            // exec lets service managers track the tunnel and propagate signals.
            let mut ssh = Command::new("ssh");
            if let Some(config) = env::var_os("TMUX_LINK_SSH_CONFIG") {
                ssh.arg("-F").arg(config);
            }
            Err(ssh
                .args([
                    "-NT",
                    "-o",
                    "BatchMode=yes",
                    "-o",
                    "StrictHostKeyChecking=yes",
                    "-o",
                    "ExitOnForwardFailure=yes",
                    "-o",
                    "ServerAliveInterval=25",
                    "-o",
                    "ServerAliveCountMax=3",
                    "-R",
                    &forward,
                    "--",
                    host,
                ])
                .exec()
                .into())
        }
        _ => bail!(
            "usage: agent attach | agent managed ACTION SESSION_ID | agent snapshot SESSION_ID | agent bind-session --help | agent unbind-session SESSION_ID | agent tunnel SSH_HOST /absolute/tunnel.sock INNER_SSH_PORT | agent import-link --help | agent pair --center HOST"
        ),
    }
}
