use anyhow::{Context, Result, bail};
#[cfg(feature = "os-vault")]
use sha2::{Digest, Sha256};
#[cfg(any(test, feature = "torka-file-secrets"))]
use std::fs;
#[cfg(feature = "os-vault")]
use std::path::Path;
#[cfg(any(test, feature = "torka-file-secrets"))]
use std::path::PathBuf;
use zeroize::Zeroizing;

/// Storage boundary for desktop secrets. Platform vault implementations can
/// replace `FileSecretStore` without changing identity/database migration.
#[allow(dead_code)]
pub(crate) trait DesktopSecretStore {
    fn read(&self) -> Result<Option<Zeroizing<Vec<u8>>>>;
    fn write(&self, secret: &[u8]) -> Result<()>;
    fn remove(&self) -> Result<()>;
}

#[allow(dead_code)]
#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) enum DesktopSecretKind {
    IdentityPrivateKey,
    DatabaseKeyActive,
    DatabaseKeyPending,
    MlsCheckpoint,
}

#[cfg(feature = "os-vault")]
impl DesktopSecretKind {
    fn label(&self) -> &'static str {
        match self {
            Self::IdentityPrivateKey => "identity-private-key",
            Self::DatabaseKeyActive => "database-key-active",
            Self::DatabaseKeyPending => "database-key-pending",
            Self::MlsCheckpoint => "mls-checkpoint",
        }
    }
}

#[cfg(feature = "os-vault")]
/// Native OS credential-store backend used for secrets that must not sit next
/// to the SQLCipher database. `keyring` selects Credential Manager, Keychain,
/// or Secret Service through compile-time platform features.
#[derive(Clone, Debug)]
pub(crate) struct OsVaultSecretStore {
    account: String,
}

#[cfg(feature = "os-vault")]
impl OsVaultSecretStore {
    pub(crate) fn for_installation(path: &Path, kind: DesktopSecretKind) -> Self {
        let mut namespace = path.to_string_lossy().as_bytes().to_vec();
        namespace.extend_from_slice(b"\0");
        namespace.extend_from_slice(kind.label().as_bytes());
        let digest = Sha256::digest(namespace);
        let account = digest.iter().map(|byte| format!("{byte:02x}")).collect();
        Self { account }
    }

    fn entry(&self) -> Result<keyring::Entry> {
        keyring::Entry::new("org.torchat.desktop", &self.account)
            .context("create desktop OS-vault entry")
    }
}

#[cfg(feature = "os-vault")]
impl DesktopSecretStore for OsVaultSecretStore {
    fn read(&self) -> Result<Option<Zeroizing<Vec<u8>>>> {
        match self.entry()?.get_secret() {
            Ok(secret) => {
                if secret.len() != 32 {
                    bail!("desktop OS-vault secret must contain 32 bytes")
                }
                Ok(Some(Zeroizing::new(secret)))
            }
            Err(error) if matches!(&error, keyring::Error::NoEntry) => Ok(None),
            Err(error) => Err(error).context("read desktop OS-vault secret"),
        }
    }

    fn write(&self, secret: &[u8]) -> Result<()> {
        if secret.len() != 32 {
            bail!("desktop OS-vault secret must contain 32 bytes")
        }
        self.entry()?
            .set_secret(secret)
            .context("write desktop OS-vault secret")
    }

    fn remove(&self) -> Result<()> {
        self.entry()?
            .delete_credential()
            .context("remove desktop OS-vault secret")
    }
}

#[cfg(any(test, feature = "torka-file-secrets"))]
#[allow(dead_code)]
#[derive(Clone, Debug)]
pub(crate) struct FileSecretStore {
    path: PathBuf,
}

#[cfg(any(test, feature = "torka-file-secrets"))]
impl FileSecretStore {
    pub(crate) fn new(path: impl Into<PathBuf>) -> Self {
        Self { path: path.into() }
    }
}

#[cfg(any(test, feature = "torka-file-secrets"))]
impl DesktopSecretStore for FileSecretStore {
    fn read(&self) -> Result<Option<Zeroizing<Vec<u8>>>> {
        if !self.path.exists() {
            return Ok(None);
        }
        let value = Zeroizing::new(fs::read(&self.path).context("read desktop secret")?);
        if value.len() != 32 {
            bail!("desktop secret must contain 32 bytes")
        }
        Ok(Some(value))
    }

    fn write(&self, secret: &[u8]) -> Result<()> {
        if secret.len() != 32 {
            bail!("desktop secret must contain 32 bytes")
        }
        if let Some(parent) = self.path.parent() {
            fs::create_dir_all(parent).context("create desktop secret directory")?;
        }
        let temporary = self.path.with_extension("tmp");
        fs::write(&temporary, secret).context("write desktop secret")?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            fs::set_permissions(&temporary, fs::Permissions::from_mode(0o600))
                .context("protect desktop secret")?;
        }
        fs::rename(temporary, &self.path).context("commit desktop secret")?;
        Ok(())
    }

    fn remove(&self) -> Result<()> {
        if self.path.exists() {
            fs::remove_file(&self.path).context("remove desktop secret")?;
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn file_store_is_atomic_shape_and_validates_secret_length() {
        let root = std::env::temp_dir().join(format!("torchat-secret-{}", uuid::Uuid::new_v4()));
        let store = FileSecretStore::new(root.join("secret"));
        assert!(store.read().unwrap().is_none());
        assert!(store.write(&[1; 31]).is_err());
        store.write(&[7; 32]).unwrap();
        assert_eq!(
            store.read().unwrap().map(|value| value.to_vec()),
            Some(vec![7; 32])
        );
        store.remove().unwrap();
        assert!(store.read().unwrap().is_none());
        let _ = fs::remove_dir_all(root);
    }
}
