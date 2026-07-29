CREATE INDEX IF NOT EXISTS idx_conversations_last_message
ON conversations(last_message_at DESC, id ASC);

CREATE INDEX IF NOT EXISTS idx_messages_conversation_created
ON messages(conversation_id, created_at ASC, id ASC);

CREATE INDEX IF NOT EXISTS idx_messages_retry
ON messages(outgoing, state, next_attempt_at, created_at, id);

CREATE INDEX IF NOT EXISTS idx_messages_ack_deadline
ON messages(outgoing, state, ack_deadline, created_at, id);

CREATE INDEX IF NOT EXISTS idx_delivery_receipts_retry
ON delivery_receipts(state, next_attempt_at, created_at, envelope_id);

CREATE INDEX IF NOT EXISTS idx_pending_welcomes_retry
ON pending_welcomes(expires_at, next_attempt_at, invite_id);

CREATE INDEX IF NOT EXISTS idx_pairing_inbox_response_retry
ON pairing_inbox(response_delivered, state, expires_at, next_attempt_at, pairing_id);

CREATE INDEX IF NOT EXISTS idx_pairing_outbox_retry
ON pairing_outbox(state, expires_at, next_attempt_at, pairing_id);
