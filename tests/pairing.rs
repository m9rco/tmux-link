//! Real WSS-compatible broker streams, with the authenticated proxy identity injected locally.
use anyhow::Result;
use std::{
    io::{BufRead, BufReader},
    process::{Child, Command, Stdio},
    time::Duration,
};
use tmux_link::pairing::{self, HostInfo, Reply, Request};
use tokio::io::{AsyncReadExt, AsyncWriteExt, DuplexStream};
use tokio_tungstenite::tungstenite::client::IntoClientRequest;

struct Server {
    child: Child,
    address: String,
}
impl Drop for Server {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}
fn start(directory: &std::path::Path) -> Server {
    let mut child = Command::new(env!("CARGO_BIN_EXE_center"))
        .arg("127.0.0.1:0")
        .arg(directory.join("unused.sock"))
        .arg("--websocket")
        .arg(format!(
            "--pairing-dir={}",
            directory.join("registry").display()
        ))
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    let mut line = String::new();
    BufReader::new(child.stderr.take().unwrap())
        .read_line(&mut line)
        .unwrap();
    let address = line.trim().split(' ').next_back().unwrap().to_owned();
    Server { child, address }
}
async fn connect(server: &Server, path: &str, device: Option<&str>) -> Result<DuplexStream> {
    let mut request = format!("ws://{}{path}", server.address).into_client_request()?;
    if let Some(device) = device {
        request
            .headers_mut()
            .insert("X-Tmux-Device", device.parse()?);
    }
    let (ws, _) = tokio_tungstenite::connect_async(request).await?;
    Ok(tmux_link::websocket::byte_stream(ws))
}
async fn rpc(
    server: &Server,
    path: &str,
    device: Option<&str>,
    message: &Request,
) -> Result<Reply> {
    let mut stream = connect(server, path, device).await?;
    pairing::write(&mut stream, message).await?;
    pairing::read(&mut stream).await
}

#[tokio::test]
async fn outbound_pairing_requires_approval_and_binds_each_device() -> Result<()> {
    let directory = std::env::temp_dir().join(format!("tmuxlink-broker-{}", pairing::secret()?));
    std::fs::create_dir(&directory)?;
    let token = pairing::secret()?;
    let code = pairing::secret()?;
    let host = HostInfo {
        name: "内网机器".into(),
        user: "alice".into(),
        pin: "SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA".into(),
    };
    let server = start(&directory);
    let reply = rpc(
        &server,
        "/tmux-link/register",
        None,
        &Request::Register {
            token: token.clone(),
            code: code.clone(),
            host: host.clone(),
        },
    )
    .await?;
    assert!(reply.error.is_none());
    let id = reply.id;
    let phone = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";
    let approve = Request::Approve {
        code: code.clone(),
        pin: host.pin.clone(),
        phone_key: phone.into(),
    };
    assert!(
        rpc(&server, "/tmux-link/pair", None, &approve)
            .await?
            .error
            .is_some()
    );
    assert!(
        rpc(
            &server,
            "/tmux-link/pair",
            Some("A11CE"),
            &Request::Approve {
                code: code.clone(),
                pin: "SHA256:wrong".into(),
                phone_key: phone.into()
            }
        )
        .await?
        .error
        .is_some()
    );
    assert!(
        rpc(&server, "/tmux-link/pair", Some("A11CE"), &approve)
            .await?
            .approved
    );
    assert!(
        rpc(&server, "/tmux-link/pair", Some("B0B"), &approve)
            .await?
            .error
            .is_some()
    );
    assert_eq!(
        rpc(
            &server,
            "/tmux-link/register",
            None,
            &Request::Status {
                token: token.clone()
            }
        )
        .await?
        .phone_key
        .as_deref(),
        Some(phone)
    );

    let mut tunnel = connect(&server, "/tmux-link/tunnel", None).await?;
    pairing::write(
        &mut tunnel,
        &Request::Tunnel {
            token: token.clone(),
        },
    )
    .await?;
    let ack: Reply = pairing::read(&mut tunnel).await?;
    assert!(ack.approved);
    let id_copy = id.clone();
    let host_side = tokio::spawn(async move {
        let ready: Reply = pairing::read(&mut tunnel).await?;
        assert_eq!(ready.id, id_copy);
        assert!(ready.ready);
        pairing::write(&mut tunnel, &ready).await?;
        let mut bytes = [0; 4];
        tunnel.read_exact(&mut bytes).await?;
        assert_eq!(&bytes, b"test");
        tunnel.write_all("中文🙂".as_bytes()).await?;
        tokio::time::sleep(Duration::from_millis(100)).await;
        Ok::<_, anyhow::Error>(())
    });
    let path = format!("/tmux-link/session/{id}");
    let mut stranger = connect(&server, &path, Some("B0B")).await?;
    assert_eq!(stranger.read(&mut [0]).await?, 0);
    let mut terminal = connect(&server, &path, Some("A11CE")).await?;
    terminal.write_all(b"test").await?;
    let mut actual = vec![0; "中文🙂".len()];
    terminal.read_exact(&mut actual).await?;
    assert_eq!(actual, "中文🙂".as_bytes());
    drop(terminal);
    host_side.await??;
    drop(server);
    // Both ownership and agent credentials survive a center restart.
    let restarted = start(&directory);
    let record = rpc(
        &restarted,
        "/tmux-link/register",
        None,
        &Request::Status { token },
    )
    .await?;
    assert!(record.approved);
    assert_eq!(record.id, id);
    assert!(
        rpc(&restarted, "/tmux-link/pair", Some("B0B"), &approve)
            .await?
            .error
            .is_some()
    );
    drop(restarted);
    std::fs::remove_dir_all(directory)?;
    Ok(())
}

#[test]
fn public_keys_cannot_inject_authorized_key_options() {
    assert!(pairing::public_key("restrict ssh-ed25519 abc").is_err());
    assert!(pairing::public_key("ssh-ed25519 AA==").is_err());
}
