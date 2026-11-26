//! One explicitly selected regular file, sent on a non-PTY SSH exec channel.
use super::{Output, Peer, Target, handoff, open_inner};
use anyhow::{Context, Result, bail, ensure};
use russh::{ChannelMsg, client};
use sha2::{Digest, Sha256};
use std::{
    ffi::{CStr, CString, c_char},
    fmt::Write,
    fs::File,
    io::SeekFrom,
    os::fd::{FromRawFd, OwnedFd},
    time::Duration,
};
use tokio::{
    io::{AsyncRead, AsyncReadExt, AsyncSeekExt, AsyncWrite, AsyncWriteExt},
    net::unix::OwnedReadHalf,
    time::timeout,
};

const MAX_BYTES: u64 = 128 * 1024 * 1024;
const CHUNK: usize = 64 * 1024;
const RECEIPT_LIMIT: usize = 32 * 1024;
const IDLE: Duration = Duration::from_secs(45);

#[derive(Clone, Copy)]
pub(super) struct Request<'a> {
    id: i64,
    instance: &'a str,
    directory: &'a str,
    name: &'a str,
    size: u64,
    file: &'a File,
}

impl Request<'_> {
    fn command(&self) -> Result<String> {
        ensure!(
            self.id >= 0
                && tmux_link::valid_managed_instance(self.instance)
                && self.directory.starts_with('/')
                && self.directory.len() <= 4096
                && !self.name.is_empty()
                && self.name.len() <= 255
                && !matches!(self.name, "." | "..")
                && !self.name.contains(['/', '\\'])
                && !self.name.chars().any(char::is_control)
                && self.size <= MAX_BYTES,
            "upload invalid"
        );
        let meta = self.file.metadata().context("upload invalid")?;
        ensure!(meta.is_file() && meta.len() == self.size, "upload invalid");
        let mut encoded_name = String::with_capacity(self.name.len() * 2);
        for b in self.name.bytes() {
            write!(encoded_name, "{b:02x}")?;
        }
        let dir_hash = Sha256::digest(self.directory.as_bytes());
        Ok(format!(
            "tmux-link-upload-v1 {} {} {dir_hash:x} {} {encoded_name}",
            self.id, self.instance, self.size
        ))
    }

    fn receipt(&self, raw: &[u8]) -> Result<Vec<u8>> {
        let expected = format!("{}/{}", self.directory.trim_end_matches('/'), self.name);
        let value: serde_json::Value = serde_json::from_slice(raw).context("upload incomplete")?;
        ensure!(
            value.get("path").and_then(|v| v.as_str()) == Some(&expected)
                && value.get("bytes").and_then(|v| v.as_u64()) == Some(self.size),
            "upload incomplete"
        );
        Ok(serde_json::to_vec(
            &serde_json::json!({"path": expected, "bytes": self.size}),
        )?)
    }
}

// Per-chunk timeouts cover stalled sources and a peer withholding SSH window credit.
// EOF is sent separately only after the local file still matches the declared length.
async fn copy_body(
    input: &mut (impl AsyncRead + Unpin),
    output: &mut (impl AsyncWrite + Unpin),
    mut remaining: u64,
) -> Result<()> {
    let mut buf = vec![0; CHUNK];
    while remaining > 0 {
        let limit = remaining.min(CHUNK as u64) as usize;
        let n = timeout(IDLE, input.read(&mut buf[..limit]))
            .await
            .context("upload timed out")?
            .context("upload incomplete")?;
        ensure!(n > 0, "upload incomplete");
        timeout(IDLE, output.write_all(&buf[..n]))
            .await
            .context("upload timed out")?
            .context("upload incomplete")?;
        remaining -= n as u64;
    }
    let n = timeout(IDLE, input.read(&mut buf[..1]))
        .await
        .context("upload timed out")?
        .context("upload incomplete")?;
    ensure!(n == 0, "upload incomplete");
    Ok(())
}

fn remote_error(stderr: &[u8]) -> &'static str {
    for line in String::from_utf8_lossy(stderr).lines() {
        match line.trim().strip_prefix("Error: ").unwrap_or(line.trim()) {
            "upload exists" => return "upload exists",
            "upload target changed" => return "upload target changed",
            "upload invalid" => return "upload invalid",
            "upload incomplete" => return "upload incomplete",
            "unsupported request" => return "upload unsupported",
            _ => {}
        }
    }
    "upload unavailable"
}

async fn receive(reader: &mut russh::ChannelReadHalf, request: Request<'_>) -> Result<Vec<u8>> {
    let mut receipt = Vec::new();
    let mut stderr = Vec::new();
    let mut status = None;
    while let Some(msg) = reader.wait().await {
        match msg {
            ChannelMsg::Data { data } => {
                ensure!(
                    data.len() <= RECEIPT_LIMIT - receipt.len(),
                    "upload incomplete"
                );
                receipt.extend_from_slice(&data);
            }
            ChannelMsg::ExtendedData { data, ext: 1 } => {
                stderr.extend_from_slice(&data[..data.len().min(1024 - stderr.len())]);
            }
            ChannelMsg::ExitStatus { exit_status } => status = Some(exit_status),
            ChannelMsg::Failure => bail!("upload unsupported"),
            ChannelMsg::Close => break,
            _ => {}
        }
    }
    match status {
        Some(0) => request.receipt(&receipt),
        Some(_) => bail!(remote_error(&stderr)),
        None => bail!("upload incomplete"),
    }
}

