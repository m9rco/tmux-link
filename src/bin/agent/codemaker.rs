//! A host-local association selected by the tmux owner. Only a read is exposed over SSH.
use crate::{codemaker_export, snapshot::transcript::Transcript};
use anyhow::{Context, Result, ensure};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::{
    env, fs,
    io::{ErrorKind, Read, Write},
    os::unix::fs::{DirBuilderExt, OpenOptionsExt},
    path::{Path, PathBuf},
    process::Command,
};

#[derive(Serialize, Deserialize, PartialEq, Eq)]
struct Binding {
    server_pid: u32,
    session_created: u64,
    pane_pid: u32,
    foreground: u32,
    started: String,
    executable: PathBuf,
    directory: PathBuf,
    session_id: String,
}

#[derive(PartialEq, Eq)]
struct Pane {
    server_pid: u32,
    session_created: u64,
    pane_pid: u32,
    pane_id: u64,
    alternate: bool,
    socket: PathBuf,
    directory: PathBuf,
}

impl Pane {
    fn inspect(id: u64) -> Result<Self> {
        let format = "#{session_id} #{pane_id} #{pid} #{session_created} #{pane_pid} #{alternate_on}\n#{socket_path}\n#{pane_current_path}";
        let output = Command::new("tmux")
            .args([
                "-u",
                "display-message",
                "-p",
                "-t",
                &format!("${id}:"),
                format,
            ])
            .output()?;
        ensure!(output.status.success(), "cannot inspect tmux session {id}");
        let raw = std::str::from_utf8(&output.stdout)?
            .strip_suffix('\n')
            .context("invalid tmux response")?;
        let mut lines = raw.split('\n');
        let fields: Vec<_> = lines.next().unwrap_or_default().split(' ').collect();
        ensure!(
            fields.len() == 6 && fields[0] == format!("${id}") && matches!(fields[5], "0" | "1"),
            "tmux session changed"
        );
        let socket = PathBuf::from(lines.next().context("missing tmux socket")?);
        let directory = PathBuf::from(lines.next().context("missing pane directory")?);
        ensure!(
            lines.next().is_none() && socket.is_absolute() && directory.is_absolute(),
            "invalid tmux paths"
        );
        Ok(Self {
            pane_id: fields[1]
                .strip_prefix('%')
                .context("invalid pane number")?
                .parse()?,
            server_pid: fields[2].parse()?,
            session_created: fields[3].parse()?,
            pane_pid: fields[4].parse()?,
            alternate: fields[5] == "1",
            socket,
            directory,
        })
    }

    fn slot(&self, root: &Path) -> PathBuf {
        let key = Sha256::digest(self.socket.as_os_str().as_encoded_bytes());
        root.join(format!("{key:x}-{}.json", self.pane_id))
    }

    fn foreground(&self) -> Result<(u32, String)> {
        fn field(pid: u32, name: &str) -> Result<String> {
            let out = Command::new("ps")
                .env("LC_ALL", "C")
                .env("TZ", "UTC")
                .args(["-o", name, "-p", &pid.to_string()])
                .output()?;
            ensure!(out.status.success(), "foreground process has ended");
            let value = std::str::from_utf8(&out.stdout)?.trim();
            ensure!(!value.is_empty(), "no foreground process identity");
            Ok(value.to_owned())
        }
        let group: u32 = field(self.pane_pid, "tpgid=")?.parse()?;
        ensure!(group > 0, "no foreground process group");
        Ok((group, field(group, "lstart=")?))
    }
}

fn root() -> Result<PathBuf> {
    let home = PathBuf::from(env::var_os("HOME").context("HOME is unavailable")?);
    ensure!(home.is_absolute(), "HOME must be absolute");
    Ok(home.join(".config/tmux-link/codemaker"))
}

fn load(path: &Path) -> Result<Option<Binding>> {
    let file = match fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
        .open(path)
    {
        Ok(file) => file,
        Err(e) if e.kind() == ErrorKind::NotFound => return Ok(None),
        Err(e) => return Err(e.into()),
    };
    ensure!(file.metadata()?.is_file(), "invalid binding file");
    let mut bytes = Vec::new();
    file.take(16 * 1024 + 1).read_to_end(&mut bytes)?;
    ensure!(bytes.len() <= 16 * 1024, "invalid binding size");
    Ok(Some(serde_json::from_slice(&bytes)?))
}

