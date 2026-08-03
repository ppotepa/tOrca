SELECT removal_id, contact_installation_id, payload, attempt_count
             FROM relationship_removal_ack_outbox
             WHERE state IN ('PENDING', 'DISPATCHED') AND next_attempt_at <= ?1
             ORDER BY next_attempt_at, removal_id;
