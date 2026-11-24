use crate::snapshot::transcript::{MAX_EXPORT_BYTES, Transcript, from_bytes, valid_id};
use anyhow::{Context, Result, anyhow, ensure};
use fs2::FileExt;
use serde::Deserialize;
use std::{
    cmp::Reverse,
    env,
    ffi::CString,
    fs::{self, File, OpenOptions},
    io::{self, BufRead, IsTerminal, Read, Write},
    os::unix::{
        ffi::OsStrExt,
        fs::{MetadataExt, OpenOptionsExt},
    },
    path::{Path, PathBuf},
    process::Stdio,
    time::Duration,
};
use tokio::{io::AsyncReadExt, process::Command, time::timeout};

const DEADLINE: Duration = Duration::from_secs(8);
const MAX_LIST_BYTES: usize = 4 * 1024 * 1024;
const MAX_CHOICES: usize = 50;

#[derive(Clone, Copy)]
enum Capture {
    Pipe,
    Export,
}

// The reader has a separate open-file description. The writer's flock then tracks
// every inherited copy of stdout, even if the launcher exits before its worker.
fn export_file() -> Result<(File, File)> {
    #[cfg(target_os = "linux")]
    {
        use std::os::{
            fd::{AsRawFd, FromRawFd},
            unix::fs::PermissionsExt,
        };
        // SAFETY: the syscall receives a static NUL-terminated name and returns an owned fd.
        let fd = unsafe {
            libc::syscall(
                libc::SYS_memfd_create,
                c"codemaker-export".as_ptr(),
                libc::MFD_CLOEXEC,
            )
        };
        if fd >= 0 {
            // SAFETY: ownership of the newly created fd is transferred exactly once.
            let writer = unsafe { File::from_raw_fd(fd as _) };
            writer.set_permissions(fs::Permissions::from_mode(0o600))?;
            if let Ok(reader) = File::open(format!("/proc/self/fd/{}", writer.as_raw_fd())) {
                return Ok((reader, writer));
            }
        }
    }
    // No output is written until the file is unlinked. create_new forbids
    // replacing an existing name and mode 0600 applies from the moment of creation.
    let nonce = getrandom::u64().map_err(|_| anyhow!("could not generate private output name"))?;
    let path = env::temp_dir().join(format!("tmux-link-export-{nonce:016x}"));
    let writer = OpenOptions::new()
        .create_new(true)
        .write(true)
        .mode(0o600)
        .open(&path)?;
    let reader = File::open(&path);
    fs::remove_file(&path)?;
    let reader = reader?;
    let meta = writer.metadata()?;
    let other = reader.metadata()?;
    ensure!(
        meta.nlink() == 0 && meta.ino() == other.ino() && meta.dev() == other.dev(),
        "could not secure CodeMaker output"
    );
    Ok((reader, writer))
}

fn limit_export(command: &mut Command, limit: usize) -> Result<()> {
    let mut size = libc::rlimit {
        rlim_cur: 0,
        rlim_max: 0,
    };
    // SAFETY: getrlimit initializes an owned rlimit structure.
    if unsafe { libc::getrlimit(libc::RLIMIT_FSIZE, &mut size) } != 0 {
        return Err(io::Error::last_os_error().into());
    }
    // The extra byte distinguishes an oversized write from a valid exact fit,
    // including when the exporting runtime ignores a short write.
    size.rlim_max = size.rlim_max.min((limit as libc::rlim_t).saturating_add(1));
    size.rlim_cur = size.rlim_cur.min(size.rlim_max);
    // SAFETY: only setrlimit and errno inspection run in the post-fork child.
    unsafe {
        command.pre_exec(move || {
            if libc::setrlimit(libc::RLIMIT_FSIZE, &size) == 0 {
                Ok(())
            } else {
                Err(io::Error::last_os_error())
            }
        })
    };
    Ok(())
}

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
        Capture::Export,
        MAX_EXPORT_BYTES,
        DEADLINE,
    )?;
    from_bytes(&bytes, id)
}

