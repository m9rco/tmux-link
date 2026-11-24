//! Recognize only the current prompt at the foot of a bounded, unstyled grid.
use serde::Serialize;

const LANGUAGE: &[&str] = &["请用简体中文回复。", "请用英文回复。"];
const FORMAT: &[&str] = &["请用纯文本展示。", "请用 Markdown 展示。"];
const DETAIL: &[&str] = &["请简短说明。", "请详细说明。"];

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub(crate) struct Prompt {
    pub question: String,
    pub options: Vec<String>,
    pub background: Vec<String>,
    pub navigation: Option<Navigation>,
    input: Input,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub(crate) struct Navigation {
    hint: String,
    pub(super) multiple: bool,
    focused: Option<usize>,
    checked: Vec<usize>,
    submit_focused: bool,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
enum Input {
    Manual,
    Digit,
    Preference,
}

#[derive(Debug, PartialEq, Eq)]
pub(crate) enum Action {
    Digit(u8),
}

pub(crate) fn is_fixed_preference(value: &str) -> bool {
    [LANGUAGE, FORMAT, DETAIL]
        .iter()
        .any(|group| group.contains(&value))
}

pub(super) fn action_for(
    prompt: &Prompt,
    index: usize,
    foreground: &str,
    alternate: bool,
    mode: &str,
) -> Option<Action> {
    if !alternate || !matches!(foreground, "codex" | "opencode" | "codemaker" | "claude") {
        return None;
    }
    let selected = prompt.options.get(index)?;
    if index >= 9 {
        return None;
    }
    match (prompt.input, mode) {
        (Input::Digit, "menu" | "assist") => Some(Action::Digit(b'1' + index as u8)),
        (Input::Preference, "assist") if is_fixed_preference(selected) => {
            Some(Action::Digit(b'1' + index as u8))
        }
        _ => None,
    }
}

fn heading(text: &str) -> String {
    text.trim_end_matches(['?', '？', ':', '：'])
        .trim_end()
        .to_ascii_lowercase()
}

fn preference_options(question: &str) -> Option<&'static [&'static str]> {
    match heading(question).as_str() {
        "which language should i use for my reply"
        | "which response language do you prefer"
        | "你希望我用哪种语言回复"
        | "你希望我用什么语言回复" => Some(LANGUAGE),
        "which display format do you prefer"
        | "which format should i use for my reply"
        | "你希望我用什么格式展示回复" => Some(FORMAT),
        "how detailed should my reply be" | "你希望我简短说明还是详细说明" => {
            Some(DETAIL)
        }
        _ => None,
    }
}

fn safe_menu(question: &str, options: &[String]) -> bool {
    let labels: &[&str] = match heading(question).as_str() {
        "select export format"
        | "choose export format"
        | "select display format"
        | "choose display format"
        | "选择导出格式"
        | "选择显示格式" => &["csv", "json", "markdown", "plain text", "纯文本"],
        "select theme" | "choose theme" | "select interface theme" | "选择界面主题" => {
            &["light", "dark", "system", "浅色", "深色", "跟随系统"]
        }
        "select display language" | "choose display language" | "选择显示语言" | "选择界面语言" => {
            &[
                "english",
                "简体中文",
                "繁體中文",
                "日本語",
                "français",
                "deutsch",
                "español",
            ]
        }
        _ => return false,
    };
    options
        .iter()
        .all(|s| labels.contains(&s.to_ascii_lowercase().as_str()))
}

fn numbered(line: &str) -> Option<(usize, &str)> {
    let bytes = line.as_bytes();
    if !matches!(bytes.first(), Some(b'1'..=b'9')) || !matches!(bytes.get(1), Some(b'.' | b')')) {
        return None;
    }
    let label = line[2..].strip_prefix(' ')?.trim();
    (!label.is_empty()).then_some(((bytes[0] - b'0') as usize, label))
}

fn digit_footer(text: &str, count: usize) -> bool {
    let literal = text.to_ascii_lowercase();
    [
        "press 1-{n} to submit",
        "press 1–{n} to submit",
        "按 1-{n} 提交",
        "按 1–{n} 提交",
    ]
    .iter()
    .any(|pattern| literal == pattern.replace("{n}", &count.to_string()))
}

fn question(line: &str) -> bool {
    line.len() <= 480
        && !["$ ", "% ", "# ", "❯ ", "> "]
            .iter()
            .any(|s| line.starts_with(s))
        && (line.ends_with(['?', '？'])
            || line.ends_with([':', '：'])
                && ["select ", "choose ", "选择", "请选择"]
                    .iter()
                    .any(|prefix| line.to_ascii_lowercase().starts_with(prefix)))
}

fn progress(line: &str) -> bool {
    let lower = line.to_ascii_lowercase();
    [
        "esc to interrupt",
        "esc interrupt",
        "in progress",
        "running…",
        "working…",
        "正在运行",
        "正在执行",
    ]
    .iter()
    .any(|p| lower.contains(p))
        || line.chars().any(|c| ('⠁'..='⣿').contains(&c))
}

// Skip private material as a whole line.
pub(super) fn sensitive(line: &str) -> bool {
    let lower = line.to_ascii_lowercase();
    [
        "-----begin ",
        "private key",
        "password",
        "passwd",
        "secret",
        "token",
        "authorization",
        "bearer ",
        "api_key",
        "api-key",
        "api key",
        "apikey",
        "cookie",
        "://",
        "sk-",
        "ghp_",
        "github_pat_",
        "akia",
        "/users/",
        "/home/",
        "/root/",
        "/etc/",
        "/opt/",
        "/var/",
        "/private/",
        "/srv/",
        "/mnt/",
        "/tmp/",
        "/volumes/",
        "~/",
        "密码",
        "密钥",
        "令牌",
    ]
    .iter()
    .any(|s| lower.contains(s))
        || line.contains(['@', '=', '\\'])
        || line
            .split(|c: char| !(c.is_ascii_hexdigit() || matches!(c, '.' | ':')))
            .any(|word| word.parse::<std::net::IpAddr>().is_ok())
        || line
            .split(|c: char| !c.is_ascii_alphanumeric() && !matches!(c, '_' | '-'))
            .any(|s| s.len() >= 32)
}

fn background(rows: &[&str], question: &str) -> Vec<String> {
    let mut found = Vec::new();
    let mut labels = Vec::new();
    let q = question.replace(' ', "").to_ascii_lowercase();
    for row in rows.iter().rev().take(16) {
        let row = row.trim();
        if row.ends_with(['?', '？']) || row.starts_with("User:") || row.starts_with("Assistant:")
        {
            break;
        }
        if sensitive(row) || row.chars().any(char::is_control) {
            continue;
        }
        let label = if let Some((label, details)) = row.split_once([':', '：']) {
            let label = label.trim().to_ascii_lowercase();
            if details.trim().is_empty()
                || !matches!(
                    label.as_str(),
                    "goal"
                        | "constraint"
                        | "reason"
                        | "preference"
                        | "目标"
                        | "约束"
                        | "原因"
                        | "偏好"
                )
            {
                continue;
            }
            label
        } else if let Some((n, _)) = numbered(row)
            && (q.contains(&format!("第{n}步")) || q.contains(&format!("step{n}")))
        {
            format!("step{n}")
        } else {
            continue;
        };
        if !labels.contains(&label) {
            labels.push(label);
            found.push(row.chars().take(96).collect());
        }
        if found.len() == 4 {
            break;
        }
    }
    found.reverse();
    found
}

fn wrapped_question(rows: &[&str], end: usize) -> (usize, String) {
    let last = rows[end].trim();
    let mut current = last.to_owned();
    for offset in 1..=3 {
        let Some(start) = end.checked_sub(offset) else {
            break;
        };
        let row = rows[start].trim();
        if row.is_empty()
            || row.len() > 180
            || sensitive(row)
            || numbered(row).is_some()
            || row.contains(['。', '？', '?', '：', ':'])
            || row.ends_with(['.', '!', '！'])
        {
            break;
        }
        current = format!("{row} {current}");
        let lower = row.to_ascii_lowercase();
        if [
            "要先",
            "是否",
            "需要",
            "请问",
            "要不要",
            "你希望",
            "可以",
            "should ",
            "which ",
            "would ",
            "do you ",
        ]
        .iter()
        .any(|s| lower.starts_with(s))
            && current.len() <= 480
        {
            return (start, current);
        }
    }
    (end, last.to_owned())
}

pub(crate) fn detect(text: &str) -> Option<Prompt> {
    if text.len() > 32 * 1024
        || text.lines().count() > 160
        || text
            .chars()
            .any(|c| c.is_control() && !matches!(c, '\n' | '\r' | '\t'))
        || text.lines().any(progress)
    {
        return None;
    }
    if let Some(prompt) = plain_prompt(text).or_else(|| navigation_prompt(text)) {
        return Some(prompt);
    }
    let clean = crate::snapshot::clean_for_advisor(text)?;
    let mut prompt = plain_prompt(&clean).or_else(|| navigation_prompt(&clean))?;
    prompt.input = Input::Manual;
    Some(prompt)
}

fn plain_prompt(text: &str) -> Option<Prompt> {
    let lines: Vec<_> = text.lines().collect();
    let rows: Vec<_> = lines
        .iter()
        .map(|s| s.trim())
        .filter(|s| !s.is_empty())
        .collect();
    let last = *rows.last()?;
    let text_footer = matches!(
        last.to_ascii_lowercase().as_str(),
        "enter to submit" | "press enter to submit" | "按 enter 提交" | "按回车提交"
    );
    let mut end = rows.len();
    if text_footer || (numbered(last).is_none() && !question(last)) {
        end -= 1;
    }
    let mut start = end;
    while start > 0 && numbered(rows[start - 1]).is_some() {
        start -= 1;
    }
    if start != end {
        let raw_question = *rows.get(start.checked_sub(1)?)?;
        if !(2..=9).contains(&(end - start)) || !question(raw_question) || sensitive(raw_question) {
            return None;
        }
        let mut options = Vec::new();
        for (i, row) in rows[start..end].iter().enumerate() {
            let (number, label) = numbered(row)?;
            if number != i + 1
                || label.len() > 240
                || sensitive(label)
                || options
                    .iter()
                    .any(|s: &String| s.eq_ignore_ascii_case(label))
            {
                return None;
            }
            options.push(label.to_owned());
        }
        let footer = rows.get(end).copied();
        let digits = footer.is_some_and(|s| digit_footer(s, options.len()));
        // Don't revive a menu above a shell prompt or unrelated output.
        if let Some(s) = footer
            && !digits
        {
            let lower = s.to_ascii_lowercase();
            let n = options.len();
            let selection_only = [
                format!("press 1-{n} to select"),
                format!("press 1–{n} to select"),
                format!("按 1-{n} 选择"),
                format!("按 1–{n} 选择"),
            ]
            .contains(&lower);
            let separate_confirmation =
                lower.starts_with("press 1-") && lower.contains("enter to confirm");
            if !selection_only
                && !separate_confirmation
                && !matches!(
                    lower.as_str(),
                    "enter to select"
                        | "↑/↓ to navigate · enter to select"
                        | "use arrow keys and press enter"
                        | "press enter to select"
                        | "按回车选择"
                )
            {
                return None;
            }
        }
        let mut input = Input::Manual;
        if start == 1 && digits {
            if safe_menu(raw_question, &options) {
                input = Input::Digit;
            } else if let Some(allowed) = preference_options(raw_question)
                && options.iter().all(|s| allowed.contains(&s.as_str()))
            {
                input = Input::Preference;
            }
        }
        return Some(Prompt {
            question: raw_question.into(),
            options,
            background: background(&rows[..start - 1], raw_question),
            navigation: None,
            input,
        });
    }
    let marker = matches!(rows.get(end.checked_sub(1)?), Some(&">" | &"❯" | &"›"));
    let offset = if text_footer && marker {
        2
    } else if !text_footer && end == rows.len() {
        1
    } else {
        return None;
    };
    let question_index = end.checked_sub(offset)?;
    let current = rows[question_index];
    if !question(current) || sensitive(current) {
        return None;
    }
    let line = lines.iter().rposition(|s| s.trim() == current)?;
    let (start, current) = wrapped_question(&lines, line);
    Some(Prompt {
        background: background(&lines[..start], &current),
        question: current,
        options: Vec::new(),
        navigation: None,
        input: Input::Manual,
    })
}

fn navigation_help(row: &str) -> bool {
    let text = row.to_ascii_lowercase();
    text.len() <= 160
        && text.split(['·', '•', '，', ',']).all(|part| {
            matches!(
                part.trim(),
                "↑↓ navigate"
                    | "↑/↓ to navigate"
                    | "↑/↓ navigate"
                    | "↑↓ 移动"
                    | "上下键移动"
                    | "space to toggle"
                    | "space to select"
                    | "空格切换"
                    | "空格选择"
                    | "按空格选择"
                    | "enter to submit"
                    | "enter to select"
                    | "enter to confirm"
                    | "enter 确认"
                    | "回车确认"
                    | "回车提交"
                    | "按回车提交"
                    | "esc to cancel"
                    | "esc 取消"
            )
        })
}

fn checkbox(row: &str) -> Option<(&str, bool, bool)> {
    for (prefix, checked, multiple) in [
        ("[ ]", false, true),
        ("[x]", true, true),
        ("[X]", true, true),
        ("☐", false, true),
        ("☑", true, true),
        ("◯", false, false),
        ("○", false, false),
        ("◉", true, false),
        ("●", true, false),
        ("( )", false, false),
        ("(*)", true, false),
    ] {
        if let Some(label) = row.strip_prefix(prefix) {
            return Some((label.trim_start(), checked, multiple));
        }
    }
    None
}

fn navigation_prompt(text: &str) -> Option<Prompt> {
    let lines: Vec<_> = text.trim_end().lines().collect();
    let (footer, body) = lines.split_last()?;
    let hint = footer.trim();
    if !navigation_help(hint) {
        return None;
    }
    let start = body.iter().rposition(|row| {
        let row = row.trim();
        question(row) || row.starts_with("请选择") || row.starts_with("选择一项")
    })?;
    let (start_question, heading) = wrapped_question(body, start);
    if heading.len() > 480 || sensitive(&heading) || body.len() - start > 32 {
        return None;
    }
    let mut nav = Navigation {
        hint: hint.into(),
        multiple: hint.to_ascii_lowercase().contains("space") || hint.contains("空格"),
        checked: Vec::new(),
        focused: None,
        submit_focused: false,
    };
    let mut rendered = false;
    let mut options = Vec::<String>::new();
    let mut prior_indent = None;
    for &raw in &body[start + 1..] {
        let line = raw.trim();
        if line.is_empty() {
            continue;
        }
        let indent = raw.len() - raw.trim_start().len();
        let focus = line.starts_with(['❯', '›', '▶', '▸']) || line.starts_with("> ");
        let mut label = if focus {
            line.chars()
                .next()
                .and_then(|c| line.strip_prefix(c))?
                .trim_start()
        } else {
            line
        };
        if matches!(
            label.to_ascii_lowercase().as_str(),
            "submit" | "submit answers" | "提交" | "提交答案"
        ) {
            nav.submit_focused = focus;
            continue;
        }
        let check = checkbox(label);
        if let Some((inner, checked, multi)) = check {
            label = inner;
            nav.multiple |= multi;
            if checked {
                nav.checked.push(options.len() + 1);
            }
        }
        let numbered = numbered(label).is_some();
        if label.is_empty()
            || label.len() > 240
            || sensitive(label)
            || label.chars().any(char::is_control)
        {
            return None;
        }
        if !focus
            && check.is_none()
            && !numbered
            && prior_indent.is_some_and(|previous| indent >= previous + 4)
        {
            let prior = options.last_mut()?;
            if prior.len() + label.len() > 240 {
                return None;
            }
            prior.push(' ');
            prior.push_str(label);
            continue;
        }
        prior_indent = Some(indent);
        rendered |= focus || check.is_some() || numbered;
        if focus && nav.focused.replace(options.len() + 1).is_some() {
            return None;
        }
        // Keep printed numeric labels intact: advisory indexes refer to the array, not hotkeys.
        if options.len() == 12 || options.iter().any(|s| s.eq_ignore_ascii_case(label)) {
            return None;
        }
        options.push(label.into());
    }
    if options.len() < 2 || !rendered {
        return None;
    }
    Some(Prompt {
        background: background(&body[..start_question], &heading),
        question: heading,
        options,
        navigation: Some(nav),
        input: Input::Manual,
    })
}