fn save(path: &Path, binding: &Binding) -> Result<()> {
    let dir = path.parent().context("missing bindings directory")?;
    fs::DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(dir)?;
    let temp = dir.join(format!(
        ".binding-{:016x}",
        getrandom::u64().map_err(|e| anyhow::anyhow!("{e}"))?
    ));
    let mut file = fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(&temp)?;
    let result = (|| -> Result<()> {
        file.write_all(&serde_json::to_vec(binding)?)?;
        file.sync_all()?;
        fs::rename(&temp, path)?;
        Ok(())
    })();
    if result.is_err() {
        let _ = fs::remove_file(&temp);
    }
    result
}

pub(super) fn configure(command: &str, args: &[String]) -> Result<()> {
    const USAGE: &str = "Usage: tmux-link-agent bind-session TMUX_ID [CODEMAKER_SESSION_ID]\n       tmux-link-agent unbind-session TMUX_ID\nRun in a separate shell on the node. Without a CodeMaker ID, select the existing conversation from a list.";
    if matches!(args,[flag] if flag == "--help" || flag == "-h") {
        println!("{USAGE}");
        return Ok(());
    }
    ensure!(
        env::var_os("SSH_ORIGINAL_COMMAND").is_none(),
        "binding is a host-local operation"
    );
    ensure!(
        matches!(args, [_]) || command == "bind-session" && matches!(args, [_, _]),
        "{USAGE}"
    );
    ensure!(
        !args[0].is_empty() && args[0].bytes().all(|b| b.is_ascii_digit()),
        "invalid tmux session ID"
    );
    let id = args[0].parse()?;
    let pane = Pane::inspect(id)?;
    let file = pane.slot(&root()?);
    if command == "unbind-session" {
        match fs::remove_file(file) {
            Err(e) if e.kind() == ErrorKind::NotFound => (),
            other => other?,
        }
        println!("Cleared CodeMaker binding for pane %{}.", pane.pane_id);
        return Ok(());
    }
    ensure!(
        pane.alternate,
        "open the intended CodeMaker full-screen conversation in tmux session {id} first"
    );
    let (foreground, started) = pane.foreground()?;
    let executable = codemaker_export::resolve()?;
    let session_id = match args.get(1) {
        Some(v) => v.to_owned(),
        None => codemaker_export::choose(&executable, &pane.directory)?,
    };
    codemaker_export::read(&executable, &pane.directory, &session_id)
        .context("could not verify the selected CodeMaker export")?;
    ensure!(
        Pane::inspect(id)? == pane && pane.foreground()? == (foreground, started.clone()),
        "active pane or foreground process changed; retry the binding"
    );
    let binding = Binding {
        server_pid: pane.server_pid,
        session_created: pane.session_created,
        pane_pid: pane.pane_pid,
        foreground,
        started,
        executable,
        directory: pane.directory,
        session_id,
    };
    save(&file, &binding)?;
    println!(
        "Bound tmux pane %{} to {}. Rebind if you switch conversations inside CodeMaker.",
        pane.pane_id, binding.session_id
    );
    Ok(())
}

fn read(id: u64, pane_id: u64) -> Result<(Option<Transcript>, Option<&'static str>)> {
    let root = root()?;
    let unbound = (None, Some("unbound"));
    if !root.try_exists()? {
        return Ok(unbound);
    }
    let pane = Pane::inspect(id)?;
    if pane.pane_id != pane_id || !pane.alternate {
        return Ok((None, Some("changed")));
    }
    let file = pane.slot(&root);
    let Some(binding) = load(&file)? else {
        return Ok(unbound);
    };
    let unchanged = || -> Result<bool> {
        Ok(pane.server_pid == binding.server_pid
            && pane.session_created == binding.session_created
            && pane.pane_pid == binding.pane_pid
            && pane.foreground()? == (binding.foreground, binding.started.clone()))
    };
    if !unchanged()? {
        return Ok((None, Some("changed")));
    }
    let transcript =
        codemaker_export::read(&binding.executable, &binding.directory, &binding.session_id)?;
    if Pane::inspect(id)? != pane || !unchanged()? || load(&file)?.as_ref() != Some(&binding) {
        return Ok((None, Some("changed")));
    }
    Ok((Some(transcript), None))
}

pub(super) fn context(id: u64, pane_id: u64) -> (Option<Transcript>, Option<&'static str>) {
    read(id, pane_id).unwrap_or((None, Some("unavailable")))
}
