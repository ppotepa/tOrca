WITH winner AS (
    SELECT MIN(pairing_id) AS pairing_id FROM (
        SELECT pairing_id FROM pairing_inbox
        WHERE pair_key = ?1 AND state IN ('PENDING', 'ACCEPTED')
        UNION ALL
        SELECT pairing_id FROM pairing_outbox
        WHERE pair_key = ?1 AND state IN ('PENDING', 'ACCEPTED')
    )
)
UPDATE pairing_outbox
SET state = 'CANCELLED', updated_at = unixepoch()
WHERE pair_key = ?1
  AND state IN ('PENDING', 'ACCEPTED')
  AND pairing_id <> (SELECT pairing_id FROM winner);
