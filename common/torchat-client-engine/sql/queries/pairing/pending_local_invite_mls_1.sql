SELECT invite_id, recipient_installation_id, snapshot,
       local_capability_id, local_capability_secret, expires_at
                 FROM pending_local_invite_mls
                 WHERE invite_id = ?1 AND expires_at >= ?2;
