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

async fn run(
    host: &str,
    port: u16,
    user: &str,
    pin: &str,
    key: PrivateKey,
    socket: UnixStream,
) -> Result<()> {
    let (mut read, mut write) = socket.into_split();
    let config = client::Config {
        keepalive_interval: Some(Duration::from_secs(20)),
        ..Default::default()
    };
    let (session, channel) = timeout(Duration::from_secs(20), async {
        let mut session =
            client::connect(Arc::new(config), (host, port), PinnedHost(pin.into())).await?;
        ensure!(
            session
                .authenticate_publickey(user, PrivateKeyWithHashAlg::new(Arc::new(key), None))
                .await?
                .success(),
            "phone key rejected"
        );
        let channel = session.channel_open_session().await?;
        channel
            .request_pty(true, "xterm-256color", 80, 24, 0, 0, &[])
            .await?;
        channel.request_shell(true).await?;
        Ok::<_, anyhow::Error>((session, channel))
    })
    .await??;
    let (mut ssh_rx, ssh_tx) = channel.split();
    // Independent pumps keep Ctrl-C responsive while the phone renders a burst of output.
    let upload = async {
        let mut kind = [0; 1];
        while read.read(&mut kind).await? != 0 {
            let count = read.read_u32().await? as usize;
            ensure!(count <= 65536, "input frame too large");
            match kind[0] {
                0 => {
                    let mut bytes = vec![0; count];
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
    tokio::select! {
        result = upload => result?,
        result = download => result?,
    }
    session
        .disconnect(russh::Disconnect::ByApplication, "", "en")
        .await?;
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
    let socket = unsafe { std::os::unix::net::UnixStream::from_raw_fd(fd) };
    let result = (|| -> Result<()> {
        let host = unsafe { CStr::from_ptr(host) }.to_str()?;
        let user = unsafe { CStr::from_ptr(user) }.to_str()?;
        let pin = unsafe { CStr::from_ptr(pin) }.to_str()?;
        let key = Ed25519Keypair::from_seed(unsafe { &*seed.cast::<[u8; 32]>() });
        socket.set_nonblocking(true)?;
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()?;
        runtime.block_on(async {
            run(
                host,
                port,
                user,
                pin,
                PrivateKey::from(key),
                UnixStream::from_std(socket)?,
            )
            .await
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
