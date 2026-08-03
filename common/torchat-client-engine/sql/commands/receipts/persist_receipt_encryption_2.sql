UPDATE delivery_receipts SET claimed_until = ?1, last_error_code = NULL WHERE message_id = ?2;
