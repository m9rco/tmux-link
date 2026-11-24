//! Host-side decisions. No pane content is sampled without a persistent, explicit per-session enable.
use crate::{codemaker::Pane, managed_decision as decision, snapshot};
use anyhow::{Context, Result, bail, ensure};
use fs2::FileExt;
use sha2::{Digest, Sha256};
use std::{
    collections::{HashMap, HashSet},
    env, fs,
    io::{self, BufRead, IsTerminal, Read},
    os::{
        fd::AsRawFd,
        unix::{fs::MetadataExt, process::CommandExt},
    },
    path::{Path, PathBuf},
    process::{Command, Stdio},
    sync::mpsc,
    thread,
    time::{Duration, Instant},
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

fn key(root: &Path) -> Result<Option<String>> {
    store::read(&root.join("api-key"), 512)?
        .map(|bytes| String::from_utf8(bytes).context("节点 API Key 格式无效"))
        .transpose()
}
pub(super) fn set_key() -> Result<()> {
    ensure!(
        env::var_os("SSH_ORIGINAL_COMMAND").is_none(),
        "请在节点本机配置 API Key"
    );
    struct Echo(libc::termios);
    impl Drop for Echo {
        fn drop(&mut self) {
            unsafe {
                libc::tcsetattr(0, libc::TCSANOW, &self.0);
            }
            eprintln!();
        }
    }
    let input = io::stdin();
    let echo = if input.is_terminal() {
        eprint!("DeepSeek API Key: ");
        let mut saved = std::mem::MaybeUninit::uninit();
        ensure!(
            unsafe { libc::tcgetattr(input.as_raw_fd(), saved.as_mut_ptr()) } == 0,
            "无法安全读取终端输入"
        );
        let saved = unsafe { saved.assume_init() };
        let mut hidden = saved;
        hidden.c_lflag &= !(libc::ECHO | libc::ECHONL);
        ensure!(
            unsafe { libc::tcsetattr(0, libc::TCSANOW, &hidden) } == 0,
            "无法关闭输入回显"
        );
        Some(Echo(saved))
    } else {
        None
    };
    let mut value = String::new();
    input.lock().take(515).read_line(&mut value)?;
    drop(echo);
    let value = value.trim_end_matches(['\n', '\r']);
    ensure!(
        (1..=512).contains(&value.len()) && value.bytes().all(|b| b.is_ascii_graphic()),
        "密钥格式无效"
    );
    store::write(&store::root()?.join("api-key"), value.as_bytes())?;
    println!("节点 DeepSeek API Key 已保存。");
    Ok(())
}

fn marker(path: &Path, on: bool) -> Result<()> {
    let flag = path.with_extension("on");
    if on {
        store::write(&flag, b"")
    } else {
        match fs::remove_file(flag) {
            Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(()),
            other => other.map_err(Into::into),
        }
    }
}
fn disarm(state: &mut State, path: &Path, reason: &str) -> Result<()> {
    state.cancel(reason);
    state.reset_memory();
    state.enabled = false;
    state.state = "needsConfirmation".into();
    state.save(path)?;
    marker(path, false)
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
    let ready = key(&root)?.is_some();
    if action == "status" && path.with_extension("on").try_exists()? {
        let _gate = store::lock(&root.join("lifecycle.lock"))?;
        start_worker(&root)?;
    }
    let lifecycle = if config.is_some() {
        Some(store::lock(&root.join("lifecycle.lock"))?)
    } else {
        None
    };
    let guard = store::lock(&path.with_extension("lock"))?;
    let mut state =
        State::load(&path)?.unwrap_or_else(|| State::new(unbound(session.clone(), &pane)));
    ensure!(state.binding.session == session, "托管会话身份已更改");
    state.expire(store::now());
    if let Some((mode, style)) = config {
        ensure!(ready, "请先在此节点配置 DeepSeek API Key");
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
            marker(&path, true)?;
            state.save(&path)?;
        }
        if let Err(error) = start_worker(&root) {
            state.enabled = false;
            state.cancel("后台进程启动失败。");
            state.state = "error".into();
            state.save(&path)?;
            marker(&path, false)?;
            return Err(error);
        }
    } else if action == "disable" {
        state.cancel("用户已停止托管。");
        state.enabled = false;
        state.state = "disabled".into();
        state.save(&path)?;
        marker(&path, false)?;
    } else if action == "forget" {
        state.forget();
        state.save(&path)?;
    } else if state.enabled
        && (!matches_pane(&state.binding, &pane)?
            || bind(session, &pane).ok().as_ref() != Some(&state.binding))
    {
        disarm(&mut state, &path, "活动窗格或前台程序已更改；请重新启用。")?;
    }
    let output = serde_json::to_string(&state.status(ready))?;
    drop(guard);
    drop(lifecycle);
    println!("{output}");
    Ok(())
}

