-- Typed RelationshipRemoved application payloads now own this workflow.
-- Remove the historical SQL triggers; the legacy text prefix is never
-- authoritative and may only be displayed as an old message.
DROP TRIGGER IF EXISTS ignore_stale_relationship_removal;
DROP TRIGGER IF EXISTS apply_incoming_relationship_removal;
