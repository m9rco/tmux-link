#!/usr/bin/env python3
"""Exercise node-managed decisions in private tmux sessions against a loopback TLS fixture."""
import argparse
import contextlib
from dataclasses import dataclass
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import ssl
import subprocess
import tempfile
import threading
import time


ROOT = Path(__file__).resolve().parents[1]
TEST_KEY = "sk-isolated-fixture"
DRAFT = "请面向第一次阅读的同事说明背景。"
TOKENS = 31


@dataclass(frozen=True)
class Case:
    name: str
    policy: str
    question: str
    options: tuple
    outcome: str

    def screen(self):
        if not self.options:
            return self.question
        return "\r\n".join([self.question, "1. " + self.options[0],
                            "2. " + self.options[1], "Press 1-2 to submit"])


EXPORT = ("CSV", "JSON")
CASES = (
    Case("export", "menu-balanced", "Choose export format:", EXPORT, "applied"),
    Case("language", "assist-concise", "Which language should I use for my reply?",
         ("请用简体中文回复。", "请用英文回复。"), "applied"),
    Case("observe", "observe-cautious", "Choose export format:", EXPORT, "observed"),
    Case("draft", "assist-balanced", "What audience should the draft address?", (), "needsConfirmation"),
    Case("remove", "assist-cautious", "Permanently remove this project?",
         ("Keep project", "Remove project"), "needsConfirmation"),
)


def command(args, directory, env, *, stdin=None, check=True):
    result = subprocess.run(args, cwd=directory, env=env, input=stdin, text=True,
                            capture_output=True, timeout=25)
    if check and result.returncode:
        raise RuntimeError(f"{Path(args[0]).name} {args[1]} failed: {result.stderr.strip()}")
    return result.stdout.strip()


def make_tls(directory, env):
    def openssl(*args):
        command(["openssl", *args], directory, env)

    (directory / "ca.cnf").write_text(
        "[req]\ndistinguished_name=dn\n[dn]\n[ca]\nbasicConstraints=critical,CA:TRUE\n"
        "keyUsage=critical,keyCertSign,cRLSign\n")
    openssl("req", "-x509", "-nodes", "-newkey", "rsa:2048", "-keyout", "ca.key",
            "-out", "ca.pem", "-days", "1", "-subj", "/CN=ManagedTestCA",
            "-config", "ca.cnf", "-extensions", "ca")
    openssl("req", "-nodes", "-newkey", "rsa:2048", "-keyout", "server.key",
            "-out", "server.csr", "-subj", "/CN=api.deepseek.com")
    (directory / "server.cnf").write_text("subjectAltName=DNS:api.deepseek.com\nextendedKeyUsage=serverAuth\n")
    openssl("x509", "-req", "-in", "server.csr", "-CA", "ca.pem", "-CAkey", "ca.key",
            "-CAcreateserial", "-out", "server.pem", "-days", "1", "-extfile", "server.cnf")
    tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    tls.load_cert_chain(directory / "server.pem", directory / "server.key")
    return tls


class QuietHandler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass


class Completion(QuietHandler):
    def do_POST(self):
        if self.path != "/chat/completions" or self.headers.get("Authorization") != f"Bearer {TEST_KEY}":
            self.send_error(403)
            return
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        prompt = json.loads(body["messages"][-1]["content"])
        self.server.questions.append(prompt["question"])
        answer = {"choice": 2 if prompt["options"] else None, "reason": "Fixture choice.",
                  "draft": None if prompt["options"] else DRAFT}
        payload = json.dumps({"choices": [{"finish_reason": "stop", "message": {"content": json.dumps(answer)}}],
                              "usage": {"total_tokens": TOKENS}}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)


class LocalProxy(QuietHandler):
    def do_CONNECT(self):
        # Terminate TLS on the existing loopback socket. Never resolve or forward the host.
        if self.path != "api.deepseek.com:443":
            self.send_error(403)
            return
        self.send_response_only(200)
        self.end_headers()
        with self.server.tls.wrap_socket(self.connection, server_side=True) as stream:
            Completion(stream, self.client_address, self.server)


# Keep the screen unchanged after a key. The binary's foreground name and alternate
# screen exercise the same tmux checks used for a real application.
PANE = r"""
#include <stdio.h>
#include <termios.h>
#include <unistd.h>
int main(int argc, char **argv) {
    struct termios mode;
    if (argc != 3 || tcgetattr(STDIN_FILENO, &mode)) return 1;
    cfmakeraw(&mode);
    if (tcsetattr(STDIN_FILENO, TCSANOW, &mode)) return 1;
    FILE *keys = fopen(argv[2], "wb");
    if (!keys) return 1;
    printf("\033[?1049h\033[2J\033[H%s", argv[1]);
    fflush(stdout);
    unsigned char key;
    while (read(STDIN_FILENO, &key, 1) == 1) {
        if (fputc(key, keys) == EOF || fflush(keys)) return 1;
    }
    return fclose(keys) != 0;
}
"""


