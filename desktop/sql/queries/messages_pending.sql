SELECT id, peer, outgoing, body, state, created_at, relay_payload,
       attempt_count, last_attempt_at, next_attempt_at, ack_deadline, last_transport_error
FROM messages
WHERE outgoing = 1
  AND UPPER(state) IN ('QUEUED', 'SENDING', 'SENT')
  AND next_attempt_at <= ?1
ORDER BY next_attempt_at, created_at, id;
