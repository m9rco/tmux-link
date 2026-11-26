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


def bound_conversation(tmp, runtime_env):
    application_id = "ses_simulator_catalog"
    def turn(number, role, text):
        return {"info": {"id": f"msg_{number}", "sessionID": application_id, "role": role,
                         "time": {"created": number, "completed": number + 1}},
                "parts": [{"type": "text", "text": text}]}

    question = turn(2, "assistant", "Should I publish the signed catalog?")
    question["parts"].insert(0, {"type": "tool", "state": {"output": "PRIVATE-TOOL-FIXTURE"}})
    export = {"info": {"id": application_id, "title": "PRIVATE-METADATA-FIXTURE"},
              "messages": [question, turn(1, "user", "Keep the signed catalog."),
                           turn(3, "user", "Yes, publish the signed catalog.")]}
    (tmp / "export.json").write_text(json.dumps(export), encoding="utf-8")
    cli = tmp / "codemaker"
    cli.write_text('#!/bin/sh\n[ "$#" = 3 ] && [ "$1/$2/$3" = "--pure/export/ses_simulator_catalog" ] || exit 2\n'
                   'exec /bin/cat "$HOME/export.json"\n', encoding="utf-8")
    cli.chmod(0o700)
    session, pane = output("tmux", "-f", "/dev/null", "new-session", "-d", "-P", "-F",
                           "#{session_id} #{pane_id}", "-s", "ios-bound-conversation", "-c", tmp,
                           sys.executable, "-c", "import time; print('PRIVATE-HISTORY-FIXTURE\\n' * 50 "
                           "+ '\\x1b[?1049h\\x1b[2J\\x1b[H', end='', flush=True); time.sleep(1800)",
                           env=runtime_env).split()
    for _ in range(100):
        if output("tmux", "display-message", "-p", "-t", pane, "#{alternate_on}", env=runtime_env) == "1":
            break
        time.sleep(.05)
    else:
        raise RuntimeError("CodeMaker fixture did not enter the alternate screen")
    bind_env = dict(runtime_env, HOME=str(tmp), PATH=str(tmp) + os.pathsep + runtime_env["PATH"])
    bind_env.pop("SSH_ORIGINAL_COMMAND", None)
    run(ROOT / "target/debug/agent", "bind-session", session[1:], application_id, env=bind_env)
    return int(session[1:]), int(pane[1:])


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
        # Put the constraint thousands of lines back and wrap the question on a narrow grid.
        run("tmux", "set-option", "-g", "history-limit", "6500", env=runtime_env)
        report = tmp / "catalog.txt"
        report.write_text("Outside the scan window.\n" + "Previous batch finished.\n" * 450
                          + "Constraint: retain the signed catalog.\n"
                          + "".join(f"Sample {i} verified.\n" for i in range(4850))
                          + "Should we publish the validated catalog for review?\n", encoding="utf-8")
        snapshot_id = output("tmux", "new-session", "-d", "-P", "-F", "#{session_id}",
                             "-x", "32", "-y", "24", "-s", "ios-decision-fixture",
                             sys.executable, "-c", "import pathlib,sys,time; "
                             "print(pathlib.Path(sys.argv[1]).read_text(), end='', flush=True); time.sleep(1800)",
                             report, env=runtime_env)
        conversation_id, conversation_pane = bound_conversation(tmp, runtime_env)
        question_id = output("tmux", "new-session", "-d", "-P", "-F", "#{session_id}",
                             "-s", "tmux-link-managed-question-simulator", sys.executable, "-c",
                             "import time; print('What audience should the draft address?', flush=True); time.sleep(1800)",
                             env=runtime_env)
        # A foreground executable with the normal tty editing discipline. This
        # fixture accepts shortcuts without contacting an AI provider.
        shortcut_dir = tmp / "agent-shortcut"
        shortcut_dir.mkdir()
        source = shortcut_dir / "codex.c"
        source.write_text(
            "#include <stdio.h>\n"
            "int main(void) {\n"
            "    int c;\n"
            "    while ((c = getchar()) != EOF) { putchar(c); fflush(stdout); }\n"
            "    return 0;\n"
            "}\n"
        )
        run("cc", "-o", shortcut_dir / "codex", source)
        shortcut_id = output("tmux", "new-session", "-d", "-P", "-F", "#{session_id}",
                             "-s", "tmux-link-agent-keys-simulator", "-c", shortcut_dir,
                             "-e", "HISTFILE=/dev/null", "-e", "PS1=$ ",
                             "/bin/bash", "--noprofile", "--norc", "-i", env=runtime_env)
        tmux_path = str(Path(shutil.which("tmux")).parent)
        command = shlex.join(["/usr/bin/env", f"TMUX_TMPDIR={tmp}", f"HOME={tmp}",
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
                    "snapshotFixtureID": int(snapshot_id.removeprefix("$")),
                    "managedQuestionFixtureID": int(question_id.removeprefix("$")),
                    "agentShortcutFixtureID": int(shortcut_id.removeprefix("$")),
                    "conversationFixtureID": conversation_id, "conversationFixturePane": conversation_pane,
                }))
                run(*sim, "terminate", device, bundle)
                result = tmp / "benchmark.xcresult"
                run(*build, "-only-testing:TmuxLinkDeviceTests/RemoteSessionTests/testTerminalPerformanceBaseline",
                    "-only-testing:TmuxLinkDeviceTests/RemoteSessionTests/testOfflineEnglishKeyboard",
                    "-only-testing:TmuxLinkDeviceTests/RemoteSessionTests/testAgentReplyMenusFollowForegroundIdentity",
                    "-only-testing:TmuxLinkDeviceTests/RemoteSessionTests/testAgentReplyInsertsTextOnlyWhileAgentIsForeground",
                    "-only-testing:TmuxLinkDeviceTests/RemoteSessionTests/testKeyboardRowAndCursorModes",
                    "-only-testing:TmuxLinkDeviceTests/RemoteSessionTests/testHostSnapshotRetainsEarlierConstraint",
                    "-only-testing:TmuxLinkDeviceTests/RemoteSessionTests/testBoundConversationUsesLatestReply",
                    "-only-testing:TmuxLinkDeviceTests/RemoteSessionTests/testManagedStatusUsesPinnedSessionWithoutEnablingIt",
                    "-only-testing:TmuxLinkDeviceTests/RemoteSessionTests/testForegroundPhoneCompletesAnIsolatedQuestion",
                    "-only-testing:TmuxLinkDeviceTests/RemoteSessionTests/testStatusButtonFitsIslandAndInlineLayouts",
                    "-only-testing:TmuxLinkDeviceTests/SessionAdvisorTests",
                    "-only-testing:TmuxLinkDeviceTests/WorkspaceExperienceTests",
                    "-only-testing:TmuxLinkDeviceTests/PersonalDecisionMemoryTests",
                    "-only-testing:TmuxLinkDeviceTests/RemoteSessionTests/testTerminalSurvivesBackgroundAndReattachesAfterDetach",
                    "-only-testing:TmuxLinkDeviceTests/RemoteSessionTests/testRecoveryRecognizesTheSameTmuxSessionAcrossPaneChanges",
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
