use std::{
    fs::{self, File, OpenOptions},
    io::Write,
    path::Path,
    time::{Duration, SystemTime, UNIX_EPOCH},
};

use serde_json::json;

use crate::{EngineEvent, PlatformKind};

const LOG_RETENTION: Duration = Duration::from_secs(7 * 24 * 60 * 60);
const LOG_BUDGET_BYTES: u64 = 20 * 1024 * 1024;

pub(crate) struct StartupJournal {
    file: Option<File>,
    session_id: String,
    platform: String,
}

impl StartupJournal {
    pub(crate) fn open(directory: Option<&Path>, platform: &PlatformKind) -> Self {
        let session_id = uuid::Uuid::new_v4().to_string();
        let platform = format!("{platform:?}").to_ascii_lowercase();
        let file = directory.and_then(|directory| {
            prepare_directory(directory).ok()?;
            let timestamp = unix_ms();
            OpenOptions::new()
                .create(true)
                .append(true)
                .open(directory.join(format!("startup-{timestamp}-{session_id}.jsonl")))
                .ok()
        });
        Self {
            file,
            session_id,
            platform,
        }
    }

    pub(crate) fn record_engine_creation_failure(&mut self, message: &str) {
        self.write(
            "error",
            "engine",
            "engine_initialization_failed",
            Some("ENGINE"),
            message,
        );
    }

    pub(crate) fn record(&mut self, event: &EngineEvent) {
        match event {
            EngineEvent::Fatal { error } => self.write(
                "error",
                "engine",
                &error.code,
                None,
                &error.message,
            ),
            EngineEvent::Log { log } => self.write(
                &log.level,
                "engine",
                "engine_log",
                None,
                &log.message,
            ),
            EngineEvent::Connection { snapshot } => self.write(
                "info",
                "relay",
                "connection_state_changed",
                Some("RELAY"),
                &format!("{:?}: {}", snapshot.state, snapshot.detail),
            ),
            EngineEvent::Runtime {
                event: torchat_client_runtime::RuntimeEvent::TorStatus {
                    phase,
                    detail,
                    retry_attempt,
                    ..
                },
            } => self.write(
                if matches!(
                    phase,
                    torchat_client_runtime::RuntimeStatusPhase::Error
                ) {
                    "error"
                } else {
                    "info"
                },
                "tor",
                "tor_status_changed",
                Some("TOR"),
                &format!("{phase:?} attempt={retry_attempt}: {detail}"),
            ),
            EngineEvent::Runtime {
                event: torchat_client_runtime::RuntimeEvent::RuntimeError { message },
            } => self.write(
                "error",
                "engine",
                "runtime_error",
                None,
                message,
            ),
            EngineEvent::Runtime {
                event: torchat_client_runtime::RuntimeEvent::RuntimeLog { message },
            } => self.write("info", "engine", "runtime_log", None, message),
            EngineEvent::PlatformAction { action } => self.write(
                "info",
                "onion",
                "platform_action",
                Some("ONION_SERVICE"),
                &format!("{action:?}"),
            ),
            EngineEvent::Response { .. } | EngineEvent::NotificationRequested { .. } => {}
            EngineEvent::Runtime { .. } => {}
        }
    }

    fn write(
        &mut self,
        level: &str,
        component: &str,
        event_code: &str,
        stage: Option<&str>,
        message: &str,
    ) {
        let Some(file) = &mut self.file else {
            return;
        };
        let entry = json!({
            "timestampMs": unix_ms(),
            "sessionId": self.session_id,
            "platform": self.platform,
            "level": level,
            "component": component,
            "eventCode": event_code,
            "stage": stage,
            "message": redact(message),
        });
        if serde_json::to_writer(&mut *file, &entry).is_ok() {
            let _ = file.write_all(b"\n");
            let _ = file.flush();
        }
    }
}

fn prepare_directory(directory: &Path) -> std::io::Result<()> {
    fs::create_dir_all(directory)?;
    let now = SystemTime::now();
    let mut logs = fs::read_dir(directory)?
        .filter_map(Result::ok)
        .filter_map(|entry| {
            let metadata = entry.metadata().ok()?;
            if !metadata.is_file()
                || !entry
                    .file_name()
                    .to_string_lossy()
                    .starts_with("startup-")
            {
                return None;
            }
            let modified = metadata.modified().ok()?;
            Some((entry.path(), modified, metadata.len()))
        })
        .collect::<Vec<_>>();
    for (path, modified, _) in &logs {
        if now.duration_since(*modified).is_ok_and(|age| age > LOG_RETENTION) {
            let _ = fs::remove_file(path);
        }
    }
    logs.retain(|(path, _, _)| path.exists());
    logs.sort_by_key(|(_, modified, _)| *modified);
    let mut total = logs.iter().map(|(_, _, size)| *size).sum::<u64>();
    for (path, _, size) in logs {
        if total <= LOG_BUDGET_BYTES {
            break;
        }
        if fs::remove_file(path).is_ok() {
            total = total.saturating_sub(size);
        }
    }
    Ok(())
}

fn redact(message: &str) -> String {
    message
        .split_whitespace()
        .map(|token| {
            if token.to_ascii_lowercase().contains(".onion") {
                "[onion]"
            } else {
                token
            }
        })
        .collect::<Vec<_>>()
        .join(" ")
}

fn unix_ms() -> u128 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn creation_failure_is_persisted_and_onion_address_is_redacted() {
        let directory = std::env::temp_dir().join(format!(
            "torchat-engine-log-test-{}-{}",
            std::process::id(),
            unix_ms()
        ));
        let mut journal = StartupJournal::open(Some(&directory), &PlatformKind::Desktop);
        journal.record_engine_creation_failure(
            "migration failed through abcdefghijklmnopqrstuvwxyz234567abcdefghijklmnopqrstuv.onion",
        );
        drop(journal);

        let path = fs::read_dir(&directory)
            .expect("log directory exists")
            .filter_map(Result::ok)
            .map(|entry| entry.path())
            .find(|path| path.extension().is_some_and(|value| value == "jsonl"))
            .expect("startup log exists");
        let contents = fs::read_to_string(path).expect("startup log is readable");
        assert!(contents.contains("engine_initialization_failed"));
        assert!(contents.contains("[onion]"));
        assert!(!contents.contains(".onion"));
        let _ = fs::remove_dir_all(directory);
    }
}
