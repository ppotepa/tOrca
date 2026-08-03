UPDATE outbound_deliveries SET claimed_until = NULL, last_error_code = NULL WHERE message_id = ?1;
