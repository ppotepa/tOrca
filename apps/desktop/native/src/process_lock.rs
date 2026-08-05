use std::{
    fs::{self, File, OpenOptions},
    io::{Read, Seek, SeekFrom, Write},
    path::{Path, PathBuf},
    time::{SystemTime, UNIX_EPOCH},
};

use anyhow::{Context, Result, bail};
use serde::{Deserialize, Serialize};

#[derive(Debug, Serialize, Deserialize)]
struct LockMetadata {
    pid: u32,
    process_start_unix_ms: u128,
    executable: String,
    data_directory: String,
    runtime_generation: u64,
}

pub struct TorDataLock {
    file: File,
    path: PathBuf,
}

impl TorDataLock {
    pub fn acquire(data_directory: &Path, runtime_generation: u64) -> Result<Self> {
        fs::create_dir_all(data_directory).context("create Tor data directory")?;
        let path = data_directory.join("torchat.lock");
        let mut file = open_lock_file(&path)?;
        if let Err(error) = try_lock_exclusive(&file) {
            let mut details = String::new();
            let _ = file.seek(SeekFrom::Start(0));
            let _ = file.read_to_string(&mut details);
            bail!(
                "Tor data directory is already in use; OS lock is held at {}{}: {}",
                path.display(),
                if details.trim().is_empty() {
                    String::new()
                } else {
                    format!(" ({})", details.replace('\n', " ").trim())
                },
                error,
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
        file.seek(SeekFrom::Start(0))
            .context("seek Tor lock metadata")?;
        file.write_all(&encoded)
            .context("write Tor lock metadata")?;
        file.write_all(b"\n").context("finish Tor lock metadata")?;
        file.sync_all().context("sync Tor lock metadata")?;

        Ok(Self { file, path })
    }
}

#[cfg(windows)]
fn open_lock_file(path: &Path) -> Result<File> {
    use std::os::windows::fs::OpenOptionsExt;
    OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .share_mode(0)
        .open(path)
        .with_context(|| format!("open exclusive Tor lock {}", path.display()))
}

#[cfg(not(windows))]
fn open_lock_file(path: &Path) -> Result<File> {
    OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .open(path)
        .with_context(|| format!("open Tor lock {}", path.display()))
}

#[cfg(windows)]
fn try_lock_exclusive(_file: &File) -> std::io::Result<()> {
    Ok(())
}

#[cfg(unix)]
fn try_lock_exclusive(file: &File) -> std::io::Result<()> {
    use std::os::fd::AsRawFd;
    const LOCK_EX: i32 = 2;
    const LOCK_NB: i32 = 4;
    unsafe extern "C" {
        fn flock(fd: i32, operation: i32) -> i32;
    }
    let result = unsafe { flock(file.as_raw_fd(), LOCK_EX | LOCK_NB) };
    if result == 0 {
        Ok(())
    } else {
        Err(std::io::Error::last_os_error())
    }
}

#[cfg(not(any(windows, unix)))]
fn try_lock_exclusive(_file: &File) -> std::io::Result<()> {
    Err(std::io::Error::new(
        std::io::ErrorKind::Unsupported,
        "exclusive Tor data lock is unsupported on this platform",
    ))
}

#[cfg(unix)]
fn unlock(file: &File) {
    use std::os::fd::AsRawFd;
    const LOCK_UN: i32 = 8;
    unsafe extern "C" {
        fn flock(fd: i32, operation: i32) -> i32;
    }
    let _ = unsafe { flock(file.as_raw_fd(), LOCK_UN) };
}

#[cfg(not(unix))]
fn unlock(_file: &File) {}

impl Drop for TorDataLock {
    fn drop(&mut self) {
        let _ = self.file.sync_all();
        unlock(&self.file);
        let _ = fs::remove_file(&self.path);
    }
}
