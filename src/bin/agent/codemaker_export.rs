use crate::snapshot::transcript::{MAX_EXPORT_BYTES, Transcript, from_bytes, valid_id};
use anyhow::{Context, Result, anyhow, ensure};
use serde::Deserialize;
use std::{
    cmp::Reverse,
    env,
    ffi::CString,
    io::{self, BufRead, IsTerminal, Read, Write},
    os::unix::ffi::OsStrExt,
    path::{Path, PathBuf},
    process::Stdio,
    time::Duration,
};
use tokio::{io::AsyncReadExt, process::Command, time::timeout};

const DEADLINE: Duration = Duration::from_secs(8);
const MAX_LIST_BYTES: usize = 4 * 1024 * 1024;
const MAX_CHOICES: usize = 50;

pub(super) fn resolve() -> Result<PathBuf> {
    let path = env::var_os("PATH").unwrap_or_default();
    env::split_paths(&path)
        .filter(|path| path.is_absolute())
        .map(|path| path.join("codemaker"))
        .find(|path| {
            if !path.is_file() {
                return false;
            }
            let Ok(name) = CString::new(path.as_os_str().as_bytes()) else {
                return false;
            };
            // SAFETY: name is a live, NUL-terminated pathname.
            unsafe { libc::access(name.as_ptr(), libc::X_OK) == 0 }
        })
        .context("could not find executable codemaker on the local PATH")
}

pub(super) fn read(executable: &Path, directory: &Path, id: &str) -> Result<Transcript> {
    ensure!(valid_id(id), "invalid CodeMaker session ID");
    let bytes = output(
        executable,
        directory,
        &["--pure", "export", id],
        MAX_EXPORT_BYTES,
        DEADLINE,
    )?;
    from_bytes(&bytes, id)
        .map_err(|_| anyhow!("invalid CodeMaker session export for the requested ID"))
}

fn output(
    executable: &Path,
    directory: &Path,
    args: &[&str],
    limit: usize,
    deadline: Duration,
) -> Result<Vec<u8>> {
    ensure!(
        executable.is_absolute()
            && executable.file_name().is_some_and(|s| s == "codemaker")
            && directory.is_absolute(),
        "invalid CodeMaker binding paths"
    );
    // npm launchers may use 'env node'. Prefer the same bin directory from the
    // local binding even if sshd supplies only the system PATH.
    let inherited = env::var_os("PATH").unwrap_or_else(|| "/usr/bin:/bin".into());
    let path = env::join_paths(
        executable
            .parent()
            .into_iter()
            .map(Path::to_owned)
            .chain(env::split_paths(&inherited).filter(|path| path.is_absolute())),
    )?;
    let runtime = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()?;
    runtime.block_on(async {
        let mut child = Command::new(executable)
            .args(args)
            .current_dir(directory)
            .env("PATH", path)
            .env("OPENCODE_DISABLE_AUTOUPDATE", "1")
            .env("OPENCODE_DISABLE_MODELS_FETCH", "1")
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .process_group(0)
            .kill_on_drop(true)
            .spawn()
            .context("could not launch CodeMaker")?;
        let pid = child.id().context("missing CodeMaker process ID")? as libc::pid_t;
        let stdout = child.stdout.take().context("missing CodeMaker output")?;
        let result = timeout(deadline, async {
            let mut bytes = Vec::new();
            stdout
                .take(limit as u64 + 1)
                .read_to_end(&mut bytes)
                .await?;
            ensure!(
                bytes.len() <= limit,
                "CodeMaker output exceeds the size limit"
            );
            Ok((child.wait().await?, bytes))
        })
        .await;
        let error = match result {
            Ok(Ok((status, bytes))) => {
                ensure!(status.success(), "CodeMaker command failed");
                return Ok(bytes);
            }
            Ok(Err(error)) => error,
            Err(_) => anyhow!("CodeMaker command timed out"),
        };
        // The leader has not been reaped. Terminate the whole dedicated group
        // in case a launcher delegated to another process still holding stdout.
        // SAFETY: -pid addresses the process group we created for this child.
        unsafe { libc::kill(-pid, libc::SIGKILL) };
        let _ = child.start_kill();
        let _ = timeout(Duration::from_secs(1), child.wait()).await;
        Err(error)
    })
}

#[derive(Deserialize)]
struct Session {
    id: String,
    #[serde(default)]
    title: String,
    #[serde(default)]
    updated: u64,
    directory: Option<PathBuf>,
}

