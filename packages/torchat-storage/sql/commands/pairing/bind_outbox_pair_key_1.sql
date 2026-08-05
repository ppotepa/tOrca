UPDATE pairing_outbox
SET pair_key = ?1, updated_at = unixepoch()
WHERE state IN ('PENDING', 'ACCEPTED')
  AND instr(CAST(payload AS TEXT), ?2) > 0;
