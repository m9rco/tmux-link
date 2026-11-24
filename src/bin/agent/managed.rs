//! Host-side decisions. No pane content is sampled without a persistent, explicit per-session enable.
use crate::{codemaker::Pane, managed_decision as decision, snapshot};
use anyhow::{Context, Result, bail, ensure};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{
    fs,
    io::{self, Read},
    os::unix::fs::MetadataExt,
    path::Path,
    process::{Command, Stdio},
};
#[path = "managed_store.rs"]
mod store;
use store::{Binding, Session, State};

fn mode_style(action: &str) -> Option<(&str, &str)> {
    if action == "enable" {
        return Some(("menu", "balanced"));
    }
    let (mode, style) = action.strip_prefix("enable-")?.split_once('-')?;
    (matches!(mode, "observe" | "menu" | "assist")
        && matches!(style, "cautious" | "balanced" | "concise"))
    .then_some((mode, style))
}

fn session(id: u64, pane: &Pane) -> Result<Session> {
    let meta = fs::metadata(&pane.socket)?;
    Ok(Session {
        id,
        socket: pane.socket.clone(),
        server: pane.server_pid,
        created: pane.session_created,
        device: meta.dev(),
        inode: meta.ino(),
    })
}
fn unbound(session: Session, pane: &Pane) -> Binding {
    Binding {
        session,
        pane: pane.pane_id,
        pane_pid: pane.pane_pid,
        foreground: 0,
        started: String::new(),
        command: String::new(),
    }
}
fn bind(session: Session, pane: &Pane) -> Result<Binding> {
    let (foreground, started) = pane.foreground()?;
    let output = Command::new("ps")
        .env("LC_ALL", "C")
        .args(["-o", "comm=", "-p", &foreground.to_string()])
        .output()?;
    ensure!(output.status.success(), "前台进程已结束");
    let command = Path::new(std::str::from_utf8(&output.stdout)?.trim())
        .file_name()
        .and_then(|s| s.to_str())
        .context("无法读取前台进程身份")?
        .to_owned();
    ensure!(
        !command.is_empty() && command.len() <= 256,
        "无效的前台进程身份"
    );
    Ok(Binding {
        foreground,
        started,
        command,
        ..unbound(session, pane)
    })
}
fn matches_pane(binding: &Binding, pane: &Pane) -> Result<bool> {
    Ok(binding.session == session(binding.session.id, pane)?
        && binding.pane == pane.pane_id
        && binding.pane_pid == pane.pane_pid)
}
fn inspect(binding: &Binding) -> Result<Pane> {
    let pane = Pane::inspect_at(binding.session.id, Some(&binding.session.socket))?;
    ensure!(
        matches_pane(binding, &pane)? && bind(binding.session.clone(), &pane)? == *binding,
        "会话、活动窗格或前台程序已更改"
    );
    Ok(pane)
}

fn remove_marker(path: &Path) -> Result<()> {
    match fs::remove_file(path.with_extension("on")) {
        Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(()),
        result => Ok(result?),
    }
}

// Every caller holds the session lock, including during the one-time format migration.
fn load(path: &Path) -> Result<Option<State>> {
    let Some(mut state) = State::load(path)? else {
        return Ok(None);
    };
    if let Some(was_enabled) = state.legacy_enabled.take() {
        if was_enabled || state.pending.is_some() {
            state.cancel("托管已升级为手机前台分析，请重新启用。");
            state.state = "disabled".into();
        }
        state.enabled = false;
        state.save(path)?;
        remove_marker(path)?;
    }
    if state.expire(store::now()) {
        state.save(path)?;
    }
    Ok(Some(state))
}

fn disarm(state: &mut State, path: &Path, reason: &str) -> Result<()> {
    state.cancel(reason);
    state.reset_memory();
    state.enabled = false;
    state.state = "needsConfirmation".into();
    state.save(path)
}

