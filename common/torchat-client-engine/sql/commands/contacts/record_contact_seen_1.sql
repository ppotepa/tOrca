UPDATE contacts SET last_seen_at = ?1, updated_at = unixepoch() WHERE installation_id = ?2
