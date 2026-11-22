//! Size-limited control messages for outbound host pairing.
use anyhow::{Result, ensure};
use base64::{Engine, engine::general_purpose::STANDARD};
use serde::{Deserialize, Serialize, de::DeserializeOwned};
use sha2::{Digest, Sha256};
use std::time::{SystemTime, UNIX_EPOCH};
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};

pub const MAX_CONTROL: usize = 8192;
pub const PAIR_TTL: u64 = 600;

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct HostInfo {
    pub name: String,
    pub user: String,
    pub pin: String,
}

impl HostInfo {
    pub fn validate(&self) -> Result<()> {
        ensure!(
            !self.name.trim().is_empty()
                && self.name.len() <= 128
                && !self.name.chars().any(char::is_control),
            "invalid host name"
        );
        ensure!(
            !self.user.is_empty()
                && self.user.len() <= 128
                && !self
                    .user
                    .chars()
                    .any(|c| c.is_whitespace() || c.is_control()),
            "invalid host user"
        );
        let digest = self.pin.strip_prefix("SHA256:").unwrap_or("");
        let bytes = base64::engine::general_purpose::STANDARD_NO_PAD.decode(digest)?;
        ensure!(bytes.len() == 32, "invalid host fingerprint");
        Ok(())
    }
}

#[derive(Serialize, Deserialize)]
#[serde(tag = "action", rename_all = "snake_case", deny_unknown_fields)]
pub enum Request {
    Register {
        token: String,
        code: String,
        host: HostInfo,
    },
    Status {
        token: String,
    },
    Approve {
        code: String,
        pin: String,
        phone_key: String,
    },
    Tunnel {
        token: String,
    },
    Ready {
        id: String,
    },
}

#[derive(Default, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Reply {
    pub id: String,
    #[serde(default)]
    pub approved: bool,
    #[serde(default)]
    pub ready: bool,
    #[serde(default)]
    pub phone_key: Option<String>,
    #[serde(default)]
    pub error: Option<String>,
}

pub fn now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}

pub fn secret() -> Result<String> {
    let mut bytes = [0u8; 32];
    getrandom::fill(&mut bytes).map_err(|err| anyhow::anyhow!("{err}"))?;
    Ok(bytes.iter().map(|b| format!("{b:02x}")).collect())
}

pub fn valid_secret(text: &str) -> bool {
    text.len() == 64
        && text
            .bytes()
            .all(|b| b.is_ascii_hexdigit() && !b.is_ascii_uppercase())
}

pub fn hash(text: &str) -> String {
    Sha256::digest(text.as_bytes())
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect()
}

pub fn public_key(text: &str) -> Result<String> {
    let fields: Vec<_> = text.split_whitespace().collect();
    ensure!(
        fields.len() >= 2 && fields.len() <= 3 && fields[0] == "ssh-ed25519",
        "expected an Ed25519 phone public key"
    );
    let bytes = STANDARD.decode(fields[1])?;
    ensure!(
        bytes.len() == 51 && bytes[..19] == *b"\0\0\0\x0bssh-ed25519\0\0\0\x20",
        "invalid phone public key"
    );
    Ok(format!("ssh-ed25519 {}", fields[1]))
}

pub async fn read<T: DeserializeOwned>(stream: &mut (impl AsyncRead + Unpin)) -> Result<T> {
    let length = stream.read_u32().await? as usize;
    ensure!((1..=MAX_CONTROL).contains(&length), "invalid control size");
    let mut bytes = vec![0; length];
    stream.read_exact(&mut bytes).await?;
    Ok(serde_json::from_slice(&bytes)?)
}

pub async fn write<T: Serialize>(stream: &mut (impl AsyncWrite + Unpin), value: &T) -> Result<()> {
    let bytes = serde_json::to_vec(value)?;
    ensure!(bytes.len() <= MAX_CONTROL, "control message too large");
    stream.write_u32(bytes.len() as u32).await?;
    stream.write_all(&bytes).await?;
    stream.flush().await?;
    Ok(())
}

pub fn checked(reply: Reply) -> Result<Reply> {
    if let Some(error) = &reply.error {
        anyhow::bail!("{error}");
    }
    Ok(reply)
}

#[cfg(feature = "tls")]
pub async fn request(url: &str, message: &Request) -> Result<Reply> {
    tokio::time::timeout(std::time::Duration::from_secs(20), async {
        let mut stream = crate::websocket::connect(url).await?;
        write(&mut stream, message).await?;
        checked(read(&mut stream).await?)
    })
    .await?
}
