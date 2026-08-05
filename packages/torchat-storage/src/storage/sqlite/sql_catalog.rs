//! Compile-time SQL catalog. Domain modules must use these constants or their
//! domain repository catalog; SQL text must never be assembled at runtime.

pub(crate) mod metadata {
    pub(crate) const SCHEMA_MIGRATIONS_TABLE_EXISTS: &str =
        include_str!("../../../sql/queries/metadata/schema_migrations_table_exists.sql");
    pub(crate) const MIGRATION_INSERT: &str =
        include_str!("../../../sql/commands/metadata/insert_schema_migration.sql");
}

pub(crate) mod delivery {
    pub(crate) const RECORD_DEAD_LETTER: &str =
        include_str!("../../../sql/commands/delivery/record_delivery_dead_letter_1.sql");
}

pub(crate) mod contacts {
    pub(crate) const RECORD_SEEN: &str =
        include_str!("../../../sql/commands/contacts/record_contact_seen_1.sql");
}

pub(crate) mod messages {
    pub(crate) const GET_BY_ID: &str = include_str!("../../../sql/queries/messages/message_1.sql");
    pub(crate) const ENQUEUE_OUTBOUND_DELIVERY: &str =
        include_str!("../../../sql/commands/messages/enqueue_outbound_delivery_1.sql");
    pub(crate) const DUE_OUTBOUND_DELIVERIES: &str =
        include_str!("../../../sql/queries/messages/due_outbound_deliveries_1.sql");
    pub(crate) const OUTBOUND_DELIVERY: &str =
        include_str!("../../../sql/queries/messages/outbound_delivery_1.sql");
    pub(crate) const NEXT_CONTACT_PEER_RETRY_DEADLINE_MS: &str =
        include_str!("../../../sql/queries/messages/next_contact_peer_retry_deadline_ms_1.sql");
    pub(crate) const NEXT_CONTACT_RECEIPT_RETRY_DEADLINE_MS: &str =
        include_str!("../../../sql/queries/messages/next_contact_receipt_retry_deadline_ms_1.sql");
    pub(crate) const CLAIM_OUTBOUND_DELIVERY: &str =
        include_str!("../../../sql/commands/messages/claim_outbound_delivery_1.sql");
    pub(crate) const REQUEUE_OUTBOUND_DELIVERY: &str =
        include_str!("../../../sql/commands/messages/requeue_outbound_delivery_1.sql");
    pub(crate) const REQUEUE_OUTBOUND_DELIVERY_AFTER_DISCONNECT: &str =
        include_str!("../../../sql/commands/messages/requeue_outbound_delivery_2.sql");
    pub(crate) const COMPLETE_OUTBOUND_DELIVERY: &str =
        include_str!("../../../sql/commands/messages/complete_outbound_delivery_1.sql");
    pub(crate) const EXPEDITE_PEER_DELIVERIES: &str =
        include_str!("../../../sql/commands/messages/expedite_peer_deliveries_1.sql");
    pub(crate) const EXPEDITE_PEER_DELIVERIES_BY_CONTACT: &str =
        include_str!("../../../sql/commands/messages/expedite_peer_deliveries_2.sql");
    pub(crate) const REQUEUE_PEER_DELIVERIES: &str =
        include_str!("../../../sql/commands/messages/requeue_peer_deliveries_1.sql");
    pub(crate) const REQUEUE_PEER_DELIVERIES_AFTER_DISCONNECT: &str =
        include_str!("../../../sql/commands/messages/requeue_peer_deliveries_2.sql");
    pub(crate) const STORE_INBOUND_PEER_ENVELOPE: &str =
        include_str!("../../../sql/queries/messages/store_inbound_peer_envelope_1.sql");
    pub(crate) const STORE_INBOUND_PEER_ENVELOPE_STATE: &str =
        include_str!("../../../sql/commands/messages/store_inbound_peer_envelope_2.sql");
    pub(crate) const PENDING_INBOUND_PEER_ENVELOPES: &str =
        include_str!("../../../sql/queries/messages/pending_inbound_peer_envelopes_1.sql");
    pub(crate) const REJECTED_INBOUND_PEER_SENDERS: &str =
        include_str!("../../../sql/queries/messages/rejected_inbound_peer_senders_1.sql");
    pub(crate) const COMPLETE_INBOUND_PEER_ENVELOPE: &str =
        include_str!("../../../sql/commands/messages/complete_inbound_peer_envelope_1.sql");
    pub(crate) const REJECT_INBOUND_PEER_ENVELOPE: &str =
        include_str!("../../../sql/commands/messages/reject_inbound_peer_envelope_1.sql");
    pub(crate) const MARK_DEAD_LETTERED: &str =
        include_str!("../../../sql/commands/messages/mark_dead_lettered.sql");
}

