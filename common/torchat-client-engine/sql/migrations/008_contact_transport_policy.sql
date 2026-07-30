ALTER TABLE contacts
    ADD COLUMN transport_policy TEXT NOT NULL DEFAULT 'PEER_ONLY';

UPDATE contacts
SET transport_policy = 'RELAY_ONLY';
