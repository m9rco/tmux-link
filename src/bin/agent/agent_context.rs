//! Read the input target of one attached phone, including after tmux switch-client.
use anyhow::{Context, Result, ensure};
use serde_json::json;
use std::{path::Path, process::Command};

pub(super) fn numeric<T: std::str::FromStr>(text: &str) -> Result<T> {
    ensure!(
        !text.is_empty() && text.bytes().all(|b| b.is_ascii_digit()),
        "invalid tmux ID"
    );
    text.parse().ok().context("invalid tmux ID")
}

fn basename(path: &str) -> &str {
    Path::new(path)
        .file_name()
        .and_then(|s| s.to_str())
        .unwrap_or("")
}

fn family(name: &str) -> Option<&'static str> {
    match basename(name) {
        "codemaker" => Some("codemaker"),
        "opencode" => Some("opencode"),
        "codex" => Some("codex"),
        "claude" => Some("claude"),
        _ => None,
    }
}

fn version_name(name: &str) -> bool {
    let mut parts = name.split('.');
    parts.clone().count() >= 3
        && parts.all(|part| !part.is_empty() && part.bytes().all(|b| b.is_ascii_digit()))
}

fn javascript_launcher(path: &str) -> Option<&'static str> {
    family(path).or_else(|| {
        [
            ("/@openai/codex/bin/codex.js", "codex"),
            ("/@anthropic-ai/claude-code/cli.js", "claude"),
        ]
        .into_iter()
        .find_map(|(suffix, name)| path.ends_with(suffix).then_some(name))
    })
}

fn interactive(agent: &str, args: &[&str]) -> bool {
    let mut args = args.iter().copied();
    while let Some(arg) = args.next() {
        let (flag, inline) = arg
            .split_once('=')
            .map_or((arg, None), |(a, b)| (a, Some(b)));
        let takes_value = matches!(
            flag,
            "--model"
                | "-m"
                | "--agent"
                | "--session"
                | "--session-id"
                | "-s"
                | "--cwd"
                | "--cd"
                | "-C"
                | "--profile"
                | "--config"
                | "--sandbox"
                | "--permission-mode"
                | "--prompt"
                | "--hostname"
                | "--port"
                | "--replay-limit"
                | "--log-level"
                | "--add-dir"
                | "--ask-for-approval"
                | "-a"
                | "--effort"
        ) || agent == "codex" && matches!(flag, "-p" | "-c");
        if takes_value {
            if inline
                .or_else(|| args.next())
                .is_none_or(|v| v.is_empty() || v.starts_with('-'))
            {
                return false;
            }
            continue;
        }
        match arg {
            "--continue"
            | "-c"
            | "--resume"
            | "-r"
            | "--dangerously-skip-permissions"
            | "--dangerously-bypass-approvals-and-sandbox"
            | "--yolo"
            | "--no-alt-screen"
            | "--full-auto"
            | "--auto"
            | "--mini"
            | "--pure"
            | "--no-replay" => {}
            // ps flattens argv on both platforms. Recognize clear natural-language
            // openings without treating e.g. "codex review" as a prompt, and never
            // ignore trailing flags such as Claude's --print.
            word if matches!(agent, "claude" | "codex")
                && (matches!(
                    word.to_ascii_lowercase().as_str(),
                    "please" | "why" | "how" | "what" | "explain"
                ) || word
                    .chars()
                    .next()
                    .is_some_and(|c| !c.is_ascii() && c.is_alphabetic())) =>
            {
                return args.all(|tail| !tail.starts_with('-'));
            }
            // Native Codex resume/fork and OpenCode attach open an interactive UI.
            "resume" | "fork" if agent == "codex" => {
                return args.all(|v| !v.starts_with('-') || v == "--last" || v == "--all");
            }
            "attach" if matches!(agent, "codemaker" | "opencode") => {
                return args
                    .next()
                    .is_some_and(|v| v.starts_with("https://") || v.starts_with("http://"))
                    && args.next().is_none();
            }
            "." | ".." if matches!(agent, "opencode" | "codemaker") => {}
            path if matches!(agent, "opencode" | "codemaker")
                && (path.starts_with('/') || path.starts_with("./") || path.starts_with("../")) => {
            }
            // An unknown subcommand (run, exec, export, serve, auth, …) or CLI
            // option has no verified interactive input semantics.
            _ => return false,
        }
    }
    true
}

fn agent_for_command(pane_command: &str, argv: &[&str]) -> Option<&'static str> {
    let (program, args) = argv.split_first()?;
    let program_name = basename(program);
    let (agent, args) = if matches!(program_name, "node" | "nodejs" | "bun") {
        let (script, rest) = args.split_first()?;
        (javascript_launcher(script)?, rest)
    } else if version_name(program_name) && program.contains("/claude/versions/") {
        ("claude", args)
    } else {
        (family(program)?, args)
    };
    let shown = basename(pane_command);
    if shown != agent
        && !matches!(shown, "node" | "nodejs" | "bun")
        && !(agent == "claude" && version_name(shown))
    {
        return None;
    }
    interactive(agent, args).then_some(agent)
}

