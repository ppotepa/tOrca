SELECT installation_id, public_key, fingerprint, nickname
FROM contacts
ORDER BY nickname COLLATE NOCASE;
