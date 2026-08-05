use crate::secret_store::DesktopSecretStore;
#[cfg(feature = "torka-file-secrets")]
use crate::secret_store::FileSecretStore;
#[cfg(feature = "os-vault")]
use crate::secret_store::{DesktopSecretKind, OsVaultSecretStore};
use anyhow::{Context, Result, bail};
#[cfg(not(feature = "os-vault"))]
use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD};
use directories::ProjectDirs;
use std::fs;
use std::path::{Path, PathBuf};
use torchat_core::Identity;
#[cfg(not(feature = "os-vault"))]
use zeroize::Zeroizing;

pub fn default_path() -> Result<PathBuf> {
    // Keep the established OS data location stable across the Torca rename so
    // an application upgrade never creates a second identity.
    let dirs = ProjectDirs::from("org", "TorChat", "TorChat")
        .context("cannot determine identity directory")?;
    Ok(dirs.data_dir().join("installation.key"))
}

fn identity_path(path: Option<&Path>) -> Result<PathBuf> {
    path.map(Path::to_path_buf)
        .map(Ok)
        .unwrap_or_else(default_path)
}

pub fn profile_root(path: Option<&Path>) -> Result<PathBuf> {
    identity_path(path)?
        .parent()
        .map(Path::to_path_buf)
        .context("cannot determine desktop profile directory")
}

#[cfg(not(feature = "os-vault"))]
fn load_or_create_file(path: Option<&Path>) -> Result<Identity> {
    let path = identity_path(path)?;
    if path.exists() {
        let encoded = fs::read_to_string(&path).context("read identity file")?;
        let decoded = Zeroizing::new(
            URL_SAFE_NO_PAD
                .decode(encoded.trim())
                .context("decode identity file")?,
        );
        let bytes: [u8; 32] = decoded
            .as_slice()
            .try_into()
            .map_err(|_| anyhow::anyhow!("identity file must contain 32 bytes"))?;
        return Ok(Identity::from_private_key_bytes(bytes));
    }

    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).context("create identity directory")?;
    }
    let identity = Identity::generate();
    let encoded = Zeroizing::new(URL_SAFE_NO_PAD.encode(identity.private_key_bytes()));
    fs::write(&path, encoded.as_bytes()).context("write identity file")?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(&path, fs::Permissions::from_mode(0o600))
            .context("protect identity file")?;
    }
    if !path.exists() {
        bail!("identity file was not created")
    }
    Ok(identity)
}

pub fn state_path(path: Option<&Path>) -> Result<PathBuf> {
    Ok(profile_root(path)?.join("torchat-client-v1.db"))
}

pub fn database_key_path(path: Option<&Path>) -> Result<PathBuf> {
    Ok(profile_root(path)?.join("torchat-client-v1.db.key"))
}

pub fn load_or_create_database_key(key_path: &Path) -> Result<Vec<u8>> {
    #[cfg(feature = "os-vault")]
    if key_path.exists() {
        bail!(
            "plaintext database key exists at {}; complete an explicit rekey before vault startup",
            key_path.display()
        );
    }
    #[cfg(feature = "os-vault")]
    let store =
        OsVaultSecretStore::for_installation(key_path, DesktopSecretKind::DatabaseKeyActive);
    #[cfg(all(not(feature = "os-vault"), feature = "torka-file-secrets"))]
    let store = FileSecretStore::new(key_path);
    if let Some(bytes) = store.read()? {
        return Ok(bytes.to_vec());
    }
    let key = generate_database_key()?;
    store.write(&key)?;
    Ok(key.to_vec())
}

pub fn generate_database_key() -> Result<[u8; 32]> {
    let mut key = [0_u8; 32];
    getrandom::fill(&mut key).context("generate database key")?;
    Ok(key)
}

#[cfg(not(feature = "os-vault"))]
pub fn load_or_create(path: Option<&Path>) -> Result<Identity> {
    load_or_create_file(path)
}

#[cfg(feature = "os-vault")]
pub fn load_or_create(path: Option<&Path>) -> Result<Identity> {
    let identity_path = identity_path(path)?;
    if identity_path.exists() {
        bail!(
            "plaintext identity exists at {}; remove it or complete a supported vault migration before startup",
            identity_path.display()
        );
    }
    let store = OsVaultSecretStore::for_installation(
        &identity_path,
        DesktopSecretKind::IdentityPrivateKey,
    );
    if let Some(bytes) = store.read()? {
        let private_key: [u8; 32] = bytes
            .as_slice()
            .try_into()
            .map_err(|_| anyhow::anyhow!("desktop identity vault value must contain 32 bytes"))?;
        return Ok(Identity::from_private_key_bytes(private_key));
    }
    let identity = Identity::generate();
    store.write(&identity.private_key_bytes())?;
    let stored = store
        .read()?
        .ok_or_else(|| anyhow::anyhow!("desktop identity vault write was not readable"))?;
    if stored.as_slice() != identity.private_key_bytes() {
        bail!("desktop identity vault read-back verification failed");
    }
    Ok(identity)
}