fn output(
    executable: &Path,
    directory: &Path,
    args: &[&str],
    capture: Capture,
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
        let mut command = Command::new(executable);
        command
            .args(args)
            .current_dir(directory)
            .env("PATH", path)
            .env("OPENCODE_DISABLE_AUTOUPDATE", "1")
            .env("OPENCODE_DISABLE_MODELS_FETCH", "1")
            .stdin(Stdio::null())
            .stderr(Stdio::null())
            .process_group(0)
            .kill_on_drop(true);
        let mut reader = match capture {
            Capture::Pipe => {
                command.stdout(Stdio::piped());
                None
            }
            Capture::Export => {
                let (reader, writer) = export_file()?;
                writer.lock_exclusive()?;
                command.stdout(Stdio::from(writer));
                limit_export(&mut command, limit)?;
                Some(reader)
            }
        };
        let mut child = command.spawn().context("could not launch CodeMaker")?;
        drop(command); // Close our copy of the writer passed to the child.
        let pid = child.id().context("missing CodeMaker process ID")? as libc::pid_t;
        let mut bytes = Vec::new();
        let result = timeout(deadline, async {
            if let Some(file) = &reader {
                loop {
                    ensure!(
                        file.metadata()?.len() <= limit as u64,
                        "CodeMaker output exceeds the size limit"
                    );
                    match FileExt::try_lock_shared(file) {
                        Ok(()) => break,
                        Err(err) if err.kind() == io::ErrorKind::WouldBlock => {
                            tokio::time::sleep(Duration::from_millis(15)).await
                        }
                        Err(err) => return Err(err.into()),
                    }
                }
            } else {
                let stdout = child.stdout.take().context("missing CodeMaker output")?;
                stdout
                    .take(limit as u64 + 1)
                    .read_to_end(&mut bytes)
                    .await?;
                ensure!(
                    bytes.len() <= limit,
                    "CodeMaker output exceeds the size limit"
                );
            }
            Ok(child.wait().await?)
        })
        .await;
        let error = match result {
            Ok(Ok(status)) => {
                ensure!(status.success(), "CodeMaker command failed");
                if let Some(file) = reader.take() {
                    file.take(limit as u64 + 1).read_to_end(&mut bytes)?;
                    ensure!(
                        bytes.len() <= limit,
                        "CodeMaker output exceeds the size limit"
                    );
                }
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
        Capture::Pipe,
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
                Capture::Pipe,
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

    #[test]
    fn export_uses_an_unlinked_regular_file_and_waits_for_all_writers() {
        let directory = env::temp_dir().join(format!(
            "tmux-link-export-test-{:016x}",
            getrandom::u64().unwrap()
        ));
        fs::create_dir(&directory).unwrap();
        let executable = directory.join("codemaker");
        fs::write(&executable, r#"#!/usr/bin/env python3
import os, resource, stat, sys, time
fd = os.fstat(1)
assert stat.S_ISREG(fd.st_mode) and fd.st_nlink == 0 and fd.st_mode & 0o077 == 0
action = sys.argv[-1]
if action in ("exact", "excess"):
    assert resource.getrlimit(resource.RLIMIT_FSIZE) == (5, 5)
    os.write(1, b"1234" if action == "exact" else b"123456")
elif action == "descendant":
    if os.fork() == 0:
        open("started", "w").close()
        time.sleep(1.2)
        open("survived", "w").close()
elif action == "ses_large":
    if os.fork() == 0:
        time.sleep(0.05)
        # Reproduce a CLI which queues one large nonblocking write and exits immediately.
        os.set_blocking(1, False)
        os.write(1, b'{"unused":"' + b'x' * (7 * 1024 * 1024) + b'","info":{"id":"ses_large"},"messages":[]}')
elif action == "ses_blank":
    os.write(1, b"  \n")
elif action == "ses_bad":
    os.write(1, b'{"info":{"id":"ses_bad"},"messages":[]')
elif action == "ses_failed":
    os.write(1, b'{"info":{"id":"ses_failed"},"messages":[]}')
    os._exit(2)
os._exit(0)
"#).unwrap();
        fs::set_permissions(&executable, fs::Permissions::from_mode(0o700)).unwrap();
        assert!(read(&executable, &directory, "ses_large").is_ok());
        for id in ["ses_blank", "ses_bad", "ses_failed"] {
            assert!(
                read(&executable, &directory, id).is_err(),
                "{id} was accepted"
            );
        }
        let run =
            |arg: &str, time| output(&executable, &directory, &[arg], Capture::Export, 4, time);
        assert_eq!(run("exact", DEADLINE).unwrap(), b"1234");
        assert!(
            run("excess", DEADLINE)
                .unwrap_err()
                .to_string()
                .contains("size limit")
        );
        assert!(
            run("descendant", Duration::from_millis(600))
                .unwrap_err()
                .to_string()
                .contains("timed out")
        );
        assert!(directory.join("started").exists());
        thread::sleep(Duration::from_millis(1250));
        assert!(!directory.join("survived").exists());
        fs::remove_dir_all(directory).unwrap();
    }
}
