//! Private per-session state. All replacements, including a charge reservation, are synced before use.
use anyhow::{Context, Result, ensure};
use fs2::FileExt;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::{
    env,
    fs::{self, File, OpenOptions},
    io::{ErrorKind, Read, Write},
    os::unix::fs::{DirBuilderExt, MetadataExt, OpenOptionsExt},
    path::{Path, PathBuf},
    time::{SystemTime, UNIX_EPOCH},
};

const DAY: u64 = 86_400;
pub(super) const MAX_CALLS: usize = 12;
const LEASE_SECONDS: u64 = 120;

pub(super) fn now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}

pub(super) fn nonce() -> Result<u64> {
    getrandom::u64().map_err(|_| anyhow::anyhow!("could not generate operation identity"))
}

pub(super) fn root() -> Result<PathBuf> {
    let home = PathBuf::from(env::var_os("HOME").context("HOME unavailable")?);
    ensure!(home.is_absolute(), "invalid home directory");
    let root = home.join(".config/tmux-link/managed");
    fs::DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(&root)?;
    let m = fs::symlink_metadata(&root)?;
    ensure!(
        m.is_dir() && m.uid() == unsafe { libc::geteuid() } && m.mode() & 0o077 == 0,
        "managed directory must be private (0700)"
    );
    Ok(root)
}

fn private(file: &File) -> Result<()> {
    let m = file.metadata()?;
    ensure!(
        m.is_file()
            && m.uid() == unsafe { libc::geteuid() }
            && m.mode() & 0o077 == 0
            && m.nlink() == 1,
        "invalid managed file permissions"
    );
    Ok(())
}

pub(super) fn lock_file(path: &Path) -> Result<File> {
    let file = OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
        .mode(0o600)
        .open(path)?;
    private(&file)?;
    Ok(file)
}

pub(super) fn lock(path: &Path) -> Result<File> {
    let file = lock_file(path)?;
    file.lock_exclusive()?;
    Ok(file)
}

pub(super) fn read(path: &Path, max: usize) -> Result<Option<Vec<u8>>> {
    let f = match OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
        .open(path)
    {
        Ok(f) => f,
        Err(e) if e.kind() == ErrorKind::NotFound => return Ok(None),
        Err(e) => return Err(e.into()),
    };
    private(&f)?;
    let mut buf = Vec::new();
    f.take((max + 1) as u64).read_to_end(&mut buf)?;
    ensure!(buf.len() <= max, "oversize managed file");
    Ok(Some(buf))
}

pub(super) fn write(path: &Path, bytes: &[u8]) -> Result<()> {
    let parent = path.parent().context("missing managed file directory")?;
    let tmp = parent.join(format!(".write-{:016x}", nonce()?));
    let mut f = OpenOptions::new()
        .create_new(true)
        .write(true)
        .mode(0o600)
        .open(&tmp)?;
    let result = (|| -> Result<()> {
        f.write_all(bytes)?;
        f.sync_all()?;
        fs::rename(&tmp, path)?;
        File::open(parent)?.sync_all()?;
        Ok(())
    })();
    if result.is_err() {
        let _ = fs::remove_file(tmp);
    }
    result
}

#[derive(Clone, PartialEq, Eq, Deserialize, Serialize)]
pub(super) struct Session {
    pub id: u64,
    pub socket: PathBuf,
    pub server: u32,
    pub created: u64,
    pub device: u64,
    pub inode: u64,
}

impl Session {
    pub fn path(&self, root: &Path) -> Result<PathBuf> {
        let digest = Sha256::digest(serde_json::to_vec(self)?);
        Ok(root.join(format!("session-{digest:x}.json")))
    }
}

#[derive(Clone, PartialEq, Eq, Deserialize, Serialize)]
pub(super) struct Binding {
    pub session: Session,
    pub pane: u64,
    pub pane_pid: u32,
    pub foreground: u32,
    pub started: String,
    pub command: String,
}

#[derive(Clone, Deserialize, Serialize)]
pub(super) struct Record {
    pub at: u64,
    pub question: String,
    pub choice: Option<String>,
    pub reason: String,
    pub outcome: String,
    pub mode: String,
    pub style: String,
    pub draft: Option<String>,
}

#[derive(Deserialize, Serialize)]
struct Charge {
    at: u64,
    id: u64,
    tokens: u64,
}

#[derive(Clone, Deserialize, Serialize)]
pub(super) struct Pending {
    pub id: u64,
    #[serde(default)]
    pub created_at: u64,
    #[serde(default)]
    pub frame_hash: String,
    #[serde(default)]
    pub fingerprint: String,
    // Filled from the verified live frame only when recording the result.
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub question: String,
    pub mode: String,
    pub style: String,
    pub sending: bool,
}

#[derive(Deserialize, Serialize)]
pub(super) struct State {
    pub binding: Binding,
    // An old detached worker requires its own "enabled" field to deserialize this file.
    // Dropping that field on migration also invalidates work already in flight.
    #[serde(default, rename = "enabled", skip_serializing)]
    pub legacy_enabled: Option<bool>,
    #[serde(default, rename = "phone_enabled")]
    pub enabled: bool,
    pub mode: String,
    pub style: String,
    pub state: String,
    pub pending: Option<Pending>,
    pub seen: Vec<String>,
    charges: Vec<Charge>,
    pub memory: String,
    #[serde(default)]
    memory_records: usize,
    pub records: Vec<Record>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct Status<'a> {
    pub enabled: bool,
    pub state: &'a str,
    pub calls_today: usize,
    pub tokens_today: u64,
    pub mode: &'a str,
    pub style: &'a str,
    pub memory: &'a str,
    pub records: &'a [Record],
}