fn active(root: &Path) -> Result<Vec<PathBuf>> {
    let mut paths = Vec::new();
    for e in fs::read_dir(root)? {
        let path = e?.path();
        if path.extension().is_some_and(|s| s == "on")
            && path
                .file_stem()
                .and_then(|s| s.to_str())
                .and_then(|s| s.strip_prefix("session-"))
                .is_some_and(|s| s.len() == 64 && s.bytes().all(|c| c.is_ascii_hexdigit()))
        {
            paths.push(path.with_extension("json"));
        }
    }
    paths.sort();
    Ok(paths)
}

// Caller serializes startup against other enables and the worker's idle shutdown.
fn start_worker(root: &Path) -> Result<()> {
    let lease = store::lock_file(&root.join("worker.lock"))?;
    match lease.try_lock_exclusive() {
        Err(e) if e.kind() == io::ErrorKind::WouldBlock => return Ok(()),
        r => r?,
    }
    FileExt::unlock(&lease)?;
    let mut cmd = Command::new(env::current_exe()?);
    cmd.arg("managed-worker")
        .current_dir("/")
        .env_remove("SSH_ORIGINAL_COMMAND")
        .env_remove("TMUX")
        .env_remove("TMUX_PANE")
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null());
    // Mark unexpected inherited descriptors close-on-exec; std's child-error pipe
    // must remain usable until exec itself. Only async-signal-safe calls run here.
    let maxfd = unsafe { libc::sysconf(libc::_SC_OPEN_MAX) };
    unsafe {
        cmd.pre_exec(move || {
            if libc::setsid() < 0 {
                return Err(io::Error::last_os_error());
            }
            for fd in 3..maxfd.min(i32::MAX as _) as i32 {
                libc::fcntl(fd, libc::F_SETFD, libc::FD_CLOEXEC);
            }
            Ok(())
        });
    }
    let mut child = cmd.spawn().context("不能启动节点托管进程")?;
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        if child.try_wait()?.is_some() {
            bail!("节点托管进程提前退出");
        }
        match lease.try_lock_exclusive() {
            Err(e) if e.kind() == io::ErrorKind::WouldBlock => break,
            Ok(()) => FileExt::unlock(&lease)?,
            Err(e) => return Err(e.into()),
        }
        if Instant::now() >= deadline {
            let _ = child.kill();
            let _ = child.wait();
            bail!("节点托管进程启动超时");
        }
        thread::sleep(Duration::from_millis(30));
    }
    thread::spawn(move || child.wait());
    Ok(())
}

