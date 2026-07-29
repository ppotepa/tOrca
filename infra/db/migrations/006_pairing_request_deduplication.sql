-- One active invitation is enough for a sender/recipient pair.  Expired rows
-- are removed before the index is made, and are also pruned by the server.
DELETE FROM pending_pairings AS duplicate
USING pending_pairings AS original
WHERE duplicate.sender_installation_id = original.sender_installation_id
  AND duplicate.recipient_installation_id = original.recipient_installation_id
  AND duplicate.created_at > original.created_at;

CREATE UNIQUE INDEX IF NOT EXISTS pending_pairings_sender_recipient_unique
    ON pending_pairings(sender_installation_id, recipient_installation_id);
