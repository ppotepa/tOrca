UPDATE conversations SET state = 'OFFLINE', updated_at = unixepoch() WHERE contact_installation_id = ?1;
