SELECT COUNT(*)
                 FROM sqlite_master
                 WHERE type = 'trigger'
                   AND name IN (
                     'record_inserted_relationship_boundary',
                     'record_reactivated_relationship_boundary',
                     'ignore_stale_relationship_removal',
                     'apply_incoming_relationship_removal',
                     'suppress_removed_relationship_mls_insert',
                     'suppress_removed_relationship_mls_update',
                     'suppress_removed_contact_endpoint_insert',
                     'suppress_removed_contact_endpoint_update'
                   );
