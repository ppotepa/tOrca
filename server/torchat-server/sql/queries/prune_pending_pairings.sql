DELETE FROM pending_pairings WHERE expires_at < NOW()
