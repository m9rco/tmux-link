#!/bin/sh
# Install verified Linux binaries from a GitHub Release.
set -eu
repo=m9rco/tmux-link
version=latest
prefix=/usr/local
role=both
from_dir=
usage() {
    cat <<'HELP'
Usage: sh install.sh [--role agent|center|both] [--version v0.1.0]
                     [--prefix /usr/local] [--repo OWNER/REPO]
                     [--from-dir DIRECTORY] [--with-deps]
Private repository: authenticate gh or export GH_TOKEN (contents:read).
--from-dir installs an already downloaded archive plus SHA256SUMS offline.
--with-deps installs OpenSSH and tmux using apt-get (root, Debian/Ubuntu).
The installer places binaries and deployment templates under PREFIX.
Configure the provided templates with your user, keys and center address.
HELP
}
deps=no
while [ "$#" -gt 0 ]; do
    case "$1" in
        --help|-h) usage; exit 0 ;;
        --with-deps) deps=yes; shift ;;
        --role|--version|--prefix|--repo|--from-dir)
            [ "$#" -ge 2 ] || { echo "Missing value for $1" >&2; exit 2; }
            case "$1" in
                --role) role=$2 ;; --version) version=$2 ;; --prefix) prefix=$2 ;;
                --repo) repo=$2 ;; --from-dir) from_dir=$2 ;;
            esac
            shift 2 ;;
        *) echo "Unknown option: $1" >&2; exit 2 ;;
    esac
done
case "$role" in agent|center|both) ;; *) echo "Invalid role" >&2; exit 2 ;; esac
case "$prefix" in /*) ;; *) echo "--prefix must be absolute" >&2; exit 2 ;; esac
[ "$(uname -s)" = Linux ] || { echo "Linux required. Build the iOS app with Xcode." >&2; exit 1; }
case "$(uname -m)" in
    x86_64|amd64) arch=x86_64 ;;
    aarch64|arm64) arch=aarch64 ;;
    *) echo "Unsupported CPU architecture" >&2; exit 1 ;;
esac
for cmd in tar sha256sum install mktemp; do
    command -v "$cmd" >/dev/null || { echo "Missing command: $cmd" >&2; exit 1; }
done
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
asset="tmux-link-linux-$arch.tar.gz"
if [ -n "$from_dir" ]; then
    cp "$from_dir/$asset" "$from_dir/SHA256SUMS" "$tmp/"
elif command -v gh >/dev/null && gh auth status >/dev/null 2>&1; then
    if [ "$version" = latest ]; then
        gh release download --repo "$repo" --pattern "$asset" --pattern SHA256SUMS --dir "$tmp"
    else
        gh release download "$version" --repo "$repo" --pattern "$asset" --pattern SHA256SUMS --dir "$tmp"
    fi
else
    [ -z "${GH_TOKEN:-}${GITHUB_TOKEN:-}" ] || {
        echo "Install gh to use authenticated private release downloads." >&2; exit 1;
    }
    command -v curl >/dev/null || { echo "curl or authenticated gh required" >&2; exit 1; }
    case "$version" in latest) base="https://github.com/$repo/releases/latest/download" ;;
        v[0-9]*) base="https://github.com/$repo/releases/download/$version" ;;
        *) echo "Invalid version" >&2; exit 2 ;; esac
    for file in "$asset" SHA256SUMS; do
        curl --fail --location --silent --show-error --proto '=https' --tlsv1.2 "$base/$file" -o "$tmp/$file"
    done
fi
# Select exactly one hash for the expected artifact, ignoring other release files.
awk -v name="$asset" '$2 == name {print}' "$tmp/SHA256SUMS" > "$tmp/selected"
[ "$(wc -l < "$tmp/selected" | tr -d ' ')" = 1 ] || { echo "Missing or duplicate checksum" >&2; exit 1; }
(cd "$tmp" && sha256sum -c selected)
# Extract only known package members, without preserving archive permissions or owners.
mkdir "$tmp/unpack"
tar -xzf "$tmp/$asset" -C "$tmp/unpack" --no-same-owner --no-same-permissions     ./bin/agent ./bin/center ./share/tmux-link
for bin in agent center; do
    [ -f "$tmp/unpack/bin/$bin" ] && [ ! -L "$tmp/unpack/bin/$bin" ] || exit 1
done
if [ "$deps" = yes ]; then
    if [ "$(id -u)" != 0 ] || ! command -v apt-get >/dev/null; then
        echo "--with-deps requires root and apt-get" >&2; exit 1
    fi
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y openssh-client openssh-server tmux
fi
install -d "$prefix/bin" "$prefix/share/tmux-link"
for bin in agent center; do
    if [ "$role" = both ] || [ "$role" = "$bin" ]; then
        install -m 755 "$tmp/unpack/bin/$bin" "$prefix/bin/$bin"
    fi
done
cp -R "$tmp/unpack/share/tmux-link/." "$prefix/share/tmux-link/"
echo "Installed $role to $prefix/bin"
echo "Deployment templates and setup guide: $prefix/share/tmux-link"
echo "Services require user, host and key configuration before activation."
