//! Select complete, sanitized history lines before any content leaves the host.
use super::SECTION_BYTES;
use std::collections::{BTreeSet, HashSet};

const MAX_LINES: usize = 320;

pub(super) fn compact(rows: &[&str], screen: &str) -> (String, bool) {
    let screen = screen.to_ascii_lowercase();
    let references: HashSet<_> = screen
        .rsplit(token_boundary)
        .map(|token| token.trim_end_matches('.'))
        .filter(|token| identifier(token))
        .take(64)
        .collect();
    let mut seen = HashSet::new();
    let mut seen_progress = HashSet::new();
    let mut priority = vec![0_u8; rows.len()];
    let mut anchors = Vec::new();
    let mut oldest = [None; 5];
    let mut newest = [None; 5];
    let mut recent = 0;
    // Retain the latest copy of a redraw, using original row indices throughout.
    for (i, &row) in rows.iter().enumerate().rev() {
        let trimmed = row.trim();
        if row.len() > SECTION_BYTES
            || trimmed.is_empty()
            || decoration(trimmed)
            || !seen.insert(trimmed)
        {
            continue;
        }
        let lower = trimmed.to_ascii_lowercase();
        let signal = meaning(&lower);
        let referenced = lower
            .split(token_boundary)
            .map(|token| token.trim_end_matches('.'))
            .any(|token| identifier(token) && references.contains(token));
        if referenced {
            oldest[4] = Some(i);
            newest[4].get_or_insert(i);
        }
        if let Some(kind) = signal {
            oldest[kind] = Some(i);
            newest[kind].get_or_insert(i);
        }
        if signal.is_some() || referenced {
            anchors.push(i);
        } else if let Some(kind) = progress(&lower) {
            if seen_progress.insert(kind) {
                priority[i] = 1;
            }
            continue;
        }
        priority[i] = match (referenced, recent) {
            (true, _) if signal.is_some() => 12,
            (true, _) => 11,
            (_, 0..=2) => 14,
            (_, 3..=31) => 7,
            _ if signal.is_some() => 6,
            _ => 2,
        };
        recent += 1;
    }
    // Nearby explanation and indented evidence belong with the source line.
    // Reserve highlights for both ends of each category before filling by recency.
    for i in anchors {
        boost_neighbours(&mut priority, i, 5);
    }
    for i in oldest.into_iter().chain(newest).flatten() {
        priority[i] = 14;
        boost_neighbours(&mut priority, i, 8);
    }
    let mut ranked: Vec<_> = (0..rows.len()).filter(|&i| priority[i] > 0).collect();
    ranked.sort_unstable_by_key(|&i| {
        // Do not let one giant formatted row exhaust the budget ahead of the
        // short, high-value evidence. Oversized rows are never cut into partial facts.
        let score = if rows[i].len() > SECTION_BYTES / 4 {
            priority[i].min(6)
        } else {
            priority[i]
        };
        std::cmp::Reverse((score, i))
    });
    let mut selected = BTreeSet::new();
    let (mut bytes, mut lines) = (0, 0);
    for i in ranked {
        let before = selected.range(..i).next_back().copied();
        let after = selected.range(i..).next().copied();
        let breaks = breaks_between(before, Some(i)) + breaks_between(Some(i), after)
            - breaks_between(before, after);
        let line_cost = breaks + usize::from(selected.is_empty());
        let byte_cost = rows[i].len() + breaks;
        if bytes + byte_cost <= SECTION_BYTES && lines + line_cost <= MAX_LINES {
            selected.insert(i);
            bytes += byte_cost;
            lines += line_cost;
        }
    }
    let mut out = String::with_capacity(bytes);
    let mut previous = None;
    for i in selected {
        for _ in 0..breaks_between(previous, Some(i)) {
            out.push('\n');
        }
        out.push_str(rows[i]);
        previous = Some(i);
    }
    let compacted = !out.lines().eq(rows.iter().copied());
    (out, compacted)
}

