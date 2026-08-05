SELECT c.installation_id, c.nickname, c.public_key, c.fingerprint,
                        c.verification, c.local_alias, c.muted, c.blocked,
                        c.transport_policy,
                        CASE WHEN p.contact_installation_id IS NULL THEN 0 ELSE 1 END
                            AS has_peer_endpoint,
                        CASE WHEN EXISTS (
                            SELECT 1 FROM capability_delivery_outbox d
                            WHERE d.contact_installation_id = c.installation_id
                        ) THEN 1 ELSE 0 END AS has_pending_peer_exchange,
                        CASE
                            WHEN p.last_connected_at IS NOT NULL
                             AND p.last_connected_at >= (unixepoch() - 120) THEN 1
                            ELSE 0
                        END AS has_recent_peer_connection,
                        p.last_connected_at,
                        c.last_seen_at
                 FROM contacts c
                 LEFT JOIN contact_peer_endpoints p
                   ON p.contact_installation_id = c.installation_id
                 ORDER BY c.updated_at DESC, c.installation_id ASC;
