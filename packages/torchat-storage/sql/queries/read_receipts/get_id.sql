SELECT receipt_id FROM read_receipt_outbox
WHERE contact_installation_id = ?1
  AND conversation_id = ?2
  AND message_ids_json = ?3;
