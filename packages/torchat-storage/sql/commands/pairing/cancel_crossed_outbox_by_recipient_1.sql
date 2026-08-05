UPDATE pairing_outbox
SET state = 'CANCELLED', pair_key = ?1, updated_at = unixepoch()
WHERE recipient_installation_id = ?2
  AND pairing_id <> ?3
  AND state IN ('PENDING', 'ACCEPTED');
