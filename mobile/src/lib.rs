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

type DeviceIdentity<'a> = Option<(&'a [u8], &'a [u8])>;

struct Peer<'a> {
    host: &'a str,
    port: u16,
    user: &'a str,
    pin: &'a str,
    key: PrivateKey,
    identity: DeviceIdentity<'a>,
}

async fn authenticated(peer: Peer<'_>, output: &mut Output) -> Result<client::Handle<PinnedHost>> {
    let Peer {
        host,
        port,
        user,
        pin,
        key,
        identity,
    } = peer;
    output.stage("connecting").await?;
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
            let stream = match identity {
                Some((cert, key)) => tmux_link::websocket::connect_mtls(&url, cert, key).await?,
                None => tmux_link::websocket::connect(&url).await?,
            };
            output.stage("ssh").await?;
            client::connect_stream(Arc::new(config), stream, PinnedHost(pin.into())).await?
        } else {
            ensure!(identity.is_none(), "device certificate requires WSS");
            output.stage("ssh").await?;
            client::connect(Arc::new(config), (host, port), PinnedHost(pin.into())).await?
        };
        output.stage("auth").await?;
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

struct Output {
    writer: tokio::net::unix::OwnedWriteHalf,
    framed: bool,
}

impl Output {
    async fn frame(&mut self, kind: u8, bytes: &[u8]) -> Result<()> {
        self.writer.write_u8(kind).await?;
        self.writer.write_u32(bytes.len().try_into()?).await?;
        self.writer.write_all(bytes).await?;
        Ok(())
    }

    async fn data(&mut self, bytes: &[u8]) -> Result<()> {
        if self.framed {
            for chunk in bytes.chunks(65536) {
                self.frame(0, chunk).await?;
            }
        } else {
            self.writer.write_all(bytes).await?;
        }
        Ok(())
    }

    async fn stage(&mut self, name: &str) -> Result<()> {
        if self.framed {
            self.frame(1, name.as_bytes()).await?;
        }
        Ok(())
    }
}

async fn heartbeat(
    session: &client::Handle<PinnedHost>,
    samples: tokio::sync::mpsc::Sender<u32>,
) -> Result<()> {
    loop {
        let start = tokio::time::Instant::now();
        let ping = session.send_ping();
        tokio::pin!(ping);
        match timeout(Duration::from_secs(8), &mut ping).await {
            Ok(result) => result?,
            Err(_) => {
                samples.send(u32::MAX).await?;
                // Keep at most one outstanding SSH global request.
                ping.await?;
            }
        }
        ensure!(!session.is_closed(), "SSH connection closed");
        let ms = start.elapsed().as_millis().min((u32::MAX - 1) as u128) as u32;
        samples.send(ms).await?;
        tokio::time::sleep(Duration::from_secs(5)).await;
    }
}

