#!/usr/bin/env python3
"""Refresh an Xcode Personal Team install from this logged-in Mac."""
import argparse
import datetime as dt
import fcntl
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile

LABEL = "dev.tmuxlink.renew"
BASE = Path.home() / "Library/Application Support/TmuxLink/Renewal"
PLIST = Path.home() / "Library/LaunchAgents" / (LABEL + ".plist")
STATE = BASE / "state.json"
OS_ENV = dict(os.environ, DEVELOPER_DIR=os.environ.get("DEVELOPER_DIR", "/Applications/Xcode.app/Contents/Developer"))
RUN = ["launchctl", "bootout", f"gui/{os.getuid()}/{LABEL}"]
BUNDLE = "dev.tmuxlink.mobile"
WIDGET_BUNDLE = BUNDLE + ".status"
CHECK_INTERVAL = 300
PENDING = "pending-install.json"

def run(*cmd, **kwargs):
    return subprocess.run(cmd, check=True, env=OS_ENV, **kwargs)

def save_state(value):
    staged = STATE.with_suffix(".new")
    staged.write_text(json.dumps(value, indent=2) + "\n")
    os.replace(staged, STATE)

def signed_expiration(app, device, now, require_widget):
    run("codesign", "--verify", "--deep", "--strict", app)
    team = None
    expirations = {}
    for bundle in [app, *sorted((app / "PlugIns").glob("*.appex"))]:
        bundle_id = plistlib.loads((bundle / "Info.plist").read_bytes())["CFBundleIdentifier"]
        if bundle == app and bundle_id != BUNDLE:
            raise RuntimeError(f"Unexpected application identifier: {bundle_id}")
        if bundle != app and not bundle_id.startswith(BUNDLE + "."):
            raise RuntimeError(f"Unexpected extension identifier: {bundle_id}")
        if bundle_id in expirations:
            raise RuntimeError(f"Duplicate bundle identifier: {bundle_id}")
        profile = plistlib.loads(run("security", "cms", "-D", "-i", bundle / "embedded.mobileprovision",
                                     capture_output=True).stdout)
        with tempfile.TemporaryDirectory() as tmp:
            prefix = Path(tmp) / "signer"
            signature = run("codesign", "-d", "--entitlements", "-", "--xml",
                            f"--extract-certificates={prefix}", bundle, capture_output=True)
            entitlements = plistlib.loads(signature.stdout)
            if (Path(tmp) / "signer0").read_bytes() not in profile["DeveloperCertificates"]:
                raise RuntimeError(f"Signing certificate not authorized by profile: {bundle_id}")
        signing_team = entitlements["com.apple.developer.team-identifier"]
        if signing_team not in profile["TeamIdentifier"] or (team is not None and team != signing_team):
            raise RuntimeError(f"Signing team mismatch: {bundle_id}")
        team = signing_team
        app_id = entitlements["application-identifier"]
        allowed_ids = {prefix + "." + bundle_id for prefix in profile["ApplicationIdentifierPrefix"]}
        pattern = profile["Entitlements"]["application-identifier"]
        profile_matches = app_id == pattern or (pattern.endswith("*") and app_id.startswith(pattern[:-1]))
        if app_id not in allowed_ids or not profile_matches:
            raise RuntimeError(f"Profile does not authorize the signed application identifier: {bundle_id}")
        expires = profile["ExpirationDate"].replace(tzinfo=dt.timezone.utc)
        if expires <= now or device.lower() not in [d.lower() for d in profile.get("ProvisionedDevices", [])]:
            raise RuntimeError(f"Expired profile or iPhone not covered: {bundle_id}")
        expirations[bundle_id] = expires
    if require_widget and WIDGET_BUNDLE not in expirations:
        raise RuntimeError("Signed build is missing the terminal status widget")
    return min(expirations.values())

def build_release(source):
    derived = BASE / "build"
    run("xcodebuild", "-project", source / "ios/TmuxLink.xcodeproj", "-scheme", "TmuxLink",
        "-configuration", "Release", "-destination", "generic/platform=iOS", "-derivedDataPath", derived,
        "-allowProvisioningUpdates", "build", timeout=600)
    return derived / "Build/Products/Release-iphoneos/TmuxLink.app"

def version_info(app):
    info = plistlib.loads((app / "Info.plist").read_bytes())
    return {"version": info["CFBundleShortVersionString"], "build": info["CFBundleVersion"]}

def queue_release(device, source):
    # Keep the exact verified app until delivery. The copied source and Rust
    # library allow a new signature if the phone returns after this one expires.
    app = source / "Release/TmuxLink.app"
    shutil.copytree(build_release(source), app, symlinks=True)
    expires = signed_expiration(app, device, dt.datetime.now(dt.timezone.utc), True)
    request = dict(device=device, expires=expires.isoformat(), **version_info(app))
    (source / PENDING).write_text(json.dumps(request, indent=2) + "\n")
    return request

