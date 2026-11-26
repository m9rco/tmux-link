//! Receive one bounded SSH exec body into the selected live pane's directory.
use anyhow::{Context, Result, ensure};
use serde_json::json;
use sha2::{Digest, Sha256};
use std::{
    ffi::{CStr, CString},
    fs::{File, OpenOptions},
    io::{self, Read, Seek, Write},
    os::{
        fd::{AsRawFd, FromRawFd},
        unix::fs::{MetadataExt, OpenOptionsExt},
    },
    path::Path,
    process::Command,
};

const MAX_BYTES: u64 = 128 * 1024 * 1024;
const INVALID: &str = "upload invalid";
const CHANGED: &str = "upload target changed";
const UNAVAILABLE: &str = "upload unavailable";
const INCOMPLETE: &str = "upload incomplete";
const EXISTS: &str = "upload exists";

struct Request<'a> {
    session: u64,
    instance: &'a str,
    directory_digest: &'a str,
    bytes: u64,
    name: String,
}

fn decimal(s: &str) -> Result<u64> {
    ensure!(
        !s.is_empty() && s.bytes().all(|c| c.is_ascii_digit()),
        INVALID
    );
    s.parse().context(INVALID)
}

impl<'a> Request<'a> {
    fn parse(command: &'a str) -> Result<Self> {
        let mut words = command.split(' ').skip(1);
        let session = decimal(words.next().context(INVALID)?)?;
        let instance = words.next().context(INVALID)?;
        ensure!(tmux_link::valid_managed_instance(instance), INVALID);
        let directory_digest = words.next().context(INVALID)?;
        ensure!(
            directory_digest.len() == 64
                && directory_digest
                    .bytes()
                    .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b)),
            INVALID
        );
        let bytes = decimal(words.next().context(INVALID)?)?;
        ensure!(bytes <= MAX_BYTES, INVALID);
        let hex = words.next().context(INVALID)?;
        ensure!(
            words.next().is_none()
                && (2..=510).contains(&hex.len())
                && hex.len().is_multiple_of(2)
                && hex.bytes().all(|b| b.is_ascii_hexdigit()),
            INVALID
        );
        let raw = (0..hex.len())
            .step_by(2)
            .map(|i| u8::from_str_radix(&hex[i..i + 2], 16))
            .collect::<std::result::Result<Vec<_>, _>>()
            .context(INVALID)?;
        let name = String::from_utf8(raw).context(INVALID)?;
        ensure!(
            name != "."
                && name != ".."
                && !name
                    .chars()
                    .any(|c| c.is_control() || c == '/' || c == '\\'),
            INVALID
        );
        Ok(Self {
            session,
            instance,
            directory_digest,
            bytes,
            name,
        })
    }

    fn target(&self) -> Result<(String, File)> {
        let session = format!("${}", self.session);
        let output = Command::new("tmux")
            .args(["-u", "display-message", "-p", "-t", &format!("{session}:"),
                "#{session_id}\n#{pid}-#{session_created}-#{pane_id}-#{pane_pid}\n#{pane_dead}\n#{pane_current_path}"])
            .output().context(UNAVAILABLE)?;
        ensure!(output.status.success(), CHANGED);
        let record = std::str::from_utf8(&output.stdout)
            .context(CHANGED)?
            .strip_suffix('\n')
            .context(CHANGED)?;
        let mut fields = record.splitn(4, '\n');
        ensure!(
            fields.next() == Some(&session)
                && fields.next() == Some(self.instance)
                && fields.next() == Some("0"),
            CHANGED
        );
        let path = fields.next().context(CHANGED)?;
        ensure!(
            path.starts_with('/')
                && format!("{:x}", Sha256::digest(path.as_bytes())) == self.directory_digest,
            CHANGED
        );
        let directory = OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC)
            .open(path)
            .context(UNAVAILABLE)?;
        Ok((path.to_owned(), directory))
    }

    fn revalidate(&self, directory: &File) -> Result<()> {
        let (_, current) = self.target().context(CHANGED)?;
        let current = current.metadata().context(UNAVAILABLE)?;
        let pinned = directory.metadata().context(UNAVAILABLE)?;
        ensure!(
            current.dev() == pinned.dev() && current.ino() == pinned.ino(),
            CHANGED
        );
        Ok(())
    }
}

