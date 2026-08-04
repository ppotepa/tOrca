SELECT MIN(pairing_id)
FROM pairing_outbox
WHERE state IN ('PENDING', 'ACCEPTED')
  AND instr(CAST(payload AS TEXT), ?1) > 0;
