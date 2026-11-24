use tokio::io::{AsyncRead, AsyncReadExt};

// CLI stderr may contain paths, credentials or conversation text. Drain it to
// avoid blocking the child, and return only a known error category on failure.
pub(super) async fn failure_hint(mut stderr: impl AsyncRead + Unpin) -> Option<&'static str> {
    const WINDOW: usize = 4096;
    let mut head = Vec::with_capacity(WINDOW);
    let mut tail = Vec::with_capacity(WINDOW);
    let mut chunk = [0; WINDOW];
    loop {
        let n = stderr.read(&mut chunk).await.ok()?;
        if n == 0 {
            break;
        }
        head.extend_from_slice(&chunk[..n.min(WINDOW - head.len())]);
        let discard = (tail.len() + n).saturating_sub(WINDOW);
        tail.drain(..discard);
        tail.extend_from_slice(&chunk[..n]);
    }
    category(&tail).or_else(|| category(&head))
}

fn category(bytes: &[u8]) -> Option<&'static str> {
    let text = String::from_utf8_lossy(bytes).to_ascii_lowercase();
    let patterns: &[(&[&str], &str)] = &[
        (
            &[
                "session not found",
                "session was not found",
                "no such session",
            ],
            "session not found",
        ),
        (
            &["database is locked", "sqlite_busy", "sqlite_locked"],
            "database locked",
        ),
        (&["disk i/o error", "sqlite_ioerr"], "database I/O error"),
        (
            &[
                "database or disk is full",
                "no space left on device",
                "sqlite_full",
                "enospc",
            ],
            "storage full",
        ),
        (&["file too large", "efbig"], "file size limit"),
        (
            &[
                "readonly database",
                "sqlite_readonly",
                "permission denied",
                "eacces",
            ],
            "access denied",
        ),
        (
            &["unknown argument", "unknown option", "unrecognized option"],
            "unsupported command option",
        ),
    ];
    patterns.iter().find_map(|(needles, hint)| {
        needles
            .iter()
            .any(|needle| text.contains(needle))
            .then_some(*hint)
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn drains_verbose_errors_and_returns_only_a_fixed_hint() {
        let mut bytes = vec![b'x'; 48 * 1024];
        bytes.extend_from_slice(b"\nError: Session not found: PRIVATE-TITLE\n");
        assert_eq!(
            failure_hint(bytes.as_slice()).await,
            Some("session not found")
        );
        assert_eq!(
            failure_hint(b"private unknown error".as_slice()).await,
            None
        );
    }
}
