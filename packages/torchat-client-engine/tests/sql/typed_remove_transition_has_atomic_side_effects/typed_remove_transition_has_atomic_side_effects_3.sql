SELECT c.blocked, o.state, t.relationship_epoch
               FROM contacts c
               JOIN relationship_removal_outbox o ON o.removal_id = 'removal-transition'
               JOIN relationship_tombstones t ON t.contact_installation_id = c.installation_id
              WHERE c.installation_id = 'peer-transition';
