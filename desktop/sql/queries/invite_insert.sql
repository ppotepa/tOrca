INSERT OR IGNORE INTO used_invites (invite_id, used_at)
VALUES (?1, unixepoch());
