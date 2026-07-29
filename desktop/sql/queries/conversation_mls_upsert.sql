INSERT INTO conversation_mls (
    conversation_id,
    snapshot,
    updated_at
)
VALUES (
    ?1,
    ?2,
    unixepoch('subsec') * 1000
)
ON CONFLICT(conversation_id) DO UPDATE SET
    snapshot = excluded.snapshot,
    updated_at = excluded.updated_at;
