SELECT i.installation_id, i.public_key, i.nickname
FROM contacts c
JOIN installations i ON i.installation_id = c.contact_installation_id
WHERE c.owner_installation_id = $1
  AND i.revoked_at IS NULL
ORDER BY i.nickname COLLATE "C"
