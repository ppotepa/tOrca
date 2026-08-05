SELECT 1 FROM pairing_outbox
WHERE pair_key = ?1 AND pairing_id < ?2
  AND state IN ('PENDING', 'ACCEPTED') LIMIT 1
