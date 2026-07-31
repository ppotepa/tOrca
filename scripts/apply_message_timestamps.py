#!/usr/bin/env python3
from __future__ import annotations

from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]


def read(rel: str) -> str:
    return (ROOT / rel).read_text(encoding="utf-8")


def write(rel: str, text: str) -> None:
    path = ROOT / rel
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")


def replace_once(rel: str, old: str, new: str) -> None:
    text = read(rel)
    count = text.count(old)
    if count != 1:
        raise RuntimeError(f"{rel}: expected one match, found {count}: {old[:140]!r}")
    write(rel, text.replace(old, new, 1))


def replace_all(rel: str, old: str, new: str, expected: int | None = None) -> None:
    text = read(rel)
    count = text.count(old)
    if expected is not None and count != expected:
        raise RuntimeError(f"{rel}: expected {expected} matches, found {count}: {old[:140]!r}")
    if count == 0:
        raise RuntimeError(f"{rel}: no matches: {old[:140]!r}")
    write(rel, text.replace(old, new))


def inject_chat_message_defaults() -> None:
    for file in (ROOT / "common").rglob("*.rs"):
        text = file.read_text(encoding="utf-8")
        cursor = 0
        changed = False
        while True:
            start = text.find("ChatMessage {", cursor)
            if start < 0:
                break
            brace = text.find("{", start)
            depth = 0
            end = None
            for index in range(brace, len(text)):
                char = text[index]
                if char == "{":
                    depth += 1
                elif char == "}":
                    depth -= 1
                    if depth == 0:
                        end = index
                        break
            if end is None:
                raise RuntimeError(f"unbalanced ChatMessage literal in {file}")
            block = text[start : end + 1]
            if "pub id:" in block or "sent_at:" in block or ".." in block:
                cursor = end + 1
                continue
            if "id:" not in block and "id," not in block:
                cursor = end + 1
                continue
            line_start = text.rfind("\n", 0, end) + 1
            closing_indent = text[line_start:end]
            field_indent = closing_indent + "    "
            addition = (
                f"{field_indent}sent_at: None,\n"
                f"{field_indent}delivered_at: None,\n"
                f"{field_indent}read_at: None,\n"
            )
            text = text[:line_start] + addition + text[line_start:]
            inserted = len(addition)
            cursor = end + inserted + 1
            changed = True
        if changed:
            file.write_text(text, encoding="utf-8")


write(
    "common/torchat-client-engine/sql/migrations/013_message_timestamps.sql",
    """ALTER TABLE messages ADD COLUMN sent_at INTEGER;
ALTER TABLE messages ADD COLUMN delivered_at INTEGER;
ALTER TABLE messages ADD COLUMN read_at INTEGER;
CREATE INDEX IF NOT EXISTS idx_messages_sent_at ON messages(sent_at);
CREATE INDEX IF NOT EXISTS idx_messages_delivered_at ON messages(delivered_at);
CREATE INDEX IF NOT EXISTS idx_messages_read_at ON messages(read_at);
""",
)

replace_once(
    "common/torchat-client-engine/src/storage/sqlite.rs",
    """    Migration {
        version: 12,
        name: \"012_pending_peer_endpoint_inbox.sql\",
        sql: include_str!(\"../../sql/migrations/012_pending_peer_endpoint_inbox.sql\"),
    },
];""",
    """    Migration {
        version: 12,
        name: \"012_pending_peer_endpoint_inbox.sql\",
        sql: include_str!(\"../../sql/migrations/012_pending_peer_endpoint_inbox.sql\"),
    },
    Migration {
        version: 13,
        name: \"013_message_timestamps.sql\",
        sql: include_str!(\"../../sql/migrations/013_message_timestamps.sql\"),
    },
];""",
)

replace_once(
    "common/torchat-client-runtime/src/models.rs",
    """    pub state: MessageState,
    pub created_at: i64,
    #[serde(default)]
    pub attempt_count: u32,""",
    """    pub state: MessageState,
    pub created_at: i64,
    #[serde(default, skip_serializing_if = \"Option::is_none\")]
    pub sent_at: Option<i64>,
    #[serde(default, skip_serializing_if = \"Option::is_none\")]
    pub delivered_at: Option<i64>,
    #[serde(default, skip_serializing_if = \"Option::is_none\")]
    pub read_at: Option<i64>,
    #[serde(default)]
    pub attempt_count: u32,""",
)

