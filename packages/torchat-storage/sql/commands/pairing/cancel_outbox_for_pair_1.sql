UPDATE pairing_outbox
SET state = 'CANCELLED', updated_at = unixepoch()
WHERE pair_key = ?1
  AND pairing_id <> ?2
  AND state IN ('PENDING', 'ACCEPTED');
