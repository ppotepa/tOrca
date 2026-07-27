INSERT OR REPLACE INTO contacts
    (installation_id, nickname, public_key, fingerprint, key_package, verification, source, created_at)
VALUES (?, ?, ?, ?, ?, ?, ?, COALESCE((SELECT created_at FROM contacts WHERE installation_id = ?), ?));
