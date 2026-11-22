//! A host only makes outbound WSS connections. Its own sshd enforces the phone key.
use super::import_link::{read_command, valid_center};
use anyhow::{Context, Result, ensure};
use fs2::FileExt;
use percent_encoding::{NON_ALPHANUMERIC, utf8_percent_encode};
use russh::{
    client,
    keys::{HashAlg, PublicKeyOrCertificate},
};
use serde::{Deserialize, Serialize};
use std::{
    collections::HashMap,
    env,
    fs::{self, OpenOptions},
    io::{Read, Write},
    os::unix::fs::{OpenOptionsExt, PermissionsExt},
    path::{Path, PathBuf},
    process::{Command, Stdio},
    sync::{Arc, Mutex},
    time::Duration,
};
use tmux_link::{
    pairing::{self, HostInfo, Reply, Request},
    websocket,
};
use tokio::{io::copy_bidirectional, net::TcpStream};

#[derive(Serialize, Deserialize)]
struct State {
    center: String,
    port: u16,
    ssh_port: u16,
    host: HostInfo,
    token: String,
    code: String,
    id: String,
    phone_key: Option<String>,
}

impl State {
    fn url(&self, path: &str) -> String {
        format!("wss://{}:{}{path}", self.center, self.port)
    }
}

fn runtime() -> Result<tokio::runtime::Runtime> {
    Ok(tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()?)
}

fn save(path: &Path, state: &State) -> Result<()> {
    let staged = path.with_extension("new");
    let mut file = OpenOptions::new()
        .create(true)
        .truncate(true)
        .write(true)
        .mode(0o600)
        .open(&staged)?;
    file.write_all(&serde_json::to_vec_pretty(state)?)?;
    file.sync_all()?;
    fs::rename(staged, path)?;
    Ok(())
}

struct HostProbe(Arc<Mutex<Option<String>>>);

impl client::Handler for HostProbe {
    type Error = russh::Error;

    async fn check_server_key(
        &mut self,
        offered: &PublicKeyOrCertificate,
    ) -> Result<bool, Self::Error> {
        if let PublicKeyOrCertificate::PublicKey { key, .. } = offered {
            *self.0.lock().unwrap() = Some(key.fingerprint(HashAlg::Sha256).to_string());
        }
        // Discovery ends before authentication. The phone separately checks this pin.
        Ok(false)
    }
}

fn detect_host(port: u16) -> Result<String> {
    let observed = Arc::new(Mutex::new(None));
    let outcome = runtime()?.block_on(async {
        tokio::time::timeout(
            Duration::from_secs(8),
            client::connect(
                Arc::new(tmux_link::ssh_client_config()),
                ("127.0.0.1", port),
                HostProbe(observed.clone()),
            ),
        )
        .await
    });
    if let Some(pin) = observed.lock().unwrap().take() {
        return Ok(pin);
    }
    match outcome {
        Ok(Err(error)) => anyhow::bail!(
            "Cannot negotiate a supported SSH host key at 127.0.0.1:{port}: {error}. Check the local sshd configuration or pass --ssh-port for its actual port."
        ),
        Ok(Ok(_)) => anyhow::bail!("Local SSH did not present a supported plain host key"),
        Err(_) => anyhow::bail!(
            "Local SSH negotiation timed out at 127.0.0.1:{port}; check the listener or pass --ssh-port"
        ),
    }
}