inject_chat_message_defaults()

replace_all(
    "common/torchat-client-engine/src/storage/runtime_storage.rs",
    """state, created_at,
                        attempt_count, last_attempt_at, next_attempt_at,""",
    """state, created_at, sent_at, delivered_at, read_at,
                        attempt_count, last_attempt_at, next_attempt_at,""",
    expected=3,
)
replace_all(
    "common/torchat-client-engine/src/storage/runtime_storage.rs",
    """row.get::<_, i64>(\"created_at\")?,
                    row.get::<_, i64>(\"attempt_count\")?,""",
    """row.get::<_, i64>(\"created_at\")?,
                    row.get::<_, Option<i64>>(\"sent_at\")?,
                    row.get::<_, Option<i64>>(\"delivered_at\")?,
                    row.get::<_, Option<i64>>(\"read_at\")?,
                    row.get::<_, i64>(\"attempt_count\")?,""",
    expected=3,
)
replace_all(
    "common/torchat-client-engine/src/storage/runtime_storage.rs",
    """created_at,
                attempt_count,
                last_attempt_at,""",
    """created_at,
                sent_at,
                delivered_at,
                read_at,
                attempt_count,
                last_attempt_at,""",
    expected=3,
)
replace_all(
    "common/torchat-client-engine/src/storage/runtime_storage.rs",
    """created_at,
                sent_at: None,
                delivered_at: None,
                read_at: None,
                attempt_count: attempt_count as u32,""",
    """created_at,
                sent_at,
                delivered_at,
                read_at,
                attempt_count: attempt_count as u32,""",
    expected=3,
)
replace_once(
    "common/torchat-client-engine/src/storage/runtime_storage.rs",
    """id, conversation_id, outgoing, body, reply_to_json, state, created_at,
                    relay_payload, ciphertext_hash, attempt_count, last_attempt_at,
                    next_attempt_at, ack_deadline, last_transport_error
                 ) VALUES (
                    ?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14
                 )""",
    """id, conversation_id, outgoing, body, reply_to_json, state, created_at,
                    sent_at, delivered_at, read_at, relay_payload, ciphertext_hash,
                    attempt_count, last_attempt_at, next_attempt_at, ack_deadline,
                    last_transport_error
                 ) VALUES (
                    ?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13,
                    ?14, ?15, ?16, ?17
                 )""",
)
replace_once(
    "common/torchat-client-engine/src/storage/runtime_storage.rs",
    """                    state = excluded.state,
                    created_at = excluded.created_at,
                    attempt_count = excluded.attempt_count,""",
    """                    state = excluded.state,
                    created_at = excluded.created_at,
                    sent_at = COALESCE(messages.sent_at, excluded.sent_at),
                    delivered_at = COALESCE(messages.delivered_at, excluded.delivered_at),
                    read_at = COALESCE(messages.read_at, excluded.read_at),
                    attempt_count = excluded.attempt_count,""",
)
replace_once(
    "common/torchat-client-engine/src/storage/runtime_storage.rs",
    """                    message.created_at,
                    relay_payload,
                    ciphertext_hash,
                    i64::from(message.attempt_count),""",
    """                    message.created_at,
                    message.sent_at,
                    message.delivered_at,
                    message.read_at,
                    relay_payload,
                    ciphertext_hash,
                    i64::from(message.attempt_count),""",
)

