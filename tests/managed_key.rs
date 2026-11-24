use std::{
    fs,
    io::Write,
    os::unix::fs::{DirBuilderExt, OpenOptionsExt},
    path::{Path, PathBuf},
    process::{Command, Stdio},
};

const OFFERED: &str = "synthetic-offered-model-credential";
const LEGACY: &str = "synthetic-legacy-model-credential";

struct TestHome(PathBuf);

impl TestHome {
    fn new() -> Self {
        let path = std::env::temp_dir().join(format!(
            "tmux-link-credential-test-{:016x}",
            getrandom::u64().unwrap()
        ));
        fs::DirBuilder::new().mode(0o700).create(&path).unwrap();
        Self(path)
    }

    fn key_path(&self) -> PathBuf {
        self.0.join(".config/tmux-link/managed/api-key")
    }
}

impl Drop for TestHome {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

fn try_retired_command(home: &Path) {
    let mut agent = Command::new(env!("CARGO_BIN_EXE_agent"))
        .env_clear()
        .env("HOME", home)
        .arg("managed-key")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    // An immediate rejection may close stdin before the parent writes the fixture.
    if let Err(error) = writeln!(agent.stdin.take().unwrap(), "{OFFERED}") {
        assert_eq!(error.kind(), std::io::ErrorKind::BrokenPipe);
    }
    let output = agent.wait_with_output().unwrap();
    assert!(!output.status.success(), "node still accepted managed-key");
    for stream in [&output.stdout, &output.stderr] {
        let text = String::from_utf8_lossy(stream);
        assert!(!text.contains(OFFERED) && !text.contains(LEGACY));
    }
}

#[test]
fn retired_managed_key_cannot_store_a_new_node_credential() {
    let home = TestHome::new();
    try_retired_command(&home.0);
    assert!(!home.key_path().try_exists().unwrap());
}

#[test]
fn retired_managed_key_cannot_replace_a_legacy_node_credential() {
    let home = TestHome::new();
    let key = home.key_path();
    fs::DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(key.parent().unwrap())
        .unwrap();
    fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(&key)
        .unwrap()
        .write_all(LEGACY.as_bytes())
        .unwrap();

    try_retired_command(&home.0);
    assert_eq!(fs::read(key).unwrap(), LEGACY.as_bytes());
}
