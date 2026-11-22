//! Optional outbound-agent broker. Only trust device identity from a loopback TLS proxy.
use anyhow::{Context, Result, ensure};
use fs2::FileExt;
use serde::{Deserialize, Serialize};
use std::{
    collections::{HashMap, VecDeque},
    fs::{self, File, OpenOptions},
    os::unix::fs::{OpenOptionsExt, PermissionsExt},
    path::PathBuf,
    time::Duration,
};
use tmux_link::pairing::{self, HostInfo, Reply, Request};
use tokio::{
    io::{AsyncWriteExt, DuplexStream, copy_bidirectional},
    sync::Mutex,
    time::timeout,
};

#[derive(Clone, Serialize, Deserialize)]
struct Record {
    id: String,
    token_hash: String,
    code_hash: String,
    created: u64,
    host: HostInfo,
    device: Option<String>,
    phone_key: Option<String>,
}

pub struct Broker {
    directory: PathBuf,
    records: Mutex<Vec<Record>>,
    tunnels: Mutex<HashMap<String, VecDeque<DuplexStream>>>,
    _lock: File,
}

impl Broker {
    pub fn open(directory: PathBuf) -> Result<Self> {
        ensure!(
            directory.is_absolute(),
            "pairing directory must be absolute"
        );
        fs::create_dir_all(&directory)?;
        fs::set_permissions(&directory, fs::Permissions::from_mode(0o700))?;
        let lock = OpenOptions::new()
            .create(true)
            .truncate(false)
            .read(true)
            .write(true)
            .mode(0o600)
            .open(directory.join("lock"))?;
        lock.try_lock_exclusive()
            .context("pairing directory already in use")?;
        let file = directory.join("hosts.json");
        let records = match fs::read(file) {
            Ok(bytes) => serde_json::from_slice::<Vec<Record>>(&bytes)?,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Vec::new(),
            Err(error) => return Err(error.into()),
        };
        ensure!(records.len() <= 128, "pairing registry is too large");
        Ok(Self {
            directory,
            records: Mutex::new(records),
            tunnels: Mutex::new(HashMap::new()),
            _lock: lock,
        })
    }

    fn persist(&self, records: &[Record]) -> Result<()> {
        let path = self.directory.join("hosts.new");
        let mut file = OpenOptions::new()
            .create(true)
            .truncate(true)
            .write(true)
            .mode(0o600)
            .open(&path)?;
        std::io::Write::write_all(&mut file, &serde_json::to_vec(records)?)?;
        file.sync_all()?;
        fs::rename(path, self.directory.join("hosts.json"))?;
        File::open(&self.directory)?.sync_all()?;
        Ok(())
    }

    async fn record(&self, token: &str) -> Result<Record> {
        ensure!(pairing::valid_secret(token), "invalid agent credential");
        let digest = pairing::hash(token);
        self.records
            .lock()
            .await
            .iter()
            .find(|r| r.token_hash == digest)
            .cloned()
            .context("unknown agent")
    }

