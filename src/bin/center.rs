//! Relay SSH ciphertext only to sockets explicitly registered by the operator.
use anyhow::{Context, Result, ensure};
use std::{collections::HashMap, env, path::PathBuf, sync::Arc, time::Duration};
use tokio::{
    io::copy_bidirectional,
    net::{TcpListener, UnixStream},
    sync::Semaphore,
    time::timeout,
};
use tokio_tungstenite::tungstenite::{
    handshake::server::Request, http::Response, protocol::WebSocketConfig,
};

#[tokio::main]
async fn main() -> Result<()> {
    let mut args = env::args().skip(1);
    let address = args.next().context(
        "usage: center LISTEN /absolute/default.sock [--websocket [NAME=/absolute/socket ...]]",
    )?;
    let default = PathBuf::from(args.next().context("missing tunnel socket")?);
    ensure!(default.is_absolute(), "expected absolute socket path");
    let websocket = match args.next().as_deref() {
        None => false,
        Some("--websocket") => true,
        _ => anyhow::bail!("expected --websocket"),
    };
    let mut routes = HashMap::from([
        ("/tmux-link".to_owned(), default.clone()),
        ("/tmux-link/primary".to_owned(), default.clone()),
    ]);
    for mapping in args {
        let (name, path) = mapping
            .split_once('=')
            .context("expected NAME=/absolute/socket")?;
        ensure!(
            !name.is_empty()
                && name.len() <= 64
                && name
                    .bytes()
                    .all(|c| c.is_ascii_alphanumeric() || matches!(c, b'-' | b'_')),
            "invalid client name"
        );
        let path = PathBuf::from(path);
        ensure!(
            path.is_absolute() && routes.insert(format!("/tmux-link/{name}"), path).is_none(),
            "invalid or duplicate route"
        );
    }
    let routes = Arc::new(routes);
    let listener = TcpListener::bind(address).await?;
    let slots = Arc::new(Semaphore::new(32));
    eprintln!("tmux-link center listening on {}", listener.local_addr()?);
    loop {
        let (mut phone, _) = listener.accept().await?;
        let Ok(slot) = slots.clone().try_acquire_owned() else {
            continue;
        };
        let routes = routes.clone();
        let default = default.clone();
        tokio::spawn(async move {
            let _slot = slot;
            let _ = phone.set_nodelay(true);
            if websocket {
                let mut path = None;
                let config = WebSocketConfig::default()
                    .max_message_size(Some(65536))
                    .max_frame_size(Some(65536));
                #[allow(clippy::result_large_err)]
                let upgrade = tokio_tungstenite::accept_hdr_async_with_config(
                    phone,
                    |req: &Request, response| {
                        path = routes.get(req.uri().path()).cloned();
                        if path.is_none() {
                            return Err(Response::builder().status(404).body(None).unwrap());
                        }
                        Ok(response)
                    },
                    Some(config),
                );
                if let Ok(Ok(ws)) = timeout(Duration::from_secs(10), upgrade).await
                    && let Some(path) = path
                    && let Ok(Ok(mut agent)) =
                        timeout(Duration::from_secs(5), UnixStream::connect(path)).await
                {
                    let mut stream = tmux_link::websocket::byte_stream(ws);
                    let _ = copy_bidirectional(&mut stream, &mut agent).await;
                }
            } else if let Ok(Ok(mut agent)) =
                timeout(Duration::from_secs(5), UnixStream::connect(default)).await
            {
                let _ = copy_bidirectional(&mut phone, &mut agent).await;
            }
        });
    }
}
