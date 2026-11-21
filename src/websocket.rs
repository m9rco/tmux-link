use anyhow::{Result, bail};
use futures_util::{SinkExt, StreamExt};
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt, DuplexStream};
use tokio_tungstenite::{WebSocketStream, tungstenite::Message};

/// Bounded queues apply backpressure without buffering terminal history.
pub fn byte_stream<S>(socket: WebSocketStream<S>) -> DuplexStream
where
    S: AsyncRead + AsyncWrite + Unpin + Send + 'static,
{
    let (client, pump) = tokio::io::duplex(65536);
    tokio::spawn(async move {
        let (mut tx, mut rx) = socket.split();
        let (mut input, mut output) = tokio::io::split(pump);
        let upload = async {
            let mut bytes = [0; 16384];
            loop {
                let count = input.read(&mut bytes).await?;
                if count == 0 {
                    tx.send(Message::Close(None)).await?;
                    break;
                }
                tx.send(Message::Binary(bytes[..count].to_vec().into()))
                    .await?;
            }
            Ok::<_, anyhow::Error>(())
        };
        let download = async {
            while let Some(message) = rx.next().await {
                match message? {
                    Message::Binary(bytes) => output.write_all(&bytes).await?,
                    Message::Close(_) => break,
                    Message::Ping(_) | Message::Pong(_) => {}
                    _ => bail!("only binary WebSocket messages are supported"),
                }
            }
            Ok::<_, anyhow::Error>(())
        };
        tokio::select! {
            _ = upload => {},
            _ = download => {},
        }
    });
    client
}

pub async fn connect(url: &str) -> Result<DuplexStream> {
    #[cfg(feature = "tls")]
    let _ = rustls::crypto::ring::default_provider().install_default();
    let config = tokio_tungstenite::tungstenite::protocol::WebSocketConfig::default()
        .max_message_size(Some(65536))
        .max_frame_size(Some(65536));
    let (socket, _) = tokio_tungstenite::connect_async_with_config(url, Some(config), true).await?;
    Ok(byte_stream(socket))
}
