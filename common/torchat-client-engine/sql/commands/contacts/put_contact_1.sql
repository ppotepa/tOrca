INSERT INTO contacts (
                    installation_id, nickname, public_key, fingerprint, key_package,
                    verification, source, local_alias, muted, blocked, transport_policy, last_seen_at, created_at, updated_at
                 ) VALUES (
                    ?1, ?2, ?3, ?4, NULL, ?5, 'runtime', ?6, ?7, ?8, ?9, ?10, unixepoch(), unixepoch()
                 )
                 ON CONFLICT(installation_id) DO UPDATE SET
                    nickname = excluded.nickname,
                    public_key = excluded.public_key,
                    fingerprint = excluded.fingerprint,
                    verification = excluded.verification,
                    local_alias = excluded.local_alias,
                    muted = excluded.muted,
                    blocked = excluded.blocked,
                    transport_policy = excluded.transport_policy,
                    last_seen_at = COALESCE(excluded.last_seen_at, contacts.last_seen_at),
                    updated_at = unixepoch();
