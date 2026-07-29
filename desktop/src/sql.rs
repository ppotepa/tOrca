pub const MIGRATION_LOOKUP: &str = include_str!("../sql/queries/migration_lookup.sql");
pub const MIGRATION_INSERT: &str = include_str!("../sql/queries/migration_insert.sql");
pub const TABLE_COLUMNS: &str = include_str!("../sql/queries/table_columns.sql");
pub const CONNECTION_PRAGMAS: &str = include_str!("../sql/queries/connection_pragmas.sql");

pub const MIGRATIONS: &[(&str, &str)] = &[
    (
        "000_schema_migrations.sql",
        include_str!("../sql/migrations/000_schema_migrations.sql"),
    ),
    (
        "001_initial.sql",
        include_str!("../sql/migrations/001_initial.sql"),
    ),
    (
        "002_messages_relay_payload.sql",
        include_str!("../sql/migrations/002_messages_relay_payload.sql"),
    ),
    (
        "003_contacts_verification.sql",
        include_str!("../sql/migrations/003_contacts_verification.sql"),
    ),
    (
        "004_conversation_runtime_state.sql",
        include_str!("../sql/migrations/004_conversation_runtime_state.sql"),
    ),
    (
        "005_canonical_state_values.sql",
        include_str!("../sql/migrations/005_canonical_state_values.sql"),
    ),
    (
        "006_message_delivery_hardening.sql",
        include_str!("../sql/migrations/006_message_delivery_hardening.sql"),
    ),
    (
        "007_received_envelopes.sql",
        include_str!("../sql/migrations/007_received_envelopes.sql"),
    ),
    (
        "008_delivery_receipts.sql",
        include_str!("../sql/migrations/008_delivery_receipts.sql"),
    ),
];

pub const CONTACT_UPSERT: &str = include_str!("../sql/queries/contact_upsert.sql");
pub const CONTACTS_LIST: &str = include_str!("../sql/queries/contacts_list.sql");
pub const CONTACT_VERIFY: &str = include_str!("../sql/queries/contact_verify.sql");
pub const CONTACT_VERIFICATION: &str = include_str!("../sql/queries/contact_verification.sql");
pub const CONVERSATION_UPSERT: &str = include_str!("../sql/queries/conversation_upsert.sql");
#[allow(dead_code)]
pub const CONVERSATION_GET: &str = include_str!("../sql/queries/conversation_get.sql");
pub const CONVERSATION_MARK_READ: &str = include_str!("../sql/queries/conversation_mark_read.sql");
pub const CONVERSATIONS_LIST: &str = include_str!("../sql/queries/conversations_list.sql");
pub const CONVERSATION_MLS_UPSERT: &str =
    include_str!("../sql/queries/conversation_mls_upsert.sql");
pub const CONVERSATION_MLS_GET: &str = include_str!("../sql/queries/conversation_mls_get.sql");
pub const CONVERSATION_MLS_DELETE: &str =
    include_str!("../sql/queries/conversation_mls_delete.sql");
pub const CONVERSATION_STATUS_PROMOTE_LEGACY: &str =
    include_str!("../sql/queries/conversation_status_promote_legacy.sql");
#[allow(dead_code)]
pub const LEGACY_CONVERSATION_INSERT: &str =
    include_str!("../sql/queries/legacy_conversation_insert.sql");
#[allow(dead_code)]
pub const LEGACY_MESSAGE_INSERT: &str = include_str!("../sql/queries/legacy_message_insert.sql");
pub const SETTING_UPSERT: &str = include_str!("../sql/queries/setting_upsert.sql");
pub const SETTING_GET: &str = include_str!("../sql/queries/setting_get.sql");
pub const MESSAGE_UPSERT: &str = include_str!("../sql/queries/message_upsert.sql");
pub const MESSAGE_GET: &str = include_str!("../sql/queries/message_get.sql");
pub const INVITE_LOOKUP: &str = include_str!("../sql/queries/invite_lookup.sql");
pub const INVITE_INSERT: &str = include_str!("../sql/queries/invite_insert.sql");
pub const MESSAGES_LIST: &str = include_str!("../sql/queries/messages_list.sql");
pub const MESSAGES_PENDING: &str = include_str!("../sql/queries/messages_pending.sql");