pub(super) fn command(args: &[String]) -> Result<()> {
    if args == ["--help"] || args == ["-h"] {
        println!(
            "tmux-link-agent pair --center HOST [--port 443] [--ssh-port 22] [--name NAME]\nRun as the tmux owner. Requires a running local OpenSSH server. Open the printed link on your enrolled iPhone to approve this host."
        );
        return Ok(());
    }
    let mut options = HashMap::new();
    let mut args = args.iter();
    while let Some(flag) = args.next() {
        ensure!(
            matches!(
                flag.as_str(),
                "--center" | "--port" | "--ssh-port" | "--name"
            ),
            "unknown pairing option"
        );
        let value = args
            .next()
            .filter(|s| !s.is_empty() && !s.starts_with("--"))
            .context("missing pairing option value")?;
        ensure!(
            options.insert(flag.as_str(), value.as_str()).is_none(),
            "duplicate pairing option"
        );
    }
    let center = *options
        .get("--center")
        .context("usage: tmux-link-agent pair --center HOST")?;
    ensure!(valid_center(center), "expected public center hostname");
    let port: u16 = options.get("--port").unwrap_or(&"443").parse()?;
    let detected_port = env::var("SSH_CONNECTION")
        .ok()
        .and_then(|value| {
            value
                .split_whitespace()
                .last()
                .and_then(|p| p.parse::<u16>().ok())
        })
        .unwrap_or(22);
    let ssh_port: u16 = match options.get("--ssh-port") {
        Some(port) => port.parse()?,
        None => detected_port,
    };
    ensure!(port != 0 && ssh_port != 0, "ports must be nonzero");
    read_command("tmux", &["-V"])
        .context("tmux is required on this host; install it before pairing")?;
    let home = PathBuf::from(env::var_os("HOME").context("HOME is missing")?);
    let directory = home
        .join(".config/tmux-link/paired")
        .join(format!("{center}-{port}"));
    fs::create_dir_all(&directory)?;
    fs::set_permissions(&directory, fs::Permissions::from_mode(0o700))?;
    let lock = OpenOptions::new()
        .create(true)
        .truncate(false)
        .write(true)
        .mode(0o600)
        .open(directory.join("pair.lock"))?;
    lock.try_lock_exclusive()
        .context("another pairing command is running")?;
    let path = directory.join("host.json");
    let mut state: State = match fs::read(&path) {
        Ok(bytes) => serde_json::from_slice(&bytes)?,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            let host = HostInfo {
                name: options
                    .get("--name")
                    .map(|s| s.to_string())
                    .unwrap_or(read_command("hostname", &[])?),
                user: read_command("id", &["-un"])?,
                pin: detect_host(ssh_port)?,
            };
            host.validate()?;
            let token = pairing::secret()?;
            State {
                center: center.to_owned(),
                port,
                ssh_port,
                host,
                id: pairing::hash(&token)[..32].to_owned(),
                token,
                code: pairing::secret()?,
                phone_key: None,
            }
        }
        Err(error) => return Err(error.into()),
    };
    ensure!(
        state.center == center && state.port == port && state.ssh_port == ssh_port,
        "saved host settings differ; reuse the original ports"
    );
    ensure!(
        detect_host(ssh_port)? == state.host.pin,
        "local SSH host key changed; review the old pairing before enrolling again"
    );
    save(&path, &state)?;
    eprintln!(
        "Local SSH verified at 127.0.0.1:{ssh_port}; connecting to {center}:{port} for pairing."
    );
    runtime()?.block_on(async {
        pairing::request(&state.url("/tmux-link/register"), &Request::Register {
            token: state.token.clone(), code: state.code.clone(), host: state.host.clone()
        }).await.context("Unable to register this host with the center")?;
        let escape = |text: &str| utf8_percent_encode(text, NON_ALPHANUMERIC).to_string();
        println!("Open this link in Tmux Link on your enrolled iPhone, then confirm the host fingerprint (link expires in 10 minutes):");
        println!("tmuxlink://pair?center={}&port={}&id={}&code={}&name={}&user={}&pin={}", escape(center), port, state.id, state.code, escape(&state.host.name), escape(&state.host.user), escape(&state.host.pin));
        println!("SSH fingerprint: {}\nWaiting for phone approval…", state.host.pin);
        let deadline = tokio::time::Instant::now() + Duration::from_secs(pairing::PAIR_TTL);
        loop {
            let reply = pairing::request(&state.url("/tmux-link/register"), &Request::Status { token: state.token.clone() }).await.context("Unable to check phone approval with the center")?;
            if reply.approved {
                let key = pairing::public_key(&reply.phone_key.context("approved host is missing its phone key")?)?;
                authorize(&home, &key)?;
                state.phone_key = Some(key);
                save(&path, &state)?;
                break;
            }
            ensure!(tokio::time::Instant::now() < deadline, "pairing expired; run pair again");
            tokio::time::sleep(Duration::from_secs(2)).await;
        }
        Ok::<_, anyhow::Error>(())
    })?;
    drop(lock);
    println!("Phone approved. Starting the outbound connection.");
    if let Err(error) = install_service(&home, &state.id, &path) {
        eprintln!(
            "Background service unavailable ({error}). Keeping the connection open in this terminal. To resume: tmux-link-agent serve-paired '{}'",
            path.display()
        );
        return serve(&path);
    }
    println!(
        "Connected host installed. Choose {} in your phone's client list.",
        state.host.name
    );
    Ok(())
}

