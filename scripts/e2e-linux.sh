#!/bin/sh
# Run on macOS or Linux with Docker and support for the selected Linux architecture.
set -eu
cd "$(dirname "$0")/.."
tmp=$(mktemp -d)
box="tmux-link-e2e-$$"
cleanup() {
    code=$?
    if [ "$code" -ne 0 ]; then
        docker exec "$box" sh -c 'cat /tmp/tunnel.log /tmp/inner.log /tmp/outer.log /tmp/center.log' >&2 || true
    fi
    docker rm -f "$box" >/dev/null 2>&1 || true
    rm -rf "$tmp"
}
trap cleanup EXIT
# On arm64 builders prefer a native target when the corresponding linker is available.
triple=${TL_LINUX_TARGET:-x86_64-unknown-linux-musl}
rustup target add "$triple"
CARGO_TARGET_X86_64_UNKNOWN_LINUX_MUSL_LINKER=rust-lld cargo build --locked -p tmux-link --target "$triple"
case "$triple" in x86_64-*) arch=amd64 ;; aarch64-*) arch=arm64 ;; *) exit 2 ;; esac
docker run -d --name "$box" --platform "linux/$arch" -p 127.0.0.1::2222 debian:12 sleep infinity >/dev/null
docker exec "$box" sh -ec 'apt-get update -qq; DEBIAN_FRONTEND=noninteractive apt-get install -yqq --no-install-recommends openssh-server openssh-client tmux >/dev/null; mkdir -p /etc/tmux-link'
for bin in agent center; do docker cp "target/$triple/debug/$bin" "$box:/usr/local/bin/$bin"; done
ssh-keygen -q -t ed25519 -N '' -f "$tmp/phone"
ssh-keygen -q -t ed25519 -N '' -f "$tmp/untrusted"
docker cp "$tmp/phone.pub" "$box:/etc/tmux-link/phone.keys"
docker cp deploy/inner-sshd.conf "$box:/etc/tmux-link/inner-sshd.conf"
docker cp deploy/center-sshd-match.conf "$box:/tmp/center-match"
docker cp scripts/linux-fixture.sh "$box:/tmp/fixture"
docker exec "$box" sh /tmp/fixture
for _attempt in $(seq 1 50); do
    docker exec "$box" test -S /home/tmuxrelay/link/linux.sock && break
    sleep 0.1
done
docker exec "$box" test -S /home/tmuxrelay/link/linux.sock || { docker exec "$box" cat /tmp/tunnel.log >&2; exit 1; }
TL_TEST_PORT=$(docker port "$box" 2222/tcp | head -1 | cut -d: -f2)
TL_TEST_PIN=$(docker exec "$box" ssh-keygen -lf /etc/tmux-link/host_ed25519.pub | awk '{print $2}')
TL_TEST_KEY="$tmp/phone" TL_TEST_UNAUTHORIZED_KEY="$tmp/untrusted" TL_TEST_PORT="$TL_TEST_PORT" TL_TEST_PIN="$TL_TEST_PIN" cargo test --locked -p tmux-link-mobile --test remote -- --ignored
