SELECT conversation_id, snapshot, state_version, snapshot_hash
                 FROM conversation_mls WHERE conversation_id = ?1;
