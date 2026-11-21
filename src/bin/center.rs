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
                let _ = copy_bidirectional(&mut phone, &mut linux).await;
            }
        });
    }
}
