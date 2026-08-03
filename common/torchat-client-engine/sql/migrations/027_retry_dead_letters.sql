ALTER TABLE peer_endpoint_bootstrap_outbox ADD COLUMN dead_lettered_at INTEGER;
ALTER TABLE pending_contact_confirmations ADD COLUMN dead_lettered_at INTEGER;
ALTER TABLE capability_delivery_outbox ADD COLUMN dead_lettered_at INTEGER;
ALTER TABLE pending_welcomes ADD COLUMN dead_lettered_at INTEGER;

CREATE INDEX IF NOT EXISTS idx_peer_endpoint_bootstrap_dead_letters
    ON peer_endpoint_bootstrap_outbox(dead_lettered_at, next_attempt_at);
CREATE INDEX IF NOT EXISTS idx_pending_contact_confirmations_dead_letters
    ON pending_contact_confirmations(dead_lettered_at, next_attempt_at);
CREATE INDEX IF NOT EXISTS idx_capability_delivery_dead_letters
    ON capability_delivery_outbox(dead_lettered_at, next_attempt_at);
CREATE INDEX IF NOT EXISTS idx_pending_welcomes_dead_letters
    ON pending_welcomes(dead_lettered_at, next_attempt_at);
