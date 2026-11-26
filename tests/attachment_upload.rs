//! The same forced SSH exec entry point used by paired phones, on a private tmux server.
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::{
    fs,
    io::Write,
    os::unix::fs::{DirBuilderExt, PermissionsExt, symlink},
    path::{Path, PathBuf},
    process::{Child, Command, Output, Stdio},
    time::{Duration, Instant},
};

struct Session {
    root: PathBuf,
    work: PathBuf,
    instance: String,
    directory: String,
}

fn hex(name: &[u8]) -> String {
    name.iter().map(|b| format!("{b:02x}")).collect()
}

impl Session {
    fn new(label: &str) -> Self {
        let root = PathBuf::from(format!("/tmp/tlu-{}-{label}", std::process::id()));
        fs::DirBuilder::new().mode(0o700).create(&root).unwrap();
        let work = root.join("工作 space | (percent %)\t\nend");
        fs::create_dir(&work).unwrap();
        let mut fixture = Self {
            root,
            work: work.canonicalize().unwrap(),
            instance: String::new(),
            directory: String::new(),
        };
        let literal = fixture.work.to_str().unwrap();
        fixture.tmux(&[
            "new-session",
            "-c",
            literal,
            "-s",
            "upload",
            "-d",
            "/bin/sh",
        ]);
        let output = fixture.agent("tmux-link-list").output().unwrap();
        let listing = success(&output);
        let row = &listing[0];
        assert_eq!(row["id"], 0);
        assert_eq!(row["uploadVersion"], 1);
        fixture.instance = row["managedInstance"].as_str().unwrap().into();
        fixture.directory = row["directory"].as_str().unwrap().into();
        assert_eq!(Path::new(&fixture.directory), fixture.work);
        fixture
    }

    fn command(&self, exe: &str) -> Command {
        let mut cmd = Command::new(exe);
        cmd.env_remove("TMUX").env("TMUX_TMPDIR", &self.root);
        cmd
    }

    fn tmux(&self, args: &[&str]) -> String {
        let out = self
            .command("tmux")
            .args(["-u", "-f", "/dev/null"])
            .args(args)
            .output()
            .unwrap();
        assert!(
            out.status.success(),
            "tmux failed: {:?}",
            String::from_utf8_lossy(&out.stderr)
        );
        String::from_utf8(out.stdout).unwrap()
    }

    fn agent(&self, request: &str) -> Command {
        let mut cmd = self.command(env!("CARGO_BIN_EXE_agent"));
        cmd.arg("attach").env("SSH_ORIGINAL_COMMAND", request);
        cmd
    }

    fn request(&self, name: &[u8], count: usize) -> String {
        format!(
            "tmux-link-upload-v1 0 {} {:x} {} {}",
            self.instance,
            Sha256::digest(self.directory.as_bytes()),
            count,
            hex(name)
        )
    }

    fn start(&self, request: &str) -> Child {
        self.agent(request)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .unwrap()
    }

    fn upload(&self, req: &str, data: &[u8]) -> Output {
        let mut child = self.start(req);
        if !data.is_empty() {
            child.stdin.take().unwrap().write_all(data).unwrap();
        }
        child.wait_with_output().unwrap()
    }

    // Writing more than a pipe's capacity guarantees that the child has
    // validated the pane and started consuming its private staging stream.
    fn underway(&self, name: &[u8], byte: u8) -> Child {
        let mut child = self.start(&self.request(name, 2 * 1024 * 1024));
        child
            .stdin
            .as_mut()
            .unwrap()
            .write_all(&vec![byte; 2 * 1024 * 1024])
            .unwrap();
        child
    }

    fn assert_empty(&self) {
        assert_eq!(fs::read_dir(&self.work).unwrap().count(), 0);
    }
}

impl Drop for Session {
    fn drop(&mut self) {
        let _ = self.command("tmux").arg("kill-server").output();
        let _ = fs::remove_dir_all(&self.root);
    }
}

fn success(output: &Output) -> Value {
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    serde_json::from_slice(&output.stdout).unwrap()
}

fn failed(output: Output, marker: &str) {
    assert!(!output.status.success());
    assert!(output.stdout.is_empty());
    assert!(
        String::from_utf8_lossy(&output.stderr).lines().next()
            == Some(format!("Error: {marker}").as_str()),
        "expected {marker}, got {:?}",
        String::from_utf8_lossy(&output.stderr)
    );
}

