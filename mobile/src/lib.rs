//! iOS transport. A private socket pair links UIKit input and terminal output to SSH.
mod handoff;
use anyhow::{Context, Result, bail, ensure};
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

#[derive(Clone)]
struct Peer<'a> {
    host: &'a str,
    port: u16,
    user: &'a str,
    pin: &'a str,
    key: PrivateKey,
    identity: DeviceIdentity<'a>,
}

async fn authenticated(
    peer: Peer<'_>,
    mut output: Option<&mut Output>,
) -> Result<client::Handle<PinnedHost>> {
    let Peer {
        host,
        port,
        user,
        pin,
        key,
        identity,
    } = peer;
    if let Some(output) = output.as_deref_mut() {
        output.stage("connecting").await?;
    }
    let config = tmux_link::ssh_client_config();
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
            if let Some(output) = output.as_deref_mut() {
                output.stage("ssh").await?;
            }
            client::connect_stream(Arc::new(config), stream, PinnedHost(pin.into())).await?
        } else {
            ensure!(identity.is_none(), "device certificate requires WSS");
            if let Some(output) = output.as_deref_mut() {
                output.stage("ssh").await?;
            }
            client::connect(Arc::new(config), (host, port), PinnedHost(pin.into())).await?
        };
        if let Some(output) = output.as_deref_mut() {
            output.stage("auth").await?;
        }
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

// Run one bounded, allowlisted tmux operation on a second channel of the
// authenticated SSH connection. Keep ordering with later keyboard input.
async fn page_pane(
    mut channel: russh::Channel<client::Msg>,
    id: u64,
    direction: &str,
) -> Result<()> {
    channel
        .exec(true, format!("tmux-link-page {id} {direction}"))
        .await?;
    channel.eof().await?;
    let mut status = None;
    while let Some(message) = channel.wait().await {
        match message {
            ChannelMsg::ExitStatus { exit_status } => status = Some(exit_status),
            ChannelMsg::Failure | ChannelMsg::Close => break,
            _ => {}
        }
    }
    ensure!(status == Some(0), "tmux page request failed");
    Ok(())
}

async fn initial_pty_grid<R: tokio::io::AsyncRead + Unpin>(
    mut read: R,
    fitted: bool,
) -> Result<((u16, u16), impl tokio::io::AsyncRead + Unpin)> {
    let mut grid = (80, 24);
    let mut prefix = Vec::new();
    if fitted {
        // A hidden or suspended WebView may not report a size. read_to_end keeps
        // partial bytes on cancellation, so a late resize still reaches the pump.
        let mut first_frame = (&mut read).take(9);
        if let Ok(result) = timeout(
            Duration::from_millis(250),
            first_frame.read_to_end(&mut prefix),
        )
        .await
        {
            result?;
        }
        if let [1, 0, 0, 0, 4, a, b, c, d] = prefix[..] {
            let cols = u16::from_be_bytes([a, b]);
            let rows = u16::from_be_bytes([c, d]);
            if cols > 0 && rows > 0 {
                grid = (cols, rows);
                prefix.clear();
            }
        }
    }
    Ok((grid, std::io::Cursor::new(prefix).chain(read)))
}

