ALTER TABLE conversation_mls ADD COLUMN state_version INTEGER NOT NULL DEFAULT 0;
ALTER TABLE conversation_mls ADD COLUMN snapshot_hash BLOB;

UPDATE conversation_mls
SET state_version = 1
WHERE state_version = 0;
