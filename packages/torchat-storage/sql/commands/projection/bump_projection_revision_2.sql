INSERT INTO conversation_projection_revisions (conversation_id, revision)
                     VALUES (?1, ?2)
                     ON CONFLICT(conversation_id) DO UPDATE SET revision = excluded.revision;
