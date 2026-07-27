DELETE FROM pairing_codes WHERE expires_at < NOW()
