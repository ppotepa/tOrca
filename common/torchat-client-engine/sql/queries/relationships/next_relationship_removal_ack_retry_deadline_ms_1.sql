SELECT MIN(next_attempt_at) FROM relationship_removal_ack_outbox
                 WHERE state IN ('PENDING', 'DISPATCHED');