fn candidates(bytes: &[u8], directory: &Path) -> Result<Vec<Session>> {
    // OpenCode emits no JSON when the list is empty.
    let mut sessions: Vec<Session> = if bytes.iter().all(u8::is_ascii_whitespace) {
        Vec::new()
    } else {
        serde_json::from_slice(bytes).map_err(|_| anyhow!("invalid CodeMaker session list"))?
    };
    sessions.retain(|s| valid_id(&s.id) && s.directory.as_deref().is_none_or(|p| p == directory));
    sessions.sort_by_key(|s| Reverse(s.updated));
    Ok(sessions)
}

fn label(text: &str) -> String {
    text.chars()
        .filter(|ch| {
            !ch.is_control()
                && !matches!(ch, '\u{061c}' | '\u{200e}' | '\u{200f}'
                    | '\u{2028}'..='\u{202e}' | '\u{2066}'..='\u{2069}')
        })
        .take(100)
        .collect()
}

pub(super) fn choose(executable: &Path, directory: &Path) -> Result<String> {
    ensure!(
        env::var_os("SSH_ORIGINAL_COMMAND").is_none()
            && io::stdin().is_terminal()
            && io::stderr().is_terminal(),
        "select a CodeMaker session in an interactive host terminal, or supply its session ID"
    );
    let bytes = output(
        executable,
        directory,
        &["--pure", "session", "list", "--format", "json"],
        MAX_LIST_BYTES,
        DEADLINE,
    )?;
    let sessions = candidates(&bytes, directory)?;
    ensure!(
        !sessions.is_empty(),
        "no CodeMaker session found in the pane directory"
    );
    eprintln!("CodeMaker sessions (most recently updated first)");
    for (index, session) in sessions.iter().take(MAX_CHOICES).enumerate() {
        let directory = session.directory.as_deref().map_or_else(
            || "directory unavailable".into(),
            |path| label(&path.to_string_lossy()),
        );
        eprintln!(
            "{:>2}  {}  {}  [{}]",
            index + 1,
            session.id,
            label(&session.title),
            directory
        );
    }
    if sessions.len() > MAX_CHOICES {
        eprintln!(
            "Showing the latest {MAX_CHOICES} sessions. Supply the session ID directly for an older session."
        );
    }
    eprint!("Session number: ");
    io::stderr().flush()?;
    let mut choice = String::new();
    io::stdin().lock().take(32).read_line(&mut choice)?;
    let number: usize = choice
        .trim()
        .parse()
        .map_err(|_| anyhow!("invalid session number"))?;
    ensure!(
        (1..=sessions.len().min(MAX_CHOICES)).contains(&number),
        "invalid session number"
    );
    Ok(sessions[number - 1].id.clone())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{fs, os::unix::fs::PermissionsExt, thread};

    #[test]
    fn picker_filters_by_directory_validates_ids_and_orders_by_update_time() {
        let list = br#"[
            {"id":"ses_old","directory":"/project","updated":1},
            {"id":"ses_neighbour","directory":"/neighbour","updated":4},
            {"id":"ses_new","directory":"/project","updated":3,"title":"new\n\u001b\u202etitle"},
            {"id":"--help","directory":"/project","updated":9}
        ]"#;
        let sessions = candidates(list, Path::new("/project")).unwrap();
        assert_eq!(
            sessions.iter().map(|s| s.id.as_str()).collect::<Vec<_>>(),
            ["ses_new", "ses_old"]
        );
        assert_eq!(label(&sessions[0].title), "newtitle");
    }

    #[test]
    fn capture_enforces_limit_and_deadline_even_when_a_descendant_keeps_stdout() {
        let directory = env::temp_dir().join(format!(
            "tmux-link-export-{:016x}",
            getrandom::u64().unwrap()
        ));
        fs::create_dir(&directory).unwrap();
        let executable = directory.join("codemaker");
        fs::write(
            &executable,
            r#"#!/bin/sh
case "$1" in
    exact) printf 1234 ;;
    excess) printf 12345; sleep 5 ;;
    descendant) (touch started; sleep 2; touch survived) & exit 0 ;;
esac
"#,
        )
        .unwrap();
        fs::set_permissions(&executable, fs::Permissions::from_mode(0o700)).unwrap();
        let run = |arg| {
            output(
                &executable,
                &directory,
                &[arg],
                4,
                if arg == "descendant" {
                    Duration::from_secs(1)
                } else {
                    DEADLINE
                },
            )
        };
        assert_eq!(run("exact").unwrap(), b"1234");
        assert!(
            run("excess")
                .unwrap_err()
                .to_string()
                .contains("size limit")
        );
        assert!(
            run("descendant")
                .unwrap_err()
                .to_string()
                .contains("timed out")
        );
        assert!(directory.join("started").exists());
        thread::sleep(Duration::from_millis(2100));
        assert!(!directory.join("survived").exists());
        fs::remove_dir_all(directory).unwrap();
    }
}
