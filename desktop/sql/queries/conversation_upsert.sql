INSERT INTO conversations (
    id,
    contact_installation_id,
    status,
    last_message_preview,
    last_message_at,
    unread_count,
    updated_at
)
VALUES (
    ?1,
    ?2,
    ?3,
    ?4,
    ?5,
    ?6,
    unixepoch('subsec') * 1000
)
ON CONFLICT(id) DO UPDATE SET
    contact_installation_id = excluded.contact_installation_id,
    status = excluded.status,
    last_message_preview = excluded.last_message_preview,
    last_message_at = excluded.last_message_at,
    unread_count = excluded.unread_count,
    updated_at = excluded.updated_at;
