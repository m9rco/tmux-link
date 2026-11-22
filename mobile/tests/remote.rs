//! Run against the disposable fixture in scripts/e2e-linux.sh.
use russh::keys::load_secret_key;
use std::{
    ffi::{CStr, CString},
    io::{self, Read, Write},
    net::Shutdown,
    os::{fd::IntoRawFd, unix::net::UnixStream},
    thread::{self, JoinHandle},
    time::{Duration, Instant},
};

fn start(pin: &str, key_env: &str) -> (UnixStream, JoinHandle<Result<(), String>>) {
    start_protocol(pin, key_env, None)
}

fn start_protocol(
    pin: &str,
    key_env: &str,
    secure_target: Option<i64>,
) -> (UnixStream, JoinHandle<Result<(), String>>) {
    let get = |key| std::env::var(key).unwrap();
    let key = load_secret_key(get(key_env), None).unwrap();
    let seed = key
        .key_data()
        .ed25519()
        .unwrap()
        .private
        .as_ref()
        .to_owned();
    let port = get("TL_TEST_PORT").parse().unwrap();
    let host =
        CString::new(std::env::var("TL_TEST_HOST").unwrap_or_else(|_| "127.0.0.1".into())).unwrap();
    let user =
        CString::new(std::env::var("TL_TEST_USER").unwrap_or_else(|_| "alice".into())).unwrap();
    let fingerprint = CString::new(pin).unwrap();
    let (view, core) = UnixStream::pair().unwrap();
    view.set_read_timeout(Some(Duration::from_secs(10)))
        .unwrap();
    let worker = thread::spawn(move || unsafe {
        let error = if let Some(target) = secure_target {
            tmux_link_mobile::tl_open_secure(
                core.into_raw_fd(),
                host.as_ptr(),
                port,
                user.as_ptr(),
                fingerprint.as_ptr(),
                seed.as_ptr(),
                target,
                std::ptr::null(),
                0,
                std::ptr::null(),
                0,
            )
        } else {
            tmux_link_mobile::tl_connect(
                core.into_raw_fd(),
                host.as_ptr(),
                port,
                user.as_ptr(),
                fingerprint.as_ptr(),
                seed.as_ptr(),
            )
        };
        if error.is_null() {
            Ok(())
        } else {
            let text = CStr::from_ptr(error).to_string_lossy().into_owned();
            tmux_link_mobile::tl_free_error(error);
            Err(text)
        }
    });
    (view, worker)
}
fn finish_session(mut view: UnixStream, worker: JoinHandle<Result<(), String>>) {
    // Signal EOF to the uploader while allowing the last terminal frames to drain.
    view.shutdown(Shutdown::Write).unwrap();
    io::copy(&mut view, &mut io::sink()).unwrap();
    worker.join().unwrap().unwrap();
}

fn send(socket: &mut UnixStream, kind: u8, bytes: &[u8]) {
    socket.write_all(&[kind]).unwrap();
    socket
        .write_all(&(bytes.len() as u32).to_be_bytes())
        .unwrap();
    socket.write_all(bytes).unwrap();
}
fn expect(socket: &mut UnixStream, text: &str) {
    let deadline = Instant::now() + Duration::from_secs(15);
    let mut seen = Vec::new();
    let mut buf = [0; 8192];
    loop {
        let n = socket.read(&mut buf).unwrap();
        assert!(
            n > 0 && Instant::now() < deadline,
            "waiting for {text}, received {:?}",
            String::from_utf8_lossy(&seen)
        );
        seen.extend_from_slice(&buf[..n]);
        if seen.windows(text.len()).any(|part| part == text.as_bytes()) {
            break;
        }
    }
}

fn read_frame(socket: &mut UnixStream) -> (u8, Vec<u8>) {
    let mut header = [0; 5];
    socket.read_exact(&mut header).unwrap();
    let size = u32::from_be_bytes(header[1..].try_into().unwrap()) as usize;
    assert!(size <= 65536);
    let mut payload = vec![0; size];
    socket.read_exact(&mut payload).unwrap();
    (header[0], payload)
}

