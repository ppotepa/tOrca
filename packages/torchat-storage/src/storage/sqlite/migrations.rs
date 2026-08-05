use crate::storage::Migration;

pub const MIGRATION_LOOKUP: &str = include_str!("../../../sql/queries/migration_lookup.sql");
pub const TABLE_COLUMNS: &str = include_str!("../../../sql/queries/table_columns.sql");

pub const MIGRATIONS: &[Migration] = &[
    Migration {
        version: 0,
        name: "000_schema_migrations.sql",
        sql: include_str!("../../../sql/migrations/000_schema_migrations.sql"),
    },
    Migration {
        version: 1,
        name: "001_base_schema.sql",
        sql: include_str!("../../../sql/migrations/001_base_schema.sql"),
    },
    Migration {
        version: 2,
        name: "002_pairing_capability_bootstrap.sql",
        sql: include_str!("../../../sql/migrations/002_pairing_capability_bootstrap.sql"),
    },
    Migration {
        version: 3,
        name: "003_pairing_session_identity.sql",
        sql: include_str!("../../../sql/migrations/003_pairing_session_identity.sql"),
    },
    Migration {
        version: 4,
        name: "004_durable_operations.sql",
        sql: include_str!("../../../sql/migrations/004_durable_operations.sql"),
    },
];