fn open_at(dir: &File, name: &CStr, flags: i32) -> io::Result<File> {
    let fd = unsafe {
        libc::openat(
            dir.as_raw_fd(),
            name.as_ptr(),
            flags | libc::O_CLOEXEC | libc::O_NOFOLLOW,
            0o600 as libc::c_uint,
        )
    };
    if fd < 0 {
        Err(io::Error::last_os_error())
    } else {
        Ok(unsafe { File::from_raw_fd(fd) })
    }
}

fn unlink_at(dir: &File, name: &CStr, flags: i32) -> io::Result<()> {
    if unsafe { libc::unlinkat(dir.as_raw_fd(), name.as_ptr(), flags) } == 0 {
        Ok(())
    } else {
        Err(io::Error::last_os_error())
    }
}

fn temporary_name() -> Result<CString> {
    let nonce = getrandom::u64().map_err(|_| anyhow::anyhow!(UNAVAILABLE))?;
    Ok(CString::new(format!(".tmux-link-{nonce:016x}.part"))?)
}

// The OS releases the unlinked file even if the SSH peer disappears or the
// process is killed before receiving EOF. No partially uploaded name is visible.
fn spool(dir: &File) -> Result<File> {
    #[cfg(target_os = "linux")]
    if let Ok(file) = open_at(dir, c".", libc::O_TMPFILE | libc::O_RDWR) {
        return Ok(file);
    }
    let temp = temporary_name()?;
    let file =
        open_at(dir, &temp, libc::O_CREAT | libc::O_EXCL | libc::O_RDWR).context(UNAVAILABLE)?;
    unlink_at(dir, &temp, 0).context(UNAVAILABLE)?;
    ensure!(
        file.metadata().context(UNAVAILABLE)?.nlink() == 0,
        UNAVAILABLE
    );
    Ok(file)
}

fn check_absent(dir: &File, name: &CStr) -> Result<()> {
    let mut stat = std::mem::MaybeUninit::<libc::stat>::uninit();
    let status = unsafe {
        libc::fstatat(
            dir.as_raw_fd(),
            name.as_ptr(),
            stat.as_mut_ptr(),
            libc::AT_SYMLINK_NOFOLLOW,
        )
    };
    ensure!(status < 0, EXISTS);
    let err = io::Error::last_os_error();
    ensure!(err.kind() == io::ErrorKind::NotFound, UNAVAILABLE);
    Ok(())
}

fn receive_body(file: &mut File, bytes: u64) -> Result<()> {
    let mut input = io::stdin().lock();
    let mut buf = [0u8; 64 * 1024];
    let mut remaining = bytes;
    while remaining > 0 {
        let size = remaining.min(buf.len() as u64) as usize;
        input.read_exact(&mut buf[..size]).context(INCOMPLETE)?;
        file.write_all(&buf[..size]).context(UNAVAILABLE)?;
        remaining -= size as u64;
    }
    let mut trailer = [0u8; 1];
    let n = loop {
        match input.read(&mut trailer) {
            Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
            other => break other.context(INCOMPLETE)?,
        }
    };
    ensure!(n == 0, INCOMPLETE);
    file.sync_all().context(UNAVAILABLE)
}

#[cfg(target_os = "linux")]
fn publish_spool(file: &File, dir: &File, name: &CStr) -> io::Result<()> {
    let rc = unsafe {
        libc::linkat(
            file.as_raw_fd(),
            c"".as_ptr(),
            dir.as_raw_fd(),
            name.as_ptr(),
            libc::AT_EMPTY_PATH,
        )
    };
    if rc == 0 {
        return Ok(());
    }
    let error = io::Error::last_os_error();
    if error.kind() == io::ErrorKind::AlreadyExists {
        return Err(error);
    }
    // Unprivileged users on older kernels need the procfs spelling for O_TMPFILE.
    let source = CString::new(format!("/proc/self/fd/{}", file.as_raw_fd()))?;
    let rc = unsafe {
        libc::linkat(
            libc::AT_FDCWD,
            source.as_ptr(),
            dir.as_raw_fd(),
            name.as_ptr(),
            libc::AT_SYMLINK_FOLLOW,
        )
    };
    if rc == 0 {
        Ok(())
    } else {
        Err(io::Error::last_os_error())
    }
}

#[cfg(target_os = "macos")]
fn publish_spool(file: &File, dir: &File, name: &CStr) -> io::Result<()> {
    if unsafe { libc::fclonefileat(file.as_raw_fd(), dir.as_raw_fd(), name.as_ptr(), 0) } == 0 {
        Ok(())
    } else {
        Err(io::Error::last_os_error())
    }
}

