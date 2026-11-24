//! Reliable byte streams over WebSocket, carrying end-to-end encrypted SSH.
pub mod pairing;
pub mod websocket;

/// The forced SSH command accepts only these management operations.
pub fn valid_managed_action(action: &str) -> bool {
    if matches!(action, "status" | "disable" | "forget") {
        return true;
    }
    let Some((mode, style)) = action
        .strip_prefix("enable-")
        .and_then(|s| s.split_once('-'))
    else {
        return false;
    };
    matches!(mode, "observe" | "menu" | "assist")
        && matches!(style, "cautious" | "balanced" | "concise")
}

pub const MAX_ADVICE_RESPONSE: usize = 64 * 1024;

pub fn valid_managed_instance(token: &str) -> bool {
    let mut parts = token.split('-');
    token.len() <= 96
        && (0..4).all(|i| {
            let raw = parts.next().unwrap_or("");
            let field = if i == 2 {
                raw.strip_prefix('%').unwrap_or("")
            } else {
                raw
            };
            !field.is_empty() && field.bytes().all(|b| b.is_ascii_digit())
        })
        && parts.next().is_none()
}

pub fn valid_advice_ticket(ticket: &str) -> bool {
    ticket.len() == 16
        && ticket
            .bytes()
            .all(|b| b.is_ascii_hexdigit() && !b.is_ascii_uppercase())
}

/// Pin remote changes to the tmux lifetime and pane shown in the phone's listing.
pub fn managed_remote_action(request: &str) -> Option<(&str, Option<&str>)> {
    let (action, instance) = match request.split_once('@') {
        Some((action, token)) => {
            if !valid_managed_instance(token) {
                return None;
            }
            (action, Some(token))
        }
        None if request == "status" => ("status", None),
        None => return None,
    };
    valid_managed_action(action).then_some((action, instance))
}

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