fn breaks_between(before: Option<usize>, after: Option<usize>) -> usize {
    match (before, after) {
        (Some(a), Some(b)) if b == a + 1 => 1,
        (Some(_), Some(_)) => 2, // omitted rows separate two independent excerpts
        _ => 0,
    }
}

fn boost_neighbours(priority: &mut [u8], i: usize, score: u8) {
    let end = (i + 3).min(priority.len());
    for item in &mut priority[i.saturating_sub(2)..end] {
        if *item > 1 {
            *item = (*item).max(score);
        }
    }
}

fn token_boundary(ch: char) -> bool {
    !ch.is_ascii_alphanumeric() && !matches!(ch, '-' | '_' | '.' | '/')
}

fn identifier(token: &str) -> bool {
    (4..=128).contains(&token.len())
        && token.bytes().any(|b| b.is_ascii_alphabetic())
        && token
            .bytes()
            .any(|b| b.is_ascii_digit() || matches!(b, b'.' | b'/' | b'_' | b'-'))
}

// Separate categories keep a long run of errors from displacing the original
// goal or constraint. Question marks and option numbers confer no priority.
fn meaning(line: &str) -> Option<usize> {
    for word in line.split(|ch: char| !ch.is_ascii_alphanumeric()) {
        match word {
            "goal" | "objective" | "criteria" | "purpose" | "aim" => return Some(0),
            "constraint" | "constraints" | "must" | "never" | "cannot" | "required"
            | "requirement" | "deadline" | "only" | "forbidden" => return Some(1),
            "because" | "reason" | "rationale" | "cause" | "caused" | "therefore" => {
                return Some(2);
            }
            "error" | "failure" | "failed" | "exception" | "blocked" | "panic" | "timeout"
            | "fatal" | "denied" | "regression" | "traceback" => return Some(3),
            _ => {}
        }
    }
    if line.contains("due to") || line.contains("to avoid") {
        return Some(2);
    }
    if line.contains("do not") || line.contains("don't") {
        return Some(1);
    }
    if !line.is_ascii() {
        for (kind, words) in [
            &["目标", "目的", "验收", "期望", "为了", "预期"][..],
            &[
                "约束",
                "限制",
                "必须",
                "不得",
                "不允许",
                "不要",
                "不能",
                "禁止",
                "要求",
                "仅限",
            ],
            &[
                "因为", "由于", "原因", "根因", "理由", "以免", "避免", "所以",
            ],
            &[
                "异常",
                "错误",
                "失败",
                "未通过",
                "阻塞",
                "卡住",
                "崩溃",
                "超时",
                "报错",
                "拒绝",
            ],
        ]
        .iter()
        .enumerate()
        {
            if words.iter().any(|word| line.contains(word)) {
                return Some(kind);
            }
        }
    }
    None
}

fn decoration(line: &str) -> bool {
    line.chars().all(|ch| ch.is_whitespace() || matches!(ch,
        '-' | '=' | '_' | '|' | '*' | '+' | '.' | '·' | '•' | '\u{2500}'..='\u{259f}' | '\u{2800}'..='\u{28ff}'))
}

fn progress(line: &str) -> Option<&'static str> {
    let line = line
        .split_once("[info]")
        .map_or(line, |(_, rest)| rest.trim_start());
    if line.contains("heartbeat") || line.contains("心跳") {
        return Some("heartbeat");
    }
    for word in [
        "progress",
        "building",
        "compiling",
        "downloading",
        "processing",
        "loading",
        "进度",
        "正在下载",
        "编译中",
        "正在加载",
    ] {
        if line.starts_with(word) && line.bytes().any(|b| b.is_ascii_digit()) {
            return Some(word);
        }
    }
    if line.contains('%') && line.contains(['█', '▓', '░', '━', '▉']) {
        return Some("meter");
    }
    None
}