pub fn reset_profile(path: Option<&Path>, tor_data_dir: Option<&Path>) -> Result<()> {
    let identity_path = identity_path(path)?;
    let root = identity_path
        .parent()
        .context("cannot determine desktop profile directory")?
        .to_path_buf();
    let database_path = root.join("torchat-client-v1.db");
    let key_path = root.join("torchat-client-v1.db.key");

    #[cfg(feature = "os-vault")]
    {
        OsVaultSecretStore::for_installation(
            &identity_path,
            DesktopSecretKind::IdentityPrivateKey,
        )
        .remove()?;
        OsVaultSecretStore::for_installation(
            &key_path,
            DesktopSecretKind::DatabaseKeyActive,
        )
        .remove()?;
    }
    #[cfg(all(not(feature = "os-vault"), feature = "torka-file-secrets"))]
    {
        FileSecretStore::new(&key_path).remove()?;
    }

    remove_profile_files(&identity_path, &database_path, &key_path)?;
    if let Some(tor_data_dir) = tor_data_dir {
        remove_managed_tor_data(&root, tor_data_dir)?;
    }
    Ok(())
}

fn remove_profile_files(
    identity_path: &Path,
    database_path: &Path,
    key_path: &Path,
) -> Result<()> {
    let database_name = database_path
        .file_name()
        .context("database path has no file name")?
        .to_string_lossy();
    let root = database_path
        .parent()
        .context("database path has no parent")?;
    let paths = [
        identity_path.to_path_buf(),
        identity_path.with_extension("tmp"),
        database_path.to_path_buf(),
        database_path.with_extension("db-wal"),
        database_path.with_extension("db-shm"),
        database_path.with_extension("db-journal"),
        key_path.to_path_buf(),
        key_path.with_extension("tmp"),
        root.join(format!("{database_name}.mls-anchors")),
        root.join("engine-logs"),
    ];
    for path in paths {
        remove_path_if_present(&path)?;
    }
    Ok(())
}

fn remove_managed_tor_data(profile_root: &Path, tor_data_dir: &Path) -> Result<()> {
    let absolute = if tor_data_dir.is_absolute() {
        tor_data_dir.to_path_buf()
    } else {
        std::env::current_dir()
            .context("resolve current directory for Tor data reset")?
            .join(tor_data_dir)
    };
    if !absolute.starts_with(profile_root) {
        bail!(
            "refusing to delete Tor data outside the Torca profile: {}",
            absolute.display()
        );
    }
    remove_path_if_present(&absolute)
}

fn remove_path_if_present(path: &Path) -> Result<()> {
    let metadata = match fs::symlink_metadata(path) {
        Ok(value) => value,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(()),
        Err(error) => return Err(error).with_context(|| format!("inspect {}", path.display())),
    };
    if metadata.file_type().is_dir() && !metadata.file_type().is_symlink() {
        fs::remove_dir_all(path).with_context(|| format!("remove {}", path.display()))
    } else {
        fs::remove_file(path).with_context(|| format!("remove {}", path.display()))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn identity_is_stable_when_reloaded() {
        let path =
            std::env::temp_dir().join(format!("torca-desktop-{}.key", uuid::Uuid::new_v4()));
        let first = load_or_create(Some(&path)).unwrap();
        let second = load_or_create(Some(&path)).unwrap();
        assert_eq!(first.installation_id(), second.installation_id());
        assert_eq!(first.fingerprint(), second.fingerprint());
        let _ = fs::remove_file(path);
    }

    #[test]
    fn database_key_is_independent_and_stable() {
        let root =
            std::env::temp_dir().join(format!("torca-desktop-key-{}", uuid::Uuid::new_v4()));
        let key_path = root.join("client.db.key");
        let first = load_or_create_database_key(&key_path).unwrap();
        assert_eq!(first.len(), 32);
        let second = load_or_create_database_key(&key_path).unwrap();
        assert_eq!(second, first);
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn reset_removes_only_known_profile_artifacts() {
        let root = std::env::temp_dir().join(format!("torca-reset-{}", uuid::Uuid::new_v4()));
        fs::create_dir_all(root.join("engine-logs")).unwrap();
        let identity = root.join("installation.key");
        let database = root.join("torchat-client-v1.db");
        let key = root.join("torchat-client-v1.db.key");
        for path in [
            identity.clone(),
            database.clone(),
            database.with_extension("db-wal"),
            key.clone(),
            root.join("engine-logs/log.txt"),
        ] {
            if let Some(parent) = path.parent() {
                fs::create_dir_all(parent).unwrap();
            }
            fs::write(path, b"test").unwrap();
        }
        let keep = root.join("keep.txt");
        fs::write(&keep, b"keep").unwrap();

        remove_profile_files(&identity, &database, &key).unwrap();

        assert!(!identity.exists());
        assert!(!database.exists());
        assert!(!root.join("engine-logs").exists());
        assert!(keep.exists());
        let _ = fs::remove_dir_all(root);
    }
}
