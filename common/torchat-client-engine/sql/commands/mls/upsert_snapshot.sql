INSERT INTO conversation_mls (conversation_id, snapshot, state_version, snapshot_hash, updated_at)
VALUES (?1, ?2, 1, ?3, unixepoch())
ON CONFLICT(conversation_id) DO UPDATE SET snapshot = excluded.snapshot,
    state_version = conversation_mls.state_version + 1,
    snapshot_hash = excluded.snapshot_hash,
    updated_at = excluded.updated_at;
