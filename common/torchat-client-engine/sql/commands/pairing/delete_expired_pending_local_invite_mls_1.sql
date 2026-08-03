DELETE FROM pending_local_invite_mls WHERE expires_at < ?1;
