//! Run as the tmux owner. OpenSSH provides authentication, PTYs and resize.
use anyhow::{Context, Result, bail, ensure};
use std::{
    env,
    io::{self, Write},
    os::unix::process::CommandExt,
    process::Command,
};

#[path = "agent/import_link.rs"]
mod import_link;

#[path = "agent/codemaker.rs"]
mod codemaker;
#[path = "agent/codemaker_export.rs"]
mod codemaker_export;
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

// Both the session list and mobile PTY use UTF-8 even when sshd supplies no locale.
fn attach() -> Result<()> {
    let command = env::var_os("SSH_ORIGINAL_COMMAND");
    let command = command
        .as_deref()
        .map(|v| v.to_str().context("invalid request"))
        .transpose()?;
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
                let path = Command::new("tmux")
                    .args(["display-message", "-p", "-t", &format!("${id}:"), "#{pane_current_path}"])
                    .output()?;
                let directory = path.status.success().then(|| {
                    String::from_utf8_lossy(&path.stdout).trim_end_matches('\n').to_owned()
                });
                Ok(serde_json::json!({"id": id, "name": name, "touchPaging": true, "directory": directory, "snapshot": true, "snapshotVersion": 2}))
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
            "usage: agent attach | agent snapshot SESSION_ID | agent bind-session --help | agent unbind-session SESSION_ID | agent tunnel SSH_HOST /absolute/tunnel.sock INNER_SSH_PORT | agent import-link --help | agent pair --center HOST"
        ),
    }
}
