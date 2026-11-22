use anyhow::{Result, bail};
use futures_util::{SinkExt, StreamExt};
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt, DuplexStream};
use tokio_tungstenite::{
    WebSocketStream,
    tungstenite::{Message, protocol::WebSocketConfig},
};

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
            let mut heartbeat = tokio::time::interval(std::time::Duration::from_secs(20));
            heartbeat.tick().await;
            loop {
                let count = tokio::select! {
                    count = input.read(&mut bytes) => count?,
                    _ = heartbeat.tick() => {
                        tx.send(Message::Ping(Vec::new().into())).await?;
                        continue;
                    }
                };
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
            while let Some(message) =
                tokio::time::timeout(std::time::Duration::from_secs(65), rx.next()).await?
            {
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

fn frame_limits() -> WebSocketConfig {
    WebSocketConfig::default()
        .max_message_size(Some(65536))
        .max_frame_size(Some(65536))
}

pub async fn connect(url: &str) -> Result<DuplexStream> {
    #[cfg(feature = "tls")]
    let _ = rustls::crypto::ring::default_provider().install_default();
    let (socket, _) =
        tokio_tungstenite::connect_async_with_config(url, Some(frame_limits()), true).await?;
    Ok(byte_stream(socket))
}

#[cfg(feature = "tls")]
pub async fn connect_mtls(url: &str, cert_der: &[u8], key_pkcs8: &[u8]) -> Result<DuplexStream> {
    let roots = rustls::RootCertStore::from_iter(webpki_roots::TLS_SERVER_ROOTS.iter().cloned());
    connect_mtls_with_roots(url, cert_der, key_pkcs8, roots).await
}

// A configured identity must guard this connection even when the gateway is
// accidentally serving ordinary HTTPS. rustls normally permits that handshake.
#[cfg(feature = "tls")]
#[derive(Debug)]
struct RequiredClientCert {
    identity: std::sync::Arc<dyn rustls::client::ResolvesClientCert>,
    selected: std::sync::atomic::AtomicBool,
}

#[cfg(feature = "tls")]
impl rustls::client::ResolvesClientCert for RequiredClientCert {
    fn resolve(
        &self,
        subjects: &[&[u8]],
        schemes: &[rustls::SignatureScheme],
    ) -> Option<std::sync::Arc<rustls::sign::CertifiedKey>> {
        let cert = self.identity.resolve(subjects, schemes)?;
        cert.key.choose_scheme(schemes)?;
        self.selected
            .store(true, std::sync::atomic::Ordering::Relaxed);
        Some(cert)
    }

    fn has_certs(&self) -> bool {
        self.identity.has_certs()
    }
}

#[cfg(feature = "tls")]
async fn connect_mtls_with_roots(
    url: &str,
    cert_der: &[u8],
    key_pkcs8: &[u8],
    roots: rustls::RootCertStore,
) -> Result<DuplexStream> {
    use rustls::pki_types::{CertificateDer, PrivatePkcs8KeyDer};
    use std::sync::Arc;

    anyhow::ensure!(url.starts_with("wss://"), "device certificate requires WSS");
    let mut config = rustls::ClientConfig::builder_with_provider(Arc::new(
        rustls::crypto::ring::default_provider(),
    ))
    .with_safe_default_protocol_versions()?
    .with_root_certificates(roots)
    .with_client_auth_cert(
        vec![CertificateDer::from(cert_der.to_owned())],
        PrivatePkcs8KeyDer::from(key_pkcs8.to_owned()).into(),
    )?;
    let resolver = Arc::new(RequiredClientCert {
        identity: config.client_auth_cert_resolver.clone(),
        selected: false.into(),
    });
    config.client_auth_cert_resolver = resolver.clone();
    config.resumption = rustls::client::Resumption::disabled();
    let connector = tokio_tungstenite::Connector::Rustls(Arc::new(config));
    let (socket, _) = tokio_tungstenite::connect_async_tls_with_config(
        url,
        Some(frame_limits()),
        true,
        Some(connector),
    )
    .await?;
    anyhow::ensure!(
        resolver.selected.load(std::sync::atomic::Ordering::Relaxed),
        "gateway did not request a compatible client certificate"
    );
    Ok(byte_stream(socket))
}

#[cfg(all(test, feature = "tls"))]
mod tests {
    use super::*;
    use rcgen::{
        BasicConstraints, CertificateParams, ExtendedKeyUsagePurpose, IsCa, Issuer, KeyPair,
    };
    use rustls::pki_types::PrivatePkcs8KeyDer;
    use rustls::{ClientConfig, RootCertStore, ServerConfig, server::WebPkiClientVerifier};
    use std::sync::Arc;
    use tokio::net::TcpListener;

    #[tokio::test]
    async fn websocket_verifies_both_endpoints_before_forwarding() -> Result<()> {
        let _ = rustls::crypto::ring::default_provider().install_default();
        let mut ca = CertificateParams::new(Vec::new())?;
        ca.is_ca = IsCa::Ca(BasicConstraints::Unconstrained);
        let ca_key = KeyPair::generate()?;
        let mut roots = RootCertStore::empty();
        roots.add(ca.self_signed(&ca_key)?.der().clone())?;
        let issuer = Issuer::new(ca, ca_key);

        let mut server_params = CertificateParams::new(vec!["127.0.0.1".into()])?;
        server_params
            .extended_key_usages
            .push(ExtendedKeyUsagePurpose::ServerAuth);
        let server_key = KeyPair::generate()?;
        let server_cert = server_params.signed_by(&server_key, &issuer)?;
        let verifier = WebPkiClientVerifier::builder(Arc::new(roots.clone())).build()?;
        let config = ServerConfig::builder()
            .with_client_cert_verifier(verifier)
            .with_single_cert(
                vec![server_cert.der().clone()],
                PrivatePkcs8KeyDer::from(server_key.serialize_der()).into(),
            )?;
        let ordinary = ServerConfig::builder()
            .with_no_client_auth()
            .with_single_cert(
                vec![server_cert.der().clone()],
                PrivatePkcs8KeyDer::from(server_key.serialize_der()).into(),
            )?;
        let acceptor = tokio_rustls::TlsAcceptor::from(Arc::new(config));
        let listener = TcpListener::bind("127.0.0.1:0").await?;
        let url = format!("wss://{}/tmux-link", listener.local_addr()?);
        let serving = tokio::spawn(async move {
            // Three failed TLS handshakes and one authenticated WebSocket.
            for _ in 0..4 {
                let (socket, _) = listener.accept().await?;
                if let Ok(tls) = acceptor.accept(socket).await {
                    let mut ws = tokio_tungstenite::accept_async(tls).await?;
                    ws.send(Message::binary(b"authenticated".to_vec())).await?;
                }
            }
            let (socket, _) = listener.accept().await?;
            let tls = tokio_rustls::TlsAcceptor::from(Arc::new(ordinary))
                .accept(socket)
                .await?;
            let _ws = tokio_tungstenite::accept_async(tls).await?;
            Ok::<_, anyhow::Error>(())
        });
        let key = KeyPair::generate()?;
        let mut params = CertificateParams::new(Vec::new())?;
        params
            .extended_key_usages
            .push(ExtendedKeyUsagePurpose::ClientAuth);
        let cert = params.signed_by(&key, &issuer)?;
        let stranger = params.self_signed(&key)?;
        let pkcs8 = key.serialize_der();
        let connector = tokio_tungstenite::Connector::Rustls(Arc::new(
            ClientConfig::builder()
                .with_root_certificates(roots.clone())
                .with_no_client_auth(),
        ));
        assert!(
            tokio_tungstenite::connect_async_tls_with_config(&url, None, true, Some(connector))
                .await
                .is_err()
        );
        assert!(
            connect_mtls_with_roots(&url, stranger.der(), &pkcs8, roots.clone())
                .await
                .is_err()
        );
        assert!(connect_mtls(&url, cert.der(), &pkcs8).await.is_err());
        assert!(
            connect_mtls(&url.replacen("wss:", "ws:", 1), cert.der(), &pkcs8)
                .await
                .is_err()
        );
        let mut authenticated =
            connect_mtls_with_roots(&url, cert.der(), &pkcs8, roots.clone()).await?;
        let mut data = [0; 13];
        authenticated.read_exact(&mut data).await?;
        assert_eq!(&data, b"authenticated");
        let downgrade = connect_mtls_with_roots(&url, cert.der(), &pkcs8, roots)
            .await
            .unwrap_err();
        assert_eq!(
            downgrade.to_string(),
            "gateway did not request a compatible client certificate"
        );
        serving.await??;
        Ok(())
    }
}
