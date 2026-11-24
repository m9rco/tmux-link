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
    fn new(case: &str) -> Self {
        let path = PathBuf::from(format!(
            "/tmp/tmux-link-snapshot-{}-{case}",
            std::process::id()
        ));
        fs::DirBuilder::new().mode(0o700).create(&path).unwrap();
        Self(path)
    }

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

    fn session(&self, name: &str, columns: &str, rows: &str, script: &str) {
        self.tmux(&[
            "new-session",
            "-d",
            "-x",
            columns,
            "-y",
            rows,
            "-s",
            name,
            "sh",
            "-c",
            script,
        ]);
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
    let server = Server::new("selected");
    server.session("chosen task", "90", "12", r#"echo 'Goal: review the distribution plan.'
        i=0; while [ "$i" -lt 145 ]; do echo "earlier-row=$i"; i=$((i+1)); done
        printf 'Decision needed\n1) prepare release\n2) wait for review\n\033[8mconcealed-marker\033[28mVisible prompt? '
        IFS= read -r response; echo "received:$response"; sleep 60"#);
    server.session(
        "other task",
        "80",
        "55",
        "echo unrelated-content; tput smcup; tput clear; echo alternate-only; sleep 60",
    );
    server.tmux(&[
        "split-window",
        "-dh",
        "-t",
        "$0:",
        "sh",
        "-c",
        "echo sibling-pane; exec sleep 60",
    ]);
    server.wait_for("%2", "sibling-pane");
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
                && s["snapshotVersion"] == 2
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
        "sibling-pane",
        "alternate-only",
        "unrelated-content",
    ] {
        assert!(!current.to_string().contains(marker), "{marker} leaked");
    }
    let detailed = server.json("tmux-link-snapshot-v2 0");
    assert_eq!(detailed["text"].as_str().unwrap().trim_end(), text);
    assert!(
        detailed["context"]
            .as_str()
            .unwrap()
            .contains("Goal: review the distribution plan.")
    );
    assert!(!detailed.to_string().contains("concealed-marker"));
    assert!(!detailed.to_string().contains("received:"));
    assert!(!detailed.to_string().contains("sibling-pane"));
    assert_eq!(state(), before);
    assert_eq!(
        server.tmux(&["capture-pane", "-e", "-p", "-t", "$0:"]),
        screen
    );
    assert_eq!(server.tmux(&["show-buffer"]), "untouched");
    assert!(server.tmux(&["list-clients"]).is_empty());
    server.tmux(&["select-pane", "-t", "%2"]);
    let sibling = server.json("tmux-link-snapshot-v2 0");
    assert_eq!(sibling["id"], 0);
    assert_eq!(sibling["paneId"], 2);
    assert_eq!(sibling["text"], "sibling-pane");

    let alt = server.json("tmux-link-snapshot 1");
    assert_eq!(alt["text"], "alternate-only");
    assert_eq!(alt["id"], 1);
    assert!(alt["context"].is_null());
    assert!(!alt.to_string().contains("unrelated-content"));
    let alt = server.json("tmux-link-snapshot-v2 1");
    assert_eq!(alt["alternate"], true);
    assert_eq!(alt["text"], "alternate-only");
    assert_eq!(alt["context"], Value::Null);
    assert_eq!(alt["historyRowsScanned"], 0);
    assert_eq!(alt["historyCompacted"], false);
    assert_eq!(alt["historyTruncated"], false);
    assert!(!alt.to_string().contains("unrelated-content"));
    for command in ["tmux-link-snapshot", "tmux-link-snapshot-v2"] {
        for invalid in [
            "7",
            "0 extra",
            "+0",
            "0;list-sessions",
            "-1",
            "18446744073709551616",
        ] {
            let result = server.request(&format!("{command} {invalid}"));
            assert!(!result.status.success() && result.stdout.is_empty());
        }
    }
    server.tmux(&["copy-mode", "-t", "$0:"]);
    for command in ["tmux-link-snapshot", "tmux-link-snapshot-v2"] {
        let copy = server.request(&format!("{command} 0"));
        assert!(!copy.status.success() && copy.stdout.is_empty());
        assert!(String::from_utf8_lossy(&copy.stderr).contains("snapshot pane in mode"));
    }
}

