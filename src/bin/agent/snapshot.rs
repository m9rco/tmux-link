use anyhow::{Context, Result, ensure};
use serde::Serialize;
use std::{
    io::Read,
    process::{Command, Stdio},
};

const HEADER: &str = "#{session_id} #{pane_id} #{alternate_on} #{pane_in_mode} #{pane_width} #{pane_height} #{history_size} #{session_name}";
#[path = "snapshot_history.rs"]
mod history;

const V1_RAW_LIMIT: usize = 4 * 1024 * 1024;
const V2_RAW_LIMIT: usize = 16 * 1024 * 1024;
const HISTORY_ROWS: usize = 5000;
const SECTION_BYTES: usize = 32 * 1024;

#[derive(Serialize)]
pub(super) struct Snapshot {
    id: u64,
    name: String,
    text: String,
    context: Option<String>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct SnapshotV2 {
    version: u8,
    #[serde(flatten)]
    snapshot: Snapshot,
    pane_id: u64,
    columns: usize,
    rows: usize,
    alternate: bool,
    screen_truncated: bool,
    history_truncated: bool,
    history_rows_scanned: usize,
    history_compacted: bool,
}

pub(super) fn read(id: u64) -> Result<Snapshot> {
    let target = format!("${id}:");
    // Queue all three synchronous commands on the same tmux server. -p avoids
    // touching paste buffers. The live screen is the default even in an alt-screen app.
    let raw = capture(
        &[
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
        ],
        V1_RAW_LIMIT,
    )?
    .context("snapshot exceeds capture limit")?;
    decode(id, &raw)
}

pub(super) fn read_v2(id: u64) -> Result<SnapshotV2> {
    let target = format!("${id}:");
    let nonce = getrandom::u64().map_err(|e| anyhow::anyhow!("snapshot framing: {e}"))?;
    let separator = format!("tmux-link-section-{nonce:016x}");
    for window in [HISTORY_ROWS, 1250, 320, 1] {
        if let Some(raw) = capture_v2(&target, &separator, window)? {
            return decode_v2(id, &raw, &separator, window);
        }
    }
    anyhow::bail!("snapshot exceeds capture limit (16 MiB with a one-row history window)")
}

fn capture_v2(target: &str, separator: &str, window: usize) -> Result<Option<String>> {
    // capture-pane clamps negative rows to the first grid row. With no history
    // that row belongs to the screen, so skip the range entirely in that case.
    let history = format!("capture-pane -e -J -p -S -{window} -E -1 -t '{target}'");
    capture(
        &[
            "-u",
            "display-message",
            "-p",
            "-t",
            target,
            HEADER,
            ";",
            "if-shell",
            "-F",
            "-t",
            target,
            "#{&&:#{==:#{alternate_on},0},#{history_size}}",
            &history,
            ";",
            "display-message",
            "-p",
            "-t",
            target,
            separator,
            ";",
            "capture-pane",
            "-e",
            "-J",
            "-p",
            "-S",
            "0",
            "-t",
            target,
            ";",
            "display-message",
            "-p",
            "-t",
            target,
            HEADER,
        ],
        V2_RAW_LIMIT,
    )
}

// Only a bounded-read overflow permits a smaller v2 retry.
fn capture(args: &[&str], raw_limit: usize) -> Result<Option<String>> {
    let mut child = Command::new("tmux")
        .args(args)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()?;
    let mut raw = Vec::new();
    let result = child
        .stdout
        .take()
        .unwrap()
        .take((raw_limit + 1) as u64)
        .read_to_end(&mut raw);
    if result.is_err() || raw.len() > raw_limit {
        // Do not wait on a producer still writing past our bounded reader.
        let _ = child.kill();
    }
    let status = child.wait()?;
    result?;
    if raw.len() > raw_limit {
        return Ok(None);
    }
    ensure!(status.success(), "snapshot unavailable");
    Ok(Some(String::from_utf8(raw)?))
}

struct Pane<'a> {
    name: &'a str,
    id: u64,
    alternate: bool,
    columns: usize,
    rows: usize,
    history: usize,
}

fn framed(id: u64, raw: &str) -> Result<(Pane<'_>, &str)> {
    let (header, rest) = raw.split_once('\n').context("missing pane metadata")?;
    let (rows, footer) = rest
        .strip_suffix('\n')
        .and_then(|s| s.rsplit_once('\n'))
        .context("incomplete pane snapshot")?;
    ensure!(header == footer, "active pane changed during snapshot");
    let mut fields = header.splitn(8, ' ');
    ensure!(
        fields.next() == Some(format!("${id}").as_str()),
        "session changed during snapshot"
    );
    let pane_id = fields
        .next()
        .and_then(|s| s.strip_prefix('%'))
        .context("missing pane ID")?
        .parse::<u64>()?;
    let alternate = fields.next().context("missing screen mode")?;
    ensure!(matches!(alternate, "0" | "1"), "invalid screen mode");
    // Older tmux capture-pane implementations expose the underlying live grid
    // while copy-mode or a tmux chooser is covering it.
    ensure!(fields.next() == Some("0"), "snapshot pane in mode");
    let columns = fields
        .next()
        .context("missing pane width")?
        .parse::<usize>()?;
    let height = fields
        .next()
        .context("missing pane height")?
        .parse::<usize>()?;
    let history = fields
        .next()
        .context("missing history size")?
        .parse::<usize>()?;
    let name = fields.next().context("missing session name")?;
    ensure!(columns > 0 && height > 0, "invalid pane dimensions");
    Ok((
        Pane {
            id: pane_id,
            name,
            alternate: alternate == "1",
            columns,
            rows: height,
            history,
        },
        rows,
    ))
}

