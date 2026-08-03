SELECT invite_id, recipient_installation_id, snapshot, expires_at
                 FROM pending_local_invite_mls
                 WHERE invite_id = ?1 AND expires_at >= ?2;
