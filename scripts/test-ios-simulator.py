"""Exercise the terminal on an isolated iOS simulator, loopback sshd and tmux server."""
import getpass
import json
import os
from pathlib import Path
import shlex
import shutil
import socket
import subprocess
import sys
import tempfile
import time


ROOT = Path(__file__).resolve().parents[1]
os.environ.setdefault("DEVELOPER_DIR", "/Applications/Xcode.app/Contents/Developer")


def output(*args, **kwargs):
    return subprocess.check_output(args, cwd=ROOT, text=True, **kwargs).strip()


def run(*args, **kwargs):
    subprocess.run(args, cwd=ROOT, check=True, **kwargs)


def simulator():
    devices = json.loads(output("xcrun", "simctl", "list", "devices", "available", "-j"))["devices"]
    runtimes = sorted((r for r in devices if ".iOS-" in r),
                      key=lambda r: tuple(map(int, r.split(".iOS-")[-1].split("-"))), reverse=True)
    for runtime in runtimes:
        for device in devices[runtime]:
            if device["name"].startswith("iPhone") and device["isAvailable"]:
                return output("xcrun", "simctl", "create", f"Tmux Link E2E {os.getpid()}",
                              device["deviceTypeIdentifier"], runtime)
    raise SystemExit("Install an iOS simulator runtime with an available iPhone first")


def benchmark(device, tmp):
    sim = ["xcrun", "simctl"]
    derived = ROOT / "target/xcode-simulator-tests"
    build = ["xcodebuild", "-project", "ios/TmuxLink.xcodeproj", "-scheme", "TmuxLink",
             "-configuration", "Debug", "-destination", f"id={device}", "-derivedDataPath", derived,
             "-parallel-testing-enabled", "NO", "CODE_SIGN_IDENTITY=-"]
    run(*sim, "bootstatus", device, "-b")
    run(*build, "build-for-testing")
    bundle = "dev.tmuxlink.mobile"
    run(*sim, "install", device, derived / "Build/Products/Debug-iphonesimulator/TmuxLink.app")
    run(*sim, "launch", device, bundle)
    docs = Path(output(*sim, "get_app_container", device, bundle, "data")) / "Documents"
    public_key = docs / "tmux-link-public-key.pub"
    for _ in range(100):
        if public_key.exists():
            break
        time.sleep(.1)
    shutil.copyfile(public_key, tmp / "authorized_keys")
    run("ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", tmp / "host")
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        port = sock.getsockname()[1]
    runtime_env = dict(os.environ, TMUX_TMPDIR=str(tmp))
    runtime_env.pop("TMUX", None)
    session = "ios-latency"
    session_id = output("tmux", "-f", "/dev/null", "new-session", "-d", "-P", "-F",
                        "#{session_id}", "-s", session, sys.executable,
                        ROOT / "scripts/terminal-latency-fixture.py", env=runtime_env)
    try:
        tmux_path = str(Path(shutil.which("tmux")).parent)
        command = shlex.join(["/usr/bin/env", f"TMUX_TMPDIR={tmp}",
                              f"PATH={tmux_path}:/usr/bin:/bin", str(ROOT / "target/debug/agent"), "attach"])
        (tmp / "sshd.conf").write_text(
            f"ListenAddress 127.0.0.1\nPort {port}\nHostKey {tmp}/host\nPidFile {tmp}/pid\n"
            f"AuthorizedKeysFile {tmp}/authorized_keys\nAllowUsers {getpass.getuser()}\n"
            # The private fixture directory lives under the shared /tmp rather than the user's home.
            f"StrictModes no\nUsePAM no\nPasswordAuthentication no\nKbdInteractiveAuthentication no\n"
            f"AuthenticationMethods publickey\nDisableForwarding yes\nMaxSessions 1\nForceCommand {command}\n")
        with (tmp / "sshd.log").open("w") as log:
            server = subprocess.Popen(["/usr/sbin/sshd", "-D", "-e", "-f", tmp / "sshd.conf"], stderr=log)
            try:
                for _ in range(50):
                    if server.poll() is not None:
                        raise RuntimeError((tmp / "sshd.log").read_text())
                    try:
                        with socket.create_connection(("127.0.0.1", port), timeout=.2):
                            break
                    except OSError:
                        time.sleep(.1)
                pin = output("ssh-keygen", "-lf", tmp / "host.pub").split()[1]
                (docs / "tmux-link-e2e.json").write_text(json.dumps({
                    "host": "127.0.0.1", "port": port, "user": getpass.getuser(), "fingerprint": pin,
                    "sessionName": session, "benchmarkSessionID": int(session_id.removeprefix("$")),
                }))
                run(*sim, "terminate", device, bundle)
                result = tmp / "benchmark.xcresult"
                run(*build, "-only-testing:TmuxLinkDeviceTests/RemoteSessionTests/testTerminalPerformanceBaseline",
                    "-only-testing:TmuxLinkDeviceTests/RemoteSessionTests/testStatusButtonFitsIslandAndInlineLayouts",
                    "-only-testing:TmuxLinkDeviceTests/SessionAdvisorTests",
                    "-only-testing:TmuxLinkDeviceTests/DecisionAnalysisTests",
                    "-resultBundlePath", result, "test-without-building")
                attachments = tmp / "attachments"
                run("xcrun", "xcresulttool", "export", "attachments", "--path", result,
                    "--output-path", attachments)
                manifest = json.loads((attachments / "manifest.json").read_text())
                reports = [attachments / a["exportedFileName"] for test in manifest for a in test["attachments"]
                           if a["suggestedHumanReadableName"].startswith("terminal-performance")]
                if len(reports) != 1:
                    raise RuntimeError("Missing benchmark report; check that XCTest ran the live fixture")
                report = json.loads(reports[0].read_text())
                if report.get("completed") != 100 or report.get("timeouts") != 0:
                    raise RuntimeError("Incomplete keyboard echo benchmark")
                shutil.copyfile(reports[0], ROOT / "target/terminal-performance-simulator.json")
            except Exception:
                print((tmp / "sshd.log").read_text(), file=sys.stderr)
                raise
            finally:
                server.terminate()
                server.wait()
    finally:
        subprocess.run(["tmux", "kill-server"], env=runtime_env, check=False)


if __name__ == "__main__":
    run("cargo", "build", "--locked", "--bin", "agent")
    run("cargo", "build", "--locked", "-p", "tmux-link-mobile", "--release",
        "--target", "aarch64-apple-ios-sim")
    device = simulator()
    try:
        with tempfile.TemporaryDirectory(dir="/tmp", prefix="tmux-link-sim-") as directory:
            benchmark(device, Path(directory))
    finally:
        subprocess.run(["xcrun", "simctl", "shutdown", device], check=False)
        run("xcrun", "simctl", "delete", device)
