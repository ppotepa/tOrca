SELECT MIN(pairing_id)
FROM pairing_outbox
WHERE pair_key = ?1
  AND state IN ('PENDING', 'ACCEPTED')
  AND instr(CAST(payload AS TEXT), ?2) = 0;