fn ps(pid: u32, columns: &str) -> Option<String> {
    let output = Command::new("ps")
        .env("LC_ALL", "C")
        .env("TZ", "UTC")
        .args(["-ww", "-p", &pid.to_string(), "-o", columns])
        .output()
        .ok()?;
    if !output.status.success() || output.stdout.len() > 32 * 1024 {
        return None;
    }
    String::from_utf8(output.stdout).ok()
}

fn foreground_agent(pane_pid: u32, pane_command: &str) -> Option<(&'static str, String)> {
    if family(pane_command).is_none()
        && !matches!(pane_command, "node" | "nodejs" | "bun")
        && !version_name(pane_command)
    {
        return None;
    }
    let group: u32 = numeric(ps(pane_pid, "tpgid=")?.trim()).ok()?;
    if group == 0 {
        return None;
    }
    let row = ps(group, "lstart=,args=")?;
    let mut fields = row.split_ascii_whitespace();
    // POSIX locale lstart is five whitespace-delimited fields on Linux and Darwin.
    let start: Vec<_> = fields.by_ref().take(5).collect();
    if start.len() != 5 {
        return None;
    }
    let agent = agent_for_command(pane_command, &fields.collect::<Vec<_>>())?;
    Some((agent, format!("{group}-{}", start.join("-"))))
}

pub(super) fn print(request: &str) -> Result<()> {
    let (initial_session, client) = request.split_once(' ').context("invalid context request")?;
    let _: u64 = numeric(initial_session)?;
    let client: u32 = numeric(client)?;
    ensure!(client > 0, "invalid tmux client");
    // list-clients expands pane/session fields in each client's current context.
    // A session target here would silently track the old window after switch-client.
    let result = Command::new("tmux").args(["-u", "list-clients", "-f", &format!("#{{==:#{{client_pid}},{client}}}"), "-F",
        "#{client_pid}\t#{session_id}\t#{pane_id}\t#{pid}-#{session_created}-#{pane_id}-#{pane_pid}\t#{pane_pid}\t#{pane_dead}#{pane_in_mode}#{synchronize-panes}#{client_readonly}\t#{client_key_table}\t#{pane_current_command}"]).output()?;
    ensure!(result.status.success(), "cannot inspect tmux client");
    let line = std::str::from_utf8(&result.stdout)?
        .strip_suffix('\n')
        .context("tmux client unavailable")?;
    ensure!(!line.contains('\n'), "invalid tmux client record");
    let fields: [&str; 8] = line
        .split('\t')
        .collect::<Vec<_>>()
        .try_into()
        .ok()
        .context("invalid tmux client record")?;
    let [
        reported,
        session,
        pane,
        instance,
        pid,
        flags,
        table,
        command,
    ] = fields;
    ensure!(
        numeric::<u32>(reported)? == client && tmux_link::valid_managed_instance(instance),
        "tmux client changed"
    );
    let id: u64 = numeric(session.strip_prefix('$').context("invalid session")?)?;
    let pane_id: u64 = numeric(pane.strip_prefix('%').context("invalid pane")?)?;
    let pid = numeric(pid)?;
    let found = (flags == "0000" && table == "root")
        .then(|| foreground_agent(pid, command))
        .flatten();
    let (agent, process_instance) = found.unzip();
    println!(
        "{}",
        json!({"version":1,"id":id,"paneId":pane_id,"instance":instance,"isAgent":agent.is_some(),"agent":agent,"processInstance":process_instance})
    );
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_known_interactive_programs_and_invocations_enable_shortcuts() {
        for (pane, argv, expected) in [
            (
                "codemaker",
                vec!["/opt/bin/codemaker", "--pure", "--session", "ses_123"],
                Some("codemaker"),
            ),
            (
                "node",
                vec![
                    "node",
                    "/opt/lib/node_modules/@openai/codex/bin/codex.js",
                    "resume",
                    "--last",
                ],
                Some("codex"),
            ),
            (
                "node",
                vec![
                    "node",
                    "/opt/lib/node_modules/@anthropic-ai/claude-code/cli.js",
                ],
                Some("claude"),
            ),
            (
                "2.1.42",
                vec!["/home/u/.local/share/claude/versions/2.1.42"],
                Some("claude"),
            ),
            (
                "opencode",
                vec!["/usr/bin/opencode", "./project"],
                Some("opencode"),
            ),
            (
                "codex",
                vec![
                    "codex",
                    "--model=gpt",
                    "--sandbox=read-only",
                    "Please",
                    "explain",
                    "this",
                ],
                Some("codex"),
            ),
            (
                "claude",
                vec!["claude", "--model=sonnet", "请帮我梳理变更"],
                Some("claude"),
            ),
            (
                "claude",
                vec!["claude", "please", "explain", "--print"],
                None,
            ),
            ("codex", vec!["codex", "review", "my", "changes"], None),
            (
                "codex",
                vec!["codex", "--model=gpt", "exec", "example"],
                None,
            ),
            ("codex", vec!["codex", "--model=", "example"], None),
            (
                "codemaker",
                vec!["codemaker", "--pure", "export", "ses_x"],
                None,
            ),
            ("claude", vec!["claude", "-p", "example"], None),
            ("codemaker", vec!["codemaker", "--help"], None),
            ("node", vec!["node", "other.js", "codex"], None),
            ("bash", vec!["bash", "-c", "codex"], None),
            ("sleep", vec!["codex"], None),
        ] {
            assert_eq!(agent_for_command(pane, &argv), expected);
        }
    }
}
