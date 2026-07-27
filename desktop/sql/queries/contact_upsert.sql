INSERT INTO contacts
    (installation_id, public_key, fingerprint, nickname, source, verification)
VALUES (?1, ?2, ?3, ?4, ?5, 'UNVERIFIED')
ON CONFLICT(installation_id) DO UPDATE SET
    public_key = excluded.public_key,
    fingerprint = excluded.fingerprint,
    nickname = excluded.nickname,
    source = excluded.source;
