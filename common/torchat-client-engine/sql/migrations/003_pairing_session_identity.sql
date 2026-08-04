ALTER TABLE pairing_inbox ADD COLUMN pair_key TEXT;
ALTER TABLE pairing_outbox ADD COLUMN pair_key TEXT;

CREATE UNIQUE INDEX unique_active_pairing_inbox_pair
ON pairing_inbox(pair_key)
WHERE pair_key IS NOT NULL AND state IN ('PENDING', 'ACCEPTED');

CREATE UNIQUE INDEX unique_active_pairing_outbox_pair
ON pairing_outbox(pair_key)
WHERE pair_key IS NOT NULL AND state IN ('PENDING', 'ACCEPTED');