async fn run(
    session: client::Handle<PinnedHost>,
    mut read: tokio::net::unix::OwnedReadHalf,
    mut output: Output,
    target: Option<u64>,
) -> Result<()> {
    output.stage("attaching").await?;
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
    let framed = output.framed;
    let (samples, mut sample_rx) = tokio::sync::mpsc::channel::<u32>(1);
    let download = async {
        let mut acknowledgments = 0;
        let ack_deadline = tokio::time::sleep(Duration::from_secs(20));
        tokio::pin!(ack_deadline);
        loop {
            let message = tokio::select! {
                message = ssh_rx.wait() => match message {
                    Some(message) => message,
                    None => break,
                },
                Some(ms) = sample_rx.recv(), if framed && acknowledgments == 2 => {
                    output.frame(2, &ms.to_be_bytes()).await?;
                    continue;
                }
                _ = &mut ack_deadline, if framed && acknowledgments < 2 => {
                    bail!("remote PTY or command acknowledgment timed out");
                }
            };
            match message {
                ChannelMsg::Data { data } | ChannelMsg::ExtendedData { data, .. } => {
                    output.data(&data).await?
                }
                ChannelMsg::Close | ChannelMsg::Eof => break,
                ChannelMsg::Success if framed && acknowledgments < 2 => {
                    acknowledgments += 1;
                    if acknowledgments == 2 {
                        output.stage("ready").await?;
                    }
                }
                ChannelMsg::Failure => bail!("remote PTY or shell request failed"),
                _ => {}
            }
        }
        Ok::<(), anyhow::Error>(())
    };
    let result = tokio::select! {
        result = upload => result,
        result = download => result,
        result = heartbeat(&session, samples), if framed => result,
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
    unsafe { open_inner(fd, host, port, user, pin, seed, target, None) }
}

/// # Safety
/// Same fd, strings and seed requirements as tl_open. Supply readable buffers
/// of the specified lengths for the DER leaf and DER PKCS#8 key, or two NULL/0 pairs.
#[unsafe(no_mangle)]
#[allow(clippy::too_many_arguments)]
pub unsafe extern "C" fn tl_open_secure(
    fd: i32,
    host: *const c_char,
    port: u16,
    user: *const c_char,
    pin: *const c_char,
    seed: *const u8,
    target: i64,
    cert_der: *const u8,
    cert_len: usize,
    key_pkcs8: *const u8,
    key_len: usize,
) -> *mut c_char {
    let credentials = Some((cert_der, cert_len, key_pkcs8, key_len));
    unsafe { open_inner(fd, host, port, user, pin, seed, target, credentials) }
}

type CredentialBuffers = (*const u8, usize, *const u8, usize);

#[allow(clippy::too_many_arguments)]
unsafe fn open_inner(
    fd: i32,
    host: *const c_char,
    port: u16,
    user: *const c_char,
    pin: *const c_char,
    seed: *const u8,
    target: i64,
    credentials: Option<CredentialBuffers>,
) -> *mut c_char {
    let socket = unsafe { std::os::unix::net::UnixStream::from_raw_fd(fd) };
    let result = (|| -> Result<()> {
        let identity = match credentials {
            None => None,
            Some((cert, 0, key, 0)) if cert.is_null() && key.is_null() => None,
            Some((cert, cert_len, key, key_len)) => {
                ensure!(
                    !cert.is_null()
                        && !key.is_null()
                        && (1..=65536).contains(&cert_len)
                        && (1..=65536).contains(&key_len),
                    "invalid device identity"
                );
                Some(unsafe {
                    (
                        std::slice::from_raw_parts(cert, cert_len),
                        std::slice::from_raw_parts(key, key_len),
                    )
                })
            }
        };
        let host = unsafe { CStr::from_ptr(host) }.to_str()?;
        let user = unsafe { CStr::from_ptr(user) }.to_str()?;
        let pin = unsafe { CStr::from_ptr(pin) }.to_str()?;
        let key = Ed25519Keypair::from_seed(unsafe { &*seed.cast::<[u8; 32]>() });
        socket.set_nonblocking(true)?;
        tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()?
            .block_on(async {
                let (read, writer) = UnixStream::from_std(socket)?.into_split();
                let mut output = Output {
                    writer,
                    framed: credentials.is_some() && target != -2,
                };
                let peer = Peer {
                    host,
                    port,
                    user,
                    pin,
                    key: PrivateKey::from(key),
                    identity,
                };
                let session = authenticated(peer, &mut output).await?;
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
                                    output.data(&data).await?;
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
                    run(session, read, output, u64::try_from(target).ok()).await
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
/// Supply readable NUL-terminated URL, ID and JSON strings and DER buffers of the
/// specified lengths for the duration of the call. The returned error is owned.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn tl_approve_pairing(
    url: *const c_char,
    id: *const c_char,
    request_json: *const c_char,
    cert: *const u8,
    cert_len: usize,
    key: *const u8,
    key_len: usize,
) -> *mut c_char {
    let result = (|| -> Result<()> {
        ensure!(
            !url.is_null()
                && !id.is_null()
                && !request_json.is_null()
                && !cert.is_null()
                && !key.is_null()
                && (1..=65536).contains(&cert_len)
                && (1..=65536).contains(&key_len),
            "invalid pairing arguments"
        );
        let url = unsafe { CStr::from_ptr(url) }.to_str()?;
        let id = unsafe { CStr::from_ptr(id) }.to_str()?;
        ensure!(
            id.len() == 32 && id.bytes().all(|b| b.is_ascii_hexdigit()),
            "invalid pairing ID"
        );
        let json = unsafe { CStr::from_ptr(request_json) }.to_str()?;
        ensure!(
            json.len() <= tmux_link::pairing::MAX_CONTROL,
            "pairing request too large"
        );
        let message: tmux_link::pairing::Request = serde_json::from_str(json)?;
        ensure!(
            matches!(message, tmux_link::pairing::Request::Approve { .. }),
            "expected pairing approval"
        );
        let cert = unsafe { std::slice::from_raw_parts(cert, cert_len) };
        let key = unsafe { std::slice::from_raw_parts(key, key_len) };
        tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()?
            .block_on(async {
                async fn call(
                    url: &str,
                    cert: &[u8],
                    key: &[u8],
                    message: &tmux_link::pairing::Request,
                ) -> Result<tmux_link::pairing::Reply> {
                    timeout(Duration::from_secs(15), async {
                        let mut stream = tmux_link::websocket::connect_mtls(url, cert, key).await?;
                        tmux_link::pairing::write(&mut stream, message).await?;
                        tmux_link::pairing::checked(tmux_link::pairing::read(&mut stream).await?)
                    })
                    .await?
                }
                let reply = call(url, cert, key, &message).await?;
                ensure!(
                    reply.id == id && reply.approved,
                    "unexpected pairing response"
                );
                for _ in 0..15 {
                    let reply = call(
                        url,
                        cert,
                        key,
                        &tmux_link::pairing::Request::Ready { id: id.to_owned() },
                    )
                    .await?;
                    if reply.ready {
                        return Ok(());
                    }
                    tokio::time::sleep(Duration::from_secs(1)).await;
                }
                anyhow::bail!("配对已确认，等待机器建立连接；保持机器上的配对命令运行后重试")
            })
    })();
    result.err().map_or(std::ptr::null_mut(), |err| {
        CString::new(err.to_string().replace('\0', " "))
            .unwrap()
            .into_raw()
    })
}

/// # Safety
/// Pass a non-null pointer returned by tl_connect or tl_approve_pairing exactly once.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn tl_free_error(p: *mut c_char) {
    drop(unsafe { CString::from_raw(p) });
}
