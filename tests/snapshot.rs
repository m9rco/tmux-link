//! Exercise the phone's forced command against a disposable tmux server and real PTYs.
use serde_json::Value;
use std::{
    fs,
    os::unix::fs::DirBuilderExt,
    path::PathBuf,
    process::{Command, Output},
    thread::sleep,
    time::{Duration, Instant},
};

struct Server(PathBuf);
impl Server {
    fn cmd(&self, program: &str) -> Command {
        let mut cmd = Command::new(program);
        cmd.env_remove("TMUX").env("TMUX_TMPDIR", &self.0);
        cmd
    }

    fn tmux(&self, args: &[&str]) -> String {
        let out = self
            .cmd("tmux")
            .args(["-u", "-f", "/dev/null"])
            .args(args)
            .output()
            .unwrap();
        assert!(
            out.status.success(),
            "tmux {:?}: {}",
            args,
            String::from_utf8_lossy(&out.stderr)
        );
        String::from_utf8(out.stdout).unwrap()
    }

    fn request(&self, command: &str) -> Output {
        self.cmd(env!("CARGO_BIN_EXE_agent"))
            .arg("attach")
            .env("SSH_ORIGINAL_COMMAND", command)
            .output()
            .unwrap()
    }

    fn json(&self, command: &str) -> Value {
        let out = self.request(command);
        assert!(
            out.status.success(),
            "{}",
            String::from_utf8_lossy(&out.stderr)
        );
        serde_json::from_slice(&out.stdout).unwrap()
    }

    fn wait_for(&self, target: &str, marker: &str) {
        let deadline = Instant::now() + Duration::from_secs(5);
        while !self
            .tmux(&["capture-pane", "-p", "-t", target])
            .contains(marker)
        {
            assert!(Instant::now() < deadline, "fixture not ready");
            sleep(Duration::from_millis(20));
        }
    }
}
impl Drop for Server {
    fn drop(&mut self) {
        let _ = self.cmd("tmux").arg("kill-server").output();
        let _ = fs::remove_dir_all(&self.0);
    }
}

#[test]
fn selected_pane_snapshot_separates_history_preserves_grid_and_never_attaches() {
    let path = PathBuf::from(format!("/tmp/tmux-link-snapshot-{}", std::process::id()));
    fs::DirBuilder::new().mode(0o700).create(&path).unwrap();
    let server = Server(path);
    server.tmux(&["new-session", "-d", "-x", "90", "-y", "12", "-s", "chosen task",
        "sh", "-c", r#"i=0; while [ "$i" -lt 145 ]; do echo "earlier-row=$i"; i=$((i+1)); done
        printf 'Decision needed\n1) prepare release\n2) wait for review\n\033[8mconcealed-marker\033[28mVisible prompt? '
        IFS= read -r response; echo "received:$response"; sleep 60"#]);
    server.tmux(&[
        "new-session",
        "-d",
        "-x",
        "80",
        "-y",
        "55",
        "-s",
        "other task",
        "sh",
        "-c",
        "echo unrelated-content; tput smcup; tput clear; echo alternate-only; sleep 60",
    ]);
    server.wait_for("$0:", "Visible prompt?");
    server.wait_for("$1:", "alternate-only");

    let state = || {
        server.tmux(&["display-message", "-p", "-t", "$0:",
        "#{session_attached} #{pane_width} #{pane_height} #{cursor_x} #{cursor_y} #{pane_in_mode} #{pane_id} #{pane_pid}"])
    };
    let before = state();
    let screen = server.tmux(&["capture-pane", "-e", "-p", "-t", "$0:"]);
    server.tmux(&["set-buffer", "untouched"]);
    let list = server.json("tmux-link-list");
    assert_eq!(list.as_array().unwrap().len(), 2);
    assert!(
        list.as_array()
            .unwrap()
            .iter()
            .all(|s| s["snapshot"] == true
                && s.get("text").is_none()
                && s.get("context").is_none())
    );
    assert!(!list.to_string().contains("Decision needed"));

    let current = server.json("tmux-link-snapshot 0");
    assert_eq!(current["name"], "chosen task");
    assert_eq!(current["id"], 0);
    let text = current["text"].as_str().unwrap();
    assert!(text.contains("Decision needed\n1) prepare release\n2) wait for review"));
    assert!(text.contains("Visible prompt?"));
    let history = current["context"].as_str().unwrap();
    assert!(history.contains("earlier-row=110"));
    assert_eq!(history.lines().count(), 120);
    assert!(!history.contains("earlier-row=1\n") && !text.contains("earlier-row=110"));
    assert!(!history.contains("Decision needed"));
    for marker in [
        "concealed-marker",
        "received:",
        "alternate-only",
        "unrelated-content",
    ] {
        assert!(!current.to_string().contains(marker), "{marker} leaked");
    }
    assert_eq!(state(), before);
    assert_eq!(
        server.tmux(&["capture-pane", "-e", "-p", "-t", "$0:"]),
        screen
    );
    assert_eq!(server.tmux(&["show-buffer"]), "untouched");
    assert!(server.tmux(&["list-clients"]).is_empty());

    let alt = server.json("tmux-link-snapshot 1");
    assert_eq!(alt["text"], "alternate-only");
    assert_eq!(alt["id"], 1);
    assert!(alt["context"].is_null());
    assert!(!alt.to_string().contains("unrelated-content"));
    server.tmux(&["copy-mode", "-t", "$0:"]);
    let copy = server.request("tmux-link-snapshot 0");
    assert!(!copy.status.success() && copy.stdout.is_empty());
    assert!(String::from_utf8_lossy(&copy.stderr).contains("snapshot pane in mode"));
    for invalid in [
        "7",
        "0 extra",
        "+0",
        "0;list-sessions",
        "-1",
        "18446744073709551616",
    ] {
        let result = server.request(&format!("tmux-link-snapshot {invalid}"));
        assert!(!result.status.success() && result.stdout.is_empty());
    }
}
