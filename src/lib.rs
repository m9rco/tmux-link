//! Reliable byte streams over WebSocket, carrying end-to-end encrypted SSH.
pub mod pairing;
pub mod websocket;

/// Keep host discovery and the phone's SSH negotiation on the same policy.
#[cfg(feature = "ssh-probe")]
pub fn ssh_client_config() -> russh::client::Config {
    let mut config = russh::client::Config {
        keepalive_interval: Some(std::time::Duration::from_secs(20)),
        ..Default::default()
    };
    config
        .preferred
        .key
        .to_mut()
        .retain(|algorithm| !matches!(algorithm, russh::keys::Algorithm::Rsa { hash: None }));
    config
}