pub(super) fn remove_private_keys<'a>(history: &mut [&'a str], screen: &mut [&'a str]) -> bool {
    // Do not separate a key body from the markers used by the phone's redactor.
    // If the scan starts inside a key, the first END closes the leading fragment.
    let mut private = vec![false; history.len() + screen.len()];
    let (mut split_begin, mut split_end) = (false, false);
    if let (Some(left), Some(right)) = (history.last(), screen.first()) {
        // tmux splits even a soft-wrapped marker at the viewport boundary.
        // Inspect just the adjoining fragments; never join the returned sections.
        let start = left.char_indices().rev().nth(96).map_or(0, |(i, _)| i);
        let mut boundary = left[start..].to_owned();
        let cut = boundary.len();
        boundary.extend(right.chars().take(96));
        let crosses = |kind: &str| {
            boundary.match_indices(kind).any(|(i, _)| {
                i < cut
                    && boundary[i + kind.len()..]
                        .find("PRIVATE KEY-----")
                        .is_some_and(|n| {
                            let label = &boundary[i + kind.len()..i + kind.len() + n];
                            label
                                .bytes()
                                .all(|b| b.is_ascii_uppercase() || b.is_ascii_digit() || b == b' ')
                                && i + kind.len() + n + "PRIVATE KEY-----".len() > cut
                        })
            })
        };
        split_begin = crosses("-----BEGIN ");
        split_end = crosses("-----END ");
    }
    let mut start = None;
    let mut last_end = 0;
    for (i, row) in history.iter().chain(screen.iter()).enumerate() {
        let marker = row.contains("PRIVATE KEY-----");
        if (marker && row.contains("-----BEGIN ")) || (split_begin && i + 1 == history.len()) {
            start.get_or_insert(i);
        }
        if (marker && row.contains("-----END ")) || (split_end && i == history.len()) {
            private[start.take().unwrap_or(last_end)..=i].fill(true);
            last_end = i + 1;
        }
    }
    if let Some(start) = start {
        private[start..].fill(true);
    }
    let removed_history = private[..history.len()].contains(&true);
    for (row, hide) in history.iter_mut().chain(screen.iter_mut()).zip(private) {
        if hide {
            *row = "";
        }
    }
    removed_history
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn retains_source_related_to_the_visible_case_among_unrelated_errors() {
        let mut logs: Vec<_> = (0..1500)
            .map(|n| format!("error during unrelated job {n}"))
            .collect();
        logs[30] = "目标：本周保留上线回滚能力".into();
        logs[80] = "Failure on PM-712: lost recovery journal".into();
        logs[82] = "Constraint: the archive must remain immutable".into();
        let rows: Vec<_> = logs.iter().map(String::as_str).collect();
        let (excerpt, compacted) = compact(&rows, "Does recovery work for pm-712?");
        assert!(compacted);
        for i in [30, 80, 82, 1499] {
            assert!(excerpt.contains(&logs[i]));
        }
        assert!(excerpt.lines().count() <= MAX_LINES && excerpt.len() <= SECTION_BYTES);
    }

    #[test]
    fn preserves_whole_lines_and_breaks_across_omitted_regions() {
        let long = "界".repeat(SECTION_BYTES);
        let (excerpt, compacted) = compact(&["first", &long, "  after"], "");
        assert_eq!(excerpt, "first\n\n  after");
        assert!(compacted);
    }

    #[test]
    fn key_fragments_cannot_become_plaintext_excerpts() {
        for (history, screen) in [
            (
                vec!["ok", "-----BEGIN RSA PRIVATE KEY-----"],
                vec!["body", "-----END RSA PRIVATE KEY-----", "done"],
            ),
            (
                vec!["ok", "-----BEGIN "],
                vec!["RSA PRIVATE KEY-----", "body"],
            ),
            (
                vec![
                    "ok",
                    "-----BEGIN RSA PRIVATE KEY-----",
                    "body",
                    "-----END RSA PR",
                ],
                vec!["IVATE KEY-----", "done"],
            ),
            (
                vec!["clipped body"],
                vec!["tail", "-----END RSA PRIVATE KEY-----", "done"],
            ),
        ] {
            let (mut history, mut screen) = (history, screen);
            assert!(remove_private_keys(&mut history, &mut screen));
            assert!(
                history
                    .into_iter()
                    .chain(screen)
                    .all(|s| matches!(s, "" | "ok" | "done"))
            );
        }
    }
}
