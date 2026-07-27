INSERT OR REPLACE INTO conversations
    (id, contact_installation_id, mls_state, status, unread_count, last_message_preview, last_message_at)
VALUES (?, ?, ?, ?, ?, ?, ?);
