UPDATE contacts SET blocked = 1, updated_at = unixepoch() WHERE installation_id = ?1;
