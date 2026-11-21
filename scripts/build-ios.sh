#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
case "${1:-device}" in
  device) target=aarch64-apple-ios; destination='generic/platform=iOS' ;;
  simulator) target=aarch64-apple-ios-sim; destination='generic/platform=iOS Simulator' ;;
  *) echo "usage: $0 [device|simulator]" >&2; exit 2 ;;
esac
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export IPHONEOS_DEPLOYMENT_TARGET=16.0
rustup target add "$target"
cargo build --locked -p tmux-link-mobile --release --target "$target"
xcodebuild -project ios/TmuxLink.xcodeproj -scheme TmuxLink -configuration Release -destination "$destination" \
    ARCHS=arm64 ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO -derivedDataPath target/xcode build
