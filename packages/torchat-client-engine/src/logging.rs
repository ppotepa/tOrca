use std::{
    fs::{self, File, OpenOptions},
    io::Write,
    path::Path,
    time::{Duration, SystemTime, UNIX_EPOCH},
};

use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD};
use serde_json::json;
use sha2::{Digest, Sha256};

use crate::{EngineEvent, PlatformKind};

const LOG_RETENTION: Duration = Duration::from_secs(7 * 24 * 60 * 60);
const LOG_BUDGET_BYTES: u64 = 20 * 1024 * 1024;

pub(crate) struct StartupJournal {
    file: Option<File>,
    session_id: String,
    pseudonym_salt: String,
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
            pseudonym_salt: uuid::Uuid::new_v4().to_string(),
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
            EngineEvent::Fatal { error } => {
                self.write("error", "engine", &error.code, None, &error.message)
            }
            EngineEvent::Log { log } => {
                self.write(&log.level, "engine", "engine_log", None, &log.message)
            }
            EngineEvent::Connection { snapshot } => self.write(
                "info",
                "relay",
                "connection_state_changed",
                Some("RELAY"),
                &format!("{:?}: {}", snapshot.state, snapshot.detail),
            ),
            EngineEvent::Runtime {
                event:
                    torchat_runtime::RuntimeEvent::TorStatus {
                        phase,
                        detail,
                        retry_attempt,
                        ..
                    },
            } => self.write(
                if matches!(phase, torchat_runtime::RuntimeStatusPhase::Error) {
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
                event: torchat_runtime::RuntimeEvent::RuntimeError { message },
            } => self.write("error", "engine", "runtime_error", None, message),
            EngineEvent::Runtime {
                event: torchat_runtime::RuntimeEvent::RuntimeLog { message },
            } => self.write("info", "engine", "runtime_log", None, message),
            EngineEvent::Runtime {
                event:
                    torchat_runtime::RuntimeEvent::PeerEndpointChanged { contact_id, status },
            } => self.write(
                if matches!(status, torchat_runtime::PeerEndpointStatus::Verified) {
                    "info"
                } else {
                    "warn"
                },
                "peer",
                "peer_endpoint_changed",
                Some("ONION_SERVICE"),
                &format!("contact={contact_id} status={status:?}"),
            ),
            EngineEvent::Runtime {
                event:
                    torchat_runtime::RuntimeEvent::PeerConnectionChanged {
                        contact_id,
                        status,
                        retry_in_ms,
                    },
            } => self.write(
                "info",
                "peer",
                "peer_connection_changed",
                Some("PEER_TRANSPORT"),
                &format!("contact={contact_id} status={status:?} retry_in_ms={retry_in_ms:?}"),
            ),
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
        let message = self.redact(message);
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
            "message": message,
        });
        if serde_json::to_writer(&mut *file, &entry).is_ok() {
            let _ = file.write_all(b"\n");
            let _ = file.flush();
        }
    }

    /// Persistent journals are useful only if they do not become a durable
    /// contact graph.  Keep identifiers linkable inside this one journal so a
    /// support trace is coherent, but make them unlinkable across sessions.
    fn redact(&self, message: &str) -> String {
        message
            .split_whitespace()
            .map(|token| self.redact_token(token))
            .collect::<Vec<_>>()
            .join(" ")
    }

    fn redact_token(&self, token: &str) -> String {
        if token.to_ascii_lowercase().contains(".onion") {
            return "[onion]".to_owned();
        }
        let Some((key, value)) = token.split_once('=') else {
            return token.to_owned();
        };
        let normalized = key
            .trim_matches(|character: char| !character.is_ascii_alphanumeric() && character != '_')
            .to_ascii_lowercase();
        let sensitive = matches!(
            normalized.as_str(),
            "contact"
                | "contact_id"
                | "installation_id"
                | "sender"
                | "recipient"
                | "message_id"
                | "pairing_id"
                | "conversation_id"
                | "invite_id"
        );
        if !sensitive || value.is_empty() {
            return token.to_owned();
        }
        let suffix = value
            .chars()
            .rev()
            .take_while(|character| {
                !character.is_ascii_alphanumeric() && *character != '-' && *character != '_'
            })
            .collect::<String>()
            .chars()
            .rev()
            .collect::<String>();
        let value = value.trim_end_matches(|character: char| {
            !character.is_ascii_alphanumeric() && character != '-' && character != '_'
        });
        let mut digest = Sha256::new();
        digest.update(self.pseudonym_salt.as_bytes());
        digest.update(b":");
        digest.update(value.as_bytes());
        let pseudonym = URL_SAFE_NO_PAD.encode(digest.finalize());
        format!("{key}=[id-{}]{suffix}", &pseudonym[..10])
    }
}

fn prepare_directory(directory: &Path) -> std::io::Result<()> {
    fs::create_dir_all(directory)?;
    let now = SystemTime::now();
    let mut logs = fs::read_dir(directory)?
        .filter_map(Result::ok)
        .filter_map(|entry| {
            let metadata = entry.metadata().ok()?;
            if !metadata.is_file() || !entry.file_name().to_string_lossy().starts_with("startup-") {
                return None;
            }
            let modified = metadata.modified().ok()?;
            Some((entry.path(), modified, metadata.len()))
        })
        .collect::<Vec<_>>();
    for (path, modified, _) in &logs {
        if now
            .duration_since(*modified)
            .is_ok_and(|age| age > LOG_RETENTION)
        {
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

    #[test]
    fn stable_identifiers_are_pseudonymous_within_one_journal() {
        let journal = StartupJournal {
            file: None,
            session_id: "session".to_owned(),
            pseudonym_salt: "session-salt".to_owned(),
            platform: "desktop".to_owned(),
        };
        let first = journal.redact("contact=peer-alice message_id=message-42");
        let second = journal.redact("contact=peer-alice message_id=message-42");
        assert_eq!(first, second);
        assert!(!first.contains("peer-alice"));
        assert!(!first.contains("message-42"));
        assert!(first.contains("contact=[id-"));
    }
}
