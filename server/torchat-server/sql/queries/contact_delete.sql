DELETE FROM contacts
WHERE owner_installation_id = $1 AND contact_installation_id = $2
