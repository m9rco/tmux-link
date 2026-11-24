//! Reduce the explicitly selected CodeMaker export to visible conversation text.
use anyhow::{Result, ensure};
use serde::{
    Deserialize, Deserializer, Serialize,
    de::{IgnoredAny, MapAccess, Visitor},
};
use std::collections::HashSet;

pub(crate) const MAX_EXPORT_BYTES: usize = 64 * 1024 * 1024;
const MAX_MESSAGES: usize = 32;
const MAX_TEXT: usize = 32 * 1024;
const MAX_MESSAGE: usize = 4 * 1024;

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct Transcript {
    pub(crate) source: &'static str,
    pub(crate) order: &'static str,
    #[serde(rename = "sessionID")]
    pub(crate) session_id: String,
    latest_is_displayed: bool,
    messages: Vec<Message>,
}

#[derive(Serialize)]
struct Message {
    role: String,
    text: String,
}

#[derive(Deserialize)]
struct Export {
    info: Session,
    messages: Vec<Turn>,
}

#[derive(Deserialize)]
struct Session {
    id: String,
}

#[derive(Deserialize)]
struct Turn {
    info: Info,
    parts: Vec<Part>,
}

#[derive(Deserialize)]
struct Info {
    id: String,
    #[serde(rename = "sessionID")]
    session: String,
    role: String,
    time: Time,
    error: Option<IgnoredAny>,
    finish: Option<String>,
    #[serde(default)]
    ignored: bool,
    #[serde(default)]
    synthetic: bool,
    #[serde(default, deserialize_with = "summary_flag")]
    summary: bool,
}

// An assistant's internal compaction has summary=true. User messages may
// instead carry a summary object with large file diffs that we never need.
fn summary_flag<'de, D: Deserializer<'de>>(deserializer: D) -> Result<bool, D::Error> {
    struct Summary;
    impl<'de> Visitor<'de> for Summary {
        type Value = bool;
        fn expecting(&self, formatter: &mut std::fmt::Formatter) -> std::fmt::Result {
            formatter.write_str("a summary flag or metadata object")
        }
        fn visit_bool<E>(self, value: bool) -> Result<bool, E> {
            Ok(value)
        }
        fn visit_map<A: MapAccess<'de>>(self, mut map: A) -> Result<bool, A::Error> {
            while map.next_entry::<IgnoredAny, IgnoredAny>()?.is_some() {}
            Ok(false)
        }
        fn visit_unit<E>(self) -> Result<bool, E> {
            Ok(false)
        }
    }
    deserializer.deserialize_any(Summary)
}

#[derive(Deserialize)]
struct Time {
    created: u64,
    completed: Option<u64>,
}

// Tool input, output, attachments, metadata and other unknown fields are skipped
// by serde without constructing a JSON value for their (often very large) trees.
#[derive(Deserialize)]
struct Part {
    #[serde(rename = "type")]
    kind: String,
    #[serde(rename = "sessionID")]
    session: Option<String>,
    #[serde(rename = "messageID")]
    message: Option<String>,
    text: Option<String>,
    #[serde(default)]
    synthetic: bool,
    #[serde(default)]
    ignored: bool,
    reason: Option<String>,
    time: Option<PartTime>,
}

#[derive(Deserialize)]
struct PartTime {
    end: Option<u64>,
}

pub(crate) fn valid_id(id: &str) -> bool {
    id.strip_prefix("ses_").is_some_and(|suffix| {
        (1..=120).contains(&suffix.len())
            && suffix
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'-' | b'_'))
    })
}