// Filesystems without linkable anonymous files or APFS cloning need a named
// inode only during finalization. Keep it inside a private, pinned directory.
struct Stage<'a> {
    parent: &'a File,
    name: CString,
    dir: File,
}
impl Drop for Stage<'_> {
    fn drop(&mut self) {
        let _ = unlink_at(&self.dir, c"payload", 0);
        let _ = unlink_at(self.parent, &self.name, libc::AT_REMOVEDIR);
    }
}
impl<'a> Stage<'a> {
    fn new(parent: &'a File) -> Result<Self> {
        let name = temporary_name()?;
        ensure!(
            unsafe { libc::mkdirat(parent.as_raw_fd(), name.as_ptr(), 0o700) } == 0,
            UNAVAILABLE
        );
        match open_at(parent, &name, libc::O_RDONLY | libc::O_DIRECTORY) {
            Ok(dir) => {
                let private = dir.metadata().context(UNAVAILABLE)?;
                ensure!(private.uid() == unsafe { libc::geteuid() }, UNAVAILABLE);
                if private.mode() & 0o077 != 0 {
                    let _ = unlink_at(parent, &name, libc::AT_REMOVEDIR);
                    anyhow::bail!(UNAVAILABLE);
                }
                Ok(Self { parent, name, dir })
            }
            Err(e) => {
                let _ = unlink_at(parent, &name, libc::AT_REMOVEDIR);
                Err(e).context(UNAVAILABLE)
            }
        }
    }
}

fn publish(file: &mut File, directory: &File, dest: &CStr, req: &Request<'_>) -> Result<()> {
    req.revalidate(directory)?;
    match publish_spool(file, directory, dest) {
        Ok(()) => return Ok(()),
        Err(e) if e.kind() == io::ErrorKind::AlreadyExists => anyhow::bail!(EXISTS),
        Err(_) => {}
    }
    let stage = Stage::new(directory)?;
    let mut pending = open_at(
        &stage.dir,
        c"payload",
        libc::O_CREAT | libc::O_EXCL | libc::O_WRONLY,
    )
    .context(UNAVAILABLE)?;
    file.rewind().context(UNAVAILABLE)?;
    io::copy(file, &mut pending).context(UNAVAILABLE)?;
    pending.sync_all().context(UNAVAILABLE)?;
    req.revalidate(directory)?;
    // Some mounts (including FAT) support exclusive rename but not hard links.
    #[cfg(target_os = "linux")]
    let rc = unsafe {
        libc::syscall(
            libc::SYS_renameat2,
            stage.dir.as_raw_fd(),
            c"payload".as_ptr(),
            directory.as_raw_fd(),
            dest.as_ptr(),
            libc::RENAME_NOREPLACE,
        )
    };
    #[cfg(target_os = "macos")]
    let rc = unsafe {
        libc::renameatx_np(
            stage.dir.as_raw_fd(),
            c"payload".as_ptr(),
            directory.as_raw_fd(),
            dest.as_ptr(),
            libc::RENAME_EXCL,
        )
    };
    if rc == 0 {
        return Ok(());
    }
    let error = io::Error::last_os_error();
    ensure!(error.kind() != io::ErrorKind::AlreadyExists, EXISTS);
    if !error.raw_os_error().is_some_and(|code| {
        [libc::ENOSYS, libc::EINVAL, libc::ENOTSUP, libc::EOPNOTSUPP].contains(&code)
    }) {
        return Err(error).context(UNAVAILABLE);
    }
    req.revalidate(directory)?;
    let rc = unsafe {
        libc::linkat(
            stage.dir.as_raw_fd(),
            c"payload".as_ptr(),
            directory.as_raw_fd(),
            dest.as_ptr(),
            0,
        )
    };
    if rc != 0 {
        let e = io::Error::last_os_error();
        ensure!(e.kind() != io::ErrorKind::AlreadyExists, EXISTS);
        return Err(e).context(UNAVAILABLE);
    }
    Ok(())
}

pub(super) fn receive(command: &str) -> Result<()> {
    let request = Request::parse(command)?;
    let name = CString::new(request.name.as_bytes()).context(INVALID)?;
    let (path, directory) = request.target()?;
    check_absent(&directory, &name)?;
    let mut file = spool(&directory)?;
    receive_body(&mut file, request.bytes)?;
    publish(&mut file, &directory, &name, &request)?;
    println!(
        "{}",
        json!({"path": Path::new(&path).join(&request.name), "bytes": request.bytes})
    );
    Ok(())
}
