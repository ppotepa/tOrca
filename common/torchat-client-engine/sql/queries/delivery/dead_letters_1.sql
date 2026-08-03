SELECT kind, id, attempt_count, dead_lettered_at, last_error
             FROM (
                SELECT 'capability' AS kind, delivery_id AS id, attempt_count, dead_lettered_at, last_error
                FROM capability_delivery_outbox WHERE dead_lettered_at IS NOT NULL
                UNION ALL
                SELECT 'endpoint_bootstrap', contact_installation_id, attempt_count, dead_lettered_at, last_error
                FROM peer_endpoint_bootstrap_outbox WHERE dead_lettered_at IS NOT NULL
                UNION ALL
                SELECT 'contact_confirmation', pairing_id, attempt_count, dead_lettered_at, last_error
                FROM pending_contact_confirmations WHERE dead_lettered_at IS NOT NULL
                UNION ALL
                SELECT 'welcome', invite_id, attempt_count, dead_lettered_at, last_error
                FROM pending_welcomes WHERE dead_lettered_at IS NOT NULL
             ) ORDER BY dead_lettered_at DESC, kind ASC, id ASC;
