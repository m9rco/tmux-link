#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/package/bin" "$tmp/package/share/tmux-link" "$tmp/dist"
for bin in agent center; do
    printf '#!/bin/sh\necho fixture-%s\n' "$bin" > "$tmp/package/bin/$bin"
done
cp -R deploy "$tmp/package/share/tmux-link/"
case "$(uname -m)" in aarch64|arm64) arch=aarch64 ;; *) arch=x86_64 ;; esac
asset="tmux-link-linux-$arch.tar.gz"
tar -C "$tmp/package" -czf "$tmp/dist/$asset" .
(cd "$tmp/dist" && sha256sum "$asset" > SHA256SUMS)
./install.sh --from-dir "$tmp/dist" --prefix "$tmp/installed" --role agent
test -x "$tmp/installed/bin/agent"
test ! -e "$tmp/installed/bin/center"
test -f "$tmp/installed/share/tmux-link/deploy/inner-sshd.conf"
./install.sh --from-dir "$tmp/dist" --prefix "$tmp/installed" --role both
test "$("$tmp/installed/bin/center")" = fixture-center
printf '\ncorruption\n' >> "$tmp/dist/$asset"
if ./install.sh --from-dir "$tmp/dist" --prefix "$tmp/rejected"; then
    echo 'Corrupted package was accepted' >&2; exit 1
fi
test ! -e "$tmp/rejected"
echo 'Installer checks passed'
