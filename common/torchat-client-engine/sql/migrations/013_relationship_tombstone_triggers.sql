CREATE TABLE IF NOT EXISTS relationship_tombstones (
    contact_installation_id TEXT PRIMARY KEY,
    removed_at INTEGER NOT NULL,
    preserve_history INTEGER NOT NULL DEFAULT 1
);

CREATE TRIGGER IF NOT EXISTS contacts_relationship_removed_after_update
AFTER UPDATE OF blocked ON contacts
WHEN OLD.blocked = 0 AND NEW.blocked = 1
BEGIN
    INSERT INTO relationship_tombstones (
        contact_installation_id,
        removed_at,
        preserve_history
    ) VALUES (
        NEW.installation_id,
        CAST(unixepoch('now') * 1000 AS INTEGER),
        1
    )
    ON CONFLICT(contact_installation_id) DO UPDATE SET
        removed_at = MAX(
            relationship_tombstones.removed_at,
            excluded.removed_at
        );

    UPDATE conversations
    SET state = 'OFFLINE', updated_at = unixepoch()
    WHERE contact_installation_id = NEW.installation_id;

    UPDATE messages
    SET state = 'FAILED',
        next_attempt_at = 0,
        ack_deadline = NULL,
        last_transport_error = 'relationship removed'
    WHERE conversation_id IN (
        SELECT id
        FROM conversations
        WHERE contact_installation_id = NEW.installation_id
    )
      AND outgoing = 1
      AND UPPER(state) IN ('QUEUED', 'SENDING')
      AND body NOT LIKE 'torchat-relationship-removed-v1:%';

    DELETE FROM outbound_deliveries
    WHERE contact_installation_id = NEW.installation_id
      AND message_id NOT IN (
          SELECT id
          FROM messages
          WHERE body LIKE 'torchat-relationship-removed-v1:%'
      );

    DELETE FROM delivery_receipts
    WHERE conversation_id IN (
        SELECT id
        FROM conversations
        WHERE contact_installation_id = NEW.installation_id
    );

    DELETE FROM conversation_mls
    WHERE conversation_id IN (
        SELECT id
        FROM conversations
        WHERE contact_installation_id = NEW.installation_id
    );

    DELETE FROM contact_peer_endpoints
    WHERE contact_installation_id = NEW.installation_id;

    DELETE FROM endpoint_update_outbox
    WHERE contact_installation_id = NEW.installation_id;

    DELETE FROM peer_endpoint_bootstrap_outbox
    WHERE contact_installation_id = NEW.installation_id;

    DELETE FROM pending_contact_confirmations
    WHERE peer_installation_id = NEW.installation_id;

    DELETE FROM pending_peer_endpoint_inbox
    WHERE contact_installation_id = NEW.installation_id;
END;

CREATE TRIGGER IF NOT EXISTS contacts_relationship_reactivated_after_update
AFTER UPDATE OF blocked, verification ON contacts
WHEN OLD.blocked = 1
 AND NEW.blocked = 0
 AND UPPER(NEW.verification) = 'VERIFIED'
BEGIN
    DELETE FROM relationship_tombstones
    WHERE contact_installation_id = NEW.installation_id;

    DELETE FROM outbound_deliveries
    WHERE message_id IN (
        SELECT id
        FROM messages
        WHERE conversation_id IN (
            SELECT id
            FROM conversations
            WHERE contact_installation_id = NEW.installation_id
        )
          AND body LIKE 'torchat-relationship-removed-v1:%'
    );

    DELETE FROM messages
    WHERE conversation_id IN (
        SELECT id
        FROM conversations
        WHERE contact_installation_id = NEW.installation_id
    )
      AND body LIKE 'torchat-relationship-removed-v1:%';
END;

CREATE TRIGGER IF NOT EXISTS contacts_relationship_reactivated_after_insert
AFTER INSERT ON contacts
WHEN NEW.blocked = 0 AND UPPER(NEW.verification) = 'VERIFIED'
BEGIN
    DELETE FROM relationship_tombstones
    WHERE contact_installation_id = NEW.installation_id;
END;