pub(crate) fn from_bytes(raw: &[u8], expected_id: &str) -> Result<Transcript> {
    ensure!(valid_id(expected_id), "invalid application session ID");
    ensure!(
        raw.len() <= MAX_EXPORT_BYTES,
        "session export exceeds limit"
    );
    let mut export: Export = serde_json::from_slice(raw)?;
    ensure!(export.info.id == expected_id, "export session mismatch");
    let mut ids = HashSet::new();
    for turn in &export.messages {
        ensure!(
            !turn.info.id.is_empty()
                && ids.insert(&turn.info.id)
                && turn.info.session == expected_id
                && turn.parts.iter().all(|p| p
                    .session
                    .as_deref()
                    .is_none_or(|id| id == expected_id)
                    && p.message.as_deref().is_none_or(|id| id == turn.info.id)),
            "inconsistent message identities in session export"
        );
    }
    // Creation time is authoritative. CodeMaker's sortable IDs break ties the
    // same way for an out-of-order export as for a chronological one.
    export.messages.sort_unstable_by(|a, b| {
        b.info
            .time
            .created
            .cmp(&a.info.time.created)
            .then_with(|| b.info.id.cmp(&a.info.id))
    });
    let key_prefixes = private_key_prefixes(&export.messages);
    let mut remaining = MAX_TEXT;
    let mut messages = Vec::with_capacity(MAX_MESSAGES);
    let mut latest_is_displayed = false;
    for (index, (turn, private)) in export.messages.into_iter().zip(key_prefixes).enumerate() {
        if messages.len() == MAX_MESSAGES || remaining == 0 {
            break;
        }
        if !turn.displayed_role() {
            continue;
        }
        let (text, complete) = visible(&turn, private)?;
        if text.trim().is_empty() {
            continue;
        }
        let excerpt = tail(&text, MAX_MESSAGE.min(remaining));
        if excerpt.is_empty() {
            break;
        }
        if index == 0 {
            latest_is_displayed = complete && text.len() == excerpt.len();
        }
        remaining -= excerpt.len();
        messages.push(Message {
            role: turn.info.role,
            text: excerpt.to_owned(),
        });
    }
    Ok(Transcript {
        session_id: export.info.id,
        source: "transcript",
        order: "newestFirst",
        latest_is_displayed,
        messages,
    })
}

impl Turn {
    fn displayed_role(&self) -> bool {
        matches!(self.info.role.as_str(), "assistant" | "user")
            && !self.info.ignored
            && !self.info.synthetic
            && !self.info.summary
    }
}

impl Part {
    fn displayed_text(&self) -> Option<&str> {
        if self.kind == "text" && !self.synthetic && !self.ignored {
            self.text.as_deref()
        } else {
            None
        }
    }
}

// A key may start outside the output budget. Record only its delimiters and
// turn boundaries here; message extraction below always runs newest first.
fn private_key_prefixes(turns: &[Turn]) -> Vec<bool> {
    let mut markers = Vec::with_capacity(turns.len());
    let mut starts = Vec::with_capacity(turns.len());
    for turn in turns.iter().rev() {
        starts.push(markers.len());
        markers.push("start of turn");
        if !turn.displayed_role() {
            continue;
        }
        for raw in turn.parts.iter().filter_map(Part::displayed_text) {
            if !raw.contains('-') {
                continue;
            }
            let plain;
            let text = if raw.contains('\x1b') {
                plain = super::plain_text(raw).ok();
                plain.as_deref().unwrap_or(raw)
            } else {
                raw
            };
            if !text.contains("PRIVATE KEY-----") {
                continue;
            }
            for line in text.lines().filter(|l| l.contains("PRIVATE KEY-----")) {
                if line.contains("-----BEGIN ") {
                    markers.push("-----BEGIN PRIVATE KEY-----");
                }
                if line.contains("-----END ") {
                    markers.push("-----END PRIVATE KEY-----");
                }
            }
        }
    }
    super::history::remove_private_keys(&mut [], &mut markers);
    starts
        .into_iter()
        .rev()
        .map(|i| markers[i].is_empty())
        .collect()
}

fn visible(turn: &Turn, in_private_key: bool) -> Result<(String, bool)> {
    let mut texts = Vec::new();
    let mut ends_in_text = false;
    let mut all_text_complete = true;
    for part in &turn.parts {
        if part.kind == "step-finish" && part.reason.as_deref() == Some("stop") {
            continue;
        }
        ends_in_text = false;
        if let Some(text) = part.displayed_text().filter(|s| !s.trim().is_empty()) {
            texts.push(text);
            ends_in_text = part.time.as_ref().is_none_or(|t| t.end.is_some());
            all_text_complete &= ends_in_text;
        }
    }
    let complete = ends_in_text
        && all_text_complete
        && (turn.info.role == "user"
            || (turn
                .info
                .time
                .completed
                .is_some_and(|end| end >= turn.info.time.created)
                && turn.info.error.is_none()
                && turn
                    .info
                    .finish
                    .as_deref()
                    .is_none_or(|reason| reason == "stop")));
    let joined = texts.join("\n");
    let plain = super::plain_text(&joined)?;
    let mut complete = complete && joined == plain;
    let visible = if in_private_key || plain.contains("PRIVATE KEY-----") {
        // A key beginning in one turn remains concealed through its end in a later turn.
        let mut rows: Vec<_> = plain.lines().collect();
        let mut prefix = if in_private_key {
            vec!["-----BEGIN PRIVATE KEY-----"]
        } else {
            vec![]
        };
        super::history::remove_private_keys(&mut prefix, &mut rows);
        complete = false;
        rows.join("\n")
    } else {
        plain
    };
    Ok((visible.trim_matches('\n').to_owned(), complete))
}

