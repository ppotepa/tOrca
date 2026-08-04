UPDATE pairing_inbox
SET state = 'ARCHIVED', updated_at = unixepoch()
WHERE pair_key = ?1
  AND pairing_id <> ?2
  AND state IN ('PENDING', 'ACCEPTED');