    async fn control(&self, route: &str, device: &str, message: Request) -> Result<Reply> {
        match (route, message) {
            ("/tmux-link/pair", Request::Ready { id }) => {
                ensure!(
                    !device.is_empty()
                        && self
                            .records
                            .lock()
                            .await
                            .iter()
                            .any(|r| r.id == id && r.device.as_deref() == Some(device)),
                    "device is not authorized for this host"
                );
                let ready = self
                    .tunnels
                    .lock()
                    .await
                    .get(&id)
                    .is_some_and(|q| !q.is_empty());
                Ok(Reply {
                    id,
                    approved: true,
                    ready,
                    ..Reply::default()
                })
            }
            ("/tmux-link/register", Request::Register { token, code, host }) => {
                ensure!(
                    pairing::valid_secret(&token) && pairing::valid_secret(&code),
                    "invalid pairing credentials"
                );
                host.validate()?;
                let digest = pairing::hash(&token);
                let code_hash = pairing::hash(&code);
                let id = digest[..32].to_owned();
                let mut records = self.records.lock().await;
                let mut next: Vec<_> = records
                    .iter()
                    .filter(|r| {
                        r.device.is_some()
                            || pairing::now().saturating_sub(r.created) < pairing::PAIR_TTL
                    })
                    .cloned()
                    .collect();
                if let Some(old) = next.iter().find(|r| r.id == id) {
                    ensure!(
                        old.token_hash == digest && old.code_hash == code_hash && old.host == host,
                        "registration differs from saved host"
                    );
                    return Ok(Reply {
                        id,
                        approved: old.device.is_some(),
                        ..Reply::default()
                    });
                }
                ensure!(
                    next.len() < 128 && !next.iter().any(|r| r.code_hash == code_hash),
                    "pairing registry is full or code already used"
                );
                next.push(Record {
                    id: id.clone(),
                    token_hash: digest,
                    code_hash,
                    created: pairing::now(),
                    host,
                    device: None,
                    phone_key: None,
                });
                self.persist(&next)?;
                *records = next;
                Ok(Reply {
                    id,
                    ..Reply::default()
                })
            }
            ("/tmux-link/register", Request::Status { token }) => {
                let record = self.record(&token).await?;
                ensure!(
                    record.device.is_some()
                        || pairing::now().saturating_sub(record.created) < pairing::PAIR_TTL,
                    "pairing expired; run pair again"
                );
                Ok(Reply {
                    id: record.id,
                    approved: record.device.is_some(),
                    phone_key: record.phone_key,
                    ..Reply::default()
                })
            }
            (
                "/tmux-link/pair",
                Request::Approve {
                    code,
                    pin,
                    phone_key,
                },
            ) => {
                ensure!(
                    !device.is_empty() && pairing::valid_secret(&code),
                    "device authentication required"
                );
                let key = pairing::public_key(&phone_key)?;
                let digest = pairing::hash(&code);
                let mut records = self.records.lock().await;
                let mut next = records.clone();
                let record = next
                    .iter_mut()
                    .find(|r| r.code_hash == digest)
                    .context("pairing not found")?;
                ensure!(
                    record.host.pin == pin,
                    "host fingerprint differs from the pairing link"
                );
                if let Some(owner) = &record.device {
                    ensure!(
                        owner == device && record.phone_key.as_deref() == Some(&key),
                        "pairing already claimed"
                    );
                } else {
                    ensure!(
                        pairing::now().saturating_sub(record.created) < pairing::PAIR_TTL,
                        "pairing expired"
                    );
                    record.device = Some(device.to_owned());
                    record.phone_key = Some(key);
                }
                let id = record.id.clone();
                self.persist(&next)?;
                *records = next;
                Ok(Reply {
                    id,
                    approved: true,
                    ..Reply::default()
                })
            }
            _ => anyhow::bail!("unsupported pairing request"),
        }
    }

    pub async fn handle(&self, path: &str, device: &str, mut stream: DuplexStream) -> Result<()> {
        if let Some(id) = path.strip_prefix("/tmux-link/session/") {
            let allowed =
                self.records.lock().await.iter().any(|r| {
                    r.id == id && r.device.as_deref() == Some(device) && !device.is_empty()
                });
            ensure!(allowed, "device is not authorized for this host");
            // A stale standby socket must never delay all the other healthy sockets.
            for _ in 0..4 {
                let agent = self
                    .tunnels
                    .lock()
                    .await
                    .get_mut(id)
                    .and_then(VecDeque::pop_front);
                let Some(mut agent) = agent else {
                    anyhow::bail!("host offline; reconnect after the host is online");
                };
                let started = timeout(Duration::from_secs(3), async {
                    pairing::write(
                        &mut agent,
                        &Reply {
                            id: id.to_owned(),
                            ready: true,
                            ..Reply::default()
                        },
                    )
                    .await?;
                    let reply: Reply = pairing::read(&mut agent).await?;
                    ensure!(
                        reply.ready && reply.error.is_none(),
                        "local SSH is unavailable"
                    );
                    Ok::<_, anyhow::Error>(())
                })
                .await;
                if matches!(started, Ok(Ok(()))) {
                    copy_bidirectional(&mut stream, &mut agent).await?;
                    return Ok(());
                }
            }
            anyhow::bail!("no healthy host tunnel available");
        }
        let message: Request =
            timeout(Duration::from_secs(10), pairing::read(&mut stream)).await??;
        if path == "/tmux-link/tunnel" {
            let Request::Tunnel { token } = message else {
                anyhow::bail!("expected agent credential");
            };
            let record = self.record(&token).await?;
            ensure!(record.device.is_some(), "pairing not approved");
            pairing::write(
                &mut stream,
                &Reply {
                    id: record.id.clone(),
                    approved: true,
                    ..Reply::default()
                },
            )
            .await?;
            let mut tunnels = self.tunnels.lock().await;
            let queue = tunnels.entry(record.id).or_default();
            if queue.len() >= 4 {
                queue.pop_front();
            }
            queue.push_back(stream);
            return Ok(());
        }
        let reply = self
            .control(path, device, message)
            .await
            .unwrap_or_else(|error| Reply {
                error: Some(error.to_string()),
                ..Reply::default()
            });
        pairing::write(&mut stream, &reply).await?;
        stream.shutdown().await?;
        Ok(())
    }

    pub fn recognizes(path: &str) -> bool {
        matches!(
            path,
            "/tmux-link/register" | "/tmux-link/pair" | "/tmux-link/tunnel"
        ) || path.strip_prefix("/tmux-link/session/").is_some_and(|id| {
            id.len() == 32
                && id
                    .bytes()
                    .all(|b| b.is_ascii_hexdigit() && !b.is_ascii_uppercase())
        })
    }
}
