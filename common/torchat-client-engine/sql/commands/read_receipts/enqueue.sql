INSERT INTO read_receipt_outbox (
    receipt_id, contact_installation_id, conversation_id,
    message_ids_json, read_at, state, next_attempt_at,
    created_at, updated_at
) VALUES (?1, ?2, ?3, ?4, ?5, 'QUEUED', ?6, ?6, ?6)
ON CONFLICT(contact_installation_id, conversation_id, message_ids_json)
DO UPDATE SET read_at = MAX(read_receipt_outbox.read_at, excluded.read_at),
              next_attempt_at = MIN(read_receipt_outbox.next_attempt_at, excluded.next_attempt_at),
              updated_at = excluded.updated_at;
