use rusqlite::Row;
use torchat_client_runtime::{ChatMessage, RuntimeError, RuntimeResult};

type StoredMessageRow = (
    String,
    String,
    i64,
    String,
    Option<String>,
    String,
    i64,
    i64,
    Option<i64>,
    i64,
    Option<i64>,
    Option<String>,
);

pub(super) fn stored_message_row(row: &Row<'_>) -> rusqlite::Result<StoredMessageRow> {
    Ok((
        row.get::<_, String>("id")?,
        row.get::<_, String>("conversation_id")?,
        row.get::<_, i64>("outgoing")?,
        row.get::<_, String>("body")?,
        row.get::<_, Option<String>>("reply_to_json")?,
        row.get::<_, String>("state")?,
        row.get::<_, i64>("created_at")?,
        row.get::<_, i64>("attempt_count")?,
        row.get::<_, Option<i64>>("last_attempt_at")?,
        row.get::<_, i64>("next_attempt_at")?,
        row.get::<_, Option<i64>>("ack_deadline")?,
        row.get::<_, Option<String>>("last_transport_error")?,
    ))
}

pub(super) fn decode_stored_message(row: StoredMessageRow) -> RuntimeResult<ChatMessage> {
    let (
        id,
        conversation_id,
        outgoing,
        body,
        reply_to_json,
        state,
        created_at,
        attempt_count,
        last_attempt_at,
        next_attempt_at,
        ack_deadline,
        last_transport_error,
    ) = row;
    Ok(ChatMessage {
        id,
        conversation_id,
        outgoing: outgoing != 0,
        body,
        reply_to: decode_reply(reply_to_json)?,
        state: super::state_codecs::message(state)?,
        created_at,
        attempt_count: attempt_count as u32,
        last_attempt_at,
        next_attempt_at,
        ack_deadline,
        last_transport_error,
    })
}

pub(super) fn encode_reply(
    reply: Option<torchat_client_runtime::MessageReply>,
) -> RuntimeResult<Option<String>> {
    reply
        .map(|value| {
            serde_json::to_string(&value).map_err(|error| RuntimeError::Storage(error.to_string()))
        })
        .transpose()
}

pub(super) fn decode_reply(
    value: Option<String>,
) -> RuntimeResult<Option<torchat_client_runtime::MessageReply>> {
    value
        .map(|value| {
            serde_json::from_str(&value).map_err(|error| RuntimeError::Storage(error.to_string()))
        })
        .transpose()
}

#[cfg(test)]
mod tests {
    use super::{decode_reply, encode_reply};

    #[test]
    fn empty_reply_round_trips_without_payload() {
        assert_eq!(decode_reply(encode_reply(None).unwrap()).unwrap(), None);
    }
}