impl State {
    pub fn new(binding: Binding) -> Self {
        Self {
            binding,
            legacy_enabled: None,
            enabled: false,
            mode: "menu".into(),
            style: "balanced".into(),
            state: "disabled".into(),
            pending: None,
            seen: vec![],
            charges: vec![],
            memory: String::new(),
            memory_records: 0,
            records: vec![],
        }
    }
    pub fn load(path: &Path) -> Result<Option<Self>> {
        read(path, 1024 * 1024)?
            .map(|bytes| serde_json::from_slice(&bytes).context("invalid managed state"))
            .transpose()
    }
    pub fn save(&self, path: &Path) -> Result<()> {
        write(path, &serde_json::to_vec(self)?)
    }
    pub fn expire(&mut self, at: u64) -> bool {
        let previous_count = self.charges.len();
        let mut changed = false;
        if self
            .pending
            .as_ref()
            .is_some_and(|p| p.sending || at < p.created_at || at - p.created_at >= LEASE_SECONDS)
        {
            self.cancel("手机请求已中断或过期，请核对原会话。");
            self.state = "needsConfirmation".into();
            changed = true;
        }
        self.charges.retain(|c| at.saturating_sub(c.at) < DAY);
        if self.state == "budgetReached" && self.charges.len() < MAX_CALLS {
            self.state = "watching".into();
            changed = true;
        }
        changed || self.charges.len() != previous_count
    }
    pub fn reset_memory(&mut self) {
        self.memory_records = 0;
        self.memory.clear();
    }
    fn refresh_memory(&mut self) {
        let notes = self
            .records
            .iter()
            .take(self.memory_records)
            .filter(|r| {
                matches!(
                    r.outcome.as_str(),
                    "applied" | "observed" | "needsConfirmation"
                )
            })
            .take(3)
            .map(|r| {
                let label = if r.outcome == "applied" {
                    "当时代选"
                } else {
                    "当时建议，待人工核实"
                };
                format!(
                    "{label} · {} · {} · {}",
                    r.question.chars().take(64).collect::<String>(),
                    r.choice
                        .as_deref()
                        .unwrap_or("无")
                        .chars()
                        .take(32)
                        .collect::<String>(),
                    r.reason.chars().take(48).collect::<String>()
                )
            })
            .collect::<Vec<_>>();
        self.memory = notes.join("\n").chars().take(480).collect();
    }
    pub fn status(&self) -> Status<'_> {
        Status {
            enabled: self.enabled,
            state: &self.state,
            calls_today: self.charges.len(),
            tokens_today: self
                .charges
                .iter()
                .fold(0_u64, |a, c| a.saturating_add(c.tokens)),
            mode: &self.mode,
            style: &self.style,
            memory: &self.memory,
            records: &self.records,
        }
    }
    pub fn begin(
        &mut self,
        at: u64,
        fingerprint: &str,
        frame_hash: &str,
    ) -> Result<Option<Pending>> {
        self.expire(at);
        if !self.enabled || self.pending.is_some() || self.seen.iter().any(|f| f == fingerprint) {
            return Ok(None);
        }
        if self.charges.len() >= MAX_CALLS {
            self.state = "budgetReached".into();
            return Ok(None);
        }
        let p = Pending {
            id: nonce()?,
            created_at: at,
            frame_hash: frame_hash.into(),
            fingerprint: fingerprint.into(),
            question: String::new(),
            mode: self.mode.clone(),
            style: self.style.clone(),
            sending: false,
        };
        self.seen.push(fingerprint.to_owned());
        if self.seen.len() > 128 {
            self.seen.remove(0);
        }
        self.charges.push(Charge {
            at,
            id: p.id,
            tokens: 0,
        });
        self.pending = Some(p.clone());
        self.state = "analyzing".into();
        Ok(Some(p))
    }
    pub fn has_charge(&self, id: u64) -> bool {
        self.charges.iter().any(|c| c.id == id)
    }
    pub fn usage(&mut self, id: u64, tokens: u64) -> bool {
        if let Some(charge) = self
            .charges
            .iter_mut()
            .find(|c| c.id == id && c.tokens == 0)
        {
            charge.tokens = tokens;
            return true;
        }
        false
    }
    pub fn record(
        &mut self,
        at: u64,
        p: &Pending,
        outcome: &str,
        reason: &str,
        choice: Option<&str>,
        draft: Option<&str>,
    ) {
        let choice = choice.map(|s| s.chars().take(256).collect::<String>());
        let reason = reason.chars().take(500).collect::<String>();
        self.records.insert(
            0,
            Record {
                at,
                question: p.question.chars().take(500).collect(),
                choice: choice.clone(),
                reason,
                outcome: outcome.into(),
                mode: p.mode.clone(),
                style: p.style.clone(),
                draft: draft.map(|s| s.chars().take(256).collect()),
            },
        );
        self.records.truncate(64);
        self.memory_records = (self.memory_records + 1).min(self.records.len());
        self.refresh_memory();
    }
    pub fn cancel(&mut self, reason: &str) {
        if let Some(p) = self.pending.take() {
            let note = if p.sending {
                format!("{reason} 已记下提交意图，实际结果请核对原会话。")
            } else {
                reason.to_string()
            };
            self.record(now(), &p, "interrupted", &note, None, None);
        }
    }
    pub fn forget(&mut self) {
        self.pending = None;
        self.reset_memory();
        self.records.clear();
        self.state = if self.enabled { "watching" } else { "disabled" }.into();
    }
}