replace_once(
    "common/torchat-client-runtime/src/runtime.rs",
    """        message.state = crate::MessageState::Read;
        self.storage.put_message(message.clone())?;""",
    """        let read_at = self.clock.now_ms();
        message.state = crate::MessageState::Read;
        message.sent_at.get_or_insert(read_at);
        message.delivered_at.get_or_insert(read_at);
        message.read_at.get_or_insert(read_at);
        self.storage.put_message(message.clone())?;""",
)
replace_once(
    "common/torchat-client-runtime/src/runtime.rs",
    """            state: crate::MessageState::Delivered,
            created_at,
            sent_at: None,
            delivered_at: None,
            read_at: None,""",
    """            state: crate::MessageState::Delivered,
            created_at,
            sent_at: None,
            delivered_at: Some(created_at),
            read_at: None,""",
)
replace_once(
    "common/torchat-client-runtime/src/runtime.rs",
    """        message.state = next_state.clone();
        self.storage.put_message(message.clone())?;""",
    """        let transitioned_at = self.clock.now_ms();
        match &next_state {
            crate::MessageState::Sent => {
                message.sent_at.get_or_insert(transitioned_at);
            }
            crate::MessageState::Delivered => {
                message.sent_at.get_or_insert(transitioned_at);
                message.delivered_at.get_or_insert(transitioned_at);
            }
            crate::MessageState::Read => {
                message.sent_at.get_or_insert(transitioned_at);
                message.delivered_at.get_or_insert(transitioned_at);
                message.read_at.get_or_insert(transitioned_at);
            }
            crate::MessageState::Queued
            | crate::MessageState::Sending
            | crate::MessageState::Failed => {}
        }
        message.state = next_state.clone();
        self.storage.put_message(message.clone())?;""",
)

replace_once(
    "tools/torchat-contract-gen/src/main.rs",
    """        (\"CREATED_AT\", \"createdAt\"),
        (\"ATTEMPT_COUNT\", \"attemptCount\"),""",
    """        (\"CREATED_AT\", \"createdAt\"),
        (\"SENT_AT\", \"sentAt\"),
        (\"DELIVERED_AT\", \"deliveredAt\"),
        (\"READ_AT\", \"readAt\"),
        (\"ATTEMPT_COUNT\", \"attemptCount\"),""",
)
replace_once(
    "mobile/lib/core/models/domain.dart",
    """    this.createdAt = '',
    this.replyTo,
  });""",
    """    this.createdAt = '',
    this.sentAt,
    this.deliveredAt,
    this.readAt,
    this.replyTo,
  });""",
)
replace_once(
    "mobile/lib/core/models/domain.dart",
    """  final String createdAt;
  final MessageReply? replyTo;""",
    """  final String createdAt;
  final String? sentAt;
  final String? deliveredAt;
  final String? readAt;
  final MessageReply? replyTo;""",
)
replace_once(
    "mobile/lib/core/models/domain.dart",
    """    createdAt: _timestamp(map[EngineContract.createdAt]),
    replyTo: map[EngineContract.replyTo] is Map""",
    """    createdAt: _timestamp(map[EngineContract.createdAt]),
    sentAt: _optionalTimestamp(map[EngineContract.sentAt]),
    deliveredAt: _optionalTimestamp(map[EngineContract.deliveredAt]),
    readAt: _optionalTimestamp(map[EngineContract.readAt]),
    replyTo: map[EngineContract.replyTo] is Map""",
)
replace_once(
    "mobile/lib/core/models/domain.dart",
    """String _timestamp(Object? value) {
  if (value is num) {
    return DateTime.fromMillisecondsSinceEpoch(value.toInt()).toIso8601String();
  }
  final text = value?.toString() ?? '';
  final epoch = int.tryParse(text);
  return epoch == null
      ? text
      : DateTime.fromMillisecondsSinceEpoch(epoch).toIso8601String();
}
""",
    """String _timestamp(Object? value) {
  if (value is num) {
    return DateTime.fromMillisecondsSinceEpoch(value.toInt()).toIso8601String();
  }
  final text = value?.toString() ?? '';
  final epoch = int.tryParse(text);
  return epoch == null
      ? text
      : DateTime.fromMillisecondsSinceEpoch(epoch).toIso8601String();
}

String? _optionalTimestamp(Object? value) {
  if (value == null) return null;
  final timestamp = _timestamp(value);
  return timestamp.isEmpty ? null : timestamp;
}
""",
)

print("message timestamp patch applied")