def refresh(device, source, force):
    now = dt.datetime.now(dt.timezone.utc)
    state = json.loads(STATE.read_text()) if STATE.exists() else {}
    previous = state.get("expires", "") if state.get("device") == device else ""
    marker = source / PENDING
    pending = json.loads(marker.read_text()) if marker.exists() else None
    if pending and pending["device"] != device:
        raise RuntimeError("The queued release belongs to another device")
    if not pending and not force and previous and dt.datetime.fromisoformat(previous) > now + dt.timedelta(days=3):
        print("Installed profile valid until", previous)
        return
    reachable = subprocess.run(
        ["xcrun", "devicectl", "device", "info", "lockState", "--device", device, "--timeout", "10"],
        env=OS_ENV, capture_output=True,
    )
    if reachable.returncode != 0:
        if force:
            raise RuntimeError("Cannot reach the paired iPhone via Wi-Fi or USB")
        print("Paired iPhone unavailable; will retry at the next check")
        return
    # Old pinned snapshots predate the widget and remain valid for their own builds.
    require_widget = bool(pending) or WIDGET_BUNDLE in (source / "ios/TmuxLink.xcodeproj/project.pbxproj").read_text()
    app = source / "Release/TmuxLink.app"
    expires = None
    if pending and dt.datetime.fromisoformat(pending["expires"]) > now and app.is_dir():
        try:
            expires = signed_expiration(app, device, now, require_widget)
        except (OSError, RuntimeError, subprocess.CalledProcessError):
            print("Queued signature needs to be rebuilt from its snapshot")
    if expires is None:
        app = build_release(source)
        expires = signed_expiration(app, device, dt.datetime.now(dt.timezone.utc), require_widget)
    release = version_info(app)
    if pending and any(release[key] != pending[key] for key in release):
        raise RuntimeError("Signed release version differs from the queued version")
    if not pending and not force and previous and expires <= dt.datetime.fromisoformat(previous):
        print("Xcode did not extend the profile; will retry at the next check")
        return
    run("xcrun", "devicectl", "device", "install", "app", "--device", device, "--timeout", "90", app)
    state.update(device=device, expires=expires.isoformat(), last_install=now.isoformat(), **release)
    save_state(state)
    if pending:
        marker.unlink()
    print("Installed. Profile valid until", expires.isoformat())

def setup(device, queue=False):
    repo = Path(__file__).resolve().parents[1]
    # Pin the build inputs so unattended refreshes never deploy an untested working tree.
    tmp = Path(tempfile.mkdtemp(prefix="snapshot-", dir=BASE))
    try:
        shutil.copytree(repo/"ios", tmp/"ios", ignore=shutil.ignore_patterns("xcuserdata","*.xcuserstate"))
        lib = Path("target/aarch64-apple-ios/release/libtmux_link_mobile.a")
        (tmp/lib.parent).mkdir(parents=True)
        shutil.copy2(repo/lib, tmp/lib)
        if queue:
            pending = queue_release(device, tmp)
        else:
            refresh(device, tmp, True)
        helper = tmp / "renew-ios.py"
        shutil.copy2(__file__, helper)
        PLIST.parent.mkdir(parents=True, exist_ok=True)
        config = {"Label": LABEL, "ProgramArguments": ["/usr/bin/python3", str(helper), "check", device],
                  "RunAtLoad": True, "StartInterval": CHECK_INTERVAL, "ProcessType":"Background",
                  "EnvironmentVariables":{"DEVELOPER_DIR": OS_ENV["DEVELOPER_DIR"], "PYTHONUNBUFFERED": "1"},
                  "StandardOutPath": str(BASE / "refresh.log"), "StandardErrorPath": str(BASE / "refresh.log")}
        stage = PLIST.with_suffix(".new")
        stage.write_bytes(plistlib.dumps(config))
        old = plistlib.loads(PLIST.read_bytes()) if PLIST.exists() else {}
        subprocess.run(RUN, capture_output=True)
        try:
            os.replace(stage, PLIST)
            run("launchctl", "bootstrap", f"gui/{os.getuid()}", PLIST)
        except Exception:
            if old:
                PLIST.write_bytes(plistlib.dumps(old))
                run("launchctl", "bootstrap", f"gui/{os.getuid()}", PLIST)
            else:
                PLIST.unlink(missing_ok=True)
            raise
    except BaseException:
        shutil.rmtree(tmp, ignore_errors=True)
        raise
    for path in BASE.glob("snapshot-*"):
        if path != tmp and path.is_dir():
            shutil.rmtree(path)
    print("Refresh job installed:", PLIST)
    if queue:
        print(f"Queued version {pending['version']} build {pending['build']} for {device}")

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["install","queue","check","status","uninstall"])
    parser.add_argument("device", nargs="?")
    args = parser.parse_args()
    if args.action in ("check","install","queue") and not args.device:
        parser.error("device UDID required")
    os.umask(0o077)
    BASE.mkdir(parents=True, exist_ok=True)
    with (BASE / "lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if args.action in ("install", "queue"):
            setup(args.device, queue=args.action == "queue")
        elif args.action == "check":
            refresh(args.device, Path(__file__).resolve().parent, False)
        elif args.action == "status":
            print(STATE.read_text() if STATE.exists() else "No successful installation")
            if PLIST.exists():
                arguments = plistlib.loads(PLIST.read_bytes())["ProgramArguments"]
                marker = Path(arguments[1]).parent / PENDING
                if marker.exists():
                    print("Pending installation:", marker.read_text().strip())
            run("launchctl", "print", f"gui/{os.getuid()}/{LABEL}")
        else:
            subprocess.run(RUN, capture_output=True)
            PLIST.unlink(missing_ok=True)
            print("Refresh job removed")

if __name__ == "__main__":
    main()
