INSERT INTO contacts
                 (installation_id, nickname, public_key, fingerprint, verification, source)
                 VALUES ('peer-read', 'Peer', 'pk', 'fp', 'UNVERIFIED', 'test');
                 INSERT INTO conversations (id, contact_installation_id, state)
                 VALUES ('peer-read', 'peer-read', 'ESTABLISHED');