async fn transfer(
    channel: russh::Channel<client::Msg>,
    command: String,
    request: Request<'_>,
) -> Result<Vec<u8>> {
    timeout(IDLE, channel.exec(true, command))
        .await
        .context("upload timed out")?
        .context("upload unavailable")?;
    let (mut reader, writer) = channel.split();
    let send = async {
        let mut file =
            tokio::fs::File::from_std(request.file.try_clone().context("upload invalid")?);
        file.seek(SeekFrom::Start(0))
            .await
            .context("upload invalid")?;
        copy_body(&mut file, &mut writer.make_writer(), request.size).await?;
        timeout(IDLE, writer.eof())
            .await
            .context("upload timed out")?
            .context("upload incomplete")?;
        Ok::<_, anyhow::Error>(())
    };
    let response = receive(&mut reader, request);
    tokio::pin!(send, response);
    tokio::select! {
        biased;
        result = &mut response => {
            let receipt = result?;
            send.await?;
            Ok(receipt)
        }
        sent = &mut send => {
            if let Err(error) = sent {
                // Older nodes and no-clobber rejections may close SSH stdin before
                // the sender finishes a chunk. Preserve their diagnostic when available.
                if let Ok(Err(remote)) = timeout(Duration::from_secs(1), response).await {
                    return Err(remote);
                }
                return Err(error);
            }
            timeout(IDLE, response).await.context("upload timed out")?
        }
    }
}

pub(super) async fn run(
    request: Request<'_>,
    peer: &Peer<'_>,
    mut cancel_socket: OwnedReadHalf,
    mut output: Output,
) -> Result<()> {
    let command = request.command()?;
    let key = handoff::PeerKey::from(peer);
    let mut byte = [0; 1];
    let cancelled = cancel_socket.read(&mut byte);
    tokio::pin!(cancelled);
    let (session, channel) = tokio::select! {
        biased;
        _ = &mut cancelled => bail!("upload cancelled"),
        result = handoff::open_channel(peer, Some(&key), &mut output) => result.context("upload unavailable")?,
    };
    let result = tokio::select! {
        biased;
        _ = &mut cancelled => Err(anyhow::anyhow!("upload cancelled")),
        result = timeout(Duration::from_secs(20 * 60), transfer(channel, command, request)) =>
            result.unwrap_or_else(|_| Err(anyhow::anyhow!("upload timed out"))),
    };
    match result {
        Ok(receipt) => {
            timeout(IDLE, output.data(&receipt))
                .await
                .context("upload timed out")?
                .context("upload incomplete")?;
            handoff::offer(key, session);
            Ok(())
        }
        Err(error) => {
            // The remote worker cleans incomplete temporary files on disconnect.
            let _ = timeout(
                Duration::from_secs(1),
                session.disconnect(russh::Disconnect::ByApplication, "", "en"),
            )
            .await;
            Err(error)
        }
    }
}

