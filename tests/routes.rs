//! A single center must not mix up clients registered on different private sockets.
use futures_util::StreamExt;
use std::{
    io::BufRead,
    process::{Child, Command, Stdio},
};
use tokio::{
    io::AsyncWriteExt,
    net::UnixListener,
    time::{Duration, timeout},
};

struct Running(Child);
impl Drop for Running {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}

#[tokio::test]
async fn routes_only_to_registered_clients() {
    let dir = std::env::temp_dir().join(format!("tmux-link-routes-{}", std::process::id()));
    std::fs::create_dir(&dir).unwrap();
    let a = dir.join("alpha.sock");
    let b = dir.join("beta.sock");
    let alpha = UnixListener::bind(&a).unwrap();
    let beta = UnixListener::bind(&b).unwrap();
    let mut server = Running(
        Command::new(env!("CARGO_BIN_EXE_center"))
            .arg("127.0.0.1:0")
            .arg(&a)
            .arg("--websocket")
            .arg(format!("build={}", b.display()))
            .stderr(Stdio::piped())
            .spawn()
            .unwrap(),
    );
    let mut line = String::new();
    std::io::BufReader::new(server.0.stderr.take().unwrap())
        .read_line(&mut line)
        .unwrap();
    let addr = line.trim().split_ascii_whitespace().last().unwrap();
    timeout(Duration::from_secs(5), async {
        for (route, endpoint, marker) in [("", &alpha, "default"), ("/build", &beta, "build"), ("/primary", &alpha, "primary")] {
            let (mut ws,_) = tokio_tungstenite::connect_async(format!("ws://{addr}/tmux-link{route}")).await.unwrap();
            let (mut socket,_) = endpoint.accept().await.unwrap();
            socket.write_all(marker.as_bytes()).await.unwrap();
            assert_eq!(ws.next().await.unwrap().unwrap().into_data().as_ref(), marker.as_bytes());
        }
        for name in ["unknown", "%2e%2e%2fbuild.sock", "build/other"] {
            let err = tokio_tungstenite::connect_async(format!("ws://{addr}/tmux-link/{name}")).await.unwrap_err();
            assert!(matches!(err, tokio_tungstenite::tungstenite::Error::Http(r) if r.status().as_u16() == 404));
        }
    }).await.unwrap();
    drop(server);
    std::fs::remove_dir_all(dir).unwrap();
}
