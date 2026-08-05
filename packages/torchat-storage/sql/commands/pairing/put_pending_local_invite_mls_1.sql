INSERT INTO pending_local_invite_mls (
                    invite_id, recipient_installation_id, snapshot,
                    local_capability_id, local_capability_secret, expires_at
                 ) VALUES (?1, ?2, ?3, ?4, ?5, ?6)
                 ON CONFLICT(invite_id) DO UPDATE SET
                    recipient_installation_id = excluded.recipient_installation_id,
                    snapshot = excluded.snapshot,
                    local_capability_id = excluded.local_capability_id,
                    local_capability_secret = excluded.local_capability_secret,
                    expires_at = excluded.expires_at;
