use sha2::{Digest, Sha256};
use tracing::info;

const DATABASE_MIGRATIONS: &[(&str, &str)] = &[
    (
        "004_schema_sql_files.sql",
        include_str!("../../../infra/db/migrations/004_schema_sql_files.sql"),
    ),
    (
        "005_pairing_sql_file.sql",
        include_str!("../../../infra/db/migrations/005_pairing_sql_file.sql"),
    ),
    (
        "006_pairing_request_deduplication.sql",
        include_str!("../../../infra/db/migrations/006_pairing_request_deduplication.sql"),
    ),
    (
        "007_contacts.sql",
        include_str!("../../../infra/db/migrations/007_contacts.sql"),
    ),
    (
        "008_connection_leases.sql",
        include_str!("../../../infra/db/migrations/008_connection_leases.sql"),
    ),
    (
        "009_connection_route_stream.sql",
        include_str!("../../../infra/db/migrations/009_connection_route_stream.sql"),
    ),
];
const SQL_SCHEMA_MIGRATIONS: &str = include_str!("../sql/schema_migrations.sql");
const SQL_SCHEMA_MIGRATION_LOOKUP: &str =
    include_str!("../sql/queries/schema_migration_lookup.sql");
const SQL_SCHEMA_MIGRATION_INSERT: &str =
    include_str!("../sql/queries/schema_migration_insert.sql");
const SQL_PRUNE_SESSIONS: &str = include_str!("../sql/queries/prune_sessions.sql");
const SQL_PRUNE_PAIRING_CODES: &str = include_str!("../sql/queries/prune_pairing_codes.sql");
const SQL_PRUNE_PENDING_PAIRINGS: &str = include_str!("../sql/queries/prune_pending_pairings.sql");

pub(crate) async fn apply_database_migrations(
    db: &mut tokio_postgres::Client,
) -> Result<(), tokio_postgres::Error> {
    db.batch_execute(SQL_SCHEMA_MIGRATIONS).await?;
    for (name, sql) in DATABASE_MIGRATIONS {
        let checksum = format!("{:x}", Sha256::digest(sql.as_bytes()));
        let existing = db.query_opt(SQL_SCHEMA_MIGRATION_LOOKUP, &[name]).await?;
        if let Some(row) = existing {
            let applied: String = row.get(0);
            if applied != checksum {
                panic!("database migration checksum changed: {name}");
            }
            continue;
        }
        let transaction = db.transaction().await?;
        transaction.batch_execute(sql).await?;
        transaction
            .execute(SQL_SCHEMA_MIGRATION_INSERT, &[name, &checksum])
            .await?;
        transaction.commit().await?;
        info!(migration = *name, "database migration applied");
    }
    Ok(())
}

pub(crate) async fn prune_server_metadata(
    db: &tokio_postgres::Client,
) -> Result<(), tokio_postgres::Error> {
    db.execute(SQL_PRUNE_SESSIONS, &[]).await?;
    db.execute(SQL_PRUNE_PAIRING_CODES, &[]).await?;
    db.execute(SQL_PRUNE_PENDING_PAIRINGS, &[]).await?;
    Ok(())
}
