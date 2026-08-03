UPDATE capability_delivery_outbox
                 SET next_attempt_at = ?1, last_error = ?2,
                     dead_lettered_at = CASE WHEN ?2 LIKE 'permanent:%' OR ?2 LIKE 'protocol:%' THEN unixepoch() ELSE dead_lettered_at END
                 WHERE delivery_id = ?3;
