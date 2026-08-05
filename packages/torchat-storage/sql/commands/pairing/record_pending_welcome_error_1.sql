UPDATE pending_welcomes
                 SET last_error = ?1,
                     dead_lettered_at = CASE WHEN ?1 LIKE 'permanent:%' OR ?1 LIKE 'protocol:%' THEN unixepoch() ELSE dead_lettered_at END
                 WHERE invite_id = ?2;
