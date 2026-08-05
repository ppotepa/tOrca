UPDATE read_receipt_outbox
SET wire_ciphertext = COALESCE(wire_ciphertext, ?1),
    state = 'SENT', attempt_count = attempt_count + 1,
    next_attempt_at = ?2, updated_at = ?3
WHERE receipt_id = ?4 AND next_attempt_at <= ?3;
