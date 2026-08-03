DELETE FROM pending_welcomes WHERE expires_at < ?1;
