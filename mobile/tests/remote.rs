//! Run against the disposable fixture in scripts/e2e-linux.sh.
use russh::keys::load_secret_key;
use std::{
    ffi::{CStr, CString},
    io::{Read, Write},
    os::{fd::IntoRawFd, unix::net::UnixStream},
    thread::{self, JoinHandle},
    time::{Duration, Instant},
};

fn start(pin: &str, key_env: &str) -> (UnixStream, JoinHandle<Result<(), String>>) {
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
        let error = tmux_link_mobile::tl_connect(
            core.into_raw_fd(),
            host.as_ptr(),
            port,
            user.as_ptr(),
            fingerprint.as_ptr(),
            seed.as_ptr(),
        );
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
    send(
        &mut view,
        0,
        b"for i in $(seq 30); do stty size; sleep .05; done\r",
    );
    expect(&mut view, "28 88"); // one row used by the tmux status bar
    drop(view);
    worker.join().unwrap().unwrap();
    let (mut view, worker) = start(&pin, "TL_TEST_KEY");
    expect(&mut view, "Session number:");
    send(&mut view, 0, b"1\r");
    expect(&mut view, "tl-live");
    send(&mut view, 0, b"printf 'session-%s\\n' \"$TL_RESUME\"\r");
    expect(&mut view, "session-retained");
    drop(view);
    worker.join().unwrap().unwrap();
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
