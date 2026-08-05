UPDATE pairing_outbox
SET state = 'CANCELLED', updated_at = unixepoch()
WHERE state IN ('PENDING', 'ACCEPTED')
  AND instr(CAST(payload AS TEXT), ?1) > 0;
