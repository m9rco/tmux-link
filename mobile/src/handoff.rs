use super::{Output, Peer, PinnedHost, authenticated};
use anyhow::{Context, Result};
use russh::{Channel, client, keys::HashAlg};
use sha2::{Digest, Sha256};
use std::{
    sync::{LazyLock, Mutex},
    time::Duration,
};
use tokio::{
    runtime::{Builder, Runtime},
    time::{Instant, sleep_until, timeout},
};

// Network tasks must keep running after the blocking list call returns to UIKit.
pub(super) static RUNTIME: LazyLock<std::io::Result<Runtime>> = LazyLock::new(|| {
    Builder::new_multi_thread()
        .worker_threads(1)
        .enable_all()
        .build()
});

#[derive(PartialEq, Eq)]
pub(super) struct PeerKey {
    endpoint: String,
    port: u16,
    user: String,
    host_pin: String,
    phone_key: russh::keys::ssh_key::Fingerprint,
    device: Option<([u8; 32], [u8; 32])>,
}

impl From<&Peer<'_>> for PeerKey {
    fn from(peer: &Peer<'_>) -> Self {
        Self {
            endpoint: peer.host.to_owned(),
            port: peer.port,
            user: peer.user.to_owned(),
            host_pin: peer.pin.to_owned(),
            phone_key: peer.key.fingerprint(HashAlg::Sha256),
            device: peer
                .identity
                .map(|(cert, key)| (Sha256::digest(cert).into(), Sha256::digest(key).into())),
        }
    }
}

struct ListedSession {
    peer: PeerKey,
    expires: Instant,
    session: client::Handle<PinnedHost>,
}

// Only the most recently listed machine needs a standby transport. Removing the
// handle under the lock gives one caller exclusive ownership of that connection.
static LISTED: Mutex<Option<ListedSession>> = Mutex::new(None);
const LIST_HANDOFF: Duration = Duration::from_secs(20);

pub(super) fn offer(peer: PeerKey, session: client::Handle<PinnedHost>) {
    let expires = Instant::now() + LIST_HANDOFF;
    *LISTED.lock().unwrap() = Some(ListedSession {
        peer,
        expires,
        session,
    });
    tokio::spawn(async move {
        sleep_until(expires).await;
        LISTED
            .lock()
            .unwrap()
            .take_if(|entry| entry.expires <= Instant::now());
    });
}

fn take(peer: &PeerKey) -> Option<client::Handle<PinnedHost>> {
    let mut entry = LISTED.lock().unwrap();
    entry.take_if(|entry| entry.expires <= Instant::now() || entry.session.is_closed());
    entry
        .take_if(|entry| &entry.peer == peer)
        .map(|entry| entry.session)
}

pub(super) type SessionChannel = (client::Handle<PinnedHost>, Channel<client::Msg>);

pub(super) async fn open_channel(
    peer: &Peer<'_>,
    key: Option<&PeerKey>,
    output: &mut Output,
) -> Result<SessionChannel> {
    if let Some(session) = key.and_then(take)
        && let Ok(Ok(channel)) =
            timeout(Duration::from_secs(2), session.channel_open_session()).await
    {
        return Ok((session, channel));
    }
    // Retry only the channel open. No PTY, attach command, or keystroke has
    // been sent, so a half-open standby cannot duplicate a remote operation.
    let session = authenticated(peer.clone(), Some(output)).await?;
    let channel = timeout(Duration::from_secs(20), session.channel_open_session())
        .await
        .context("SSH channel open timed out")??;
    Ok((session, channel))
}

#[cfg(test)]
mod tests {
    use super::*;
    use russh::keys::{PrivateKey, ssh_key::private::Ed25519Keypair};

    #[test]
    fn handoff_is_bound_to_route_user_and_both_authentications() {
        let peer = Peer {
            host: "wss://center.example/tmux-link/session/first",
            port: 443,
            user: "builder",
            pin: "pinned-host-key",
            key: PrivateKey::from(Ed25519Keypair::from_seed(&[1; 32])),
            identity: Some((b"cert-a", b"key-a")),
        };
        let listed = PeerKey::from(&peer);
        assert!(listed == PeerKey::from(&peer.clone()));
        for other in [
            Peer {
                host: "wss://center.example/tmux-link/session/second",
                ..peer.clone()
            },
            Peer {
                port: 8443,
                ..peer.clone()
            },
            Peer {
                user: "other",
                ..peer.clone()
            },
            Peer {
                pin: "rotated-host-key",
                ..peer.clone()
            },
            Peer {
                key: PrivateKey::from(Ed25519Keypair::from_seed(&[2; 32])),
                ..peer.clone()
            },
            Peer {
                identity: Some((b"cert-b", b"key-a")),
                ..peer.clone()
            },
            Peer {
                identity: Some((b"cert-a", b"key-b")),
                ..peer.clone()
            },
            Peer {
                identity: None,
                ..peer.clone()
            },
        ] {
            assert!(listed != PeerKey::from(&other));
        }
    }
}
