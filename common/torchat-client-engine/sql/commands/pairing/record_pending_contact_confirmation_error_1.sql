UPDATE pending_contact_confirmations
                 SET last_error = ?1,
                     dead_lettered_at = CASE WHEN ?1 LIKE 'permanent:%' OR ?1 LIKE 'protocol:%' THEN unixepoch() ELSE dead_lettered_at END,
                     updated_at = unixepoch()
                 WHERE pairing_id = ?2;
