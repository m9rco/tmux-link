//! Remove CodeMaker/OpenCode chrome only after locating its bottom prompt frame.

pub(super) fn clean(rows: &mut Vec<&str>) -> Option<&'static str> {
    if let Some(input) = narrow_idle_frame(rows) {
        rows.truncate(input);
        return None;
    }
    let mut bottom = rows
        .iter()
        .enumerate()
        .rev()
        .filter(|(_, r)| !r.trim().is_empty());
    let (last, row) = bottom.next()?;
    let (border, running) = if prompt_border(row) {
        (last, false)
    } else {
        let running = toolbar(row)?;
        let (index, row) = bottom.next()?;
        if !prompt_border(row) {
            return None;
        }
        (index, running)
    };
    let label = rows[..border]
        .iter()
        .rposition(|row| !matches!(row.trim(), "" | "┃"))?;
    let (mode, model) = gutter(rows[label])?.trim().split_once(" · ")?;
    if !matches!(mode, "Build" | "Plan") || model.trim().is_empty() {
        return None;
    }
    if last == border && !rows[..label].iter().any(|row| telemetry(row)) {
        return None;
    }

    rows.truncate(label);
    rows.retain(|row| !telemetry(row));
    // Drop the common left padding inside the gutter, keeping indentation
    // between code lines and between menu items and their descriptions.
    let padding = rows
        .iter()
        .filter_map(|row| gutter(row))
        .filter(|s| !s.trim().is_empty())
        .map(|s| s.len() - s.trim_start_matches(' ').len())
        .min()
        .unwrap_or(0);
    let mut previous_blank = true;
    rows.retain_mut(|row| {
        if let Some(inner) = gutter(row) {
            *row = if inner.trim().is_empty() {
                ""
            } else {
                &inner[padding..]
            };
        }
        let blank = row.trim().is_empty();
        let keep = !blank || !previous_blank;
        previous_blank = blank;
        keep
    });
    running.then_some("running")
}

// The narrow layout wraps the shortcut footer and model name, and draws a
// thin gutter around an empty input. Require the whole footer and input frame.
fn narrow_idle_frame(rows: &[&str]) -> Option<usize> {
    let border = rows.iter().rposition(|row| {
        let line = row.trim();
        line.chars().count() >= 4 && line.chars().all(|c| c == '▄')
    })?;
    let footer: Vec<_> = rows[border + 1..]
        .iter()
        .map(|row| row.trim())
        .filter(|s| !s.is_empty())
        .collect();
    let [counts, shortcuts] = footer.as_slice() else {
        return None;
    };
    if !counts.trim_end().ends_with("ctrl+p")
        || shortcuts.split_whitespace().last() != Some("commands")
        || !counts.contains('%')
        || !counts.contains('(')
        || !counts.contains(')')
        || counts.contains("interrupt")
        || shortcuts.contains("interrupt")
    {
        return None;
    }
    let label = rows[..border].iter().rposition(|row| {
        row.trim().strip_prefix('│').is_some_and(|inner| {
            inner.trim_start().starts_with("Build · ") || inner.trim_start().starts_with("Plan · ")
        })
    })?;
    // A wrapped model name can occupy at most two more gutter lines.
    if border - label > 3
        || !rows[label + 1..border]
            .iter()
            .all(|row| row.trim_start().starts_with('│'))
    {
        return None;
    }
    let input = rows[..label]
        .iter()
        .rposition(|row| !row.trim().is_empty())?;
    matches!(rows[input].trim(), "│ ▏" | "│" | "│ ▎").then_some(input)
}

fn gutter(row: &str) -> Option<&str> {
    let inner = row.trim_start_matches(' ').strip_prefix('┃')?;
    (inner.is_empty() || inner.starts_with(' ')).then_some(inner)
}

fn prompt_border(row: &str) -> bool {
    row.trim()
        .strip_prefix("╹▀▀")
        .is_some_and(|rest| rest.chars().all(|ch| ch == '▀'))
}

fn telemetry(row: &str) -> bool {
    let Some(status) = row.trim().strip_prefix('▣') else {
        return false;
    };
    let mut fields = status.split('·').map(str::trim);
    matches!(fields.next(), Some("Build" | "Plan"))
        && fields.next().is_some_and(|model| !model.is_empty())
        && fields
            .next()
            .is_some_and(|ttft| ttft.starts_with("Avg TTFT "))
        && fields
            .next()
            .is_some_and(|tps| tps.starts_with("Avg TPS ") && tps.ends_with(" tok/s"))
        && fields
            .next()
            .and_then(|calls| calls.strip_suffix(" LLM calls"))
            .is_some_and(|n| n.parse::<u64>().is_ok())
        && fields.next().is_none()
}

// Parse the complete key hints at the screen edge. Prose or menu items that
// quote either shortcut may also appear in the conversation above the prompt.
fn toolbar(row: &str) -> Option<bool> {
    let mut words = row.split_whitespace();
    if words.next_back()? != "commands" || words.next_back()? != "ctrl+p" {
        return None;
    }
    if words
        .clone()
        .next()
        .is_some_and(|s| s.chars().all(|ch| matches!(ch, '⬝' | '⠁'..='⣿')))
    {
        words.next();
    }
    let running = words.clone().take(2).eq(["esc", "interrupt"]);
    if running || words.clone().take(2).eq(["tab", "agents"]) {
        words.nth(1);
    }
    let counters = words.all(|word| {
        word == "·"
            || (word.bytes().any(|b| b.is_ascii_digit())
                && word
                    .chars()
                    .all(|ch| ch.is_ascii_digit() || ".,()%$€£¥KMGTk".contains(ch)))
    });
    counters.then_some(running)
}

#[cfg(test)]
mod tests {
    use super::clean;

    #[test]
    fn idle_frame_preserves_options_shortcut_help_and_relative_indent() {
        let mut rows = vec![
            "  ┃  1) Explain esc interrupt",
            "  ┃      [ ] ctrl+p commands",
            "  ┃  [x] Build · Deepseek Flash",
            "  ┃  | sed 's/a/b/'",
            "  ┃  Build · selected-model",
            "  ╹▀▀▀▀▀",
            "  tab agents   ctrl+p commands",
        ];
        assert_eq!(clean(&mut rows), None);
        assert_eq!(
            rows,
            [
                "1) Explain esc interrupt",
                "    [ ] ctrl+p commands",
                "[x] Build · Deepseek Flash",
                "| sed 's/a/b/'"
            ]
        );
    }

    #[test]
    fn shortcut_prose_at_the_bottom_of_a_frame_is_preserved() {
        for last in [
            "[ ] esc interrupt",
            "esc interrupt to cancel; ctrl+p commands",
            "running",
        ] {
            let mut rows = vec!["  ┃  output", "  ┃  Build · model", "  ╹▀▀▀▀▀", last];
            let original = rows.clone();
            assert_eq!(clean(&mut rows), None);
            assert_eq!(rows, original);
        }
    }
}
