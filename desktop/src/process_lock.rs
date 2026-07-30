use std::{
    fs::{self, File, OpenOptions},
    io::{Read, Seek, SeekFrom, Write},
    path::{Path, PathBuf},
    time::{SystemTime, UNIX_EPOCH},
};

use anyhow::{Context, Result, bail};
use fs2::FileExt;
use serde::{Deserialize, Serialize};

#[derive(Debug, Serialize, Deserialize)]
struct LockMetadata {
    pid: u32,
    process_start_unix_ms: u128,
    executable: String,
    data_directory: String,
    runtime_generation: u64,
}

/// Owns an operating-system exclusive lock for one Tor data directory.
///
/// The JSON file is diagnostic only. Ownership is determined exclusively by
/// the kernel file lock, so stale metadata from a crashed process is safe to
/// recover while a live owner can never be deleted by another process.
pub struct TorDataLock {
    file: File,
    path: PathBuf,
}

impl TorDataLock {
    pub fn acquire(data_directory: &Path, runtime_generation: u64) -> Result<Self> {
        fs::create_dir_all(data_directory).context("create Tor data directory")?;
        let path = data_directory.join("torchat.lock");
        let mut file = OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .open(&path)
            .with_context(|| format!("open Tor data directory lock {}", path.display()))?;

        if let Err(error) = file.try_lock_exclusive() {
            let mut details = String::new();
            let _ = file.seek(SeekFrom::Start(0));
            let _ = file.read_to_string(&mut details);
            bail!(
                "Tor data directory is already in use; OS lock is held at {}{}",
                path.display(),
                if details.trim().is_empty() {
                    String::new()
                } else {
                    format!(" ({})", details.replace('\n', " ").trim())
                },
            )
        }

        let executable = std::env::current_exe()
            .map(|value| value.display().to_string())
            .unwrap_or_else(|_| "unknown".to_owned());
        let process_start_unix_ms = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_millis();
        let metadata = LockMetadata {
            pid: std::process::id(),
            process_start_unix_ms,
            executable,
            data_directory: data_directory.display().to_string(),
            runtime_generation,
        };
        let encoded = serde_json::to_vec_pretty(&metadata).context("encode Tor lock metadata")?;
        file.set_len(0).context("truncate Tor lock metadata")?;
        file.seek(SeekFrom::Start(0)).context("seek Tor lock metadata")?;
        file.write_all(&encoded).context("write Tor lock metadata")?;
        file.write_all(b"\n").context("finish Tor lock metadata")?;
        file.sync_all().context("sync Tor lock metadata")?;

        Ok(Self { file, path })
    }
}

impl Drop for TorDataLock {
    fn drop(&mut self) {
        let _ = self.file.sync_all();
        let _ = self.file.unlock();
        let _ = fs::remove_file(&self.path);
    }
}