fn tail(text: &str, limit: usize) -> &str {
    let mut start = text.len().saturating_sub(limit);
    while !text.is_char_boundary(start) {
        start += 1;
    }
    &text[start..]
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::{Value, json};

    const ID: &str = "ses_example";

    fn turn(id: &str, created: u64, role: &str, parts: Value) -> Value {
        json!({"info":{"id":id, "time":{"created": created, "completed":created+1}, "role":role,
                       "sessionID":ID}, "parts":parts})
    }

    fn bytes(turns: &[Value]) -> Vec<u8> {
        serde_json::to_vec(&json!({"info":{"id":ID},"messages":turns})).unwrap()
    }

    fn read(turns: &[Value]) -> Value {
        serde_json::to_value(from_bytes(&bytes(turns), ID).unwrap()).unwrap()
    }

    #[test]
    fn orders_by_creation_then_id_and_selects_only_visible_turn_text() {
        let mut question = turn(
            "msg_b",
            202,
            "assistant",
            json!([
                {"type":"reasoning","text":"private rationale"},
                {"type":"text","synthetic":true,"text":"internal"},
                {"type":"text","ignored":true,"text":"omitted"},
                {"type":"text","text":"Proceed?","messageID":"msg_b","sessionID":ID},
                {"type":"step-finish","reason":"stop","tokens":{"input":40}}
            ]),
        );
        question["info"]["finish"] = json!("stop");
        let other = turn(
            "msg_a",
            202,
            "assistant",
            json!([
                {"type":"tool","state":{"input":{"token":"secret"},"output":"tool output"}},
                {"type":"text","text":"One"},{"type":"text","text":"Two"}
            ]),
        );
        let mut first = turn(
            "msg_z",
            1,
            "user",
            json!([{"type":"text","text":"My goal"}]),
        );
        first["info"]["summary"] = json!({"diffs":[{"after":"irrelevant data"}]});
        assert_eq!(
            read(&[other, first, question]),
            json!({
                "source":"transcript", "order":"newestFirst", "sessionID":ID, "latestIsDisplayed":true,
                "messages":[{"role":"assistant","text":"Proceed?"},{"role":"assistant","text":"One\nTwo"},{"role":"user","text":"My goal"}]
            })
        );
    }

    #[test]
    fn omitted_incomplete_and_tool_followups_never_make_an_older_question_live() {
        let old = turn(
            "msg_a",
            1,
            "assistant",
            json!([{"type":"text","text":"Earlier question?"}]),
        );
        let shown = turn(
            "msg_b",
            2,
            "assistant",
            json!([{"type":"text","text":"Working"}]),
        );
        for (key, value) in [
            ("time", json!({"created":2})),
            ("finish", json!("tool-calls")),
            ("error", json!({"name":"aborted"})),
            ("ignored", json!(true)),
            ("synthetic", json!(true)),
            ("summary", json!(true)),
        ] {
            let mut last = shown.clone();
            last["info"][key] = value;
            assert_eq!(
                read(&[old.clone(), last])["latestIsDisplayed"],
                false,
                "{key}"
            );
        }
        for parts in [
            json!([]),
            json!([{"type":"tool","state":{"output":"only tool output"}}]),
            json!([{"type":"text","text":"Done?"},{"type":"tool"}]),
            json!([{"type":"text","text":"Done?"},{"type":"text","ignored":true,"text":"ignored"}]),
            json!([{"type":"text","text":"Half","time":{"start":2}}]),
            json!([{"type":"text","text":"Done?"},{"type":"step-finish","reason":"length"}]),
        ] {
            let latest = read(&[old.clone(), turn("msg_b", 2, "assistant", parts)]);
            assert_eq!(latest["latestIsDisplayed"], false);
            assert!(
                latest["messages"]
                    .as_array()
                    .unwrap()
                    .iter()
                    .any(|m| m["text"] == "Earlier question?")
            );
        }
        assert_eq!(read(&[])["latestIsDisplayed"], false);
    }

    #[test]
    fn rejects_malformed_exports_and_unrelated_or_ambiguous_message_identities() {
        let message = turn(
            "msg_one",
            1,
            "assistant",
            json!([{"type":"text","text":"first"}]),
        );
        assert!(from_bytes(b"{}", ID).is_err());
        assert!(from_bytes(&bytes(&[]), "ses_other").is_err());
        assert!(from_bytes(&bytes(&[message.clone(), message.clone()]), ID).is_err());
        for at in [
            "/info/sessionID",
            "/parts/0/sessionID",
            "/parts/0/messageID",
        ] {
            let mut bad = message.clone();
            match at {
                "/info/sessionID" => bad["info"]["sessionID"] = json!("ses_other"),
                "/parts/0/sessionID" => bad["parts"][0]["sessionID"] = json!("ses_other"),
                _ => bad["parts"][0]["messageID"] = json!("msg_other"),
            }
            assert!(from_bytes(&bytes(&[bad]), ID).is_err(), "{at}");
        }
        for id in [
            "",
            "ses_",
            "-h",
            "ses_other dir",
            "ses_../s",
            &format!("ses_{}", "x".repeat(121)),
        ] {
            assert!(!valid_id(id));
        }
        assert!(valid_id(&format!("ses_{}", "a".repeat(120))));
    }

    #[test]
    fn filters_terminal_controls_and_key_material_even_across_turns() {
        let first = turn(
            "a",
            1,
            "user",
            json!([{"type":"text","text":"Goal\n-----BEGIN OPENSSH PRIVATE KEY-----\nkey body"}]),
        );
        let middle = turn(
            "b",
            2,
            "assistant",
            json!([{"type":"text","text":"still key body"}]),
        );
        let last = turn(
            "c",
            3,
            "user",
            json!([{"type":"text","text":"end of body\n-----END OPENSSH PRIVATE KEY-----\nOkay\u{1b}[8mhidden\u{1b}[28m?"}]),
        );
        let result = read(&[last, first, middle]);
        assert_eq!(
            result["messages"],
            json!([{"role":"user","text":"Okay      ?"},{"role":"user","text":"Goal"}])
        );
        assert_eq!(result["latestIsDisplayed"], false);
    }

    #[test]
    fn enforces_message_and_total_utf8_budgets_at_the_newest_end() {
        let turns = |s: &str| {
            (0..40)
                .map(|i| {
                    turn(
                        &format!("msg_{i}"),
                        i,
                        "assistant",
                        json!([{"type":"text","text":format!("{s}-{i}")}]),
                    )
                })
                .collect::<Vec<_>>()
        };
        let short = read(&turns("message"));
        assert_eq!(short["messages"].as_array().unwrap().len(), MAX_MESSAGES);
        assert_eq!(short["messages"][0]["text"], "message-39");
        assert_eq!(short["messages"][31]["text"], "message-8");
        let long = read(&turns(&"终".repeat(1500)));
        let strings: Vec<_> = long["messages"]
            .as_array()
            .unwrap()
            .iter()
            .map(|message| message["text"].as_str().unwrap())
            .collect();
        assert!(strings.iter().all(|s| s.len() <= MAX_MESSAGE));
        assert!(strings.iter().map(|s| s.len()).sum::<usize>() <= MAX_TEXT);
        assert!(strings[0].ends_with("-39") && strings[0].len() >= MAX_MESSAGE - 2);
        assert_eq!(long["latestIsDisplayed"], false);
    }

    #[test]
    fn stops_extracting_older_turns_as_soon_as_either_budget_is_full() {
        for (count, text) in [
            (MAX_MESSAGES, "recent".to_owned()),
            (MAX_TEXT / MAX_MESSAGE, "x".repeat(MAX_MESSAGE)),
        ] {
            let mut turns = vec![turn(
                "old",
                0,
                "user",
                json!([{"type":"text", "text":"incomplete terminal escape\u{1b}"}]),
            )];
            turns.extend((1..=count).map(|i| {
                turn(
                    &format!("msg_{i}"),
                    i as u64,
                    "user",
                    json!([{"type":"text", "text":text}]),
                )
            }));
            let result = read(&turns);
            assert_eq!(result["messages"].as_array().unwrap().len(), count);
            assert_eq!(result["latestIsDisplayed"], true);
        }
    }
}
