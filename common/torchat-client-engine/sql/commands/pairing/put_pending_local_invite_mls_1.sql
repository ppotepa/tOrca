INSERT INTO pending_local_invite_mls (
                    invite_id, recipient_installation_id, snapshot, expires_at
                 ) VALUES (?1, ?2, ?3, ?4)
                 ON CONFLICT(invite_id) DO UPDATE SET
                    recipient_installation_id = excluded.recipient_installation_id,
                    snapshot = excluded.snapshot,
                    expires_at = excluded.expires_at;