#[test]
#[ignore = "requires a disposable Linux sshd/tmux fixture"]
fn pinned_mobile_session() {
    let pin = std::env::var("TL_TEST_PIN").unwrap();
    let (mut view, worker) = start(&pin, "TL_TEST_KEY");
    expect(&mut view, "Session number:");
    view.write_all(&[0, 0]).unwrap();
    view.write_all(&[0, 0, 2]).unwrap();
    view.write_all(b"1").unwrap();
    view.write_all(b"\r").unwrap();
    expect(&mut view, "tl-live");
    send(&mut view, 1, &[0, 88, 0, 29]);
    send(
        &mut view,
        0,
        b"export TL_RESUME=retained; printf 'input-%s\\n' passed\r",
    );
    expect(&mut view, "input-passed");
    // Only the command's output contains the UTF-8 text, never its echo.
    send(
        &mut view,
        0,
        b"printf '\\344\\270\\255\\360\\237\\231\\202\\n'\r",
    );
    expect(&mut view, "中🙂");
    send(
        &mut view,
        0,
        b"for i in $(seq 30); do stty size; sleep .05; done\r",
    );
    expect(&mut view, "28 88"); // one row used by the tmux status bar
    finish_session(view, worker);
    let (mut view, worker) = start(&pin, "TL_TEST_KEY");
    expect(&mut view, "Session number:");
    send(&mut view, 0, b"1\r");
    expect(&mut view, "tl-live");
    send(&mut view, 0, b"printf 'session-%s\\n' \"$TL_RESUME\"\r");
    expect(&mut view, "session-retained");
    finish_session(view, worker);
}

#[test]
#[ignore = "requires a disposable Linux sshd/tmux fixture"]
fn rejects_untrusted_peers() {
    let pin = std::env::var("TL_TEST_PIN").unwrap();
    let (_view, bad) = start("SHA256:incorrect", "TL_TEST_KEY");
    assert_eq!(bad.join().unwrap().unwrap_err(), "Unknown server key");
    let (_view, unauthorized) = start(&pin, "TL_TEST_UNAUTHORIZED_KEY");
    assert_eq!(
        unauthorized.join().unwrap().unwrap_err(),
        "phone key rejected"
    );
}

#[test]
#[ignore = "requires a disposable Linux sshd/tmux fixture"]
fn rejects_oversized_input_frame() {
    let pin = std::env::var("TL_TEST_PIN").unwrap();
    let (mut view, worker) = start(&pin, "TL_TEST_KEY");
    expect(&mut view, "Session number:");
    view.write_all(&[0]).unwrap();
    view.write_all(&65537_u32.to_be_bytes()).unwrap();
    assert_eq!(worker.join().unwrap().unwrap_err(), "input frame too large");
}

#[test]
#[ignore = "requires a disposable Linux sshd/tmux fixture"]
fn rejects_unknown_input_frame() {
    let pin = std::env::var("TL_TEST_PIN").unwrap();
    let (mut view, worker) = start(&pin, "TL_TEST_KEY");
    expect(&mut view, "Session number:");
    send(&mut view, 9, &[]);
    assert_eq!(worker.join().unwrap().unwrap_err(), "invalid input frame");
}

#[test]
#[ignore = "requires a disposable Linux sshd/tmux fixture"]
fn framed_terminal_reports_remote_round_trip_and_keeps_output_separate() {
    let pin = std::env::var("TL_TEST_PIN").unwrap();
    let (mut view, worker) = start_protocol(&pin, "TL_TEST_KEY", Some(-1));
    let mut stages = Vec::new();
    let mut terminal = Vec::new();
    let mut measured = false;
    let deadline = Instant::now() + Duration::from_secs(20);
    while !measured || !terminal.windows(15).any(|p| p == b"Session number:") {
        assert!(Instant::now() < deadline);
        let (kind, payload) = read_frame(&mut view);
        match kind {
            0 => terminal.extend(payload),
            1 => stages.push(String::from_utf8(payload).unwrap()),
            2 => {
                assert_eq!(stages.last().unwrap(), "ready");
                let ms = u32::from_be_bytes(payload.try_into().unwrap());
                assert!(ms < 8000);
                measured = true;
            }
            kind => panic!("unknown output kind {kind}"),
        }
    }
    assert_eq!(stages, ["connecting", "ssh", "auth", "attaching", "ready"]);
    finish_session(view, worker);
}

#[test]
#[ignore = "requires a disposable Linux sshd/tmux fixture"]
fn lists_and_attaches_unicode_session_in_c_locale() {
    let pin = std::env::var("TL_TEST_PIN").unwrap();
    let (mut view, worker) = start_protocol(&pin, "TL_TEST_KEY", Some(-2));
    let mut list = String::new();
    view.read_to_string(&mut list).unwrap();
    worker.join().unwrap().unwrap();
    assert!(list.contains("zz-中文🙂"), "{list}");

    // The fixture creates this pane in its second session (ID 1).
    let (mut view, worker) = start_protocol(&pin, "TL_TEST_KEY", Some(1));
    let marker = "pane-左🙂右".as_bytes();
    let mut terminal = Vec::new();
    let deadline = Instant::now() + Duration::from_secs(10);
    while !terminal.windows(marker.len()).any(|p| p == marker) {
        assert!(Instant::now() < deadline, "missing Unicode pane text");
        let (kind, payload) = read_frame(&mut view);
        if kind == 0 {
            terminal.extend(payload);
        }
    }
    finish_session(view, worker);
}
