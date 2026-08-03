SELECT MIN(next_attempt_at) FROM read_receipt_outbox
WHERE UPPER(state) IN ('QUEUED', 'SENT');
