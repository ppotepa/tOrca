SELECT pairing_id, pair_key, sender_installation_id, sender_nickname,
       sender_public_key, sender_fingerprint, capability, expires_at,
       state, offer_invite_id, offer_payload
FROM pairing_inbox
WHERE pairing_id = ?1
LIMIT 1;
