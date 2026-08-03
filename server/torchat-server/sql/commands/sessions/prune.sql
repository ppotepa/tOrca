DELETE FROM sessions WHERE expires_at < NOW() - INTERVAL '7 days';