pub(super) fn control(action: &str, id: u64, expected_instance: Option<&str>) -> Result<()> {
    let config = mode_style(action);
    ensure!(
        config.is_some() || matches!(action, "status" | "disable" | "forget"),
        "无效的托管操作"
    );
    let root = store::root()?;
    let pane = Pane::inspect(id)?;
    ensure!(
        expected_instance.is_none_or(|value| value == pane.instance()),
        "managed session changed"
    );
    let session = session(id, &pane)?;
    let path = session.path(&root)?;
    let guard = store::lock(&path.with_extension("lock"))?;
    let mut state = load(&path)?.unwrap_or_else(|| State::new(unbound(session.clone(), &pane)));
    ensure!(state.binding.session == session, "托管会话身份已更改");
    if let Some((mode, style)) = config {
        let current = bind(session, &pane)?;
        if !state.enabled || state.mode != mode || state.style != style || state.binding != current
        {
            state.cancel("托管设置已更改，先前分析已取消。");
            if state.binding != current {
                state.seen.clear();
                state.reset_memory();
            }
            state.binding = current;
            state.enabled = true;
            state.state = "watching".into();
            state.mode = mode.into();
            state.style = style.into();
            state.save(&path)?;
        }
    } else if action == "disable" {
        state.cancel("用户已停止托管。");
        state.enabled = false;
        state.state = "disabled".into();
        state.save(&path)?;
    } else if action == "forget" {
        state.forget();
        state.save(&path)?;
    } else if state.enabled
        && (!matches_pane(&state.binding, &pane)?
            || bind(session, &pane).ok().as_ref() != Some(&state.binding))
    {
        disarm(&mut state, &path, "活动窗格或前台程序已更改，请重新启用。")?;
    }
    let output = serde_json::to_string(&state.status())?;
    drop(guard);
    println!("{output}");
    Ok(())
}

// A v0.5 background supervisor exits when its last marker disappears. Rewriting the
// state under its own lock first also invalidates any model reply that is still in flight.
pub(super) fn retire_legacy() -> Result<()> {
    let root = store::root()?;
    let _gate = store::lock(&root.join("lifecycle.lock"))?;
    let mut first_error = None;
    for item in fs::read_dir(&root)? {
        let path = item?.path();
        if path.extension().is_some_and(|ext| ext == "on")
            && path
                .file_stem()
                .and_then(|stem| stem.to_str())
                .and_then(|s| s.strip_prefix("session-"))
                .is_some_and(|s| s.len() == 64 && s.bytes().all(|c| c.is_ascii_hexdigit()))
        {
            let result = retire_marker(&path.with_extension("json"));
            if let Err(err) = result {
                first_error.get_or_insert(err);
            }
        }
    }
    first_error.map_or(Ok(()), Err)
}

fn retire_marker(path: &Path) -> Result<()> {
    let _guard = store::lock(&path.with_extension("lock"))?;
    load(path)?;
    remove_marker(path)
}

#[cfg(all(feature = "tls", feature = "ssh-probe"))]
pub(super) fn resume() {
    if retire_legacy().is_err() {
        eprintln!("无法停用旧版托管进程。");
    }
}

#[derive(PartialEq, Eq)]
struct Frame {
    width: u32,
    height: u32,
    cursor_x: u32,
    cursor_y: u32,
    text: String,
}

fn sample(binding: &Binding) -> Result<Frame> {
    let target = format!("%{}", binding.pane);
    let mut child = Command::new("tmux")
        .arg("-S")
        .arg(&binding.session.socket)
        .args([
            "-u",
            "display-message",
            "-p",
            "-t",
            &target,
            "#{pane_width} #{pane_height} #{cursor_x} #{cursor_y}",
            ";",
            "capture-pane",
            "-e",
            "-p",
            "-t",
            &target,
        ])
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()?;
    let mut bytes = Vec::new();
    let read = child
        .stdout
        .take()
        .context("无窗格输出")?
        .take(256 * 1024 + 1)
        .read_to_end(&mut bytes);
    if read.is_err() || bytes.len() > 256 * 1024 {
        let _ = child.kill();
    }
    let status = child.wait()?;
    read?;
    ensure!(
        status.success() && bytes.len() <= 256 * 1024,
        "活动窗格超出采样范围"
    );
    let (header, text) = std::str::from_utf8(&bytes)?
        .split_once('\n')
        .context("缺少窗格尺寸")?;
    let dims = header
        .split_ascii_whitespace()
        .map(str::parse)
        .collect::<std::result::Result<Vec<u32>, _>>()?;
    let [width, height, cursor_x, cursor_y] = dims[..] else {
        bail!("无效的窗格尺寸")
    };
    let text = snapshot::plain_text(text)?;
    ensure!(text.lines().count() == height as usize, "窗格尺寸已改变");
    Ok(Frame {
        width,
        height,
        cursor_x,
        cursor_y,
        text,
    })
}

