#!/bin/sh
# Install verified Linux/macOS binaries from a GitHub Release.
set -eu
repo=m9rco/tmux-link
version=latest
if [ "$(id -u)" = 0 ]; then prefix=/usr/local; else prefix="$HOME/.local"; fi
role=agent
from_dir=
download_base=
connect_center=
usage() {
    cat <<'HELP'
Usage: sh install.sh [--role agent|center|both] [--version v0.1.0]
                     [--prefix /usr/local] [--repo OWNER/REPO]
                     [--from-dir DIRECTORY] [--download-base-url HTTPS_URL] [--with-deps]
                     [--connect CENTER_HOSTNAME]
Defaults: agent role, ~/.local for users, /usr/local for root.
Public GitHub downloads use curl without authentication.
Private repository: set GH_TOKEN or GITHUB_TOKEN and install gh.
--from-dir installs an already downloaded archive plus SHA256SUMS offline.
--with-deps installs OpenSSH/tmux via apt-get on Debian/Ubuntu, or tmux via Homebrew on macOS.
The installer places binaries and deployment templates under PREFIX.
Configure the provided templates with your user, keys and center address.
--connect starts outbound pairing after installation. Run as the tmux owner.
HELP
}
deps=no
while [ "$#" -gt 0 ]; do
    case "$1" in
        --help|-h) usage; exit 0 ;;
        --with-deps) deps=yes; shift ;;
        --role|--version|--prefix|--repo|--from-dir|--download-base-url|--connect)
            [ "$#" -ge 2 ] || { echo "Missing value for $1" >&2; exit 2; }
            case "$1" in
                --role) role=$2 ;; --version) version=$2 ;; --prefix) prefix=$2 ;;
                --repo) repo=$2 ;; --from-dir) from_dir=$2 ;;
                --download-base-url) download_base=$2 ;;
                --connect) connect_center=$2 ;;
            esac
            shift 2 ;;
        *) echo "Unknown option: $1" >&2; exit 2 ;;
    esac
done
case "$role" in agent|center|both) ;; *) echo "Invalid role" >&2; exit 2 ;; esac
if [ -n "$connect_center" ]; then
    [ "$role" != center ] || { echo "--connect requires the agent role" >&2; exit 2; }
    case "$connect_center" in ""|*[!a-zA-Z0-9.-]*|-*|*-) echo "Invalid center hostname" >&2; exit 2 ;; esac
fi
case "$prefix" in /*) ;; *) echo "--prefix must be absolute" >&2; exit 2 ;; esac
case "$(uname -s)" in Linux) platform=linux ;; Darwin) platform=macos ;;
    *) echo "Linux or macOS required" >&2; exit 1 ;; esac
case "$(uname -m)" in
    x86_64|amd64) arch=x86_64 ;;
    aarch64|arm64) arch=aarch64 ;;
    *) echo "Unsupported CPU architecture" >&2; exit 1 ;;
esac
for cmd in tar install mktemp; do
    command -v "$cmd" >/dev/null || { echo "Missing command: $cmd" >&2; exit 1; }
done
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
if ! command -v sha256sum >/dev/null && ! command -v shasum >/dev/null; then
    echo "sha256sum or shasum required" >&2; exit 1
fi
asset="tmux-link-$platform-$arch.tar.gz"
if [ -n "$from_dir" ]; then
    cp "$from_dir/$asset" "$from_dir/SHA256SUMS" "$tmp/"
elif [ -n "${GH_TOKEN:-}${GITHUB_TOKEN:-}" ]; then
    command -v gh >/dev/null || { echo "Install gh for authenticated downloads" >&2; exit 1; }
    if [ "$version" = latest ]; then
        gh release download --repo "$repo" --pattern "$asset" --pattern SHA256SUMS --dir "$tmp"
    else
        gh release download "$version" --repo "$repo" --pattern "$asset" --pattern SHA256SUMS --dir "$tmp"
    fi
else
    command -v curl >/dev/null || { echo "curl or authenticated gh required" >&2; exit 1; }
    case "$version" in latest) base="https://github.com/$repo/releases/latest/download" ;;
        v[0-9]*) base="https://github.com/$repo/releases/download/$version" ;;
        *) echo "Invalid version" >&2; exit 2 ;; esac
    if [ -n "$download_base" ]; then
        case "$download_base" in https://*) base=${download_base%/} ;;
            *) echo "Download base must use HTTPS" >&2; exit 2 ;; esac
    fi
    for file in "$asset" SHA256SUMS; do
        curl --fail --location --silent --show-error --proto '=https' --proto-redir '=https' --tlsv1.2 \
            --retry 3 --connect-timeout 15 --max-time 300 "$base/$file" -o "$tmp/$file"
    done
fi
# Select exactly one hash for the expected artifact, ignoring other release files.
awk -v name="$asset" '$2 == name {print}' "$tmp/SHA256SUMS" > "$tmp/selected"
[ "$(wc -l < "$tmp/selected" | tr -d ' ')" = 1 ] || { echo "Missing or duplicate checksum" >&2; exit 1; }
(cd "$tmp" && if command -v sha256sum >/dev/null; then sha256sum -c selected; else shasum -a 256 -c selected; fi)
# Extract only known package members, without preserving archive permissions or owners.
mkdir "$tmp/unpack"
tar -xzf "$tmp/$asset" -C "$tmp/unpack" --no-same-owner --no-same-permissions \
    ./bin/agent ./bin/center ./share/tmux-link
for bin in agent center; do
    [ -f "$tmp/unpack/bin/$bin" ] && [ ! -L "$tmp/unpack/bin/$bin" ] || exit 1
done
if [ "$deps" = yes ]; then
    if [ "$platform" = macos ]; then
        command -v brew >/dev/null || { echo "Install Homebrew to use --with-deps on macOS" >&2; exit 1; }
        brew list tmux >/dev/null 2>&1 || brew install tmux
    elif [ "$(id -u)" != 0 ] || ! command -v apt-get >/dev/null; then
        echo "--with-deps requires root and apt-get" >&2; exit 1
    else
        apt-get update
        DEBIAN_FRONTEND=noninteractive apt-get install -y openssh-client openssh-server tmux
    fi
fi
install -d "$prefix/bin" "$prefix/share/tmux-link"
for bin in agent center; do
    if [ "$role" = both ] || [ "$role" = "$bin" ]; then
        # Rename on the same filesystem so upgrades work with running processes.
        stage=$(mktemp "$prefix/bin/.tmux-link-$bin.XXXXXX")
        if ! install -m 755 "$tmp/unpack/bin/$bin" "$stage" || ! mv -f "$stage" "$prefix/bin/tmux-link-$bin"; then
            rm -f "$stage"
            exit 1
        fi
    fi
done
cp -R "$tmp/unpack/share/tmux-link/." "$prefix/share/tmux-link/"
echo "Installed $role to $prefix/bin"
echo "Deployment templates and setup guide: $prefix/share/tmux-link"
if [ -n "$connect_center" ]; then
    "$prefix/bin/tmux-link-agent" pair --center "$connect_center"
else
    echo "Connect a new host: $prefix/bin/tmux-link-agent pair --center YOUR_CENTER_HOST"
    echo "Manual deployment guide: $prefix/share/tmux-link/README.md"
fi
