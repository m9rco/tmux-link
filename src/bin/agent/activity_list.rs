//! List metadata and small observations of the foreground pane. Never read history or app exports.
use super::snapshot;
use anyhow::Result;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{
    fmt::Write,
    process::Command,
    time::{SystemTime, UNIX_EPOCH},
};

struct Row {
    json: Value,
    pane: Option<u64>,
    height: usize,
    cursor: usize,
    agent: bool,
    shell: bool,
}

pub(super) fn print() -> Result<()> {
    // The metadata fields following the numbers are free text. A per-request
    // separator also preserves literal newlines in a pane's working directory.
    let nonce = getrandom::u64().map_err(|e| anyhow::anyhow!("list framing: {e}"))?;
    let sep = format!("tmux-link-list-{nonce:016x}-");
    let end = format!("{sep}end\n");
    let format = format!(
        "#{{session_id}} #{{pid}}-#{{session_created}}-#{{pane_id}}-#{{pane_pid}} #{{pane_id}} #{{pane_dead}}#{{pane_in_mode}} #{{pane_width}} #{{pane_height}} #{{cursor_y}} #{{window_activity}}{sep}#{{pane_current_command}}{sep}#{{session_name}}{sep}#{{pane_current_path}}{sep}end"
    );
    let output = Command::new("tmux")
        .args(["-u", "list-sessions", "-F", &format])
        .output()?;
    if !output.status.success() {
        let reason = String::from_utf8_lossy(&output.stderr);
        if [
            "no server running",
            "No such file or directory",
            "no sessions",
        ]
        .iter()
        .any(|s| reason.contains(s))
        {
            println!("[]");
            return Ok(());
        }
        anyhow::bail!("no tmux sessions available for this account");
    }

    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs();
    let mut rows = Vec::new();
    let listing = String::from_utf8_lossy(&output.stdout);
    for record in listing.split_terminator(&end) {
        let mut parts = record.splitn(4, &sep);
        let fields: Vec<_> = parts.next().unwrap_or("").split(' ').collect();
        let (Some(command), Some(name), Some(path)) = (parts.next(), parts.next(), parts.next())
        else {
            continue;
        };
        let Some(id) = fields
            .first()
            .and_then(|s| s.strip_prefix('$'))
            .and_then(|s| s.parse::<u64>().ok())
        else {
            continue;
        };
        let instance = fields
            .get(1)
            .filter(|s| tmux_link::valid_managed_instance(s));
        // An observing row without a sample lets the phone retry a transient
        // pane change or oversized grid on its next visible refresh.
        let item = json!({"id": id, "name": name, "touchPaging": true, "activity": "observing",
            "directory": (!path.is_empty()).then_some(path), "snapshot": true, "snapshotVersion": 2,
            "managedVersion": 2, "managedInstance": instance, "agentContextVersion": 1});
        let num = |n| fields.get(n).and_then(|s: &&str| s.parse::<usize>().ok());
        let pane = fields
            .get(2)
            .and_then(|s| s.strip_prefix('%'))
            .and_then(|s| s.parse().ok());
        let mut row = Row {
            json: item,
            pane: None,
            height: 0,
            cursor: 0,
            agent: false,
            shell: false,
        };
        let cmd = command
            .rsplit('/')
            .next()
            .unwrap_or(command)
            .trim_start_matches('-');
        row.shell = matches!(
            cmd,
            "bash" | "sh" | "zsh" | "fish" | "dash" | "ksh" | "csh" | "tcsh" | "nu" | "login"
        );
        let recently_active = fields
            .get(7)
            .and_then(|value| value.parse::<u64>().ok())
            .is_some_and(|at| now.saturating_sub(at) <= 20);
        // Window activity also changes on focus. Use it only to skip sampling
        // quiescent shells, never as evidence a foreground pane is producing output.
        if fields
            .get(3)
            .is_some_and(|s| ["01", "10", "11"].contains(s))
            || (row.shell && !recently_active)
        {
            row.json["activity"] = "idle".into();
        } else if let (Some(width), Some(height), Some(cursor)) = (num(4), num(5), num(6))
            && (1..=512).contains(&width)
            && height > 0
            && cursor < height
            && !cmd.is_empty()
            && fields.get(3) == Some(&"00")
        {
            row.pane = pane;
            row.height = height;
            row.cursor = cursor;
            row.agent = matches!(
                cmd,
                "codemaker" | "opencode" | "codex" | "claude" | "node" | "nodejs" | "bun"
            ) || (cmd.split('.').count() >= 3
                && cmd
                    .split('.')
                    .all(|n| !n.is_empty() && n.bytes().all(|b| b.is_ascii_digit())));
        }
        rows.push(row);
    }
    // One metadata query and one batched query per 32 observed panes. Idle
    // shells require no capture. A pane closing during the read is harmless.
    let mut candidates: Vec<_> = rows.iter_mut().filter(|row| row.pane.is_some()).collect();
    for batch in candidates.chunks_mut(32) {
        observe_batch(batch, &sep);
    }
    println!(
        "{}",
        serde_json::to_string(&rows.into_iter().map(|row| row.json).collect::<Vec<_>>())?
    );
    Ok(())
}