// tmux C/r can look for one POSIX ERE anywhere on the visible grid. Build the
// complement of the exact allowed rows, so a warning on a formerly blank row
// invalidates the send inside the same tmux command queue.
fn unexpected_row(suffixes: &[&str]) -> String {
    let mut prefixes = std::collections::BTreeMap::<char, Vec<&str>>::new();
    let mut allowed_end = false;
    for s in suffixes {
        if let Some(ch) = s.chars().next() {
            prefixes.entry(ch).or_default().push(&s[ch.len_utf8()..]);
        } else {
            allowed_end = true;
        }
    }
    if prefixes.is_empty() {
        return ".".to_owned();
    }
    let mut others = prefixes.keys().filter(|&&c| c != '-').collect::<String>();
    if prefixes.contains_key(&'-') {
        others.push('-');
    }
    let mut alternatives = vec![format!("[^{others}]")];
    if !allowed_end {
        alternatives.push("$".to_owned());
    }
    for (ch, rest) in prefixes {
        let escape = if ".()?".contains(ch) { "\\" } else { "" };
        alternatives.push(format!("{escape}{ch}{}", unexpected_row(&rest)));
    }
    format!("({})", alternatives.join("|"))
}

fn menu_guard(binding: &Binding, screen: &Frame) -> Option<String> {
    let mut checks = vec![
        format!("#{{==:#{{pid}},{}}}", binding.session.server),
        format!("#{{==:#{{session_created}},{}}}", binding.session.created),
        format!("#{{==:#{{s/^.//:pane_id}},{}}}", binding.pane),
        format!("#{{==:#{{pane_pid}},{}}}", binding.pane_pid),
        format!("#{{==:#{{pane_current_command}},{}}}", binding.command),
        format!("#{{==:#{{pane_width}},{}}}", screen.width),
        format!("#{{==:#{{pane_height}},{}}}", screen.height),
        format!("#{{==:#{{cursor_x}},{}}}", screen.cursor_x),
        format!("#{{==:#{{cursor_y}},{}}}", screen.cursor_y),
        "#{pane_active}".into(),
        "#{window_active}".into(),
        "#{alternate_on}".into(),
        "#{==:#{pane_dead},0}".into(),
        "#{==:#{pane_in_mode},0}".into(),
        "#{==:#{synchronize-panes},0}".into(),
        "#{==:#{window_linked},0}".into(),
    ];
    // C/r returns the visible row number. Only recognized menu text, represented
    // by literal anchored regexes, may enter tmux's format language.
    let mut permitted = vec![""];
    for (index, row) in screen.text.lines().enumerate() {
        let row = row.trim_end_matches(' ');
        if row.is_empty() {
            continue;
        }
        if row.len() > 256
            || !row
                .chars()
                .all(|c| c.is_alphanumeric() || " -.–():：?？。".contains(c))
        {
            return None;
        }
        let mut expr = String::new();
        permitted.push(row);
        for c in row.chars() {
            if ".()?".contains(c) {
                expr.push('\\');
            }
            expr.push(c);
        }
        checks.push(format!("#{{==:#{{C/r:^{expr}$}},{}}}", index + 1));
    }
    let other = unexpected_row(&permitted);
    if other.len() > 12 * 1024 {
        return None;
    }
    checks.push(format!("#{{==:#{{C/r:^{other}}},0}}"));
    while checks.len() > 1 {
        checks = checks
            .chunks(2)
            .map(|v| {
                if v.len() == 1 {
                    v[0].clone()
                } else {
                    format!("#{{&&:{},{}}}", v[0], v[1])
                }
            })
            .collect();
    }
    checks.pop()
}

fn checked_digit(binding: &Binding, screen: &Frame, digit: u8) -> Result<bool> {
    // A shell waiting behind a child can resume between ps and key delivery. Only
    // act when the approved application's own group leader is the pane root.
    if binding.foreground != binding.pane_pid
        || !matches!(
            binding.command.as_str(),
            "codemaker" | "opencode" | "claude" | "codex"
        )
        || !(b'1'..=b'9').contains(&digit)
    {
        return Ok(false);
    }
    let Some(condition) = menu_guard(binding, screen) else {
        return Ok(false);
    };
    let target = format!("${}:", binding.session.id);
    let action = format!(
        "send-keys -t '%{}' -H {:02x} ; display-message -p tmux-link-managed-applied",
        binding.pane, digit
    );
    let reply = Command::new("tmux")
        .arg("-S")
        .arg(&binding.session.socket)
        .args(["if-shell", "-F", "-t", &target, &condition, &action])
        .output()?;
    Ok(reply.status.success() && reply.stdout == b"tmux-link-managed-applied\n")
}

