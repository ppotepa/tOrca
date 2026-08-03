# Relationship transition inventory

Migration `014_runtime_integrity.sql` contains historical SQL side effects.
The typed Rust boundary is the owner for new writes; this table is the audit
map used before removing any remaining trigger.

| SQL effect | Typed Rust owner | Invariant |
| --- | --- | --- |
| `record_inserted_message_state_timestamps` | message storage/state transition helpers | state timestamps are written with the message mutation |
| `record_inserted_relationship_boundary` | `SqliteRuntimeStorage::begin_verified_relationship` | accepted pairing creates/advances one boundary in the same transaction |
| `record_reactivated_relationship_boundary` | `begin_verified_relationship` | re-pair advances epoch and clears only the matching tombstone |
| `ignore_stale_relationship_removal` | typed removal handler + `relationship_epoch` guard | stale removal has no side effect and is still consumed at the protocol layer |
| `apply_incoming_relationship_removal` | `RuntimeStorage::remove_relationship_with_id` | tombstone, blocked contact, failed pending messages and typed outbox are atomic |
| `suppress_removed_relationship_mls_insert/update` | `put_conversation_mls_snapshot` transaction guard | removed relationships cannot recreate MLS state |
| `suppress_removed_contact_endpoint_insert/update` | endpoint storage guard | removed relationships cannot recreate endpoint state |

Migration `026_remove_legacy_relationship_triggers.sql` already drops the two
legacy text-removal triggers. The remaining triggers must not be dropped until
each row above has an equivalent regression test and a release migration.
