INSERT INTO contacts (
                    installation_id, nickname, public_key, fingerprint,
                    verification, source, created_at, updated_at, transport_policy
                 ) VALUES (
                    'contact-1', 'Alice', 'pk', 'fp',
                    'VERIFIED', 'PAIRING', 1, 1, 'PEER_ONLY'
                 );