fn decode(id: u64, raw: &str) -> Result<Snapshot> {
    let (pane, rows) = framed(id, raw)?;
    let visible = plain_text(rows)?;
    let rows: Vec<_> = visible.split('\n').collect();
    ensure!(pane.rows <= rows.len(), "incomplete visible pane");
    let (prior, screen) = rows.split_at(rows.len() - pane.rows);
    ensure!(
        prior.len() <= pane.history.min(120),
        "unexpected scrollback"
    );
    let context = if !pane.alternate && !prior.is_empty() {
        let (text, _) = tail(prior, 120, 16 * 1024);
        (!text.is_empty()).then_some(text)
    } else {
        None
    };
    Ok(Snapshot {
        id,
        name: pane.name.to_owned(),
        text: tail(screen, 40, 6000).0,
        context,
    })
}

fn decode_v2(id: u64, raw: &str, separator: &str, window: usize) -> Result<SnapshotV2> {
    let (pane, body) = framed(id, raw)?;
    let (prior, screen) = body
        .split_once(separator)
        .context("missing section boundary")?;
    let screen = screen
        .strip_prefix('\n')
        .context("invalid section boundary")?;
    ensure!(!screen.contains(separator), "ambiguous section boundary");
    // Each capture starts with tmux's default attributes. Within a capture,
    // concealment must survive every hard newline and all soft wraps.
    let screen = plain_text(screen)?;
    let mut screen: Vec<_> = screen.split('\n').collect();
    ensure!(screen.len() <= pane.rows, "unexpected screen rows");

    let history_rows_scanned = if pane.alternate {
        0
    } else {
        pane.history.min(window)
    };
    let history_text;
    let mut prior = if history_rows_scanned == 0 {
        ensure!(prior.is_empty(), "unexpected scrollback");
        Vec::new()
    } else {
        history_text = plain_text(prior.strip_suffix('\n').context("incomplete scrollback")?)?;
        history_text.split('\n').collect()
    };
    ensure!(prior.len() <= history_rows_scanned, "unexpected scrollback");
    let private_history = history::remove_private_keys(&mut prior, &mut screen);
    // -J preserves right-margin padding. Trim after wrap-aware capture and
    // marker inspection so an internal word separator or indentation survives.
    for row in prior.iter_mut().chain(screen.iter_mut()) {
        *row = row.trim_end_matches(' ');
    }
    let (text, screen_truncated) = tail(&screen, 256, SECTION_BYTES);
    let (context, history_compacted) = history::compact(&prior, &text);
    Ok(SnapshotV2 {
        version: 2,
        snapshot: Snapshot {
            id,
            name: pane.name.to_owned(),
            text,
            context: (!context.is_empty()).then_some(context),
        },
        pane_id: pane.id,
        columns: pane.columns,
        rows: pane.rows,
        alternate: pane.alternate,
        screen_truncated,
        history_truncated: !pane.alternate && pane.history > history_rows_scanned,
        history_rows_scanned,
        history_compacted: history_compacted || private_history,
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

fn tail(rows: &[&str], lines: usize, bytes: usize) -> (String, bool) {
    let end = rows
        .iter()
        .rposition(|s| !s.trim().is_empty())
        .map_or(0, |i| i + 1);
    let text = rows[end.saturating_sub(lines)..end].join("\n");
    let mut start = text.len().saturating_sub(bytes);
    while !text.is_char_boundary(start) {
        start += 1;
    }
    (text[start..].to_owned(), start > 0 || end > lines)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn terminal_styles_and_utf8_caps_do_not_disclose_hidden_cells() {
        let styled = "\x1b[8mhidden\x1b[38;2;0;28;8mstill\x1b[48;5;0msecret\x1b[28m选\x1b]8;;https://hidden\x1b\\择\x1b]8;;\x1b\\";
        assert_eq!(plain_text(styled).unwrap(), "                 选择");
        let huge = "🙂".repeat(5000);
        let (text, truncated) = tail(&[&huge, "last"], 40, 6000);
        assert!(truncated);
        assert!(text.len() <= 6000 && text.len() > 5995 && text.ends_with("last"));
        let (history, truncated) = tail(&[&huge, "历史"], 120, 16 * 1024);
        assert!(truncated);
        assert!(history.len() <= 16 * 1024 && history.ends_with("历史"));
    }

    #[test]
    fn discards_results_when_session_pane_or_grid_changed() {
        let header = "$1 %9 0 0 80 1 0 name";
        for footer in [
            "$2 %9 0 0 80 1 0 name",
            "$1 %8 0 0 80 1 0 name",
            "$1 %9 0 0 80 2 0 name",
        ] {
            assert!(decode(1, &format!("{header}\nprivate\n{footer}\n")).is_err());
        }
        assert!(decode(2, &format!("{header}\nprivate\n{header}\n")).is_err());
    }

    #[test]
    fn v2_rejects_ambiguous_frames_and_unexpected_history() {
        let header = "$1 %9 0 0 80 2 0 name";
        for body in [
            "screen",
            "part\nSECTION\nscreen",
            "SECTION\nscreen\nSECTION",
        ] {
            assert!(
                decode_v2(
                    1,
                    &format!("{header}\n{body}\n{header}\n"),
                    "SECTION",
                    HISTORY_ROWS
                )
                .is_err()
            );
        }
        let alt = "$1 %9 1 0 80 2 10 name";
        assert!(
            decode_v2(
                1,
                &format!("{alt}\nshell\nSECTION\ntui\n{alt}\n"),
                "SECTION",
                HISTORY_ROWS
            )
            .is_err()
        );
    }
}