pub(super) fn resume() {
    let result = (|| -> Result<()> {
        let root = store::root()?;
        let _guard = store::lock(&root.join("lifecycle.lock"))?;
        if !active(&root)?.is_empty() {
            start_worker(&root)?;
        }
        Ok(())
    })();
    if result.is_err() {
        eprintln!("无法恢复节点托管进程。");
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

fn tick(root: &Path, path: &Path) -> Result<bool> {
    let lock_path = path.with_extension("lock");
    let binding = {
        let _lock = store::lock(&lock_path)?;
        let Some(mut state) = State::load(path)? else {
            marker(path, false)?;
            return Ok(false);
        };
        ensure!(
            state.binding.session.path(root)? == path,
            "托管身份和记录不符"
        );
        if !state.enabled {
            marker(path, false)?;
            return Ok(false);
        }
        if state.pending.is_some() {
            state.cancel("节点进程已重启，先前请求的执行结果须人工核对。");
            state.state = "needsConfirmation".into();
            state.save(path)?;
        }
        state.binding
    };
    let pane = match inspect(&binding) {
        Ok(pane) => pane,
        Err(_) => {
            let _lock = store::lock(&lock_path)?;
            if let Some(mut state) = State::load(path)?
                && state.enabled
                && state.binding == binding
            {
                disarm(&mut state, path, "会话、窗格或前台程序已更改，请重新启用。")?;
            }
            return Ok(false);
        }
    };
    let screen = sample(&binding)?;
    let direct = decision::detect(&screen.text);
    let whole_menu = direct.is_some();
    // Recognized app decorations may be stripped for a recommendation. Input
    // requires the actual full frame to pass the local menu policy.
    let Some(prompt) = direct.or_else(|| {
        pane.alternate
            .then(|| snapshot::clean_for_advisor(&screen.text))
            .flatten()
            .and_then(|text| decision::detect(&text))
    }) else {
        return Ok(false);
    };
    let fingerprint = format!("{:x}", Sha256::digest(serde_json::to_vec(&prompt)?));
    let (p, memory, key) = {
        let _lock = store::lock(&lock_path)?;
        let mut state = State::load(path)?.context("托管记录已删除")?;
        if !state.enabled || state.binding != binding {
            return Ok(false);
        }
        let Some(key) = key(root)? else {
            state.enabled = false;
            state.state = "error".into();
            state.save(path)?;
            marker(path, false)?;
            return Ok(false);
        };
        // Never transmit the API credential as pane content or recalled memory.
        if serde_json::to_string(&prompt)?.contains(&key) || state.memory.contains(&key) {
            return Ok(false);
        }
        let prior = state.state.clone();
        let Some(p) = state.begin(store::now(), &fingerprint, &prompt.question)? else {
            if prior != state.state {
                state.save(path)?;
            }
            return Ok(false);
        };
        state.save(path)?; // Claim this prompt and charge before the network request.
        (p, state.memory, key)
    };
    let result = decision::decide(&key, &prompt, &memory, &p.mode, &p.style);
    let _lock = store::lock(&lock_path)?;
    let Some(mut state) = State::load(path)? else {
        return Ok(false);
    };
    if let Ok(d) = &result {
        state.usage(p.id, d.tokens);
    }
    if !state.enabled
        || state.binding != binding
        || state.pending.as_ref().map(|p| p.id) != Some(p.id)
    {
        // A concurrent stop, forget or mode change cancelled authorization. Retain billing only.
        state.save(path)?;
        return Ok(false);
    }
    let at = store::now();
    let d = match result {
        Ok(d) => d,
        Err(err) => {
            state.pending = None;
            state.state = "error".into();
            state.record(at, &p, "failed", &err.to_string(), None, None);
            state.save(path)?;
            return Ok(true);
        }
    };
    let current = match inspect(&binding) {
        Ok(current) => current,
        Err(_) => {
            disarm(&mut state, path, "分析后前台身份发生变化，已停止托管。")?;
            return Ok(true);
        }
    };
    if sample(&binding).ok().as_ref() != Some(&screen) {
        state.pending = None;
        state.state = "watching".into();
        state.record(
            at,
            &p,
            "interrupted",
            "分析期间当前画面已变化，建议已撤回。",
            None,
            None,
        );
        state.save(path)?;
        return Ok(true);
    }
    let mut outcome = if p.mode == "observe" {
        "observed"
    } else {
        "needsConfirmation"
    };
    let mut reason = d.reason.clone();
    if whole_menu
        && p.mode != "observe"
        && let Some(decision::Action::Digit(digit)) = decision::action(
            &prompt,
            &d,
            &binding.command,
            current.alternate && pane.alternate,
            &p.mode,
        )
    {
        // Commit an at-most-once intent before sending. A crash at any later line
        // creates an interrupted audit record on restart; it never replays the key.
        state.pending.as_mut().unwrap().sending = true;
        state.save(path)?;
        if checked_digit(&binding, &screen, digit).unwrap_or(false) {
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
    state.save(path)?;
    Ok(true)
}

pub(super) fn supervise() -> Result<()> {
    ensure!(
        env::var_os("SSH_ORIGINAL_COMMAND").is_none(),
        "worker 只能在节点本机运行"
    );
    let root = store::root()?;
    let lease = store::lock_file(&root.join("worker.lock"))?;
    match lease.try_lock_exclusive() {
        Err(e) if e.kind() == io::ErrorKind::WouldBlock => return Ok(()),
        r => r?,
    }
    let (tx, rx) = mpsc::channel::<(PathBuf, bool)>();
    let mut running = HashSet::new();
    let mut schedule: HashMap<PathBuf, (Instant, u64)> = HashMap::new();
    loop {
        let paths = active(&root)?;
        if paths.is_empty() && running.is_empty() {
            let _gate = store::lock(&root.join("lifecycle.lock"))?;
            if active(&root)?.is_empty() {
                drop(lease);
                return Ok(());
            }
            continue;
        }
        let now = Instant::now();
        schedule.retain(|p, _| running.contains(p) || paths.contains(p));
        for path in paths {
            schedule.entry(path).or_insert((now, 2));
        }
        let mut ready = schedule
            .iter()
            .filter(|(p, (due, _))| *due <= now && !running.contains(*p))
            .map(|(p, (due, _))| (*due, p.clone()))
            .collect::<Vec<_>>();
        ready.sort();
        for (_, path) in ready.into_iter().take(4usize.saturating_sub(running.len())) {
            running.insert(path.clone());
            let root = root.clone();
            let tx = tx.clone();
            thread::spawn(move || {
                let worked = std::panic::catch_unwind(|| tick(&root, &path))
                    .ok()
                    .and_then(Result::ok)
                    .unwrap_or(false);
                let _ = tx.send((path, worked));
            });
        }
        if let Ok((path, worked)) = rx.recv_timeout(Duration::from_secs(1)) {
            running.remove(&path);
            let previous = schedule.get(&path).map_or(2, |(_, n)| *n);
            let delay = if worked { 2 } else { (previous * 2).min(20) };
            schedule.insert(path, (Instant::now() + Duration::from_secs(delay), delay));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
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
        let p = s.begin(100, "original", "Example?").unwrap().unwrap();
        assert!(s.begin(101, "other", "Other?").unwrap().is_none());
        let mut s: State = serde_json::from_slice(&serde_json::to_vec(&s).unwrap()).unwrap();
        s.cancel("restart");
        s.usage(p.id, 439);
        assert!(s.begin(101, "original", "Example?").unwrap().is_none());
        assert_eq!(s.status(true).tokens_today, 439);
        for i in 1..12 {
            s.begin(100 + i, &format!("q-{i}"), "Question?")
                .unwrap()
                .unwrap();
            s.pending = None;
        }
        assert!(s.begin(200, "over", "Over?").unwrap().is_none());
        assert_eq!(s.state, "budgetReached");
        assert!(s.begin(86_500, "new", "New?").unwrap().is_some());
        assert_eq!(s.status(true).calls_today, 12);
    }
    #[test]
    fn forget_cancels_in_flight_releases_content_and_retains_dedup_and_budget() {
        let mut s = state();
        let p = s.begin(100, "p", "Format?").unwrap().unwrap();
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
        assert_eq!(s.status(true).tokens_today, 123);
        assert!(s.begin(101, "p", "Format?").unwrap().is_none());
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
        let mut p = s.begin(100, "abc", "Old question?").unwrap().unwrap();
        for at in 100..180 {
            s.record(at, &p, "observed", "Old reason", Some("Old choice"), None);
        }
        s.expire(90_000);
        assert!(s.memory.contains("Old reason") && s.memory.contains("待人工核实"));
        assert_eq!(s.records.len(), 64);
        assert_eq!(s.status(true).calls_today, 0);
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
