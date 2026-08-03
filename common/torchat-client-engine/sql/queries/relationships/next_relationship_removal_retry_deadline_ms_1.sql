SELECT MIN(next_attempt_at) FROM relationship_removal_outbox
                 WHERE state IN ('PENDING', 'DISPATCHED', 'WAITING_FOR_ACK');