pub(crate) mod pairing {
    pub(crate) const CANCEL_OUTBOX_FOR_PAIR: &str =
        include_str!("../../../sql/commands/pairing/cancel_outbox_for_pair_1.sql");
    pub(crate) const CANDIDATE_OUTBOX_FOR_INVITE: &str =
        include_str!("../../../sql/queries/pairing/candidate_outbox_for_invite_1.sql");
    pub(crate) const EXISTING_OUTBOX_FOR_PAIR: &str =
        include_str!("../../../sql/queries/pairing/existing_outbox_for_pair_1.sql");
    pub(crate) const CANCEL_OUTBOX_FOR_INVITE: &str =
        include_str!("../../../sql/commands/pairing/cancel_outbox_for_invite_1.sql");
    pub(crate) const BIND_OUTBOX_PAIR_KEY: &str =
        include_str!("../../../sql/commands/pairing/bind_outbox_pair_key_1.sql");
    pub(crate) const RECONCILE_PAIRING_INBOX: &str =
        include_str!("../../../sql/commands/pairing/reconcile_pairing_inbox_1.sql");
    pub(crate) const RECONCILE_PAIRING_OUTBOX: &str =
        include_str!("../../../sql/commands/pairing/reconcile_pairing_outbox_1.sql");
    pub(crate) const INVITE_USED: &str =
        include_str!("../../../sql/queries/pairing/invite_used_1.sql");
    pub(crate) const CONSUME_INVITE: &str =
        include_str!("../../../sql/commands/pairing/consume_invite_1.sql");
    pub(crate) const PUT_PENDING_LOCAL_INVITE_MLS: &str =
        include_str!("../../../sql/commands/pairing/put_pending_local_invite_mls_1.sql");
    pub(crate) const PENDING_LOCAL_INVITE_MLS: &str =
        include_str!("../../../sql/queries/pairing/pending_local_invite_mls_1.sql");
    pub(crate) const DELETE_EXPIRED_PENDING_LOCAL_INVITE_MLS: &str =
        include_str!("../../../sql/commands/pairing/delete_expired_pending_local_invite_mls_1.sql");
    pub(crate) const PENDING_WELCOMES: &str =
        include_str!("../../../sql/queries/pairing/pending_welcomes_1.sql");
    pub(crate) const PENDING_WELCOME: &str =
        include_str!("../../../sql/queries/pairing/pending_welcome_1.sql");
    pub(crate) const PUT_PENDING_WELCOME: &str =
        include_str!("../../../sql/commands/pairing/put_pending_welcome_1.sql");
    pub(crate) const REMOVE_PENDING_WELCOME: &str =
        include_str!("../../../sql/commands/pairing/remove_pending_welcome_1.sql");
    pub(crate) const PUT_PENDING_PEER_ENDPOINT_INBOX: &str =
        include_str!("../../../sql/commands/pairing/put_pending_peer_endpoint_inbox_1.sql");
    pub(crate) const PENDING_PEER_ENDPOINT_INBOX: &str =
        include_str!("../../../sql/queries/pairing/pending_peer_endpoint_inbox_1.sql");
    pub(crate) const REMOVE_PENDING_PEER_ENDPOINT_INBOX: &str =
        include_str!("../../../sql/commands/pairing/remove_pending_peer_endpoint_inbox_1.sql");
}

