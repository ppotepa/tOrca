ALTER TABLE pairing_inbox
ADD COLUMN attempt_count INTEGER NOT NULL DEFAULT 0;

ALTER TABLE pairing_inbox
ADD COLUMN next_attempt_at INTEGER NOT NULL DEFAULT 0;

ALTER TABLE pairing_inbox
ADD COLUMN last_error TEXT;

