UPDATE read_receipt_outbox
SET state = 'QUEUED', wire_ciphertext = wire_ciphertext,
    next_attempt_at = ?2, last_error = ?3, updated_at = unixepoch()
WHERE receipt_id = ?1;
