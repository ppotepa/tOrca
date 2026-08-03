use crate::secret_store::DesktopSecretStore;
#[cfg(feature = "torka-file-secrets")]
use crate::secret_store::FileSecretStore;
#[cfg(feature = "os-vault")]
use crate::secret_store::{DesktopSecretKind, OsVaultSecretStore};
use anyhow::{Context, Result, bail};
use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD};
use directories::ProjectDirs;
use std::fs;
use std::path::{Path, PathBuf};
use torchat_core::Identity;
use zeroize::Zeroizing;

pub fn default_path() -> Result<PathBuf> {
    let dirs = ProjectDirs::from("org", "TorChat", "TorChat")
        .context("cannot determine identity directory")?;
    Ok(dirs.data_dir().join("installation.key"))
}

#[cfg(not(feature = "os-vault"))]
fn load_or_create_file(path: Option<&Path>) -> Result<Identity> {
    let path = path
        .map(Path::to_path_buf)
        .map(Ok)
        .unwrap_or_else(default_path)?;
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
    let identity_path = path
        .map(Path::to_path_buf)
        .map(Ok)
        .unwrap_or_else(default_path)?;
    let parent = identity_path
        .parent()
        .context("cannot determine desktop state directory")?;
    Ok(parent.join("torchat-client-v1.db"))
}

pub fn database_key_path(path: Option<&Path>) -> Result<PathBuf> {
    let identity_path = path
        .map(Path::to_path_buf)
        .map(Ok)
        .unwrap_or_else(default_path)?;
    let parent = identity_path
        .parent()
        .context("cannot determine desktop state directory")?;
    Ok(parent.join("torchat-client-v1.db.key"))
}

pub fn load_or_create_database_key(key_path: &Path) -> Result<Vec<u8>> {
    #[cfg(feature = "os-vault")]
    if key_path.exists() {
        bail!(
            "legacy plaintext database key exists at {}; use explicit rekey migration",
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

#[allow(dead_code)]
pub fn write_database_key(key_path: &Path, key: &[u8; 32]) -> Result<()> {
    #[cfg(feature = "os-vault")]
    let store =
        OsVaultSecretStore::for_installation(key_path, DesktopSecretKind::DatabaseKeyActive);
    #[cfg(all(not(feature = "os-vault"), feature = "torka-file-secrets"))]
    let store = FileSecretStore::new(key_path);
    store.write(key)
}

#[cfg(not(feature = "os-vault"))]
pub fn load_or_create(path: Option<&Path>) -> Result<Identity> {
    load_or_create_file(path)
}

#[cfg(feature = "os-vault")]
pub fn load_or_create(path: Option<&Path>) -> Result<Identity> {
    let identity_path = path
        .map(Path::to_path_buf)
        .map(Ok)
        .unwrap_or_else(default_path)?;
    if identity_path.exists() {
        bail!(
            "legacy plaintext identity exists at {}; use explicit migration/import before vault startup",
            identity_path.display()
        );
    }
    let store =
        OsVaultSecretStore::for_installation(&identity_path, DesktopSecretKind::IdentityPrivateKey);
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

#[cfg(feature = "os-vault")]
pub fn import_legacy_identity(path: &Path) -> Result<Identity> {
    let encoded = fs::read_to_string(path).context("read legacy identity file")?;
    let decoded = Zeroizing::new(
        URL_SAFE_NO_PAD
            .decode(encoded.trim())
            .context("decode legacy identity file")?,
    );
    let bytes: [u8; 32] = decoded
        .as_slice()
        .try_into()
        .map_err(|_| anyhow::anyhow!("legacy identity file must contain 32 bytes"))?;
    let identity = Identity::from_private_key_bytes(bytes);
    let store = OsVaultSecretStore::for_installation(path, DesktopSecretKind::IdentityPrivateKey);
    store.write(&identity.private_key_bytes())?;
    let stored = store
        .read()?
        .ok_or_else(|| anyhow::anyhow!("identity vault import was not readable"))?;
    if stored.as_slice() != identity.private_key_bytes() {
        bail!("identity vault import read-back verification failed");
    }
    fs::remove_file(path).context("remove imported legacy identity file")?;
    Ok(identity)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn identity_is_stable_when_reloaded() {
        let path =
            std::env::temp_dir().join(format!("torchat-desktop-{}.key", uuid::Uuid::new_v4()));
        let first = load_or_create(Some(&path)).unwrap();
        let second = load_or_create(Some(&path)).unwrap();
        assert_eq!(first.installation_id(), second.installation_id());
        assert_eq!(first.fingerprint(), second.fingerprint());
        let _ = fs::remove_file(path);
    }

    #[test]
    fn database_key_is_independent_and_stable() {
        let root =
            std::env::temp_dir().join(format!("torchat-desktop-key-{}", uuid::Uuid::new_v4()));
        let key_path = root.join("client.db.key");
        let first = load_or_create_database_key(&key_path).unwrap();
        assert_eq!(first.len(), 32);
        let second = load_or_create_database_key(&key_path).unwrap();
        assert_eq!(second, first);
        let _ = fs::remove_dir_all(root);
    }
}
