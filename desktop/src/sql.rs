pub const MIGRATION_LOOKUP: &str = include_str!("../sql/queries/migration_lookup.sql");
pub const MIGRATION_INSERT: &str = include_str!("../sql/queries/migration_insert.sql");
pub const TABLE_COLUMNS: &str = include_str!("../sql/queries/table_columns.sql");

pub const MIGRATIONS: &[(&str, &str)] = &[
    ("000_schema_migrations.sql", include_str!("../sql/migrations/000_schema_migrations.sql")),
    ("001_initial.sql", include_str!("../sql/migrations/001_initial.sql")),
    ("002_messages_relay_payload.sql", include_str!("../sql/migrations/002_messages_relay_payload.sql")),
    ("003_contacts_verification.sql", include_str!("../sql/migrations/003_contacts_verification.sql")),
];

pub const CONTACT_UPSERT: &str = include_str!("../sql/queries/contact_upsert.sql");
pub const CONTACTS_LIST: &str = include_str!("../sql/queries/contacts_list.sql");
pub const CONTACT_VERIFY: &str = include_str!("../sql/queries/contact_verify.sql");
pub const CONTACT_VERIFICATION: &str = include_str!("../sql/queries/contact_verification.sql");
pub const CONVERSATION_UPSERT: &str = include_str!("../sql/queries/conversation_upsert.sql");
pub const CONVERSATION_GET: &str = include_str!("../sql/queries/conversation_get.sql");
pub const CONVERSATIONS_LIST: &str = include_str!("../sql/queries/conversations_list.sql");
pub const SETTING_UPSERT: &str = include_str!("../sql/queries/setting_upsert.sql");
pub const SETTING_GET: &str = include_str!("../sql/queries/setting_get.sql");
pub const MESSAGE_UPSERT: &str = include_str!("../sql/queries/message_upsert.sql");
pub const MESSAGE_STATE_UPDATE: &str = include_str!("../sql/queries/message_state_update.sql");
pub const INVITE_LOOKUP: &str = include_str!("../sql/queries/invite_lookup.sql");
pub const INVITE_INSERT: &str = include_str!("../sql/queries/invite_insert.sql");
pub const MESSAGES_LIST: &str = include_str!("../sql/queries/messages_list.sql");
pub const MESSAGES_PENDING: &str = include_str!("../sql/queries/messages_pending.sql");
