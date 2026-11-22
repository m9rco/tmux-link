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

#[cfg(feature = "tls")]
#[path = "agent/pair.rs"]
mod pair;

// Both the session list and mobile PTY use UTF-8 even when sshd supplies no locale.
fn attach() -> Result<()> {
    let command = env::var_os("SSH_ORIGINAL_COMMAND");
    let command = command
        .as_deref()
        .map(|v| v.to_str().context("invalid request"))
        .transpose()?;
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
                Ok(serde_json::json!({"id": id, "name": name}))
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
        [op] if op == "attach" => attach(),
        [op, options @ ..] if op == "import-link" => import_link::print(options),
        #[cfg(feature = "tls")]
        [op, options @ ..] if op == "pair" => pair::command(options),
        #[cfg(feature = "tls")]
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
            "usage: agent attach | agent tunnel SSH_HOST /absolute/tunnel.sock INNER_SSH_PORT | agent import-link --help | agent pair --center HOST"
        ),
    }
}
