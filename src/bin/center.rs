//! Public SSH byte relay. The Linux tunnel owns the private Unix socket.
use anyhow::{Context, Result};
use std::{env, path::PathBuf, sync::Arc, time::Duration};
use tokio::{
    io::copy_bidirectional,
    net::{TcpListener, UnixStream},
    sync::Semaphore,
    time::timeout,
};

#[tokio::main]
async fn main() -> Result<()> {
    let mut args = env::args().skip(1);
    let address = args
        .next()
        .context("usage: center LISTEN /absolute/tunnel.sock")?;
    let socket = Arc::new(PathBuf::from(args.next().context("missing tunnel socket")?));
    let websocket = match args.next().as_deref() {
        Some("--websocket") => true,
        None => false,
        _ => anyhow::bail!("expected --websocket"),
    };
    anyhow::ensure!(
        socket.is_absolute() && args.next().is_none(),
        "expected one absolute socket path"
    );
    let listener = TcpListener::bind(address).await?;
    let slots = Arc::new(Semaphore::new(32));
    eprintln!("tmux-link center listening on {}", listener.local_addr()?);
    loop {
        let (mut phone, _) = listener.accept().await?;
        let Ok(slot) = slots.clone().try_acquire_owned() else {
            continue;
        };
        let socket = socket.clone();
        tokio::spawn(async move {
            let _slot = slot;
            let _ = phone.set_nodelay(true);
            if let Ok(Ok(mut linux)) = timeout(
                Duration::from_secs(5),
                UnixStream::connect(socket.as_path()),
            )
            .await
            {
                if websocket {
                    let config =
                        tokio_tungstenite::tungstenite::protocol::WebSocketConfig::default()
                            .max_message_size(Some(65536))
                            .max_frame_size(Some(65536));
                    // tungstenite requires its HTTP error response by value.
                    #[allow(clippy::result_large_err)]
                    let upgrade = tokio_tungstenite::accept_hdr_async_with_config(
                        phone,
                        |request: &tokio_tungstenite::tungstenite::handshake::server::Request,
                         response| {
                            if request.uri().path() != "/tmux-link" {
                                return Err(
                                    tokio_tungstenite::tungstenite::http::Response::builder()
                                        .status(404)
                                        .body(None)
                                        .unwrap(),
                                );
                            }
                            Ok(response)
                        },
                        Some(config),
                    );
                    if let Ok(Ok(socket)) = timeout(Duration::from_secs(10), upgrade).await {
                        let mut stream = tmux_link::websocket::byte_stream(socket);
                        let _ = copy_bidirectional(&mut stream, &mut linux).await;
                    }
                } else {
                    let _ = copy_bidirectional(&mut phone, &mut linux).await;
                }
            }
        });
    }
}