pub(crate) mod receipts {
    pub(crate) const RECEIVED_ENVELOPE: &str =
        include_str!("../../../sql/queries/receipts/received_envelope_1.sql");
    pub(crate) const PUT_RECEIVED_ENVELOPE: &str =
        include_str!("../../../sql/commands/receipts/put_received_envelope_1.sql");
    pub(crate) const DELIVERY_RECEIPT: &str =
        include_str!("../../../sql/queries/receipts/delivery_receipt_1.sql");
    pub(crate) const PUT_DELIVERY_RECEIPT: &str =
        include_str!("../../../sql/commands/receipts/put_delivery_receipt_1.sql");
    pub(crate) const PERSIST_RECEIPT_ENCRYPTION: &str =
        include_str!("../../../sql/commands/receipts/persist_receipt_encryption_1.sql");
    pub(crate) const PERSIST_RECEIPT_ENCRYPTION_RETRY: &str =
        include_str!("../../../sql/commands/receipts/persist_receipt_encryption_2.sql");
    pub(crate) const PERSIST_RECEIPT_ENCRYPTION_CLAIM: &str =
        include_str!("../../../sql/commands/receipts/persist_receipt_encryption_3.sql");
    pub(crate) const PERSIST_RECEIPT_ENCRYPTION_COMPLETE: &str =
        include_str!("../../../sql/commands/receipts/persist_receipt_encryption_4.sql");
    pub(crate) const CLAIM_RECEIPT_ATTEMPT: &str =
        include_str!("../../../sql/commands/receipts/claim_receipt_attempt_1.sql");
    pub(crate) const CLAIM_RECEIPT_ATTEMPT_RETRY: &str =
        include_str!("../../../sql/commands/receipts/claim_receipt_attempt_2.sql");
    pub(crate) const CLAIM_RECEIPT_ATTEMPT_COMPLETE: &str =
        include_str!("../../../sql/commands/receipts/claim_receipt_attempt_3.sql");
    pub(crate) const COMPLETE_DELIVERY_RECEIPT: &str =
        include_str!("../../../sql/commands/receipts/complete_delivery_receipt_1.sql");
    pub(crate) const COMPLETE_DELIVERY_RECEIPT_FINAL: &str =
        include_str!("../../../sql/commands/receipts/complete_delivery_receipt_2.sql");
    pub(crate) const REQUEUE_DELIVERY_RECEIPT: &str =
        include_str!("../../../sql/commands/receipts/requeue_delivery_receipt_1.sql");
    pub(crate) const REQUEUE_DELIVERY_RECEIPT_FINAL: &str =
        include_str!("../../../sql/commands/receipts/requeue_delivery_receipt_2.sql");
    pub(crate) const MARK_DEAD_LETTERED: &str =
        include_str!("../../../sql/commands/receipts/mark_dead_lettered.sql");
}

pub(crate) mod read_receipts {
    pub(crate) const NEXT_RETRY: &str =
        include_str!("../../../sql/queries/read_receipts/next_retry.sql");
    pub(crate) const ENQUEUE: &str =
        include_str!("../../../sql/commands/read_receipts/enqueue.sql");
    pub(crate) const GET_ID: &str = include_str!("../../../sql/queries/read_receipts/get_id.sql");
    pub(crate) const LIST_DUE: &str =
        include_str!("../../../sql/queries/read_receipts/list_due.sql");
    pub(crate) const GET: &str = include_str!("../../../sql/queries/read_receipts/get.sql");
    pub(crate) const PERSIST_ENCRYPTION: &str =
        include_str!("../../../sql/commands/read_receipts/persist_encryption.sql");
    pub(crate) const COMPLETE: &str =
        include_str!("../../../sql/commands/read_receipts/complete.sql");
    pub(crate) const REQUEUE: &str =
        include_str!("../../../sql/commands/read_receipts/requeue.sql");
}

