#!/usr/bin/env python3
"""Run the foreground phone claim/finish protocol against isolated, real tmux sessions."""
import argparse
import contextlib
from dataclasses import dataclass
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time


ROOT = Path(__file__).resolve().parents[1]
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


def command(args, directory, env, *, stdin="", check=True):
    result = subprocess.run(args, cwd=directory, env=env, input=stdin, text=True,
                            capture_output=True, timeout=25)
    if check and result.returncode:
        raise RuntimeError(f"{Path(args[0]).name} {args[1]} failed: {result.stderr.strip()}")
    return result.stdout.strip()


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
        if (key == '!') { /* Repaint on a simulated manual keystroke. */
            printf("\033[2J\033[HChanged by the user");
            fflush(stdout);
        } else if (fputc(key, keys) == EOF || fflush(keys)) return 1;
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


def exercise(agent, directory, env):
    def run(*args, request=None, stdin="", check=True):
        child_env = env if request is None else dict(env, SSH_ORIGINAL_COMMAND=request)
        return command(args, directory, child_env, stdin=stdin, check=check)

    def host(action, binding):
        sid, instance = binding
        return json.loads(run(agent, "attach", request=f"tmux-link-managed-v1 {action}@{instance} {sid}"))

    def claim(binding):
        sid, instance = binding
        return json.loads(run(agent, "attach", request=f"tmux-link-advisor-v2 claim {sid} {instance}"))["claim"]

    def completion(case, claimed):
        assert (claimed["mode"], claimed["style"]) == tuple(case.policy.split("-")), claimed
        request = claimed["request"]
        assert [m["role"] for m in request["messages"]] == ["system", "user"], request
        assert request["response_format"] == {"type": "json_object"} and request["max_tokens"] == 384
        assert {"model", "api_key", "base_url"}.isdisjoint(request), request
        prompt = json.loads(request["messages"][-1]["content"])
        assert prompt["question"] == case.question and prompt["options"] == list(case.options), prompt
        answer = {"choice": 2 if case.options else None, "reason": "Fixture choice.",
                  "draft": None if case.options else DRAFT}
        return {"choices": [{"finish_reason": "stop", "message": {"content": json.dumps(answer)}}],
                "usage": {"total_tokens": TOKENS}}

    def finish(binding, ticket, response, *, check=True):
        sid, instance = binding
        return run(agent, "attach", request=f"tmux-link-advisor-v2 finish {sid} {instance} {ticket}",
                   stdin=json.dumps(response), check=check)

    (directory / "pane.c").write_text(PANE)
    pane = directory / "codemaker"
    run("cc", "pane.c", "-o", pane)
    bindings = {}

    def create(name, case):
        target = run("tmux", "-u", "-f", "/dev/null", "new-session", "-d", "-P", "-F", "#{session_id}",
                     "-s", name, "-x", "100", "-y", "20", pane, case.screen(), directory / (name + ".keys"))
        wait_for(f"{name} alternate screen",
                 lambda: run("tmux", "display-message", "-p", "-t", target + ":", "#{alternate_on}"),
                 lambda value: value == "1", 10)
        sessions = json.loads(run(agent, "attach", request="tmux-link-list"))
        session = next(item for item in sessions if str(item["id"]) == target[1:])
        binding = session["id"], session["managedInstance"]
        bindings[name] = binding
        assert not host("status", binding)["enabled"], name
        enabled = host("enable-" + case.policy, binding)
        assert enabled["enabled"] and enabled["callsToday"] == 0 and not enabled["records"], enabled
        return binding

    def keys(name):
        return (directory / (name + ".keys")).read_bytes()

    try:
        for case in CASES:
            binding = create(case.name, case)
            job = claim(binding)
            payload = completion(case, job)
            assert claim(binding) is None, "a concurrent phone must not claim this ticket"
            status = json.loads(finish(binding, job["ticket"], payload))
            assert status["enabled"] and status["memory"], (case, status)
            assert len(status["records"]) == 1, (case, status)
            record = status["records"][0]
            assert (record["mode"], record["style"]) == tuple(case.policy.split("-")), record
            assert record["outcome"] == case.outcome and record["question"] == case.question, record
            assert record.get("choice") == (case.options[1] if case.options else None) and record["reason"], record
            if not case.options:
                assert record.get("draft") == DRAFT, record
            finish(binding, job["ticket"], payload, check=False)
            assert claim(binding) is None, "an unchanged screen must not trigger another phone request"
            final = host("status", binding)
            assert final["callsToday"] == 1 and final["tokensToday"] == TOKENS, final
            assert final["records"] == status["records"], final
            expected = b"2" if case.outcome == "applied" else b""
            assert keys(case.name) == expected, (case, keys(case.name))

            stopped = host("disable", binding)
            assert not stopped["enabled"] and stopped["records"] == final["records"], stopped
            cleared = host("forget", binding)
            assert not cleared["enabled"] and not cleared["records"] and not cleared["memory"], cleared
            assert cleared["callsToday"] == 1 and cleared["tokensToday"] == TOKENS, cleared
            print(f"{case.name}: {case.outcome}, {len(expected)} key(s), one phone request", flush=True)

        case = CASES[0]
        for event in ("pause", "repaint", "expired", "model-failure"):
            binding = create(event, case)
            job = claim(binding)
            payload = completion(case, job)
            if event == "pause":
                host("disable", binding)
            elif event == "repaint":
                target = f"${binding[0]}:"
                run("tmux", "send-keys", "-t", target, "-l", "!")
                wait_for(event, lambda: run("tmux", "capture-pane", "-p", "-t", target),
                         lambda value: "Changed by the user" in value, 5)
            elif event == "expired":
                # Move only this lease's clock inside the isolated test HOME.
                managed_dir = directory / ".config/tmux-link/managed"
                for path in managed_dir.glob("session-*.json"):
                    state = json.loads(path.read_text())
                    if state["binding"]["session"]["id"] == binding[0]:
                        assert state["pending"]["created_at"] > 0
                        state["pending"]["created_at"] -= 121
                        path.write_text(json.dumps(state))
                        break
                else:
                    raise AssertionError("Missing lease fixture")
            else:
                payload = None
            finish(binding, job["ticket"], payload, check=False)
            status = host("status", binding)
            assert keys(event) == b"" and all(r["outcome"] != "applied" for r in status["records"]), status
            if event == "expired":
                assert claim(binding) is None, "expiry must not spend another call on the same screen"
            if event == "model-failure":
                assert status["records"] and status["records"][0]["outcome"] == "failed", status
            print(f"{event}: no terminal input", flush=True)

        assert not (directory / ".config/tmux-link/managed/api-key").exists()
    finally:
        for binding in bindings.values():
            with contextlib.suppress(Exception):
                host("disable", binding)
        run("tmux", "kill-server", check=False)


def main():
    args = argparse.ArgumentParser(description=__doc__)
    args.add_argument("agent", nargs="?", type=Path, default=ROOT / "target/debug/agent")
    agent = args.parse_args().agent.resolve(strict=True)
    # Keep sockets short enough for macOS sockaddr_un. The node gets no model
    # credential or provider endpoint; the test stands in for the foreground phone.
    with tempfile.TemporaryDirectory(prefix="tl-managed-", dir="/tmp") as work:
        env = {"HOME": work, "TMUX_TMPDIR": work, "PATH": os.environ["PATH"], "LANG": "en_US.UTF-8"}
        exercise(agent, Path(work), env)


if __name__ == "__main__":
    main()