impl Frame {
    fn digest(&self, alternate: bool) -> String {
        let mut digest = Sha256::new();
        for n in [self.width, self.height, self.cursor_x, self.cursor_y] {
            digest.update(n.to_be_bytes());
        }
        digest.update([alternate as u8]);
        digest.update(self.text.as_bytes());
        format!("{:x}", digest.finalize())
    }
}

fn prompt(screen: &Frame, alternate: bool) -> Option<(decision::Prompt, bool)> {
    if let Some(p) = decision::detect(&screen.text) {
        return Some((p, true));
    }
    alternate
        .then(|| snapshot::clean_for_advisor(&screen.text))
        .flatten()
        .and_then(|text| decision::detect(&text))
        .map(|p| (p, false))
}

fn fingerprint(prompt: &decision::Prompt) -> Result<String> {
    Ok(format!("{:x}", Sha256::digest(serde_json::to_vec(prompt)?)))
}

fn claim_current(state: &mut State, path: &Path) -> Result<Option<Value>> {
    if !state.enabled || state.pending.is_some() || state.state == "budgetReached" {
        return Ok(None);
    }
    let pane = match inspect(&state.binding) {
        Ok(pane) => pane,
        Err(_) => {
            disarm(state, path, "活动窗格或前台程序已更改，请重新启用。")?;
            return Ok(None);
        }
    };
    let screen = sample(&state.binding)?;
    let Some((prompt, _)) = prompt(&screen, pane.alternate) else {
        return Ok(None);
    };
    let fingerprint = fingerprint(&prompt)?;
    let prior = state.state.clone();
    let Some(p) = state.begin(store::now(), &fingerprint, &screen.digest(pane.alternate))? else {
        if prior != state.state {
            state.save(path)?;
        }
        return Ok(None);
    };
    let request = decision::request(&prompt, &state.memory, &p.mode, &p.style)?;
    state.save(path)?;
    Ok(Some(
        json!({"ticket":format!("{:016x}",p.id),"request":request,"mode":p.mode,"style":p.style}),
    ))
}

pub(super) fn claim(id: u64, instance: &str) -> Result<()> {
    let unavailable = json!({"enabled":false,"claim":null});
    let Ok(pane) = Pane::inspect(id) else {
        println!("{unavailable}");
        return Ok(());
    };
    if pane.instance() != instance {
        println!("{unavailable}");
        return Ok(());
    }
    let session = session(id, &pane)?;
    let path = session.path(&store::root()?)?;
    let guard = store::lock(&path.with_extension("lock"))?;
    let Some(mut state) = load(&path)? else {
        println!("{unavailable}");
        return Ok(());
    };
    ensure!(state.binding.session == session, "托管会话身份已更改");
    let claim = claim_current(&mut state, &path)?;
    drop(guard);
    println!("{}", json!({"enabled":state.enabled,"claim":claim}));
    Ok(())
}

