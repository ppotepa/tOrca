INSERT INTO contacts (
                    installation_id, nickname, public_key, fingerprint,
                    verification, source, created_at, updated_at, transport_policy
                 ) VALUES
                    ('contact-1', 'Alice', 'pk-1', 'fp-1', 'VERIFIED', 'PAIRING', 1, 1, 'PEER_ONLY'),
                    ('contact-2', 'Bob', 'pk-2', 'fp-2', 'VERIFIED', 'PAIRING', 1, 1, 'PEER_ONLY');
                 INSERT INTO conversations (
                    id, contact_installation_id, state, unread_count, last_message_preview,
                    last_message_at, created_at, updated_at
                 ) VALUES
                    ('conversation-1', 'contact-1', 'ACTIVE', 0, NULL, NULL, 1, 1),
                    ('conversation-2', 'contact-2', 'ACTIVE', 0, NULL, NULL, 1, 1);
                 INSERT INTO messages (
                    id, conversation_id, outgoing, body, state, created_at,
                    relay_payload, ciphertext_hash, attempt_count, last_attempt_at,
                    next_attempt_at, ack_deadline, last_transport_error
                 ) VALUES
                    ('message-1', 'conversation-1', 1, 'hello', 'QUEUED', 100, NULL, NULL, 0, NULL, 0, NULL, NULL),
                    ('message-2', 'conversation-2', 1, 'hello', 'QUEUED', 200, NULL, NULL, 0, NULL, 0, NULL, NULL);
                 INSERT INTO outbound_deliveries (
                    message_id, contact_installation_id, sequence, state,
                    attempt_count, next_attempt_at, created_at, updated_at
                 ) VALUES
                    ('message-1', 'contact-1', 1, 'QUEUED', 0, 3456, 100, unixepoch()),
                    ('message-2', 'contact-2', 1, 'QUEUED', 0, 7890, 200, unixepoch());
