-- Durable terminal record for deliveries that exceeded the retry budget.
-- Payloads stay in their source tables; this table is only an auditable index.
CREATE TABLE IF NOT EXISTS delivery_dead_letters (
    kind TEXT NOT NULL,
    item_id TEXT NOT NULL,
    contact_installation_id TEXT,
    attempt_count INTEGER NOT NULL,
    last_error TEXT NOT NULL,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL,
    PRIMARY KEY (kind, item_id)
);

CREATE INDEX IF NOT EXISTS idx_delivery_dead_letters_updated
    ON delivery_dead_letters(updated_at, kind);