fn authorize(home: &Path, public: &str) -> Result<()> {
    let ssh = home.join(".ssh");
    fs::create_dir_all(&ssh)?;
    fs::set_permissions(&ssh, fs::Permissions::from_mode(0o700))?;
    let path = ssh.join("authorized_keys");
    ensure!(
        !path.is_symlink(),
        "authorized_keys is a symlink; review the file before pairing"
    );
    let mut file = OpenOptions::new()
        .create(true)
        .truncate(false)
        .read(true)
        .append(true)
        .mode(0o600)
        .open(&path)?;
    file.lock_exclusive()?;
    let mut existing = String::new();
    file.read_to_string(&mut existing)?;
    if !existing
        .lines()
        .any(|line| !line.trim_start().starts_with('#') && line.contains(public))
    {
        let executable = env::current_exe()?
            .to_str()
            .context("non-UTF8 executable path")?
            .to_owned();
        ensure!(
            !executable.chars().any(char::is_control),
            "invalid executable path"
        );
        let shell = format!(
            "/usr/bin/env PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin '{}' attach",
            executable.replace('\'', "'\\''")
        );
        let command = shell.replace('\\', "\\\\").replace('"', "\\\"");
        writeln!(
            file,
            "\nrestrict,pty,command=\"{command}\" {public} tmux-link-paired"
        )?;
        file.sync_all()?;
    }
    Ok(())
}

fn install_service(home: &Path, id: &str, state: &Path) -> Result<()> {
    let executable = env::current_exe()?;
    if cfg!(target_os = "macos") {
        let label = format!("dev.tmuxlink.host-{id}");
        let directory = home.join("Library/LaunchAgents");
        fs::create_dir_all(&directory)?;
        let escape = |path: &Path| {
            path.to_string_lossy()
                .replace('&', "&amp;")
                .replace('<', "&lt;")
                .replace('>', "&gt;")
        };
        let path = directory.join(format!("{label}.plist"));
        fs::write(
            &path,
            format!(
                "<?xml version=\"1.0\"?><plist version=\"1.0\"><dict><key>Label</key><string>{label}</string><key>ProgramArguments</key><array><string>{}</string><string>serve-paired</string><string>{}</string></array><key>RunAtLoad</key><true/><key>KeepAlive</key><true/><key>ThrottleInterval</key><integer>5</integer></dict></plist>",
                escape(&executable),
                escape(state)
            ),
        )?;
        let domain = format!("gui/{}", read_command("id", &["-u"])?);
        let _ = Command::new("launchctl")
            .args(["bootout", &format!("{domain}/{label}")])
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status();
        ensure!(
            Command::new("launchctl")
                .args(["bootstrap", &domain])
                .arg(path)
                .status()?
                .success(),
            "launchd could not start the host"
        );
    } else {
        let directory = home.join(".config/systemd/user");
        fs::create_dir_all(&directory)?;
        let unit = format!("tmux-link-host-{id}.service");
        let quote = |path: &Path| {
            path.to_string_lossy()
                .replace('\\', "\\\\")
                .replace('"', "\\\"")
                .replace('%', "%%")
        };
        ensure!(
            !executable.to_string_lossy().chars().any(char::is_control)
                && !state.to_string_lossy().chars().any(char::is_control),
            "invalid service path"
        );
        fs::write(
            directory.join(&unit),
            format!(
                "[Unit]\nDescription=Tmux Link outbound host\nAfter=network-online.target\n[Service]\nExecStart=\"{}\" serve-paired \"{}\"\nRestart=always\nRestartSec=5\n[Install]\nWantedBy=default.target\n",
                quote(&executable),
                quote(state)
            ),
        )?;
        ensure!(
            Command::new("systemctl")
                .args(["--user", "daemon-reload"])
                .status()?
                .success(),
            "systemd user services unavailable"
        );
        ensure!(
            Command::new("systemctl")
                .args(["--user", "enable", "--now", &unit])
                .status()?
                .success(),
            "could not enable user service"
        );
        ensure!(
            Command::new("systemctl")
                .args(["--user", "restart", &unit])
                .status()?
                .success(),
            "could not start user service"
        );
        println!(
            "For service after logout, an administrator can enable user lingering: sudo loginctl enable-linger {}",
            read_command("id", &["-un"])?
        );
    }
    Ok(())
}

pub(super) fn serve(path: &Path) -> Result<()> {
    let state: State = serde_json::from_slice(&fs::read(path)?)?;
    ensure!(state.phone_key.is_some(), "host is not yet paired");
    let lock = OpenOptions::new()
        .create(true)
        .truncate(false)
        .write(true)
        .mode(0o600)
        .open(path.with_extension("run.lock"))?;
    lock.try_lock_exclusive()
        .context("outbound host is already running")?;
    runtime()?.block_on(async {
        let mut tasks = tokio::task::JoinSet::new();
        let state = std::sync::Arc::new(state);
        for _ in 0..4 {
            let state = state.clone();
            tasks.spawn(async move {
                loop {
                    let result = connect_once(&state).await;
                    if let Err(error) = result {
                        eprintln!("Host tunnel reconnecting: {error}");
                    }
                    tokio::time::sleep(Duration::from_secs(3)).await;
                }
            });
        }
        tasks
            .join_next()
            .await
            .context("all host tunnel workers stopped")??;
        Ok(())
    })
}

