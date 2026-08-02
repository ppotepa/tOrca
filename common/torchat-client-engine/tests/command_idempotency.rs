use std::{fs, path::PathBuf};

use tokio::time::{Duration, timeout};
use torchat_client_engine::{
    ClientDatabase, ClientEngine, EngineCommand, EngineCommandEnvelope, EngineConfig, EngineEvent,
    PlatformKind, config::SecretBytes, event::ResponseResult,
};
use url::Url;
use uuid::Uuid;

fn temporary_database_path() -> PathBuf {
    std::env::temp_dir().join(format!(
        "torchat-command-idempotency-{}.sqlite3",
        Uuid::new_v4()
    ))
}

fn remove_database(path: &std::path::Path) {
    for candidate in [
        path.to_path_buf(),
        PathBuf::from(format!("{}-wal", path.display())),
        PathBuf::from(format!("{}-shm", path.display())),
    ] {
        let _ = fs::remove_file(candidate);
    }
}

async fn response_for(engine: &mut ClientEngine, request_id: &str) -> ResponseResult {
    timeout(Duration::from_secs(5), async {
        loop {
            if let Some(EngineEvent::Response {
                request_id: received,
                result,
            }) = engine.poll_timeout(Duration::from_millis(250)).await
                && received == request_id
            {
                return result;
            }
        }
    })
    .await
    .expect("engine should answer command")
}

#[tokio::test]
async fn replayed_bootstrap_command_uses_the_durable_result_without_a_second_mutation() {
    let path = temporary_database_path();
    let key = vec![0x6b; 32];
    let mut engine = ClientEngine::new(EngineConfig {
        database_path: path.clone(),
        database_key: SecretBytes(key.clone()),
        identity_private_key: SecretBytes(vec![0x11; 32]),
        relay_onion_url: Url::parse("http://127.0.0.1:9").expect("relay URL"),
        initial_socks5_url: None,
        log_directory: None,
        platform: PlatformKind::Windows,
    })
    .expect("engine should start");

    for request_id in ["bootstrap-first", "bootstrap-replay"] {
        engine
            .submit_envelope(EngineCommandEnvelope {
                request_id: request_id.to_owned(),
                command_id: Some("bootstrap-command-id".to_owned()),
                command: EngineCommand::Bootstrap,
            })
            .await
            .expect("command should be accepted");
        assert!(matches!(
            response_for(&mut engine, request_id).await,
            ResponseResult::Ok { .. }
        ));
    }

    engine.shutdown();
    drop(engine);
    tokio::time::sleep(Duration::from_millis(100)).await;

    let database = ClientDatabase::open(&path, &SecretBytes(key)).expect("database reopens");
    let stored = database
        .load_processed_command("bootstrap-command-id")
        .expect("stored command is readable")
        .expect("command result is durable");
    assert!(stored.0.starts_with("bootstrap:"));
    let payload: serde_json::Value =
        serde_json::from_str(&stored.1).expect("stored result remains valid JSON");
    assert!(payload.get("type").is_some());
    remove_database(&path);
}
