-- Relationship lifecycle is owned by the typed runtime transition.
-- Keep schema constraints in SQL, but remove lifecycle side effects and
-- resurrection guards implemented by the former trigger workflow.
DROP TRIGGER IF EXISTS record_inserted_relationship_boundary;
DROP TRIGGER IF EXISTS record_reactivated_relationship_boundary;
DROP TRIGGER IF EXISTS ignore_stale_relationship_removal;
DROP TRIGGER IF EXISTS apply_incoming_relationship_removal;
DROP TRIGGER IF EXISTS suppress_removed_relationship_mls_insert;
DROP TRIGGER IF EXISTS suppress_removed_relationship_mls_update;
DROP TRIGGER IF EXISTS suppress_removed_contact_endpoint_insert;
DROP TRIGGER IF EXISTS suppress_removed_contact_endpoint_update;
