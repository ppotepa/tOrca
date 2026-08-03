SELECT EXISTS(SELECT 1 FROM used_invites WHERE invite_id = ?1) AS used;