pub(crate) mod peer_endpoints {
    pub(crate) const LOCAL: &str =
        include_str!("../../../sql/queries/peer_endpoints/local_peer_endpoint_1.sql");
    pub(crate) const PUT_LOCAL: &str =
        include_str!("../../../sql/commands/peer_endpoints/put_local_peer_endpoint_1.sql");
    pub(crate) const DELETE_LOCAL: &str =
        include_str!("../../../sql/commands/peer_endpoints/delete_local_peer_endpoint_1.sql");
    pub(crate) const CONTACT: &str =
        include_str!("../../../sql/queries/peer_endpoints/contact_peer_endpoint_1.sql");
    pub(crate) const PUT_CONTACT: &str =
        include_str!("../../../sql/queries/peer_endpoints/put_contact_peer_endpoint_1.sql");
    pub(crate) const PUT_CONTACT_COMMAND: &str =
        include_str!("../../../sql/commands/peer_endpoints/put_contact_peer_endpoint_2.sql");
    pub(crate) const ENSURE_CONTACT_CAPABILITY: &str = include_str!(
        "../../../sql/queries/peer_endpoints/ensure_contact_endpoint_capability_1.sql"
    );
    pub(crate) const ENSURE_CONTACT_CAPABILITY_COMMAND: &str = include_str!(
        "../../../sql/commands/peer_endpoints/ensure_contact_endpoint_capability_2.sql"
    );
    pub(crate) const REVOKE_CONTACT_CAPABILITY: &str = include_str!(
        "../../../sql/commands/peer_endpoints/revoke_contact_endpoint_capability_1.sql"
    );
    pub(crate) const CONTACT_CAPABILITY: &str =
        include_str!("../../../sql/queries/peer_endpoints/contact_endpoint_capability_1.sql");
    pub(crate) const PUT_CAPABILITY: &str =
        include_str!("../../../sql/commands/peer_endpoints/put_peer_endpoint_capability_1.sql");
    pub(crate) const CAPABILITY_SECRET: &str =
        include_str!("../../../sql/queries/peer_endpoints/peer_endpoint_capability_secret_1.sql");
    pub(crate) const REVOKE_CAPABILITY: &str =
        include_str!("../../../sql/commands/peer_endpoints/revoke_peer_endpoint_capability_1.sql");
    pub(crate) const MARK_CONNECTED: &str =
        include_str!("../../../sql/commands/peer_endpoints/mark_peer_connected_1.sql");
    pub(crate) const ENQUEUE_UPDATE: &str = include_str!(
        "../../../sql/commands/peer_endpoints/enqueue_endpoint_update_for_contacts_1.sql"
    );
    pub(crate) const PENDING_UPDATES: &str =
        include_str!("../../../sql/queries/peer_endpoints/pending_endpoint_updates_1.sql");
    pub(crate) const COMPLETE_UPDATES: &str =
        include_str!("../../../sql/commands/peer_endpoints/complete_endpoint_updates_1.sql");
}