#[test]
fn detailed_snapshot_joins_soft_wraps_and_preserves_hard_breaks_and_menu_rows() {
    let server = Server::new("wrap");
    server.session(
        "menu",
        "48",
        "60",
        r#"printf '%048d%s\n' 1 'archive continuation'
        i=0; while [ "$i" -lt 160 ]; do printf 'archive-%03d\n' "$i"; i=$((i+1)); done
        i=0; while [ "$i" -lt 48 ]; do printf 'option-%02d)  description\n' "$i"; i=$((i+1)); done
        printf '%048d%s\n' 2 'soft continuation'
        printf '%048d\n%s\n' 3 '  hard break'
        printf '%045d\033[8mXYZSECRET-AFTER-WRAP\033[28m  shown\n' 4
        printf 'Choose an option'; exec sleep 60"#,
    );
    server.wait_for("$0:", "Choose an option");
    let legacy = server.json("tmux-link-snapshot 0");
    assert!(!legacy["text"].as_str().unwrap().contains("option-00)"));
    assert!(!legacy["context"].as_str().unwrap().contains("archive-000"));

    let detailed = server.json("tmux-link-snapshot-v2 0");
    assert_eq!(detailed["version"], 2);
    assert_eq!(detailed["id"], 0);
    assert_eq!(detailed["name"], "menu");
    assert_eq!(detailed["paneId"], 0);
    assert_eq!(detailed["columns"], 48);
    assert_eq!(detailed["rows"], 60);
    assert_eq!(detailed["alternate"], false);
    assert_eq!(detailed["screenTruncated"], false);
    assert_eq!(detailed["historyTruncated"], false);
    let text = detailed["text"].as_str().unwrap();
    let history = detailed["context"].as_str().unwrap();
    assert!(history.contains(&format!("{:048}archive continuation", 1)));
    assert!(text.contains("option-00)  description\noption-01)"));
    assert!(text.contains(&format!(
        "{:048}soft continuation\n{:048}\n  hard break",
        2, 3
    )));
    assert!(text.contains("  shown\nChoose an option"));
    assert!(!history.contains("option-00)") && !history.contains("Choose an option"));
    for secret in ["XYZ", "SECRET", "AFTER-WRAP", "\x1b"] {
        assert!(!text.contains(secret), "{secret:?} leaked");
    }
}

#[test]
fn wrap_at_viewport_edge_keeps_each_half_on_its_own_side() {
    let server = Server::new("edge");
    server.session(
        "boundary",
        "32",
        "6",
        r#"printf 'HISTORY-%020d\033[8mMASKSECRET\033[28mVISIBLE-CONTINUATION\n' 1
        printf 'second\nthird\nfourth\nfifth\nEDGE-READY'; exec sleep 60"#,
    );
    server.wait_for("$0:", "EDGE-READY");
    let detailed = server.json("tmux-link-snapshot-v2 0");
    assert_eq!(
        detailed["context"].as_str().unwrap().trim_end(),
        format!("HISTORY-{:020}", 1)
    );
    assert_eq!(
        detailed["text"],
        "      VISIBLE-CONTINUATION\nsecond\nthird\nfourth\nfifth\nEDGE-READY"
    );
    assert_eq!(detailed["screenTruncated"], false);
    assert_eq!(detailed["historyRowsScanned"], 1);
    assert_eq!(detailed["historyCompacted"], false);
    assert_eq!(detailed["historyTruncated"], false);

    server.tmux(&["clear-history", "-t", "$0:"]);
    let cleared = server.json("tmux-link-snapshot-v2 0");
    assert_eq!(cleared["text"], detailed["text"]);
    assert_eq!(cleared.get("context"), Some(&Value::Null));
    assert_eq!(cleared["historyRowsScanned"], 0);
    assert_eq!(cleared["historyCompacted"], false);
    assert_eq!(cleared["historyTruncated"], false);
}

#[test]
fn v2_flags_row_and_byte_limits_independently_and_keeps_newest_output() {
    let server = Server::new("bounds");
    for (name, columns, rows, script) in [
        (
            "lines",
            "40",
            "262",
            r#"i=0; while [ "$i" -lt 600 ]; do printf 'row-%03d\n' "$i"; i=$((i+1)); done
         printf 'ROW-READY'; exec sleep 60"#,
        ),
        (
            "bytes",
            "220",
            "190",
            r#"i=0; while [ "$i" -lt 359 ]; do printf 'row-%03d-%0200d\n' "$i" 0; i=$((i+1)); done
         printf 'BYTE-READY'; exec sleep 60"#,
        ),
    ] {
        server.session(name, columns, rows, script);
    }
    server.wait_for("$0:", "ROW-READY");
    server.wait_for("$1:", "BYTE-READY");
    let lines = server.json("tmux-link-snapshot-v2 0");
    let text = lines["text"].as_str().unwrap();
    let history = lines["context"].as_str().unwrap();
    assert_eq!(lines["screenTruncated"], true);
    assert_eq!(lines["historyRowsScanned"], 339);
    assert_eq!(lines["historyCompacted"], true);
    assert_eq!(lines["historyTruncated"], false);
    assert_eq!(text.lines().count(), 256);
    assert!(history.lines().count() <= 320);
    assert!(text.starts_with("row-345\n") && text.ends_with("row-599\nROW-READY"));
    assert!(history.ends_with("row-338"));

    let bytes = server.json("tmux-link-snapshot-v2 1");
    assert_eq!(bytes["screenTruncated"], true);
    assert_eq!(bytes["historyRowsScanned"], 170);
    assert_eq!(bytes["historyCompacted"], true);
    assert_eq!(bytes["historyTruncated"], false);
    let screen = bytes["text"].as_str().unwrap();
    let history = bytes["context"].as_str().unwrap();
    assert!((30 * 1024..=32 * 1024).contains(&screen.len()));
    assert!(screen.ends_with("BYTE-READY"));
    assert!(history.len() <= 32 * 1024);
    assert!(history.lines().last().unwrap().starts_with("row-169-"));

    server.tmux(&["resize-window", "-t", "$0:", "-y", "30"]);
    let shorter = server.json("tmux-link-snapshot-v2 0");
    assert_eq!(shorter["screenTruncated"], false);
    assert_eq!(shorter["historyCompacted"], true);
    assert_eq!(shorter["historyTruncated"], false);
    server.tmux(&["clear-history", "-t", "$1:"]);
    let cleared = server.json("tmux-link-snapshot-v2 1");
    assert_eq!(cleared["screenTruncated"], true);
    assert_eq!(cleared["historyCompacted"], false);
    assert_eq!(cleared["historyTruncated"], false);
}

