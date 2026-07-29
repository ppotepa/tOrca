SELECT *
FROM messages
WHERE outgoing = 1
  AND UPPER(state) IN ('QUEUED', 'SENDING', 'SENT')
  AND next_attempt_at <= ?1
ORDER BY next_attempt_at, created_at, id;