pub(crate) mod runtime_storage {
    pub(crate) const CANCEL_CROSSED_OUTBOX_BY_RECIPIENT: &str =
        include_str!("../../../sql/commands/pairing/cancel_crossed_outbox_by_recipient_1.sql");
    pub(crate) const ARCHIVE_CROSSED_INBOX: &str =
        include_str!("../../../sql/commands/pairing/archive_crossed_inbox_1.sql");
    pub(crate) const ARCHIVE_INBOX_FOR_PAIR: &str =
        include_str!("../../../sql/commands/pairing/archive_inbox_for_pair_1.sql");
    pub(crate) const CANCEL_OUTBOX_FOR_PAIR: &str =
        include_str!("../../../sql/commands/pairing/cancel_outbox_for_pair_1.sql");
    pub(crate) const LIST_CONVERSATIONS: &str =
        include_str!("../../../sql/queries/runtime/runtime_1003.sql");
    pub(crate) const UPSERT_CONVERSATION: &str =
        include_str!("../../../sql/commands/runtime/runtime_1047.sql");
    pub(crate) const MARK_CONVERSATION_READ: &str =
        include_str!("../../../sql/commands/runtime/runtime_1076.sql");
    pub(crate) const LIST_MESSAGES: &str =
        include_str!("../../../sql/queries/runtime/runtime_1091.sql");
    pub(crate) const LIST_MESSAGES_BEFORE: &str =
        include_str!("../../../sql/queries/runtime/runtime_1114.sql");
    pub(crate) const LIST_MESSAGES_LIMITED: &str =
        include_str!("../../../sql/queries/runtime/runtime_1136.sql");
    pub(crate) const GET_MESSAGE_METADATA: &str =
        include_str!("../../../sql/queries/runtime/runtime_1161.sql");
    pub(crate) const UPSERT_MESSAGE: &str =
        include_str!("../../../sql/commands/runtime/runtime_1177.sql");
    pub(crate) const DELETE_MESSAGE: &str =
        include_str!("../../../sql/commands/runtime/runtime_1219.sql");
    pub(crate) const LIST_PENDING_MESSAGES: &str =
        include_str!("../../../sql/queries/runtime/runtime_1228.sql");
    pub(crate) const LIST_PENDING_RECEIPTS: &str =
        include_str!("../../../sql/queries/runtime/runtime_1292.sql");
    pub(crate) const EXPEDITE_MESSAGE_RETRIES: &str =
        include_str!("../../../sql/commands/runtime/runtime_1316.sql");
    pub(crate) const EXPEDITE_RECEIPT_RETRIES: &str =
        include_str!("../../../sql/commands/runtime/runtime_1324.sql");
    pub(crate) const EXPEDITE_READ_RECEIPT_RETRIES: &str =
        include_str!("../../../sql/commands/runtime/runtime_1332.sql");
    pub(crate) const EXPEDITE_PAIRING_RETRIES: &str =
        include_str!("../../../sql/commands/runtime/runtime_1340.sql");
    pub(crate) const EXPEDITE_CAPABILITY_RETRIES: &str =
        include_str!("../../../sql/commands/runtime/runtime_1361.sql");
    pub(crate) const GET_MESSAGE: &str =
        include_str!("../../../sql/queries/runtime/runtime_1373.sql");
    pub(crate) const PERSIST_OUTBOUND_ENCRYPTION: &str =
        include_str!("../../../sql/commands/projection/persist_outbound_encryption_1.sql");
    pub(crate) const CLAIM_OUTGOING_ATTEMPT: &str =
        include_str!("../../../sql/commands/projection/claim_outgoing_attempt_1.sql");
    pub(crate) const GET_RELATIONSHIP_TOMBSTONE_EPOCH: &str =
        include_str!("../../../sql/queries/relationships/remove_relationship_with_id_1.sql");
    pub(crate) const UPSERT_RELATIONSHIP_TOMBSTONE: &str =
        include_str!("../../../sql/commands/relationships/remove_relationship_with_id_2.sql");
    pub(crate) const ENQUEUE_RELATIONSHIP_REMOVAL: &str =
        include_str!("../../../sql/commands/relationships/remove_relationship_with_id_3.sql");
    pub(crate) const BLOCK_CONTACT: &str =
        include_str!("../../../sql/commands/relationships/remove_relationship_with_id_4.sql");
    pub(crate) const SET_CONVERSATION_OFFLINE: &str =
        include_str!("../../../sql/commands/relationships/remove_relationship_with_id_5.sql");
    pub(crate) const FAIL_PENDING_MESSAGES: &str =
        include_str!("../../../sql/commands/relationships/remove_relationship_with_id_6.sql");
    pub(crate) const DELETE_OUTBOUND_DELIVERIES: &str =
        include_str!("../../../sql/commands/relationships/remove_relationship_with_id_7.sql");
    pub(crate) const DELETE_DELIVERY_RECEIPTS: &str =
        include_str!("../../../sql/commands/relationships/remove_relationship_with_id_8.sql");
    pub(crate) const DELETE_HISTORY: &str =
        include_str!("../../../sql/commands/relationships/remove_relationship_with_id_9.sql");
    pub(crate) const DELETE_MLS: &str =
        include_str!("../../../sql/commands/relationships/remove_relationship_with_id_10.sql");
    pub(crate) const DELETE_CONTACT_ENDPOINT: &str =
        include_str!("../../../sql/commands/relationships/remove_relationship_with_id_11.sql");
    pub(crate) const DELETE_ENDPOINT_UPDATES: &str =
        include_str!("../../../sql/commands/relationships/remove_relationship_with_id_12.sql");
    pub(crate) const DELETE_PENDING_ENDPOINT_INBOX: &str =
        include_str!("../../../sql/commands/relationships/remove_relationship_with_id_15.sql");
    pub(crate) const DELETE_INBOUND_PEER_ENVELOPES: &str =
        include_str!("../../../sql/commands/relationships/remove_relationship_with_id_16.sql");
    pub(crate) const DELETE_RECEIVED_ENVELOPES: &str =
        include_str!("../../../sql/commands/relationships/remove_relationship_with_id_17.sql");
    pub(crate) const GET_REMOTE_TOMBSTONE_EPOCH: &str =
        include_str!("../../../sql/queries/relationships/apply_remote_relationship_removal_1.sql");
    pub(crate) const UPSERT_REMOTE_TOMBSTONE: &str =
        include_str!("../../../sql/commands/relationships/apply_remote_relationship_removal_2.sql");
    pub(crate) const BLOCK_REMOTE_CONTACT: &str =
        include_str!("../../../sql/commands/relationships/apply_remote_relationship_removal_3.sql");
    pub(crate) const SET_REMOTE_CONVERSATION_OFFLINE: &str =
        include_str!("../../../sql/commands/relationships/apply_remote_relationship_removal_4.sql");
    pub(crate) const FAIL_REMOTE_PENDING_MESSAGES: &str =
        include_str!("../../../sql/commands/relationships/apply_remote_relationship_removal_5.sql");
    pub(crate) const DELETE_REMOTE_MLS: &str =
        include_str!("../../../sql/commands/relationships/apply_remote_relationship_removal_6.sql");
    pub(crate) const ENQUEUE_RELATIONSHIP_REMOVAL_ACK: &str =
        include_str!("../../../sql/commands/relationships/apply_remote_relationship_removal_7.sql");
    pub(crate) const PUT_RELATIONSHIP_REMOVAL_ACK: &str =
        include_str!("../../../sql/commands/relationships/put_relationship_removal_ack_1.sql");
    pub(crate) const LIST_PAIRING_INBOX: &str =
        include_str!("../../../sql/queries/pairing/pairing_inbox_1.sql");
    pub(crate) const UPSERT_PAIRING_INBOX: &str =
        include_str!("../../../sql/commands/pairing/put_pairing_inbox_1.sql");
    pub(crate) const LIST_PAIRING_OUTBOX: &str =
        include_str!("../../../sql/queries/pairing/pairing_outbox_1.sql");
    pub(crate) const UPSERT_PAIRING_OUTBOX: &str =
        include_str!("../../../sql/commands/pairing/put_pairing_outbox_1.sql");
    pub(crate) const LIST_CONTACTS: &str =
        include_str!("../../../sql/queries/contacts/contacts_1.sql");
    pub(crate) const UPSERT_CONTACT: &str =
        include_str!("../../../sql/commands/contacts/put_contact_1.sql");
    pub(crate) const PUT_PEER_ENDPOINT_CAPABILITY: &str =
        include_str!("../../../sql/commands/projection/put_peer_endpoint_capability_1.sql");
    pub(crate) const REVOKE_PEER_ENDPOINT_CAPABILITY: &str =
        include_str!("../../../sql/commands/projection/revoke_peer_endpoint_capability_1.sql");
    pub(crate) const PROJECTION_HEAD: &str =
        include_str!("../../../sql/queries/projection/projection_head_1.sql");
    pub(crate) const SAVE_PROCESSED_COMMAND: &str =
        include_str!("../../../sql/commands/projection/save_processed_command_1.sql");
    pub(crate) const BUMP_PROJECTION_REVISION: &str =
        include_str!("../../../sql/commands/projection/bump_projection_revision_1.sql");
    pub(crate) const BUMP_CONVERSATION_REVISION: &str =
        include_str!("../../../sql/commands/projection/bump_projection_revision_2.sql");
    pub(crate) const GET_SETTING_JSON: &str =
        include_str!("../../../sql/queries/settings/get_setting_json_1.sql");
    pub(crate) const PUT_SETTING_JSON: &str =
        include_str!("../../../sql/commands/settings/put_setting_json_1.sql");
    pub(crate) const REMOVE_PENDING_LOCAL_INVITE_MLS: &str =
        include_str!("../../../sql/commands/pairing/remove_pending_local_invite_mls_1.sql");
    pub(crate) const GET_MLS_SNAPSHOT: &str =
        include_str!("../../../sql/queries/mls/put_conversation_mls_snapshot_1.sql");
    pub(crate) const PUT_MLS_SNAPSHOT: &str =
        include_str!("../../../sql/commands/mls/put_conversation_mls_snapshot_2.sql");
    pub(crate) const BEGIN_VERIFIED_RELATIONSHIP: &str =
        include_str!("../../../sql/queries/relationships/begin_verified_relationship_1.sql");
    pub(crate) const BEGIN_VERIFIED_RELATIONSHIP_COMMAND: &str =
        include_str!("../../../sql/commands/relationships/begin_verified_relationship_2.sql");
    pub(crate) const BEGIN_VERIFIED_RELATIONSHIP_FINALIZE: &str =
        include_str!("../../../sql/commands/relationships/begin_verified_relationship_3.sql");
    pub(crate) const CURRENT_RELATIONSHIP_EPOCH: &str =
        include_str!("../../../sql/queries/relationships/current_relationship_epoch_1.sql");
    pub(crate) const PUT_PENDING_WELCOME: &str =
        include_str!("../../../sql/commands/pairing/put_pending_welcome_1.sql");
    pub(crate) const REMOVE_PENDING_WELCOME: &str =
        include_str!("../../../sql/commands/pairing/remove_pending_welcome_1.sql");
    pub(crate) const CONSUME_INVITE: &str =
        include_str!("../../../sql/commands/pairing/consume_invite_1.sql");
    pub(crate) const PUT_RECEIVED_ENVELOPE: &str =
        include_str!("../../../sql/commands/projection/put_received_envelope_1.sql");
    pub(crate) const PUT_DELIVERY_RECEIPT: &str =
        include_str!("../../../sql/commands/receipts/put_delivery_receipt_1.sql");
}

