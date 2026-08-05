DELETE FROM processed_commands
WHERE rowid IN (
    SELECT rowid FROM processed_commands
    ORDER BY created_at ASC, rowid ASC
    LIMIT MAX((SELECT COUNT(*) FROM processed_commands) - ?1, 0)
);
