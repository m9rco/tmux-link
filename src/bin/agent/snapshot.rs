use anyhow::{Context, Result, ensure};
use serde::Serialize;
use std::{
    io::Read,
    process::{Command, Stdio},
};

const HEADER: &str = "#{session_id} #{pane_id} #{alternate_on} #{pane_in_mode} #{pane_height} #{history_size} #{session_name}";
const RAW_LIMIT: usize = 4 * 1024 * 1024;

#[derive(Serialize)]
pub(super) struct Snapshot {
    id: u64,
    name: String,
    text: String,
    context: Option<String>,
}

pub(super) fn read(id: u64) -> Result<Snapshot> {
    let target = format!("${id}:");
    // Queue all three synchronous commands on the same tmux server. -p avoids
    // touching paste buffers. The live screen is the default even in an alt-screen app.
    let mut child = Command::new("tmux")
        .args([
            "-u",
            "display-message",
            "-p",
            "-t",
            &target,
            HEADER,
            ";",
            "capture-pane",
            "-e",
            "-p",
            "-S",
            "-120",
            "-t",
            &target,
            ";",
            "display-message",
            "-p",
            "-t",
            &target,
            HEADER,
        ])
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()?;
    let mut raw = Vec::new();
    let result = child
        .stdout
        .take()
        .unwrap()
        .take((RAW_LIMIT + 1) as u64)
        .read_to_end(&mut raw);
    let status = child.wait()?;
    result?;
    ensure!(raw.len() <= RAW_LIMIT, "snapshot exceeds capture limit");
    ensure!(status.success(), "snapshot unavailable");
    decode(id, std::str::from_utf8(&raw)?)
}

fn decode(id: u64, raw: &str) -> Result<Snapshot> {
    let (header, rest) = raw.split_once('\n').context("missing pane metadata")?;
    let (rows, footer) = rest
        .strip_suffix('\n')
        .and_then(|s| s.rsplit_once('\n'))
        .context("incomplete pane snapshot")?;
    ensure!(header == footer, "active pane changed during snapshot");
    let mut fields = header.splitn(7, ' ');
    ensure!(
        fields.next() == Some(format!("${id}").as_str()),
        "session changed during snapshot"
    );
    fields
        .next()
        .and_then(|s| s.strip_prefix('%'))
        .context("missing pane ID")?
        .parse::<u64>()?;
    let alternate = fields.next().context("missing screen mode")?;
    ensure!(matches!(alternate, "0" | "1"), "invalid screen mode");
    // Older tmux capture-pane implementations expose the underlying live grid
    // while copy-mode or a tmux chooser is covering it.
    ensure!(fields.next() == Some("0"), "snapshot pane in mode");
    let height = fields
        .next()
        .context("missing pane height")?
        .parse::<usize>()?;
    let history = fields
        .next()
        .context("missing history size")?
        .parse::<usize>()?
        .min(120);
    let name = fields.next().context("missing session name")?.to_owned();

    let visible = plain_text(rows)?;
    let rows: Vec<_> = visible.split('\n').collect();
    ensure!(
        height > 0 && height <= rows.len(),
        "incomplete visible pane"
    );
    let (prior, screen) = rows.split_at(rows.len() - height);
    ensure!(prior.len() <= history, "unexpected scrollback");
    let context = if alternate == "0" && !prior.is_empty() {
        let text = tail(prior, 120, 16 * 1024);
        (!text.is_empty()).then_some(text)
    } else {
        None
    };
    Ok(Snapshot {
        id,
        name,
        text: tail(screen, 40, 6000),
        context,
    })
}

// tmux's plain capture prints the underlying characters of concealed cells.
// Read its styled capture, discard control sequences (including hyperlink URLs),
// and replace SGR 8 cells with spaces before taking either excerpt.
fn plain_text(styled: &str) -> Result<String> {
    let mut chars = styled.chars();
    let mut plain = String::new();
    let mut concealed = false;
    while let Some(ch) = chars.next() {
        if ch != '\x1b' {
            if ch == '\n' || ch == '\t' || !ch.is_control() {
                plain.push(if concealed && ch != '\n' { ' ' } else { ch });
            }
            continue;
        }
        match chars.next().context("incomplete terminal escape")? {
            '[' => {
                let params = chars.as_str();
                let final_char = chars
                    .by_ref()
                    .find(|c| ('@'..='~').contains(c))
                    .context("incomplete terminal attributes")?;
                if final_char == 'm' {
                    let length = params.len() - chars.as_str().len() - 1;
                    set_concealment(&params[..length], &mut concealed);
                }
            }
            ']' | 'P' | '^' | '_' | 'X' => {
                let mut escaped = false;
                loop {
                    let ch = chars.next().context("incomplete terminal string")?;
                    if ch == '\x07' || (escaped && ch == '\\') {
                        break;
                    }
                    escaped = ch == '\x1b';
                }
            }
            ' '..='/' => {
                chars
                    .by_ref()
                    .find(|c| ('0'..='~').contains(c))
                    .context("incomplete character set")?;
            }
            _ => {}
        }
    }
    Ok(plain)
}

fn set_concealment(params: &str, concealed: &mut bool) {
    let mut codes = params.split(';');
    while let Some(code) = codes.next() {
        match code {
            "" | "0" | "28" => *concealed = false,
            "8" => *concealed = true,
            // tmux emits indexed or RGB color values; a color component of 8 or 0
            // is data and must never change the concealment state.
            "38" | "48" | "58" => match codes.next() {
                Some("5") => {
                    codes.next();
                }
                Some("2") => {
                    codes.nth(2);
                }
                _ => {}
            },
            _ => {}
        }
    }
}

fn tail(rows: &[&str], lines: usize, bytes: usize) -> String {
    let end = rows
        .iter()
        .rposition(|s| !s.trim().is_empty())
        .map_or(0, |i| i + 1);
    let text = rows[end.saturating_sub(lines)..end].join("\n");
    let mut start = text.len().saturating_sub(bytes);
    while !text.is_char_boundary(start) {
        start += 1;
    }
    text[start..].to_owned()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn terminal_styles_and_utf8_caps_do_not_disclose_hidden_cells() {
        let styled = "\x1b[8mhidden\x1b[38;2;0;28;8mstill\x1b[48;5;0msecret\x1b[28m选\x1b]8;;https://hidden\x1b\\择\x1b]8;;\x1b\\";
        assert_eq!(plain_text(styled).unwrap(), "                 选择");
        let huge = "🙂".repeat(5000);
        let text = tail(&[&huge, "last"], 40, 6000);
        assert!(text.len() <= 6000 && text.len() > 5995 && text.ends_with("last"));
        let history = tail(&[&huge, "历史"], 120, 16 * 1024);
        assert!(history.len() <= 16 * 1024 && history.ends_with("历史"));
    }

    #[test]
    fn discards_results_when_session_pane_or_grid_changed() {
        let header = "$1 %9 0 0 1 0 name";
        for footer in [
            "$2 %9 0 0 1 0 name",
            "$1 %8 0 0 1 0 name",
            "$1 %9 0 0 2 0 name",
        ] {
            assert!(decode(1, &format!("{header}\nprivate\n{footer}\n")).is_err());
        }
        assert!(decode(2, &format!("{header}\nprivate\n{header}\n")).is_err());
    }
}
