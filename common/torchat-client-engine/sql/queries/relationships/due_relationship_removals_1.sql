SELECT o.removal_id, o.contact_installation_id, t.removed_at,
                    o.relationship_epoch, o.preserve_history, o.attempt_count
             FROM relationship_removal_outbox o
             JOIN relationship_tombstones t
               ON t.contact_installation_id = o.contact_installation_id
              AND t.removal_id = o.removal_id
             WHERE o.state IN ('PENDING', 'DISPATCHED', 'WAITING_FOR_ACK')
               AND o.next_attempt_at <= ?1
             ORDER BY o.next_attempt_at ASC, o.removal_id ASC;