fn complete(
    state: &mut State,
    path: &Path,
    mut p: store::Pending,
    reply: Option<&Value>,
) -> Result<()> {
    let at = store::now();
    let Some(envelope) = reply else {
        state.pending = None;
        state.state = "error".into();
        state.record(
            at,
            &p,
            "failed",
            "未收到有效的手机模型响应，请核对原会话。",
            None,
            None,
        );
        return state.save(path);
    };
    let binding = &state.binding;
    let Ok(current) = inspect(binding) else {
        return disarm(state, path, "分析后前台身份发生变化，已停止托管。");
    };
    let verified = sample(binding)
        .ok()
        .filter(|frame| frame.digest(current.alternate) == p.frame_hash)
        .and_then(|frame| {
            let (prompt, whole) = prompt(&frame, current.alternate)?;
            (fingerprint(&prompt).ok()? == p.fingerprint).then_some((frame, prompt, whole))
        });
    let Some((screen, prompt, whole_menu)) = verified else {
        state.cancel("分析期间当前画面已变化，建议已撤回。");
        state.state = "watching".into();
        return state.save(path);
    };
    state.expire(store::now());
    if state.pending.is_none() {
        return state.save(path);
    }
    p.question = prompt.question.clone();
    let d = match decision::decode(envelope, &prompt) {
        Ok(d) => d,
        Err(_) => {
            state.pending = None;
            state.state = "error".into();
            state.record(
                at,
                &p,
                "failed",
                "模型服务未返回有效的决策与用量。",
                None,
                None,
            );
            return state.save(path);
        }
    };
    let mut outcome = if p.mode == "observe" {
        "observed"
    } else {
        "needsConfirmation"
    };
    let binding = &state.binding;
    let mut reason = d.reason.clone();
    if whole_menu
        && p.mode != "observe"
        && let Some(decision::Action::Digit(digit)) =
            decision::action(&prompt, &d, &binding.command, current.alternate, &p.mode)
    {
        // Commit intent before sending. An interrupted commit can never replay a key.
        state.pending.as_mut().context("手机请求已取消")?.sending = true;
        state.save(path)?;
        if checked_digit(binding, &screen, digit).unwrap_or(false) {
            outcome = "applied";
        } else {
            reason.push_str(" 当前输入目标未通过最终核对，请在原会话选择。");
        }
    }
    state.pending = None;
    state.state = if outcome == "needsConfirmation" {
        "needsConfirmation"
    } else {
        "watching"
    }
    .into();
    state.record(
        at,
        &p,
        outcome,
        &reason,
        d.choice.as_deref(),
        d.draft.as_deref(),
    );
    state.save(path)
}

