CREATE TABLE IF NOT EXISTS queue_items (
  id TEXT PRIMARY KEY,
  recipient TEXT NOT NULL,
  payload BLOB NOT NULL,
  state TEXT NOT NULL,
  attempt INTEGER NOT NULL DEFAULT 0,
  next_attempt_at INTEGER NOT NULL DEFAULT 0,
  lease_until INTEGER,
  last_error TEXT
);
CREATE INDEX IF NOT EXISTS idx_queue_due
  ON queue_items(state, next_attempt_at);
