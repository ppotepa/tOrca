SELECT receipt_id, contact_installation_id, conversation_id,
    message_ids_json, read_at, wire_ciphertext, state,
    attempt_count, next_attempt_at, last_error, created_at
FROM read_receipt_outbox WHERE receipt_id = ?1;
