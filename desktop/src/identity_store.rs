use anyhow::{Context, Result, bail};
use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD};
use directories::ProjectDirs;
use std::{
    fs,
    path::{Path, PathBuf},
};
use torchat_core::Identity;

pub fn default_path() -> Result<PathBuf> {
    let dirs = ProjectDirs::from("org", "TorChat", "TorChat")
        .context("cannot determine identity directory")?;
    Ok(dirs.data_dir().join("installation.key"))
}

pub fn load_or_create(path: Option<&Path>) -> Result<Identity> {
    let path = path
        .map(Path::to_path_buf)
        .map(Ok)
        .unwrap_or_else(default_path)?;
    if path.exists() {
        let encoded = fs::read_to_string(&path).context("read identity file")?;
        let bytes = URL_SAFE_NO_PAD
            .decode(encoded.trim())
            .context("decode identity file")?;
        let bytes: [u8; 32] = bytes
            .try_into()
            .map_err(|_| anyhow::anyhow!("identity file must contain 32 bytes"))?;
        return Ok(Identity::from_private_key_bytes(bytes));
    }

    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).context("create identity directory")?;
    }
    let identity = Identity::generate();
    let encoded = URL_SAFE_NO_PAD.encode(identity.private_key_bytes());
    fs::write(&path, encoded).context("write identity file")?;
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

pub fn load_existing(path: &Path) -> Result<Identity> {
    if !path.is_file() {
        bail!("identity file does not exist: {}", path.display())
    }
    let encoded = fs::read_to_string(path).context("read identity file")?;
    let bytes = URL_SAFE_NO_PAD
        .decode(encoded.trim())
        .context("decode identity file")?;
    let bytes: [u8; 32] = bytes
        .try_into()
        .map_err(|_| anyhow::anyhow!("identity file must contain 32 bytes"))?;
    Ok(Identity::from_private_key_bytes(bytes))
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
}