pub(crate) mod mls {
    pub(crate) const LIST_SNAPSHOTS: &str =
        include_str!("../../../sql/queries/mls/conversation_mls_snapshots_1.sql");
    pub(crate) const GET_SNAPSHOT: &str =
        include_str!("../../../sql/queries/mls/conversation_mls_snapshot_1.sql");
    pub(crate) const GET_CHECKPOINT: &str =
        include_str!("../../../sql/queries/mls/conversation_mls_checkpoint_1.sql");
    pub(crate) const UPSERT_SNAPSHOT_FROM_DATABASE: &str =
        include_str!("../../../sql/commands/mls/put_conversation_mls_snapshot_1.sql");
    pub(crate) const DELETE_SNAPSHOT: &str =
        include_str!("../../../sql/commands/mls/delete_conversation_mls_snapshot_1.sql");
    pub(crate) const UPSERT_SNAPSHOT: &str =
        include_str!("../../../sql/commands/mls/upsert_snapshot.sql");
}

pub(crate) mod relationships {
    pub(crate) const DUE_REMOVALS: &str =
        include_str!("../../../sql/queries/relationships/due_relationship_removals_1.sql");
    pub(crate) const MARK_REMOVAL_DISPATCHED: &str = include_str!(
        "../../../sql/commands/relationships/mark_relationship_removal_dispatched_1.sql"
    );
    pub(crate) const COMPLETE_REMOVAL_ACK: &str =
        include_str!("../../../sql/commands/relationships/complete_relationship_removal_ack_1.sql");
    pub(crate) const DEAD_LETTER_REMOVAL: &str = include_str!(
        "../../../sql/commands/relationships/retry_relationship_removal_dead_letter_1.sql"
    );
    pub(crate) const DUE_REMOVAL_ACKS: &str =
        include_str!("../../../sql/queries/relationships/due_relationship_removal_acks_1.sql");
    pub(crate) const MARK_REMOVAL_ACK_DISPATCHED: &str = include_str!(
        "../../../sql/commands/relationships/mark_relationship_removal_ack_dispatched_1.sql"
    );
    pub(crate) const COMPLETE_REMOVAL_ACK_DELIVERY: &str = include_str!(
        "../../../sql/commands/relationships/complete_relationship_removal_ack_delivery_1.sql"
    );
    pub(crate) const DEAD_LETTER_REMOVAL_ACK: &str = include_str!(
        "../../../sql/commands/relationships/retry_relationship_removal_ack_dead_letter_1.sql"
    );
}

