UPDATE delivery_receipts
SET dead_lettered_at = unixepoch(), last_error_code = ?1
WHERE message_id = ?2;