fn observe_batch(rows: &mut [&mut Row], sep: &str) {
    let mut args = vec!["-u".to_owned()];
    for row in rows.iter() {
        let target = format!("%{}", row.pane.unwrap());
        let bottom = row.height - 1;
        let ranges = if row.shell {
            [
                (row.cursor.saturating_sub(5), row.cursor),
                (row.cursor, row.cursor),
            ]
        } else if row.agent {
            [
                (row.cursor.saturating_sub(8), (row.cursor + 2).min(bottom)),
                (bottom.saturating_sub(13), bottom),
            ]
        } else {
            [
                (0, 3.min(bottom)),
                (row.cursor.saturating_sub(5), (row.cursor + 1).min(bottom)),
            ]
        };
        let [(first, last), (start, end)] = ranges;
        let spans = if start <= last + 1 {
            vec![(first.min(start), end.max(last))]
        } else {
            vec![(first, last), (start, end)]
        };
        for (start, end) in spans {
            args.extend([
                "capture-pane".into(),
                "-p".into(),
                "-e".into(),
                "-t".into(),
                target.clone(),
                "-S".into(),
                start.to_string(),
                "-E".into(),
                end.to_string(),
                ";".into(),
            ]);
        }
        args.extend([
            "display-message".into(),
            "-p".into(),
            format!("{sep}pane-{}", row.pane.unwrap()),
            ";".into(),
        ]);
    }
    args.pop();
    let argv: Vec<_> = args.iter().map(String::as_str).collect();
    let Ok(Some(raw)) = snapshot::capture(&argv, 4 * 1024 * 1024) else {
        return;
    };
    let mut rest = raw.as_str();
    for row in rows {
        let boundary = format!("{sep}pane-{}\n", row.pane.unwrap());
        let Some((sample, tail)) = rest.split_once(&boundary) else {
            return;
        };
        rest = tail;
        if let Ok(text) = snapshot::plain_text(sample) {
            let lines: Vec<_> = text.lines().map(str::trim_end).collect();
            if row.shell
                && lines
                    .last()
                    .is_some_and(|line| looks_like_shell_prompt(line))
            {
                row.json["activity"] = "idle".into();
            } else if let Some(state) = row.agent.then(|| agent_activity(&lines)).flatten() {
                row.json["activity"] = state.into();
            } else {
                // A repaint of identical text (including colour/cursor changes)
                // has the same sample. No timestamp, pane characters or argv leave the host here.
                let mut digest = Sha256::new();
                digest.update(row.json["managedInstance"].as_str().unwrap_or_default());
                // For custom shell prompts, edits to the live input row are
                // indistinguishable from a partial write. Compare completed
                // rows; external foreground programs include cursor-row output.
                let count = lines.len().saturating_sub(usize::from(row.shell));
                for line in &lines[..count] {
                    digest.update(line.as_bytes());
                    digest.update(b"\n");
                }
                let mut token = String::with_capacity(24);
                for byte in &digest.finalize()[..12] {
                    write!(token, "{byte:02x}").unwrap();
                }
                row.json["activitySample"] = token.into();
            }
        }
    }
}

fn looks_like_shell_prompt(line: &str) -> bool {
    // Standard shell prompts terminate in a symbol followed by whitespace;
    // ignore edits after the prompt as well as an ordinary empty prompt.
    line.split_whitespace()
        .any(|word| word.ends_with(['$', '#', '%', '❯', '➜', 'λ', '›']) || word == ">")
}

fn agent_activity(lines: &[&str]) -> Option<&'static str> {
    // A live confirmation dialog can cover an older Working line. Require a
    // selection row as well as a visible selection/submission instruction.
    let tail: Vec<_> = lines
        .iter()
        .map(|s| s.trim())
        .filter(|s| !s.is_empty())
        .rev()
        .take(18)
        .collect();
    let option = tail.iter().any(|s| {
        s.starts_with(['❯', '›', '☐', '☑', '◉', '○', '●'])
            || s.starts_with("[ ]")
            || s.starts_with("[x]")
            || s.as_bytes().first().is_some_and(u8::is_ascii_digit)
                && (s.contains(". ") || s.contains(") "))
    });
    if option
        && tail.iter().take(4).any(|s| {
            let s = s.to_lowercase();
            [
                "enter to confirm",
                "enter to select",
                "enter to submit",
                "to submit",
                "space to select",
                "space to toggle",
                "回车确认",
                "回车提交",
                "回车选择",
                "空格选择",
            ]
            .iter()
            .any(|needle| s.contains(needle))
        })
    {
        return Some("waiting");
    }
    if let Some(state) = snapshot::footer_activity(lines) {
        return Some(state);
    }
    for line in tail.iter().take(9) {
        let lower = line.to_lowercase();
        if lower.ends_with(['?', '？'])
            && [
                "do you want",
                "would you like",
                "would you prefer",
                "should i ",
                "should we ",
                "which ",
                "can i ",
                "是否",
                "要我",
                "需要我",
                "你希望",
            ]
            .iter()
            .any(|prefix| {
                lower
                    .trim_start_matches(['•', ' ', '●'])
                    .starts_with(prefix)
            })
        {
            return Some("waiting");
        }
        let decorated = line.starts_with(['•', '·', '✢', '✳', '✶', '✻', '✽', '⏺'])
            || line
                .chars()
                .next()
                .is_some_and(|c| ('⠁'..='⣿').contains(&c));
        if lower.contains("esc to interrupt")
            && (decorated || lower.starts_with("working (") || lower.starts_with("thinking ("))
        {
            return Some("running");
        }
    }
    if tail
        .iter()
        .take(4)
        .any(|s| *s == "›" || *s == "❯" || s.starts_with("› ") || s.starts_with("❯ "))
    {
        return Some("waiting");
    }
    None
}