/// Upload one file over an authenticated non-PTY SSH channel.
/// # Safety
/// Both descriptors must be live, distinct, and transferred to this call.
/// The C strings, 32-byte seed and optional DER buffers must be valid throughout.
#[unsafe(no_mangle)]
#[allow(clippy::too_many_arguments)]
pub unsafe extern "C" fn tl_upload_secure(
    fd: i32,
    file_fd: i32,
    host: *const c_char,
    port: u16,
    user: *const c_char,
    pin: *const c_char,
    seed: *const u8,
    session_id: i64,
    instance: *const c_char,
    directory: *const c_char,
    name: *const c_char,
    size: u64,
    cert: *const u8,
    cert_len: usize,
    pkcs8: *const u8,
    key_len: usize,
) -> *mut c_char {
    if fd < 0 || file_fd < 0 || fd == file_fd {
        if fd >= 0 {
            drop(unsafe { OwnedFd::from_raw_fd(fd) });
        }
        if file_fd >= 0 && file_fd != fd {
            drop(unsafe { OwnedFd::from_raw_fd(file_fd) });
        }
        return CString::new("upload invalid").unwrap().into_raw();
    }
    let file = unsafe { File::from_raw_fd(file_fd) };
    let text = |ptr: *const c_char| {
        if ptr.is_null() {
            ""
        } else {
            unsafe { CStr::from_ptr(ptr) }.to_str().unwrap_or("")
        }
    };
    let request = Request {
        id: session_id,
        instance: text(instance),
        directory: text(directory),
        name: text(name),
        size,
        file: &file,
    };
    unsafe {
        open_inner(
            fd,
            host,
            port,
            user,
            pin,
            seed,
            Target::Upload(request),
            Some((cert, cert_len, pkcs8, key_len)),
            false,
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn file() -> File {
        File::open(concat!(env!("CARGO_MANIFEST_DIR"), "/Cargo.toml")).unwrap()
    }

    fn request(file: &File) -> Request<'_> {
        Request {
            id: 7,
            instance: "1-22-%3-4",
            directory: "/工作/dir space",
            name: "a $x?.txt",
            size: file.metadata().unwrap().len(),
            file,
        }
    }

    #[test]
    fn command_encodes_only_the_directory_digest_and_literal_basename() {
        let file = file();
        let req = request(&file);
        assert_eq!(
            req.command().unwrap(),
            format!(
                "tmux-link-upload-v1 7 1-22-%3-4 a3fd68161f44fcdffa75cc6ac0f815fca2785a990b714269222afbef4148e8c3 {} 612024783f2e747874",
                req.size
            )
        );
        for name in ["", ".", "..", "a/b", "a\\b", "a\nb", &"文".repeat(86)] {
            assert!(Request { name, ..req }.command().is_err());
        }
        for invalid in [
            Request { id: -1, ..req },
            Request {
                instance: "7;sh",
                ..req
            },
            Request {
                directory: "relative",
                ..req
            },
            Request {
                size: req.size + 1,
                ..req
            },
            Request {
                size: MAX_BYTES + 1,
                ..req
            },
        ] {
            assert!(invalid.command().is_err());
        }
        assert!(
            Request {
                name: ".hidden",
                ..req
            }
            .command()
            .is_ok()
        );
    }

    #[test]
    fn receipts_require_the_selected_destination_and_count() {
        let file = file();
        let req = Request {
            directory: "/",
            ..request(&file)
        };
        let path = "/a $x?.txt";
        let raw = serde_json::json!({"path": path, "bytes":req.size, "unexpected":"anything"});
        let receipt = req.receipt(&serde_json::to_vec(&raw).unwrap()).unwrap();
        assert_eq!(
            serde_json::from_slice::<serde_json::Value>(&receipt).unwrap(),
            serde_json::json!({"path":path, "bytes":req.size})
        );
        for bad in [
            serde_json::json!({"path":"/elsewhere", "bytes":req.size}),
            serde_json::json!({"path":path, "bytes":req.size + 1}),
            serde_json::json!({"path":path}),
        ] {
            assert!(req.receipt(&serde_json::to_vec(&bad).unwrap()).is_err());
        }
        assert!(req.receipt(br#"{broken"#).is_err());
    }

    #[tokio::test]
    async fn streams_multiple_chunks_and_rejects_short_or_growing_files() {
        let data: Vec<u8> = (0..CHUNK * 3 + 23).map(|n| n as u8).collect();
        let mut out = Vec::new();
        copy_body(&mut data.as_slice(), &mut out, data.len() as u64)
            .await
            .unwrap();
        assert_eq!(out, data);
        copy_body(&mut &[][..], &mut tokio::io::sink(), 0)
            .await
            .unwrap();
        for size in [0, data.len() as u64 - 1, data.len() as u64 + 1] {
            let err = copy_body(&mut data.as_slice(), &mut tokio::io::sink(), size)
                .await
                .unwrap_err();
            assert_eq!(err.to_string(), "upload incomplete");
        }
    }

    #[test]
    fn remote_errors_are_bounded_to_known_markers() {
        for (wire, result) in [
            ("Error: upload exists\n", "upload exists"),
            ("upload target changed\n", "upload target changed"),
            ("Error: unsupported request\n", "upload unsupported"),
            (
                "remote error includes upload exists and private text",
                "upload unavailable",
            ),
        ] {
            assert_eq!(remote_error(wire.as_bytes()), result);
        }
    }

    #[tokio::test]
    async fn cancelling_stalled_ssh_authentication_returns_without_the_network() {
        use russh::keys::{PrivateKey, ssh_key::private::Ed25519Keypair};
        use tokio::net::{TcpListener, UnixStream};

        let listener = TcpListener::bind(("127.0.0.1", 0)).await.unwrap();
        let peer = Peer {
            host: "127.0.0.1",
            port: listener.local_addr().unwrap().port(),
            user: "fixture",
            pin: "unused",
            key: PrivateKey::from(Ed25519Keypair::from_seed(&[9; 32])),
            identity: None,
        };
        let (wire, mut swift) = UnixStream::pair().unwrap();
        let (read, writer) = wire.into_split();
        let (finished, hold) = tokio::sync::oneshot::channel();
        let server = tokio::spawn(async move {
            let (_stalled_peer, _) = listener.accept().await.unwrap();
            swift.shutdown().await.unwrap();
            let _ = hold.await;
        });
        let file = file();
        let upload = run(
            request(&file),
            &peer,
            read,
            Output {
                writer,
                framed: false,
            },
        );
        let error = timeout(Duration::from_secs(3), upload)
            .await
            .unwrap()
            .unwrap_err();
        assert_eq!(error.to_string(), "upload cancelled");
        finished.send(()).unwrap();
        server.await.unwrap();
    }
}