#[test]
fn binary_filename_and_receipt_round_trip_no_clobber() {
    let s = Session::new("bytes");
    let name = "- 截图 🐈 \"\u{27} $(echo nope)%.bin";
    let payload = b"\0\n\x01\xff\r\x80tail";
    let req = s.request(name.as_bytes(), payload.len());
    let receipt = success(&s.upload(&req, payload));
    let dest = s.work.join(name);
    assert_eq!(receipt["path"], dest.to_str().unwrap());
    assert_eq!(receipt["bytes"], payload.len() as u64);
    assert_eq!(fs::read(&dest).unwrap(), payload);
    assert_eq!(
        fs::metadata(&dest).unwrap().permissions().mode() & 0o777,
        0o600
    );
    failed(
        s.upload(&s.request(name.as_bytes(), 0), b""),
        "upload exists",
    );
    assert_eq!(fs::read(&dest).unwrap(), payload);

    let empty = "zero";
    assert_eq!(
        success(&s.upload(&s.request(empty.as_bytes(), 0), b""))["bytes"],
        0
    );
    assert_eq!(fs::metadata(s.work.join(empty)).unwrap().len(), 0);

    for (target, link) in [("zero", "existing-link"), ("missing", "dangling")] {
        symlink(target, s.work.join(link)).unwrap();
        failed(
            s.upload(&s.request(link.as_bytes(), 0), b""),
            "upload exists",
        );
        assert_eq!(fs::read_link(s.work.join(link)).unwrap(), Path::new(target));
    }
}

#[test]
fn malformed_requests_and_bad_frames_leave_no_files() {
    let s = Session::new("frames");
    for bad in [
        b"" as &[u8],
        b"..",
        b".",
        b"x/y",
        b"x\\y",
        b"\n",
        b"nul\0",
        b"\xff",
        &[b'a'; 256],
    ] {
        failed(s.upload(&s.request(bad, 0), b""), "upload invalid");
    }
    failed(s.upload("tmux-link-upload-v1", b""), "upload invalid");
    let good = s.request(b"x", 0);
    failed(s.upload(&format!("{good} zz"), b""), "upload invalid");
    failed(
        s.upload(&good.replace(" 0 ", " +0 "), b""),
        "upload invalid",
    );
    failed(
        s.upload(&s.request(b"x", 134_217_729), b""),
        "upload invalid",
    );
    failed(
        s.upload(&s.request(b"x", 134_217_728), b""),
        "upload incomplete",
    );
    failed(s.upload(&s.request(b"x", 4), b"abc"), "upload incomplete");
    failed(s.upload(&s.request(b"x", 1), b"ab"), "upload incomplete");
    let other = good.replace(&s.instance, "1-1-%1-1");
    failed(s.upload(&other, b""), "upload target changed");
    let wrong_dir = good.replace(
        &format!("{:x}", Sha256::digest(s.directory.as_bytes())),
        &"0".repeat(64),
    );
    failed(s.upload(&wrong_dir, b""), "upload target changed");
    s.assert_empty();
}

#[test]
fn switching_directory_before_eof_cancels_commit() {
    let s = Session::new("move");
    let mut child = s.underway(b"later", 71);
    let next = s.root.join("next");
    fs::create_dir(&next).unwrap();
    let next = next.canonicalize().unwrap();
    s.tmux(&[
        "send-keys",
        "-t",
        "$0:",
        "-l",
        &format!("cd '{}'", next.display()),
    ]);
    s.tmux(&["send-keys", "-t", "$0:", "Enter"]);
    let deadline = Instant::now() + Duration::from_secs(5);
    while s
        .tmux(&["display-message", "-p", "-t", "$0:", "#{pane_current_path}"])
        .trim_end()
        != next.to_str().unwrap()
    {
        assert!(Instant::now() < deadline, "pane did not change directory");
        std::thread::sleep(Duration::from_millis(15));
    }
    drop(child.stdin.take());
    failed(child.wait_with_output().unwrap(), "upload target changed");
    s.assert_empty();
    assert_eq!(fs::read_dir(&next).unwrap().count(), 0);
}

#[test]
fn interrupted_and_racing_receivers_never_publish_partial_data() {
    let s = Session::new("race");
    let mut cancelled = s.underway(b"cancelled", 1);
    s.assert_empty();
    cancelled.kill().unwrap();
    assert!(!cancelled.wait().unwrap().success());
    s.assert_empty();

    let a = s.underway(b"same", 10);
    let b = s.underway(b"same", 20);
    s.assert_empty();
    // Both preflight checks succeeded. Only the first commit may create the name.
    success(&a.wait_with_output().unwrap());
    failed(b.wait_with_output().unwrap(), "upload exists");
    let contents = fs::read(s.work.join("same")).unwrap();
    assert_eq!(contents.len(), 2 * 1024 * 1024);
    assert!(contents.iter().all(|&b| b == 10));
    assert_eq!(fs::read_dir(&s.work).unwrap().count(), 1);
}