async fn connect_once(state: &State) -> Result<()> {
    let mut stream = tokio::time::timeout(
        Duration::from_secs(15),
        websocket::connect(&state.url("/tmux-link/tunnel")),
    )
    .await??;
    pairing::write(
        &mut stream,
        &Request::Tunnel {
            token: state.token.clone(),
        },
    )
    .await?;
    let accepted: Reply = pairing::read(&mut stream).await?;
    ensure!(
        accepted.id == state.id && accepted.approved,
        "outbound tunnel was not authorized"
    );
    let start: Reply = pairing::read(&mut stream).await?;
    ensure!(
        start.id == state.id && start.ready,
        "invalid tunnel activation"
    );
    let mut local = tokio::time::timeout(
        Duration::from_secs(2),
        TcpStream::connect(("127.0.0.1", state.ssh_port)),
    )
    .await??;
    local.set_nodelay(true)?;
    pairing::write(
        &mut stream,
        &Reply {
            id: state.id.clone(),
            ready: true,
            ..Reply::default()
        },
    )
    .await?;
    copy_bidirectional(&mut stream, &mut local).await?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs::File;
    use std::net::{TcpListener, TcpStream as BlockingStream};

    struct LocalSshd(std::process::Child);
    impl Drop for LocalSshd {
        fn drop(&mut self) {
            let _ = self.0.kill();
            let _ = self.0.wait();
        }
    }

    #[test]
    fn probe_matches_the_phone_on_each_openssh_host_key_type() -> Result<()> {
        let directory = env::temp_dir().join(format!("tmuxlink-host-probe-{}", pairing::secret()?));
        fs::create_dir(&directory)?;
        fs::set_permissions(&directory, fs::Permissions::from_mode(0o700))?;
        for (index, (kind, algorithm, supported)) in [
            ("ed25519", "ssh-ed25519", true),
            ("ecdsa", "ecdsa-sha2-nistp256", true),
            ("rsa", "rsa-sha2-512,rsa-sha2-256", true),
            ("rsa", "ssh-rsa", false),
        ]
        .into_iter()
        .enumerate()
        {
            let key = directory.join(format!("{kind}-{index}"));
            ensure!(
                Command::new("ssh-keygen")
                    .args(["-q", "-t", kind, "-N", ""])
                    .arg("-f")
                    .arg(&key)
                    .status()?
                    .success(),
                "generate host key"
            );
            let expected = read_command(
                "ssh-keygen",
                &[
                    "-E",
                    "sha256",
                    "-lf",
                    key.with_extension("pub").to_str().unwrap(),
                ],
            )?
            .split_whitespace()
            .nth(1)
            .unwrap()
            .to_owned();
            let listener = TcpListener::bind("127.0.0.1:0")?;
            let port = listener.local_addr()?.port();
            drop(listener);
            let log = directory.join(format!("{kind}.log"));
            let mut daemon = LocalSshd(
                Command::new("/usr/sbin/sshd")
                    .args([
                        "-D",
                        "-e",
                        "-f",
                        "/dev/null",
                        "-o",
                        "ListenAddress=127.0.0.1",
                        "-o",
                        "PasswordAuthentication=no",
                        "-o",
                        "KbdInteractiveAuthentication=no",
                        "-o",
                        "UsePAM=no",
                        "-o",
                        &format!("HostKeyAlgorithms={algorithm}"),
                    ])
                    .arg("-h")
                    .arg(&key)
                    .arg("-p")
                    .arg(port.to_string())
                    .stderr(File::create(&log)?)
                    .stdout(Stdio::null())
                    .spawn()?,
            );
            for _ in 0..100 {
                if BlockingStream::connect(("127.0.0.1", port)).is_ok() {
                    break;
                }
                if daemon.0.try_wait()?.is_some() {
                    anyhow::bail!("sshd exited: {}", fs::read_to_string(&log)?);
                }
                std::thread::sleep(Duration::from_millis(20));
            }
            let result = detect_host(port);
            if !supported {
                assert!(result.is_err(), "legacy SHA-1 host signature was accepted");
                continue;
            }
            let actual = result.with_context(|| {
                format!(
                    "probe {kind}; sshd log: {}",
                    fs::read_to_string(&log).unwrap_or_default()
                )
            })?;
            assert_eq!(actual, expected, "{kind} host key on nonstandard port");
        }
        fs::remove_dir_all(directory)?;
        Ok(())
    }
}
