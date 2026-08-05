//! Restartable desktop secret migration journal.
//! The journal contains no secret material; it only records migration state
//! and public/data-root checksums.

use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::{
    fs,
    path::{Path, PathBuf},
};

#[allow(dead_code)]
#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
pub(crate) enum SecretMigrationState {
    DiscoveredLegacy,
    IdentityVaultWritten,
    PendingDbKeyWritten,
    DatabaseRekeyed,
    ActiveDbKeyPromoted,
    DatabaseVerified,
    LegacyIdentityRemoved,
    Complete,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
#[allow(dead_code)]
pub(crate) enum SecretMigrationRecovery {
    Start,
    ContinueWithPendingDatabaseKey,
    VerifyActiveDatabaseKey,
    Complete,
}

#[allow(dead_code)]
pub(crate) fn recovery_action(
    journal: Option<&SecretMigrationJournal>,
    pending_key_exists: bool,
    active_key_exists: bool,
) -> SecretMigrationRecovery {
    let Some(journal) = journal else {
        return if pending_key_exists {
            SecretMigrationRecovery::ContinueWithPendingDatabaseKey
        } else {
            SecretMigrationRecovery::Start
        };
    };
    match journal.state {
        SecretMigrationState::Complete | SecretMigrationState::LegacyIdentityRemoved => {
            SecretMigrationRecovery::Complete
        }
        SecretMigrationState::DatabaseRekeyed | SecretMigrationState::PendingDbKeyWritten
            if pending_key_exists =>
        {
            SecretMigrationRecovery::ContinueWithPendingDatabaseKey
        }
        SecretMigrationState::ActiveDbKeyPromoted | SecretMigrationState::DatabaseVerified
            if active_key_exists =>
        {
            SecretMigrationRecovery::VerifyActiveDatabaseKey
        }
        _ => SecretMigrationRecovery::Start,
    }
}

#[allow(dead_code)]
#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct SecretMigrationJournal {
    pub schema: u16,
    pub state: SecretMigrationState,
    pub identity_fingerprint: String,
    pub database_path_hash: String,
    pub started_at: i64,
    pub updated_at: i64,
}

#[allow(dead_code)]
pub(crate) fn journal_path(data_root: &Path) -> PathBuf {
    data_root.join("secret-migration-v1.json")
}

#[allow(dead_code)]
pub(crate) fn hash_path(path: &Path) -> String {
    Sha256::digest(path.to_string_lossy().as_bytes())
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect()
}

#[allow(dead_code)]
pub(crate) fn load(path: &Path) -> Result<Option<SecretMigrationJournal>> {
    if !path.exists() {
        return Ok(None);
    }
    let bytes = fs::read(path).context("read secret migration journal")?;
    Ok(Some(
        serde_json::from_slice(&bytes).context("decode secret migration journal")?,
    ))
}

#[allow(dead_code)]
pub(crate) fn store(path: &Path, journal: &SecretMigrationJournal) -> Result<()> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).context("create secret migration journal directory")?;
    }
    let temporary = path.with_extension("json.tmp");
    let bytes = serde_json::to_vec_pretty(journal).context("encode secret migration journal")?;
    {
        let mut file = fs::File::create(&temporary).context("create secret migration journal")?;
        use std::io::Write;
        file.write_all(&bytes)
            .context("write secret migration journal")?;
        file.sync_all().context("sync secret migration journal")?;
    }
    fs::rename(&temporary, path).context("commit secret migration journal")?;
    #[cfg(unix)]
    if let Some(parent) = path.parent() {
        fs::File::open(parent)
            .context("open secret migration journal directory")?
            .sync_all()
            .context("sync secret migration journal directory")?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn journal_round_trip_uses_stable_wire_names() {
        let root =
            std::env::temp_dir().join(format!("torchat-secret-journal-{}", uuid::Uuid::new_v4()));
        let path = journal_path(&root);
        let journal = SecretMigrationJournal {
            schema: 1,
            state: SecretMigrationState::PendingDbKeyWritten,
            identity_fingerprint: "fingerprint".to_owned(),
            database_path_hash: "path-hash".to_owned(),
            started_at: 1,
            updated_at: 2,
        };
        store(&path, &journal).unwrap();
        let raw = fs::read_to_string(&path).unwrap();
        assert!(raw.contains("PENDING_DB_KEY_WRITTEN"));
        assert!(raw.contains("identityFingerprint"));
        assert_eq!(load(&path).unwrap().unwrap().state, journal.state);
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn recovery_never_discards_a_pending_key() {
        assert_eq!(
            recovery_action(None, true, false),
            SecretMigrationRecovery::ContinueWithPendingDatabaseKey
        );
        let journal = SecretMigrationJournal {
            schema: 1,
            state: SecretMigrationState::DatabaseRekeyed,
            identity_fingerprint: String::new(),
            database_path_hash: String::new(),
            started_at: 0,
            updated_at: 0,
        };
        assert_eq!(
            recovery_action(Some(&journal), true, true),
            SecretMigrationRecovery::ContinueWithPendingDatabaseKey
        );
    }
}