pub(super) fn finish(id: u64, instance: &str, ticket: &str, outcome: Option<&[u8]>) -> Result<()> {
    ensure!(tmux_link::valid_advice_ticket(ticket), "无效的手机请求");
    ensure!(
        outcome.is_none_or(|b| b.len() <= tmux_link::MAX_ADVICE_RESPONSE),
        "手机响应过大"
    );
    let ticket = u64::from_str_radix(ticket, 16)?;
    let pane = Pane::inspect(id)?;
    ensure!(pane.instance() == instance, "managed session changed");
    let session = session(id, &pane)?;
    let path = session.path(&store::root()?)?;
    let guard = store::lock(&path.with_extension("lock"))?;
    let mut state = load(&path)?.context("托管记录不存在")?;
    ensure!(
        state.binding.session == session && state.has_charge(ticket),
        "未知或过期的手机请求"
    );
    let envelope = outcome.and_then(|b| serde_json::from_slice::<Value>(b).ok());
    let charged = envelope
        .as_ref()
        .and_then(decision::usage)
        .is_some_and(|n| state.usage(ticket, n));
    if let Some(p) = state
        .pending
        .clone()
        .filter(|p| state.enabled && p.id == ticket)
    {
        complete(&mut state, &path, p, envelope.as_ref())?;
    } else if charged {
        // A late receipt for a cancelled or expired request can only settle usage.
        state.save(&path)?;
    }
    let output = serde_json::to_string(&state.status())?;
    drop(guard);
    println!("{output}");
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{
        env,
        path::PathBuf,
        thread,
        time::{Duration, Instant},
    };
    fn state() -> State {
        let s = Session {
            id: 2,
            socket: "/tmp/fixture".into(),
            server: 42,
            created: 100,
            device: 1,
            inode: 2,
        };
        let mut state = State::new(Binding {
            session: s,
            pane: 3,
            pane_pid: 44,
            foreground: 44,
            started: "fixture".into(),
            command: "codemaker".into(),
        });
        state.enabled = true;
        state
    }
    #[test]
    fn reserves_once_before_analysis_and_charges_actual_usage() {
        let mut s = state();
        let p = s.begin(100, "original", "frame-a").unwrap().unwrap();
        assert!(s.begin(101, "other", "frame-b").unwrap().is_none());
        let mut s: State = serde_json::from_slice(&serde_json::to_vec(&s).unwrap()).unwrap();
        s.cancel("restart");
        s.usage(p.id, 439);
        assert!(s.begin(101, "original", "frame-a").unwrap().is_none());
        assert_eq!(s.status().tokens_today, 439);
        for i in 1..12 {
            s.begin(100 + i, &format!("q-{i}"), "frame")
                .unwrap()
                .unwrap();
            s.pending = None;
        }
        assert!(s.begin(200, "over", "frame").unwrap().is_none());
        assert_eq!(s.state, "budgetReached");
        assert!(s.begin(86_500, "new", "frame").unwrap().is_some());
        assert_eq!(s.status().calls_today, 12);
    }
    #[test]
    fn forget_cancels_in_flight_releases_content_and_retains_dedup_and_budget() {
        let mut s = state();
        let p = s.begin(100, "p", "frame").unwrap().unwrap();
        s.record(
            100,
            &p,
            "observed",
            "Display only",
            Some("CSV"),
            Some("Review CSV"),
        );
        assert!(s.memory.contains("CSV"));
        s.forget();
        assert!(s.records.is_empty() && s.memory.is_empty() && s.pending.is_none());
        s.usage(p.id, 123);
        assert_eq!(s.status().tokens_today, 123);
        assert!(s.begin(101, "p", "frame").unwrap().is_none());
    }
    #[test]
    fn expired_and_uncertain_sends_do_not_reissue_or_replay() {
        let mut s = state();
        let p = s
            .begin(100, "prompt-digest", "frame-digest")
            .unwrap()
            .unwrap();
        let saved = serde_json::to_value(s.pending.as_ref().unwrap()).unwrap();
        assert!(saved.get("question").is_none());
        assert!(!s.expire(219));
        assert!(s.expire(220));
        assert!(s.pending.is_none());
        assert!(
            s.begin(221, "prompt-digest", "another-frame")
                .unwrap()
                .is_none()
        );
        assert_eq!(s.records[0].outcome, "interrupted");
        assert!(s.usage(p.id, 731));
        assert!(!s.usage(p.id, 963));
        assert_eq!(s.status().tokens_today, 731);

        s.begin(222, "next-prompt", "next-frame").unwrap().unwrap();
        s.pending.as_mut().unwrap().sending = true;
        let mut recovered: State =
            serde_json::from_value(serde_json::to_value(s).unwrap()).unwrap();
        assert!(recovered.expire(222));
        assert!(recovered.records[0].reason.contains("提交意图"));
        assert!(
            recovered
                .begin(223, "next-prompt", "next-frame")
                .unwrap()
                .is_none()
        );
    }

    #[test]
    fn retiring_legacy_authorization_preserves_records_and_disarms_old_workers() {
        let dir = env::temp_dir().join(format!("managed-migrate-{:016x}", store::nonce().unwrap()));
        fs::create_dir(&dir).unwrap();
        let path = dir.join("session-fixture.json");
        let mut s = state();
        let now = store::now();
        let mut p = s.begin(now, "abc", "digest").unwrap().unwrap();
        p.question = "Previous safe question?".into();
        s.record(now, &p, "applied", "Previous reason", Some("CSV"), None);
        s.usage(p.id, 42);
        s.pending = None;
        s.begin(now, "ghi", "digest").unwrap().unwrap();
        let mut legacy = serde_json::to_value(&s).unwrap();
        legacy.as_object_mut().unwrap().remove("phone_enabled");
        legacy["enabled"] = json!(true);
        legacy["pending"]["question"] = json!("Legacy in-flight question?");
        for field in ["created_at", "frame_hash", "fingerprint"] {
            legacy["pending"].as_object_mut().unwrap().remove(field);
        }
        store::write(&path, &serde_json::to_vec(&legacy).unwrap()).unwrap();
        store::write(&path.with_extension("on"), b"").unwrap();
        let recovered = load(&path).unwrap().unwrap();
        assert!(!recovered.enabled && recovered.pending.is_none());
        assert_eq!(recovered.records[0].outcome, "interrupted");
        assert_eq!(recovered.records[1].question, "Previous safe question?");
        assert!(recovered.memory.contains("Previous reason"));
        assert_eq!(recovered.status().calls_today, 2);
        assert_eq!(recovered.status().tokens_today, 42);
        assert!(!path.with_extension("on").exists());
        let saved: Value = serde_json::from_slice(&fs::read(&path).unwrap()).unwrap();
        assert!(saved.get("enabled").is_none());
        assert_eq!(saved["phone_enabled"], false);
        assert_eq!(load(&path).unwrap().unwrap().records.len(), 2);
        fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn session_number_reuse_and_other_servers_have_distinct_slots() {
        let s = state();
        let session = &s.binding.session;
        let p = session.path(Path::new("/private")).unwrap();
        for different in [
            Session {
                created: 200,
                ..session.clone()
            },
            Session {
                inode: 3,
                ..session.clone()
            },
            Session {
                server: 43,
                ..session.clone()
            },
        ] {
            assert_ne!(p, different.path(Path::new("/private")).unwrap());
        }
        assert!(mode_style("enable-assist-cautious").is_some());
        assert!(mode_style("enable-assist-cautious-extra").is_none());
    }
    #[test]
    fn memory_outlives_the_budget_window_and_never_resurrects_an_old_binding() {
        let mut s = state();
        let mut p = s.begin(100, "abc", "frame").unwrap().unwrap();
        for at in 100..180 {
            s.record(at, &p, "observed", "Old reason", Some("Old choice"), None);
        }
        s.expire(90_000);
        assert!(s.memory.contains("Old reason") && s.memory.contains("待人工核实"));
        assert_eq!(s.records.len(), 64);
        assert_eq!(s.status().calls_today, 0);
        s.reset_memory();
        p.question = "New question?".into();
        s.record(
            90_001,
            &p,
            "applied",
            "New reason",
            Some("New choice"),
            None,
        );
        assert!(!s.memory.contains("Old"));
        assert!(s.memory.contains("New reason") && s.memory.contains("当时代选"));
    }

    #[test]
    fn tmux_guard_refuses_a_reordered_resized_or_synchronized_menu() {
        struct Fixture(PathBuf);
        impl Fixture {
            fn call(&self, args: &[&str]) -> String {
                let out = Command::new("tmux")
                    .env_remove("TMUX")
                    .args(["-u", "-f", "/dev/null", "-S"])
                    .arg(&self.0)
                    .args(args)
                    .output()
                    .unwrap();
                assert!(out.status.success(), "{args:?}");
                String::from_utf8(out.stdout).unwrap().trim_end().into()
            }
        }
        impl Drop for Fixture {
            fn drop(&mut self) {
                let _ = Command::new("tmux")
                    .arg("-S")
                    .arg(&self.0)
                    .arg("kill-server")
                    .output();
                let _ = fs::remove_dir_all(self.0.parent().unwrap());
            }
        }
        let root = env::temp_dir().join(format!("managed-guard-{:016x}", store::nonce().unwrap()));
        fs::create_dir(&root).unwrap();
        let server = Fixture(root.join("sock"));
        server.call(&["new-session","-d","-x","70","-y","10","sh","-c",
            "printf '\\033[?1049h\\033[HSelect format?\\r\\n1. CSV\\r\\n2. JSON\\r\\nPress 1-2 to submit'; sleep 30"]);
        let pane = Pane::inspect_at(0, Some(&server.0)).unwrap();
        let mut binding = unbound(session(0, &pane).unwrap(), &pane);
        let deadline = Instant::now() + Duration::from_secs(3);
        let mut frame = loop {
            let s = sample(&binding).unwrap();
            if s.text.contains("Press 1-2") {
                break s;
            }
            assert!(Instant::now() < deadline);
            thread::sleep(Duration::from_millis(10));
        };
        binding.command = server.call(&[
            "display-message",
            "-p",
            "-t",
            "%0",
            "#{pane_current_command}",
        ]);
        let evaluate = |frame: &Frame| {
            server.call(&[
                "display-message",
                "-p",
                "-t",
                "$0:",
                &menu_guard(&binding, frame).unwrap(),
            ])
        };
        assert_eq!(evaluate(&frame), "1");
        // Simulate a frame taken while the bottom line was still blank. The
        // existing frame has one additional visible row at the same cursor.
        let complete = frame.text.clone();
        frame.text = frame.text.replace("Press 1-2 to submit", "");
        assert_eq!(evaluate(&frame), "0");
        frame.text = complete;
        frame.text = frame.text.replace("1. CSV\n2. JSON", "2. JSON\n1. CSV");
        assert_eq!(evaluate(&frame), "0");
        let original = sample(&binding).unwrap();
        server.call(&["resize-window", "-x", "80", "-y", "10"]);
        assert_eq!(evaluate(&original), "0");
        let resized = sample(&binding).unwrap();
        assert_eq!(evaluate(&resized), "1");
        server.call(&["set-window-option", "synchronize-panes", "on"]);
        assert_eq!(evaluate(&resized), "0");
    }
}