async fn run(
    (session, channel): handoff::SessionChannel,
    read: tokio::net::unix::OwnedReadHalf,
    mut output: Output,
    target: Option<u64>,
    peer: Peer<'_>,
    fit_initial_grid: bool,
) -> Result<()> {
    output.stage("attaching").await?;
    let (mut applied_grid, mut read) = initial_pty_grid(read, fit_initial_grid).await?;
    let channel = timeout(Duration::from_secs(20), async {
        channel
            .request_pty(
                true,
                "xterm-256color",
                applied_grid.0.into(),
                applied_grid.1.into(),
                0,
                0,
                &[],
            )
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
    let (page_errors, mut page_error_rx) = tokio::sync::mpsc::channel(1);
    let upload = async {
        let mut kind = [0; 1];
        let mut bytes = Vec::new();
        let mut paging_connection: Option<client::Handle<PinnedHost>> = None;
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
                    if !fit_initial_grid || applied_grid != (cols, rows) {
                        ssh_tx.window_change(cols.into(), rows.into(), 0, 0).await?;
                        applied_grid = (cols, rows);
                    }
                }
                2 if count == 1 => {
                    let id = target.context("paging requires a named session")?;
                    let direction = match read.read_u8().await? {
                        0 => "down",
                        1 => "up",
                        _ => bail!("invalid page direction"),
                    };
                    // MaxSessions=1 permits the PTY but disallows a second
                    // channel. Reuse a separately authenticated connection there.
                    let result = timeout(Duration::from_secs(5), async {
                        let control = paging_connection.as_ref().unwrap_or(&session);
                        let channel = match control.channel_open_session().await {
                            Ok(channel) => channel,
                            // OpenSSH may still count the previous page channel against
                            // MaxSessions even after sending its close. No command has
                            // been submitted on the denied channel, so a fresh one is safe.
                            Err(russh::Error::ChannelOpenFailure(_)) => {
                                let control = authenticated(peer.clone(), None).await?;
                                let channel = control.channel_open_session().await?;
                                paging_connection = Some(control);
                                channel
                            }
                            Err(error) => return Err(error.into()),
                        };
                        page_pane(channel, id, direction).await
                    })
                    .await;
                    if !matches!(result, Ok(Ok(()))) {
                        paging_connection = None;
                        let _ = page_errors.try_send(());
                    }
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
                Some(()) = page_error_rx.recv(), if framed => {
                    output.frame(3, &[]).await?;
                    continue;
                }
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
/// Values <= -3 read a snapshot for ID (-3 - target), in 0..=i64::MAX-2.
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
    unsafe { open_inner(fd, host, port, user, pin, seed, target.into(), None, false) }
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
    unsafe {
        open_inner(
            fd,
            host,
            port,
            user,
            pin,
            seed,
            target.into(),
            credentials,
            false,
        )
    }
}

/// # Safety
/// Same requirements as tl_open_secure. A terminal caller replies to "attaching"
/// with its measured grid in the usual resize frame before sending any other input.
#[unsafe(no_mangle)]
#[allow(clippy::too_many_arguments)]
pub unsafe extern "C" fn tl_open_secure_fitted(
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
    unsafe {
        open_inner(
            fd,
            host,
            port,
            user,
            pin,
            seed,
            target.into(),
            credentials,
            true,
        )
    }
}

/// Reads the host-native, read-only v2 snapshot for a nonnegative tmux session ID.
/// # Safety
/// Same fd, pointer and identity requirements as tl_open_secure.
#[unsafe(no_mangle)]
#[allow(clippy::too_many_arguments)]
pub unsafe extern "C" fn tl_snapshot_v2_secure(
    fd: i32,
    host: *const c_char,
    port: u16,
    user: *const c_char,
    pin: *const c_char,
    seed: *const u8,
    session_id: i64,
    cert_der: *const u8,
    cert_len: usize,
    key_pkcs8: *const u8,
    key_len: usize,
) -> *mut c_char {
    let credentials = Some((cert_der, cert_len, key_pkcs8, key_len));
    unsafe {
        open_inner(
            fd,
            host,
            port,
            user,
            pin,
            seed,
            Target::SnapshotV2(session_id),
            credentials,
            false,
        )
    }
}

/// Run one scoped managed-session operation over the same pinned SSH channel as snapshots.
/// # Safety
/// Same requirements as tl_open_secure; action must be a NUL-terminated UTF-8 string.
#[unsafe(no_mangle)]
#[allow(clippy::too_many_arguments)]
pub unsafe extern "C" fn tl_managed_secure(
    fd: i32,
    host: *const c_char,
    port: u16,
    user: *const c_char,
    pin: *const c_char,
    seed: *const u8,
    session_id: i64,
    action: *const c_char,
    cert_der: *const u8,
    cert_len: usize,
    key_pkcs8: *const u8,
    key_len: usize,
) -> *mut c_char {
    let action = if action.is_null() {
        ""
    } else {
        unsafe { CStr::from_ptr(action) }.to_str().unwrap_or("")
    };
    let credentials = Some((cert_der, cert_len, key_pkcs8, key_len));
    unsafe {
        open_inner(
            fd,
            host,
            port,
            user,
            pin,
            seed,
            Target::Managed(session_id, action),
            credentials,
            false,
        )
    }
}

#[derive(Clone, Copy)]
enum Target<'a> {
    Terminal(Option<u64>),
    List,
    SnapshotV1(i64),
    SnapshotV2(i64),
    Managed(i64, &'a str),
}

impl From<i64> for Target<'_> {
    fn from(target: i64) -> Self {
        match target {
            -1 => Self::Terminal(None),
            -2 => Self::List,
            ..=-3 => Self::SnapshotV1(-3 - target),
            id => Self::Terminal(Some(id as u64)),
        }
    }
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
    target: Target<'_>,
    credentials: Option<CredentialBuffers>,
    fit_initial_grid: bool,
) -> *mut c_char {
    let socket = unsafe { std::os::unix::net::UnixStream::from_raw_fd(fd) };
    let result = (|| -> Result<()> {
        ensure!(
            !matches!(target, Target::SnapshotV2(id) if id < 0),
            "invalid snapshot ID"
        );
        if let Target::Managed(id, action) = target {
            ensure!(
                id >= 0 && tmux_link::managed_remote_action(action).is_some(),
                "invalid managed request"
            );
        }
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
        handoff::RUNTIME
            .as_ref()
            .context("starting SSH runtime")?
            .block_on(async {
                let (read, writer) = UnixStream::from_std(socket)?.into_split();
                let mut output = Output {
                    writer,
                    framed: credentials.is_some() && matches!(target, Target::Terminal(_)),
                };
                let peer = Peer {
                    host,
                    port,
                    user,
                    pin,
                    key: PrivateKey::from(key),
                    identity,
                };
                let key = (!matches!(target, Target::Terminal(None)))
                    .then(|| handoff::PeerKey::from(&peer));
                let connection = handoff::open_channel(&peer, key.as_ref(), &mut output).await?;
                let (command, limit) = match target {
                    Target::Terminal(id) => {
                        return run(connection, read, output, id, peer, fit_initial_grid).await;
                    }
                    Target::List => (String::from("tmux-link-list"), 1024 * 1024),
                    Target::Managed(id, action) => {
                        (format!("tmux-link-managed-v1 {action} {id}"), 1024 * 1024)
                    }
                    Target::SnapshotV1(id) => (format!("tmux-link-snapshot {id}"), 128 * 1024),
                    // Two 32 KiB excerpts, plus room for JSON string escaping and metadata.
                    Target::SnapshotV2(id) => (format!("tmux-link-snapshot-v2 {id}"), 512 * 1024),
                };
                let capture = !matches!(target, Target::List);
                let managed = matches!(target, Target::Managed(..));
                let (session, mut channel) = connection;
                timeout(Duration::from_secs(15), async {
                    channel.exec(true, command).await?;
                    if capture {
                        channel.eof().await?;
                    }
                    let mut size = 0;
                    let mut status = None;
                    let mut error = Vec::new();
                    while let Some(message) = channel.wait().await {
                        match message {
                            ChannelMsg::Data { data } => {
                                size += data.len();
                                ensure!(size <= limit, "remote response too large");
                                output.data(&data).await?;
                            }
                            ChannelMsg::ExtendedData { data, .. } if capture => {
                                error.extend_from_slice(&data[..data.len().min(256 - error.len())]);
                            }
                            ChannelMsg::ExitStatus { exit_status } => status = Some(exit_status),
                            ChannelMsg::Failure if managed => bail!("managed unsupported"),
                            ChannelMsg::Failure if capture => {
                                bail!("snapshot unsupported")
                            }
                            ChannelMsg::Failure => bail!("session list was refused"),
                            _ => {}
                        }
                    }
                    if capture && status != Some(0) {
                        let diagnostic = String::from_utf8_lossy(&error);
                        if managed {
                            if diagnostic.contains("unsupported request") {
                                bail!("managed unsupported");
                            }
                            if diagnostic.contains("managed session changed") {
                                bail!("managed session changed");
                            }
                            bail!("managed unavailable");
                        }
                        if diagnostic.contains("unsupported request") {
                            bail!("snapshot unsupported");
                        }
                        if diagnostic.contains("snapshot pane in mode") {
                            bail!("snapshot pane in mode");
                        }
                        if diagnostic.contains("snapshot exceeds capture limit") {
                            bail!("snapshot exceeds capture limit");
                        }
                        bail!("snapshot unavailable");
                    }
                    ensure!(
                        status == Some(0),
                        "session list unavailable; check the host agent"
                    );
                    Ok(())
                })
                .await??;
                if let Some(key) = key {
                    handoff::offer(key, session);
                }
                Ok(())
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

#[cfg(test)]
mod grid_tests {
    use super::*;

    #[tokio::test]
    async fn interrupted_first_frame_is_replayed_and_legacy_open_never_waits_for_input() {
        let (mut producer, input) = tokio::io::duplex(64);
        let (grid, input) = timeout(Duration::from_millis(20), initial_pty_grid(input, false))
            .await
            .unwrap()
            .unwrap();
        assert_eq!(grid, (80, 24));
        let resize = [1, 0, 0, 0, 4, 0, 53, 0, 31];
        producer.write_all(&resize[..3]).await.unwrap();
        let (grid, mut input) = timeout(Duration::from_secs(2), initial_pty_grid(input, true))
            .await
            .unwrap()
            .unwrap();
        assert_eq!(grid, (80, 24));
        producer.write_all(&resize[3..]).await.unwrap();
        let mut replay = [0; 9];
        input.read_exact(&mut replay).await.unwrap();
        assert_eq!(replay, resize);
    }

    #[tokio::test]
    async fn consumes_only_a_complete_valid_first_resize() {
        for first in [
            [1, 0, 0, 0, 4, 0, 53, 0, 31],
            [0, 0, 0, 0, 4, b'a', b'b', b'c', b'd'],
        ] {
            let (mut writer, input) = tokio::io::duplex(64);
            writer.write_all(&first).await.unwrap();
            writer.write_all(b"next").await.unwrap();
            writer.shutdown().await.unwrap();
            let (grid, mut input) = initial_pty_grid(input, true).await.unwrap();
            let mut rest = Vec::new();
            input.read_to_end(&mut rest).await.unwrap();
            if first[0] == 1 {
                assert_eq!(grid, (53, 31));
                assert_eq!(rest, b"next");
            } else {
                assert_eq!(grid, (80, 24));
                assert_eq!(rest, [&first[..], b"next"].concat());
            }
        }
    }
}
