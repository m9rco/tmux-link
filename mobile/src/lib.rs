//! iOS transport. A private socket pair links UIKit input and terminal output to SSH.
use anyhow::{Result, bail, ensure};
use russh::{
    ChannelMsg, client,
    keys::{
        HashAlg, PrivateKey, PrivateKeyWithHashAlg, PublicKeyOrCertificate,
        ssh_key::private::Ed25519Keypair,
    },
};
use std::{
    ffi::{CStr, CString, c_char},
    os::fd::FromRawFd,
    sync::Arc,
    time::Duration,
};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::UnixStream,
    time::timeout,
};

struct PinnedHost(String);
impl client::Handler for PinnedHost {
    type Error = russh::Error;
    async fn check_server_key(
        &mut self,
        offered: &PublicKeyOrCertificate,
    ) -> Result<bool, Self::Error> {
        let PublicKeyOrCertificate::PublicKey { key, .. } = offered else {
            return Ok(false);
        };
        Ok(key.fingerprint(HashAlg::Sha256).to_string() == self.0)
    }
}

async fn authenticated(
    host: &str,
    port: u16,
    user: &str,
    pin: &str,
    key: PrivateKey,
) -> Result<client::Handle<PinnedHost>> {
    let config = client::Config {
        keepalive_interval: Some(Duration::from_secs(20)),
        ..Default::default()
    };
    timeout(Duration::from_secs(20), async {
        let mut session = if port == 443 || host.starts_with("ws://") || host.starts_with("wss://")
        {
            let url = if host.starts_with("ws://") || host.starts_with("wss://") {
                host.to_owned()
            } else {
                format!("wss://{host}/tmux-link")
            };
            let stream = tmux_link::websocket::connect(&url).await?;
            client::connect_stream(Arc::new(config), stream, PinnedHost(pin.into())).await?
        } else {
            client::connect(Arc::new(config), (host, port), PinnedHost(pin.into())).await?
        };
        ensure!(
            session
                .authenticate_publickey(user, PrivateKeyWithHashAlg::new(Arc::new(key), None))
                .await?
                .success(),
            "phone key rejected"
        );
        Ok(session)
    })
    .await?
}

async fn run(
    session: client::Handle<PinnedHost>,
    socket: UnixStream,
    target: Option<u64>,
) -> Result<()> {
    let (mut read, mut write) = socket.into_split();
    let channel = timeout(Duration::from_secs(20), async {
        let channel = session.channel_open_session().await?;
        channel
            .request_pty(true, "xterm-256color", 80, 24, 0, 0, &[])
            .await?;
        if let Some(id) = target {
            channel.exec(true, format!("tmux-link-attach {id}")).await?;
        } else {
            channel.request_shell(true).await?;
        }
        Ok::<_, anyhow::Error>(channel)
    })
    .await??;
    let (mut ssh_rx, ssh_tx) = channel.split();
    // Independent pumps keep Ctrl-C responsive while the phone renders a burst of output.
    let upload = async {
        let mut kind = [0; 1];
        let mut bytes = Vec::new();
        while read.read(&mut kind).await? != 0 {
            let count = read.read_u32().await? as usize;
            ensure!(count <= 65536, "input frame too large");
            match kind[0] {
                0 => {
                    bytes.resize(count, 0);
                    read.read_exact(&mut bytes).await?;
                    ssh_tx.data(&bytes[..]).await?;
                }
                1 if count == 4 => {
                    let cols = read.read_u16().await?;
                    let rows = read.read_u16().await?;
                    ssh_tx.window_change(cols.into(), rows.into(), 0, 0).await?;
                }
                _ => bail!("invalid input frame"),
            }
        }
        Ok::<(), anyhow::Error>(())
    };
    let download = async {
        while let Some(message) = ssh_rx.wait().await {
            match message {
                ChannelMsg::Data { data } | ChannelMsg::ExtendedData { data, .. } => {
                    write.write_all(&data).await?
                }
                ChannelMsg::Close | ChannelMsg::Eof => break,
                ChannelMsg::Failure => bail!("remote PTY or shell request failed"),
                _ => {}
            }
        }
        Ok::<(), anyhow::Error>(())
    };
    let result = tokio::select! {
        result = upload => result,
        result = download => result,
    };
    // Close even when input validation failed, with a bounded shutdown wait.
    let disconnected = timeout(
        Duration::from_secs(5),
        session.disconnect(russh::Disconnect::ByApplication, "", "en"),
    )
    .await;
    result?;
    disconnected??;
    Ok(())
}

/// Blocks on a worker thread. Takes ownership of fd. Returns NULL or owned error text.
/// # Safety
/// Supply a connected Unix stream fd, valid NUL-terminated UTF-8 strings and a 32-byte seed.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn tl_connect(
    fd: i32,
    host: *const c_char,
    port: u16,
    user: *const c_char,
    pin: *const c_char,
    seed: *const u8,
) -> *mut c_char {
    unsafe { tl_open(fd, host, port, user, pin, seed, -1) }
}

/// # Safety
/// Same ownership and pointer requirements as tl_connect. -1 opens the legacy picker,
/// -2 lists sessions, and a nonnegative number attaches to that exact tmux session ID.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn tl_open(
    fd: i32,
    host: *const c_char,
    port: u16,
    user: *const c_char,
    pin: *const c_char,
    seed: *const u8,
    target: i64,
) -> *mut c_char {
    let socket = unsafe { std::os::unix::net::UnixStream::from_raw_fd(fd) };
    let result = (|| -> Result<()> {
        let host = unsafe { CStr::from_ptr(host) }.to_str()?;
        let user = unsafe { CStr::from_ptr(user) }.to_str()?;
        let pin = unsafe { CStr::from_ptr(pin) }.to_str()?;
        let key = Ed25519Keypair::from_seed(unsafe { &*seed.cast::<[u8; 32]>() });
        socket.set_nonblocking(true)?;
        tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()?
            .block_on(async {
                let mut socket = UnixStream::from_std(socket)?;
                let session = authenticated(host, port, user, pin, PrivateKey::from(key)).await?;
                if target == -2 {
                    timeout(Duration::from_secs(15), async {
                        let mut channel = session.channel_open_session().await?;
                        channel.exec(true, "tmux-link-list").await?;
                        let mut size = 0;
                        let mut status = None;
                        while let Some(message) = channel.wait().await {
                            match message {
                                ChannelMsg::Data { data } => {
                                    size += data.len();
                                    ensure!(size <= 1024 * 1024, "session list too large");
                                    socket.write_all(&data).await?;
                                }
                                ChannelMsg::ExitStatus { exit_status } => {
                                    status = Some(exit_status)
                                }
                                ChannelMsg::Failure => bail!("session list was refused"),
                                _ => {}
                            }
                        }
                        ensure!(
                            status == Some(0),
                            "session list unavailable; check the host agent"
                        );
                        Ok(())
                    })
                    .await?
                } else {
                    ensure!(target >= -1, "invalid session");
                    run(session, socket, u64::try_from(target).ok()).await
                }
            })
    })();
    result.err().map_or(std::ptr::null_mut(), |err| {
        CString::new(err.to_string().replace('\0', " "))
            .unwrap()
            .into_raw()
    })
}
/// # Safety
/// Pass a non-null pointer returned by tl_connect exactly once.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn tl_free_error(p: *mut c_char) {
    drop(unsafe { CString::from_raw(p) });
}
