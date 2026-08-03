INSERT INTO contacts (owner_installation_id, contact_installation_id)
VALUES ($1, $2), ($2, $1)
ON CONFLICT DO NOTHING;
