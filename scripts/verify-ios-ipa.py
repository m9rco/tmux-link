#!/usr/bin/env python3
"""Check the unsigned release IPA as distributed, including its embedded widget."""

import os
from pathlib import Path, PurePosixPath
import plistlib
import subprocess
import sys
import tempfile
import zipfile


def bundle_info(archive, bundle):
    info = plistlib.loads(archive.read(f"{bundle}/Info.plist"))
    if "iPhoneOS" not in info.get("CFBundleSupportedPlatforms", []):
        raise ValueError(f"{bundle} is not an iOS device build")
    executable = info["CFBundleExecutable"]
    if not executable or PurePosixPath(executable).name != executable:
        raise ValueError(f"{bundle} has an invalid executable name")
    with tempfile.TemporaryDirectory() as directory:
        binary = Path(directory) / executable
        binary.write_bytes(archive.read(f"{bundle}/{executable}"))
        subprocess.run(["xcrun", "lipo", binary, "-verify_arch", "arm64"], check=True)
        signature = subprocess.run(
            ["codesign", "--display", "--verbose=4", binary],
            capture_output=True, text=True, env={**os.environ, "LC_ALL": "C"},
        )
        # Linker-generated ad hoc signatures contain no signing identity.
        if signature.returncode == 0:
            if "Signature=adhoc" not in signature.stderr.splitlines():
                raise ValueError(f"{bundle} contains a distribution or development signature")
        elif "code object is not signed at all" not in signature.stderr:
            raise ValueError(f"Cannot inspect the signature for {bundle}: {signature.stderr.strip()}")
    return info


def verify(archive):
    host = PurePosixPath("Payload/TmuxLink.app")
    entries = [PurePosixPath(name) for name in archive.namelist()]
    if any("_CodeSignature" in path.parts or path.name == "embedded.mobileprovision" for path in entries):
        raise ValueError("Unsigned IPA contains a signing resource or provisioning profile")
    keyboard = host / "assets/keyboard"
    for name in ("index.html", "keyboard.css", "keyboard.js", "simple-keyboard.js", "LICENSE-simple-keyboard"):
        if keyboard / name not in entries:
            raise ValueError(f"IPA is missing the offline keyboard resource {name}")
    for name in ("pinyin.js", "decoder.js", "LICENSE-pinyin-simp", "AUTHORS-pinyin-simp"):
        if keyboard / name in entries:
            raise ValueError(f"IPA still contains the retired Pinyin keyboard resource {name}")
    app = bundle_info(archive, host)
    if app.get("NSSupportsLiveActivities") is not True:
        raise ValueError("TmuxLink.app does not declare NSSupportsLiveActivities")
    extensions = {path.parent for path in entries if path.match("*.appex/Info.plist")
                  and path.parent.parent == host / "PlugIns"}
    widget_found = False
    for ext in sorted(extensions):
        info = bundle_info(archive, ext)
        if not info["CFBundleIdentifier"].startswith(app["CFBundleIdentifier"] + "."):
            raise ValueError(f"{ext} has a different parent bundle identifier")
        for key in ("CFBundleVersion", "CFBundleShortVersionString"):
            if not app.get(key) or info.get(key) != app[key]:
                raise ValueError(f"{ext} and TmuxLink.app must share {key}")
        if info.get("NSExtension", {}).get("NSExtensionPointIdentifier") == "com.apple.widgetkit-extension":
            widget_found = True
    if not widget_found:
        raise ValueError("IPA is missing an embedded WidgetKit app extension")


if __name__ == "__main__":
    with zipfile.ZipFile(sys.argv[1]) as ipa:
        verify(ipa)
    print("Verified unsigned arm64 iOS app and embedded WidgetKit extension")
