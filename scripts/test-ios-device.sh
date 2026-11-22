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
created=no
cleanup() {
    if [ "$created" = yes ]; then tmux kill-session -t "=$session" 2>/dev/null || true; fi
    if [ "$other" = yes ]; then tmux kill-session -t "=${session}-other" 2>/dev/null || true; fi
    rm -rf "$temp"
}
trap cleanup EXIT
rustup target add aarch64-apple-ios
cargo build --locked --release -p tmux-link-mobile --target aarch64-apple-ios
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
tmux new-session -d -s "${session}-other"
other=yes
python3 - "$temp/phone.pub" "$temp/tmux-link-e2e.json" "$agent" "$session" <<'PY'
import fcntl
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys

key_file, output, agent, session = sys.argv[1:]
parts = Path(key_file).read_text().strip().split()
if len(parts) < 2 or parts[0] != "ssh-ed25519":
    raise SystemExit("Unexpected phone public key")
key = " ".join(parts[:2])
command = "/usr/bin/env PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin " + shlex.quote(agent) + " attach"
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
pin = subprocess.check_output(["ssh-keygen", "-lf", "/etc/ssh/ssh_host_ed25519_key.pub"], text=True).split()[1]
Path(output).write_text(json.dumps({
    "host": os.environ.get("TMUX_LINK_E2E_HOST", "center.example.com"), "port": 443,
    "user": os.environ.get("USER", Path.home().name),
    "fingerprint": pin, "sessionName": session,
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
