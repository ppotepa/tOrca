ALTER TABLE pending_local_invite_mls
    ADD COLUMN local_capability_id TEXT NOT NULL DEFAULT '';
ALTER TABLE pending_local_invite_mls
    ADD COLUMN local_capability_secret BLOB NOT NULL DEFAULT X'';