pub(crate) mod projection {
    pub(crate) const PERSIST_ENCRYPTION: &str = include_str!(
        "../../../sql/commands/projection/persist_outbound_encryption_and_claim_1.sql"
    );
    pub(crate) const SET_ACK_DEADLINE: &str = include_str!(
        "../../../sql/commands/projection/persist_outbound_encryption_and_claim_2.sql"
    );
    pub(crate) const CLAIM_ENCRYPTED_MESSAGE: &str = include_str!(
        "../../../sql/commands/projection/persist_outbound_encryption_and_claim_3.sql"
    );
    pub(crate) const CLAIM_OUTGOING_ATTEMPT: &str =
        include_str!("../../../sql/commands/projection/claim_outgoing_attempt_1.sql");
    pub(crate) const SET_OUTGOING_ACK_DEADLINE: &str =
        include_str!("../../../sql/commands/projection/claim_outgoing_attempt_2.sql");
    pub(crate) const REQUEUE_DISCONNECTED_DELIVERIES: &str =
        include_str!("../../../sql/commands/projection/requeue_after_disconnect_1.sql");
    pub(crate) const REQUEUE_DISCONNECTED_ACKS: &str =
        include_str!("../../../sql/commands/projection/requeue_after_disconnect_2.sql");
    pub(crate) const HAS_SCHEMA_MIGRATIONS: &str =
        include_str!("../../../sql/queries/projection/open_1.sql");
    pub(crate) const HAS_CLIENT_TABLES: &str =
        include_str!("../../../sql/queries/projection/open_2.sql");
    pub(crate) const PRUNE_BY_AGE: &str =
        include_str!("../../../sql/commands/projection/prune_by_age.sql");
    pub(crate) const PRUNE_OVER_LIMIT: &str =
        include_str!("../../../sql/commands/projection/prune_over_limit.sql");
    pub(crate) const GET_PROCESSED_COMMAND: &str =
        include_str!("../../../sql/queries/projection/get_processed_command.sql");
    pub(crate) const SAVE_PROCESSED_COMMAND: &str =
        include_str!("../../../sql/commands/projection/save_processed_command.sql");
    pub(crate) const GET_HEAD: &str = include_str!("../../../sql/queries/projection/get_head.sql");
}

pub(crate) mod capabilities {
    pub(crate) const PUT_DELIVERY: &str =
        include_str!("../../../sql/commands/capabilities/put_capability_delivery_1.sql");
    pub(crate) const DUE_DELIVERIES: &str =
        include_str!("../../../sql/queries/capabilities/due_capability_deliveries_1.sql");
    pub(crate) const HAS_DELIVERY_FOR_CONTACT: &str =
        include_str!("../../../sql/queries/capabilities/has_capability_delivery_for_contact_1.sql");
    pub(crate) const CLAIM_DELIVERY: &str =
        include_str!("../../../sql/commands/capabilities/claim_capability_delivery_1.sql");
    pub(crate) const COMPLETE_DELIVERY: &str =
        include_str!("../../../sql/commands/capabilities/complete_capability_delivery_1.sql");
    pub(crate) const COMPLETE_CONTACT_DELIVERIES: &str = include_str!(
        "../../../sql/commands/capabilities/complete_capability_deliveries_for_contact_1.sql"
    );
    pub(crate) const RECORD_DELIVERY_ERROR: &str =
        include_str!("../../../sql/commands/capabilities/record_capability_delivery_error_1.sql");
}