#[test]
fn scans_five_thousand_history_rows_and_compacts_decision_evidence_on_the_host() {
    let server = Server::new("scan");
    // tmux applies history-limit when it creates the pane.
    server.session("setup", "80", "6", "exec sleep 60");
    server.tmux(&["set-option", "-g", "history-limit", "7000"]);
    server.session(
        "inspection",
        "96",
        "6",
        r#"awk 'BEGIN {
        for (i = 0; i < 5350; i++) {
            if (i == 10) print "Constraint: OUTSIDE-SCAN green trays only."
            else if (i == 530) print "Goal: reconstruct the blue tray inventory."
            else if (i == 610) print "Constraint: the original lot labels must stay attached."
            else if (i == 690) print "Error: calibration failed on shelf nine."
            else if (i == 5349) print "Leah set aside the sample from the last carton."
            else if (i % 4 == 0) printf "progress: batch %d of 5350\n", i
            else if (i % 4 == 1) printf "[INFO] heartbeat job=%d\n", i
            else if (i % 4 == 2) print "worker queue unchanged"
            else print "waiting for the next batch"
        }
    }'
    printf 'Inspect tray\nindigo\ngreen\nwhite\nChoose one\nSCAN-READY'; exec sleep 60"#,
    );
    server.wait_for("$1:", "SCAN-READY");
    let actual_history = server.tmux(&["display-message", "-p", "-t", "$1:", "#{history_size}"]);
    assert_eq!(actual_history.trim(), "5350");

    let snapshot = server.json("tmux-link-snapshot-v2 1");
    assert_eq!(snapshot["historyRowsScanned"], 5000);
    assert_eq!(snapshot["historyCompacted"], true);
    assert_eq!(snapshot["historyTruncated"], true);
    assert_eq!(snapshot["screenTruncated"], false);
    assert_eq!(
        snapshot["text"],
        "Inspect tray\nindigo\ngreen\nwhite\nChoose one\nSCAN-READY"
    );
    let history = snapshot["context"].as_str().unwrap();
    assert!(history.lines().count() <= 320 && history.len() <= 32 * 1024);
    assert!(!history.contains("OUTSIDE-SCAN") && !history.contains("Inspect tray"));
    let mut remaining = history;
    for evidence in [
        "Goal: reconstruct the blue tray inventory.",
        "Constraint: the original lot labels must stay attached.",
        "Error: calibration failed on shelf nine.",
        "Leah set aside the sample from the last carton.",
    ] {
        remaining = remaining
            .split_once(evidence)
            .unwrap_or_else(|| panic!("missing or reordered: {evidence}"))
            .1;
    }
    assert!(history.matches("worker queue unchanged").count() < 16);
    assert!(history.matches("waiting for the next batch").count() < 16);

    let local = server
        .cmd(env!("CARGO_BIN_EXE_agent"))
        .args(["snapshot", "1"])
        .output()
        .unwrap();
    assert!(
        local.status.success(),
        "{}",
        String::from_utf8_lossy(&local.stderr)
    );
    assert_eq!(
        serde_json::from_slice::<Value>(&local.stdout).unwrap(),
        snapshot
    );

    server.session(
        "exact-limit",
        "80",
        "1",
        "awk 'BEGIN {for (i=0; i<5000; i++) print \"syncing\"}'; printf EXACT-READY; exec sleep 60",
    );
    server.wait_for("$2:", "EXACT-READY");
    let exact = server.json("tmux-link-snapshot-v2 2");
    assert_eq!(exact["historyRowsScanned"], 5000);
    assert_eq!(exact["historyCompacted"], true);
    assert_eq!(exact["historyTruncated"], false);
}
