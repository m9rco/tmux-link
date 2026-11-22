#!/bin/sh
# Build, pair and test the physical iPhone against this Mac through the public relay.
set -eu
cd "$(dirname "$0")/.."
if [ "$#" -ne 2 ] || [ "$2" != --pair-local-mac ]; then
    echo "usage: $0 DEVICE_ID --pair-local-mac" >&2
    echo "Requires Xcode Apple Account login and ios/LocalSigning.xcconfig with DEVELOPMENT_TEAM." >&2
    exit 2
fi
device=$1
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export IPHONEOS_DEPLOYMENT_TARGET=16.0
agent="$HOME/.local/bin/tmux-link-agent"
test -x "$agent" || { echo "Install the macOS tmux-link-agent first" >&2; exit 1; }
test -f ios/LocalSigning.xcconfig || { echo "Configure the local signing team first" >&2; exit 1; }
temp=$(mktemp -d)
session="tmux-link-device-e2e-$$"
other=no
messages=no
created=no
cleanup() {
    if [ "$created" = yes ]; then tmux kill-session -t "=$session" 2>/dev/null || true; fi
    if [ "$other" = yes ]; then tmux kill-session -t "=${session}-other" 2>/dev/null || true; fi
    if [ "$messages" = yes ]; then tmux kill-session -t "=${session}-messages" 2>/dev/null || true; fi
    rm -rf "$temp"
}
trap cleanup EXIT
rustup target add aarch64-apple-ios
cargo build --locked --release -p tmux-link-mobile --target aarch64-apple-ios
(unset CARGO_BUILD_TARGET; cargo build --release --locked -p tmux-link --bin agent --target-dir "$PWD/target")
xcodebuild -project ios/TmuxLink.xcodeproj -scheme TmuxLink -configuration Debug \
    -destination "id=$device" -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
    -derivedDataPath target/xcode-device build-for-testing
app="$PWD/target/xcode-device/Build/Products/Debug-iphoneos/TmuxLink.app"
bundle=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Info.plist")
xcrun devicectl device install app --device "$device" "$app"
xcrun devicectl device process launch --device "$device" --terminate-existing "$bundle"
ready=no
for _attempt in $(seq 1 20); do
    if xcrun devicectl device copy from --device "$device" --domain-type appDataContainer \
        --domain-identifier "$bundle" --source Documents/tmux-link-public-key.pub \
        --destination "$temp/phone.pub" --timeout 5 > "$temp/copy.log" 2>&1; then
        ready=yes
        break
    fi
    sleep 1
done
[ "$ready" = yes ] || { cat "$temp/copy.log" >&2; exit 1; }
ssh-keygen -lf "$temp/phone.pub"
tmux new-session -d -s "$session"
created=yes
git init -q "$temp/repo"
git -C "$temp/repo" config pager.status false
git -C "$temp/repo" config column.status never
git -C "$temp/repo" config status.showUntrackedFiles all
for n in $(seq 1 150); do touch "$temp/repo/status-file-$(printf '%03d' "$n")"; done
tmux new-session -d -s "${session}-other" -c "$temp/repo"
other=yes
# Fill the pane before the iPhone attaches. These rows cannot be recovered
# from a snapshot of frames delivered to the phone.
tmux set-option -t "${session}-other" prefix C-b
tmux set-option -t "${session}-other" mouse off
tmux send-keys -t "${session}-other" 'git status' Enter
awk 'BEGIN {for (i=1; i<=200; i++) printf "Message %03d\n", i}' > "$temp/messages.txt"
tmux new-session -d -s "${session}-messages" /usr/bin/vim -Nu NONE -i NONE -n -R \
    -c 'set mouse=a ttymouse=sgr nowrap scrolloff=0' -c 'normal! G' "$temp/messages.txt"
messages=yes
tmux set-option -t "${session}-messages" mouse on
python3 - "$temp/phone.pub" "$temp/tmux-link-e2e.json" "$agent" "$session" "$PWD/target/release/agent" <<'PY'
import fcntl
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys

key_file, output, ssh_agent, session, source_agent = sys.argv[1:]
parts = Path(key_file).read_text().strip().split()
if len(parts) < 2 or parts[0] != "ssh-ed25519":
    raise SystemExit("Unexpected phone public key")
key = " ".join(parts[:2])
command = "/usr/bin/env PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin " + shlex.quote(ssh_agent) + " attach"
line = 'restrict,pty,command="' + command.replace("\\", "\\\\").replace('"', '\\"') + '" ' + key + " tmux-link-ios\n"
folder = Path.home() / ".ssh"
folder.mkdir(mode=0o700, exist_ok=True)
authorized = folder / "authorized_keys"
with authorized.open("a+") as handle:
    fcntl.flock(handle, fcntl.LOCK_EX)
    handle.seek(0)
    if key not in handle.read():
        handle.write("\n" + line)
    os.chmod(authorized, 0o600)
host_key = "/etc/ssh/ssh_host_ed25519_key.pub"
center = os.environ.get("TMUX_LINK_E2E_HOST", "center.example.com")
user = os.environ.get("USER", Path.home().name)
pin = subprocess.check_output(["ssh-keygen", "-lf", host_key], text=True).split()[1]
link = subprocess.check_output([
    source_agent, "import-link", "--center", center, "--route", "primary",
    "--user", user, "--name", "Clipboard-E2E", "--host-key", host_key,
], text=True).strip()
if not link.startswith("tmuxlink://client?") or len(link.splitlines()) != 1:
    raise SystemExit("The agent did not produce a single client import link")
Path(output).write_text(json.dumps({
    "host": center, "port": 443, "user": user,
    "fingerprint": pin, "sessionName": session, "importLink": link, "hasHistoryFixture": True,
}) + "\n")
PY
xcrun devicectl device copy to --device "$device" --domain-type appDataContainer \
    --domain-identifier "$bundle" --source "$temp/tmux-link-e2e.json" \
    --destination Documents/tmux-link-e2e.json
result="$PWD/target/iphone-e2e-$(date +%Y%m%d-%H%M%S).xcresult"
xcodebuild -project ios/TmuxLink.xcodeproj -scheme TmuxLink -configuration Debug \
    -destination "id=$device" -derivedDataPath target/xcode-device \
    -parallel-testing-enabled NO -resultBundlePath "$result" test-without-building
xcrun devicectl device process launch --device "$device" --terminate-existing "$bundle"
echo "Device E2E result: $result"
