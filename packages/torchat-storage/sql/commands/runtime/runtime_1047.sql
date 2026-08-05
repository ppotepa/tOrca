INSERT INTO conversations (
                    id, contact_installation_id, state, unread_count,
                    last_message_preview, last_message_at, created_at, updated_at
                 ) VALUES (
                    ?1, ?2, ?3, ?4, ?5, ?6, unixepoch(), unixepoch()
                 )
                 ON CONFLICT(id) DO UPDATE SET
                    contact_installation_id = excluded.contact_installation_id,
                    state = excluded.state,
                    unread_count = excluded.unread_count,
                    last_message_preview = excluded.last_message_preview,
                    last_message_at = excluded.last_message_at,
                    updated_at = unixepoch();
