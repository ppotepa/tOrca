UPDATE pairing_inbox
SET expires_at = expires_at / 1000
WHERE expires_at > 9999999999;

UPDATE pairing_outbox
SET expires_at = expires_at / 1000
WHERE expires_at > 9999999999;
