SELECT message_id, contact_installation_id, sequence, state,
                        attempt_count, next_attempt_at, ack_deadline, last_error, created_at
                 FROM outbound_deliveries
                 WHERE message_id = ?1;