def wait_for(description, sample, ready, timeout):
    end = time.monotonic() + timeout
    while True:
        value = sample()
        if ready(value):
            return value
        if time.monotonic() >= end:
            raise AssertionError(f"Timed out waiting for {description}: {value!r}")
        time.sleep(0.5)


def exercise(agent, directory, env, server):
    def run(*args, request=None, stdin=None, check=True):
        child_env = env if request is None else dict(env, SSH_ORIGINAL_COMMAND=request)
        return command(args, directory, child_env, stdin=stdin, check=check)

    def host(action, binding):
        sid, instance = binding
        return json.loads(run(agent, "attach", request=f"tmux-link-managed-v1 {action}@{instance} {sid}"))

    (directory / "pane.c").write_text(PANE)
    pane = directory / "codemaker"
    run("cc", "pane.c", "-o", pane)
    bindings = {}
    try:
        run(agent, "managed-key", stdin=TEST_KEY + "\n")
        for case in CASES:
            target = run("tmux", "-u", "-f", "/dev/null", "new-session", "-d", "-P", "-F", "#{session_id}",
                         "-s", case.name, "-x", "100", "-y", "20", pane,
                         case.screen(), directory / (case.name + ".keys"))
            wait_for(f"{case.name} alternate screen",
                     lambda: run("tmux", "display-message", "-p", "-t", target + ":", "#{alternate_on}"),
                     lambda value: value == "1", 10)
            sessions = json.loads(run(agent, "attach", request="tmux-link-list"))
            session = next(item for item in sessions if str(item["id"]) == target[1:])
            binding = (session["id"], session["managedInstance"])
            bindings[case.name] = binding
            assert not host("status", binding)["enabled"], case.name
            enabled = host("enable-" + case.policy, binding)
            assert enabled["enabled"] and enabled["keyReady"], enabled

        def statuses():
            return {name: host("status", binding) for name, binding in bindings.items()}

        wait_for("a decision in every pane", statuses,
                 lambda value: all(s["records"] for s in value.values()), 150)
        # Exceed the worker's 20-second maximum idle polling interval. Repeated scans
        # of exactly the same screen must neither bill nor inject another key.
        time.sleep(23)
        states = statuses()
        for case in CASES:
            status = states[case.name]
            records = status["records"]
            assert status["enabled"] and status["memory"], (case, status)
            assert len(records) == 1 and status["callsToday"] == 1 and status["tokensToday"] == TOKENS, (case, status)
            record = records[0]
            assert (record["mode"], record["style"]) == tuple(case.policy.split("-")), (case, record)
            assert record["outcome"] == case.outcome and record["question"] == case.question, (case, record)
            choice = case.options[1] if case.options else None
            assert record.get("choice") == choice and record["reason"], (case, record)
            keys = (directory / (case.name + ".keys")).read_bytes()
            assert keys == (b"2" if case.outcome == "applied" else b""), (case, keys)
            if not case.options:
                assert record.get("draft") == DRAFT, record

            binding = bindings[case.name]
            stopped = host("disable", binding)
            assert not stopped["enabled"] and stopped["records"] == records, (case, stopped)
            cleared = host("forget", binding)
            assert not cleared["enabled"] and not cleared["records"] and not cleared["memory"], (case, cleared)
            assert cleared["callsToday"] == 1 and cleared["tokensToday"] == TOKENS, (case, cleared)
            print(f"{case.name}: {case.outcome}, {len(keys)} key(s), one request", flush=True)
        assert sorted(server.questions) == sorted(case.question for case in CASES), server.questions
    finally:
        for binding in bindings.values():
            with contextlib.suppress(Exception):
                host("disable", binding)
        run("tmux", "kill-server", check=False)


def main():
    args = argparse.ArgumentParser(description=__doc__)
    args.add_argument("agent", nargs="?", type=Path, default=ROOT / "target/debug/agent")
    agent = args.parse_args().agent.resolve(strict=True)
    # Short socket paths also fit macOS sockaddr_un. Only test state and fake
    # credentials enter the worker environment.
    with tempfile.TemporaryDirectory(prefix="tl-managed-", dir="/tmp") as work:
        directory = Path(work)
        env = {"HOME": work, "TMUX_TMPDIR": work, "PATH": os.environ["PATH"], "LANG": "en_US.UTF-8"}
        with ThreadingHTTPServer(("127.0.0.1", 0), LocalProxy) as server:
            server.tls = make_tls(directory, env)
            server.questions = []
            proxy = f"http://127.0.0.1:{server.server_port}"
            env.update(HTTPS_PROXY=proxy, ALL_PROXY=proxy, NO_PROXY="", CURL_CA_BUNDLE=str(directory / "ca.pem"))
            thread = threading.Thread(target=server.serve_forever)
            thread.start()
            try:
                exercise(agent, directory, env, server)
            finally:
                server.shutdown()
                thread.join()


if __name__ == "__main__":
    main()
