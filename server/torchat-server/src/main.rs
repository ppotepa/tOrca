//! TorChat delivery server bootstrap API.
//!
//! This process routes authenticated opaque envelopes. It must not contain
//! message decryption code or receive client private keys.

use axum::{
    Json, Router,
    extract::{
        State, WebSocketUpgrade,
        ws::{Message, WebSocket},
    },
    http::{HeaderMap, StatusCode},
    response::Response,
    routing::{get, post},
};
use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD};
use futures_util::StreamExt;
use rand::{Rng, rng};
use serde::{Deserialize, Serialize};
use sha2::Digest;
use std::{
    collections::HashMap,
    env,
    net::SocketAddr,
    sync::Arc,
    time::{Duration, SystemTime, UNIX_EPOCH},
};
use tokio::sync::{RwLock, mpsc};
use tracing::info;
use uuid::Uuid;

const CHALLENGE_TTL_SECONDS: u64 = 300;

#[derive(Clone)]
struct AppState {
    db: Arc<tokio_postgres::Client>,
    challenges: Arc<RwLock<HashMap<Uuid, Challenge>>>,
    installations: Arc<RwLock<HashMap<String, Installation>>>,
    sessions: Arc<RwLock<HashMap<String, String>>>,
    connections: Arc<RwLock<HashMap<String, mpsc::UnboundedSender<Message>>>>,
}

#[derive(Clone)]
struct Challenge {
    value: String,
    expires_at: u64,
}

#[derive(Clone)]
struct Installation {
    public_key: String,
    nickname: Option<String>,
}

#[derive(Serialize)]
struct Health {
    status: &'static str,
    protocol_version: u16,
}

#[derive(Serialize)]
struct ChallengeResponse {
    challenge_id: Uuid,
    challenge: String,
    expires_in_seconds: u64,
}

#[derive(Deserialize)]
struct InstallationRequest {
    challenge_id: Uuid,
    public_key: String,
    proof: String,
}

#[derive(Serialize)]
struct InstallationResponse {
    installation_id: String,
    session_token: String,
    security_status: &'static str,
}

#[derive(Deserialize)]
struct SessionRequest {
    installation_id: String,
    challenge_id: Uuid,
    proof: String,
}

#[derive(Deserialize)]
struct NicknameRequest {
    nickname: String,
}

#[derive(Serialize)]
struct ProfileResponse {
    installation_id: String,
    nickname: Option<String>,
    public_key: String,
    fingerprint: String,
}

#[derive(Serialize)]
struct DirectoryEntry {
    installation_id: String,
    nickname: String,
    public_key: String,
    fingerprint: String,
}

#[tokio::main]
async fn main() {
    tracing_subscriber::fmt()
        .with_env_filter(env::var("RUST_LOG").unwrap_or_else(|_| "info".into()))
        .init();
    let database_url = env::var("TORCHAT_DATABASE_URL").unwrap_or_else(|_| {
        "postgres://torchat:local-development-only@127.0.0.1:5432/torchat".into()
    });
    let (db, connection) = tokio_postgres::connect(&database_url, tokio_postgres::NoTls)
        .await
        .expect("TORCHAT_DATABASE_URL must point to PostgreSQL");
    tokio::spawn(async move {
        if let Err(error) = connection.await {
            tracing::error!(%error, "postgres connection failed");
        }
    });
    db.batch_execute(include_str!("../../../infra/db/001_init.sql"))
        .await
        .expect("database migration failed");
    let state = AppState {
        db: Arc::new(db),
        challenges: Arc::new(RwLock::new(HashMap::new())),
        installations: Arc::new(RwLock::new(HashMap::new())),
        sessions: Arc::new(RwLock::new(HashMap::new())),
        connections: Arc::new(RwLock::new(HashMap::new())),
    };
    let app = Router::new()
        .route("/health", get(health))
        .route("/v1/bootstrap/challenge", post(create_challenge))
        .route("/v1/installations", post(register_installation))
        .route("/v1/sessions", post(create_session))
        .route("/v1/profile", get(get_profile).put(update_profile))
        .route("/v1/directory/search", get(search_directory))
        .route("/v1/events", get(events))
        .with_state(state);
    let bind = env::var("TORCHAT_BIND").unwrap_or_else(|_| "127.0.0.1:8080".into());
    let address: SocketAddr = bind
        .parse()
        .expect("TORCHAT_BIND must be a valid socket address");
    let listener = tokio::net::TcpListener::bind(address)
        .await
        .expect("bind failed");
    info!(%address, "torchat server listening");
    axum::serve(listener, app).await.expect("server failed");
}

async fn health() -> Json<Health> {
    Json(Health {
        status: "ok",
        protocol_version: torchat_core::protocol_version(),
    })
}

async fn create_challenge(State(state): State<AppState>) -> Json<ChallengeResponse> {
    let challenge_id = Uuid::new_v4();
    let mut bytes = [0u8; 32];
    rng().fill(&mut bytes);
    let challenge = URL_SAFE_NO_PAD.encode(bytes);
    let expires_at = now() + CHALLENGE_TTL_SECONDS;
    state.challenges.write().await.insert(
        challenge_id,
        Challenge {
            value: challenge.clone(),
            expires_at,
        },
    );
    Json(ChallengeResponse {
        challenge_id,
        challenge,
        expires_in_seconds: CHALLENGE_TTL_SECONDS,
    })
}

async fn register_installation(
    State(state): State<AppState>,
    Json(request): Json<InstallationRequest>,
) -> Result<(StatusCode, Json<InstallationResponse>), (StatusCode, Json<serde_json::Value>)> {
    let challenge = take_valid_challenge(&state, request.challenge_id).await?;
    if request.public_key.is_empty()
        || !torchat_core::verify_signature(
            &request.public_key,
            challenge.value.as_bytes(),
            &request.proof,
        )
    {
        return Err(error(StatusCode::BAD_REQUEST, "invalid bootstrap proof"));
    }
    let mut digest = sha2::Sha256::new();
    digest.update(
        base64::engine::general_purpose::URL_SAFE_NO_PAD
            .decode(&request.public_key)
            .unwrap(),
    );
    let installation_id = URL_SAFE_NO_PAD.encode(digest.finalize());
    let nickname = if let Some(existing) = state.installations.read().await.get(&installation_id) {
        existing.nickname.clone()
    } else {
        state
            .db
            .query_opt(
                "SELECT nickname FROM installations WHERE installation_id = $1",
                &[&installation_id],
            )
            .await
            .map_err(|_| error(StatusCode::INTERNAL_SERVER_ERROR, "database error"))?
            .and_then(|row| row.get(0))
    };
    state.installations.write().await.insert(
        installation_id.clone(),
        Installation {
            public_key: request.public_key.clone(),
            nickname,
        },
    );
    state.db.execute(
        "INSERT INTO installations (installation_id, public_key) VALUES ($1, $2) ON CONFLICT (installation_id) DO UPDATE SET public_key = EXCLUDED.public_key",
        &[&installation_id, &request.public_key],
    ).await.map_err(|_| error(StatusCode::INTERNAL_SERVER_ERROR, "database error"))?;
    let session_token = issue_session(&state, &installation_id).await;
    Ok((
        StatusCode::CREATED,
        Json(InstallationResponse {
            installation_id,
            session_token,
            security_status: "verified",
        }),
    ))
}

async fn create_session(
    State(state): State<AppState>,
    Json(request): Json<SessionRequest>,
) -> Result<Json<InstallationResponse>, (StatusCode, Json<serde_json::Value>)> {
    let challenge = take_valid_challenge(&state, request.challenge_id).await?;
    let installation = if let Some(installation) = state
        .installations
        .read()
        .await
        .get(&request.installation_id)
        .cloned()
    {
        installation
    } else {
        let row = state.db.query_opt(
            "SELECT public_key, nickname FROM installations WHERE installation_id = $1 AND revoked_at IS NULL",
            &[&request.installation_id],
        ).await.map_err(|_| error(StatusCode::INTERNAL_SERVER_ERROR, "database error"))?;
        let Some(row) = row else {
            return Err(error(StatusCode::NOT_FOUND, "installation not found"));
        };
        Installation {
            public_key: row.get(0),
            nickname: row.get(1),
        }
    };
    let signed = format!("session-v1:{}:{}", request.installation_id, challenge.value);
    if !torchat_core::verify_signature(&installation.public_key, signed.as_bytes(), &request.proof)
    {
        return Err(error(StatusCode::BAD_REQUEST, "invalid session proof"));
    }
    let session_token = issue_session(&state, &request.installation_id).await;
    Ok(Json(InstallationResponse {
        installation_id: request.installation_id,
        session_token,
        security_status: "verified",
    }))
}

async fn get_profile(
    State(state): State<AppState>,
    headers: HeaderMap,
) -> Result<Json<ProfileResponse>, (StatusCode, Json<serde_json::Value>)> {
    let installation_id = authorize(&state, &headers).await?;
    let (public_key, nickname) = profile_row(&state, &installation_id).await?;
    Ok(Json(ProfileResponse {
        fingerprint: fingerprint_for_public_key(&public_key)?,
        installation_id,
        nickname,
        public_key,
    }))
}

async fn update_profile(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(request): Json<NicknameRequest>,
) -> Result<Json<ProfileResponse>, (StatusCode, Json<serde_json::Value>)> {
    let installation_id = authorize(&state, &headers).await?;
    let nickname = validate_nickname(request.nickname)?;
    state
        .db
        .execute(
            "UPDATE installations SET nickname = $1 WHERE installation_id = $2",
            &[&nickname, &installation_id],
        )
        .await
        .map_err(|_| error(StatusCode::INTERNAL_SERVER_ERROR, "database error"))?;
    if let Some(installation) = state.installations.write().await.get_mut(&installation_id) {
        installation.nickname = Some(nickname.clone());
    }
    let (public_key, _) = profile_row(&state, &installation_id).await?;
    Ok(Json(ProfileResponse {
        installation_id,
        nickname: Some(nickname),
        fingerprint: fingerprint_for_public_key(&public_key)?,
        public_key,
    }))
}

async fn search_directory(
    State(state): State<AppState>,
    headers: HeaderMap,
    axum::extract::Query(query): axum::extract::Query<HashMap<String, String>>,
) -> Result<Json<Vec<DirectoryEntry>>, (StatusCode, Json<serde_json::Value>)> {
    let _ = authorize(&state, &headers).await?;
    let value = query.get("q").map(String::as_str).unwrap_or("").trim();
    if value.len() < 2 || value.len() > 64 {
        return Err(error(
            StatusCode::BAD_REQUEST,
            "query must be 2-64 characters",
        ));
    }
    let pattern = format!("%{}%", value.replace('%', "\\%").replace('_', "\\_"));
    let rows = state
        .db
        .query(
            "SELECT installation_id, nickname, public_key FROM installations WHERE revoked_at IS NULL AND nickname IS NOT NULL AND nickname ILIKE $1 ESCAPE '\\' ORDER BY nickname LIMIT 25",
            &[&pattern],
        )
        .await
        .map_err(|_| error(StatusCode::INTERNAL_SERVER_ERROR, "database error"))?;
    let entries = rows
        .into_iter()
        .filter_map(|row| {
            let nickname: Option<String> = row.get(1);
            nickname.map(|nickname| DirectoryEntry {
                installation_id: row.get(0),
                public_key: row.get(2),
                fingerprint: fingerprint_for_public_key_value(row.get(2)).unwrap_or_default(),
                nickname,
            })
        })
        .collect();
    Ok(Json(entries))
}

async fn profile_row(
    state: &AppState,
    installation_id: &str,
) -> Result<(String, Option<String>), (StatusCode, Json<serde_json::Value>)> {
    if let Some(installation) = state
        .installations
        .read()
        .await
        .get(installation_id)
        .cloned()
    {
        return Ok((installation.public_key, installation.nickname));
    }
    let row = state
        .db
        .query_opt(
            "SELECT public_key, nickname FROM installations WHERE installation_id = $1 AND revoked_at IS NULL",
            &[&installation_id],
        )
        .await
        .map_err(|_| error(StatusCode::INTERNAL_SERVER_ERROR, "database error"))?
        .ok_or_else(|| error(StatusCode::NOT_FOUND, "installation not found"))?;
    Ok((row.get(0), row.get(1)))
}

fn validate_nickname(value: String) -> Result<String, (StatusCode, Json<serde_json::Value>)> {
    let value = value.trim().to_owned();
    let valid_length = (2..=32).contains(&value.chars().count());
    let valid_chars = value
        .chars()
        .all(|character| character.is_alphanumeric() || matches!(character, ' ' | '_' | '-' | '.'));
    if !valid_length || !valid_chars {
        return Err(error(
            StatusCode::BAD_REQUEST,
            "nickname must be 2-32 letters, numbers, spaces, _-.",
        ));
    }
    Ok(value)
}

fn fingerprint_for_public_key(
    value: &str,
) -> Result<String, (StatusCode, Json<serde_json::Value>)> {
    fingerprint_for_public_key_value(value.to_owned())
        .ok_or_else(|| error(StatusCode::INTERNAL_SERVER_ERROR, "invalid public key"))
}

fn fingerprint_for_public_key_value(value: String) -> Option<String> {
    let bytes = URL_SAFE_NO_PAD.decode(value).ok()?;
    let bytes: [u8; 32] = bytes.try_into().ok()?;
    Some(torchat_core::fingerprint_from_public_key(&bytes))
}

async fn events(
    State(state): State<AppState>,
    headers: HeaderMap,
    upgrade: WebSocketUpgrade,
) -> Result<Response, (StatusCode, Json<serde_json::Value>)> {
    let installation_id = authorize(&state, &headers).await?;
    Ok(upgrade.on_upgrade(move |socket| websocket_session(state, installation_id, socket)))
}

async fn websocket_session(state: AppState, installation_id: String, mut socket: WebSocket) {
    let (outgoing_tx, mut outgoing_rx) = mpsc::unbounded_channel();
    state
        .connections
        .write()
        .await
        .insert(installation_id.clone(), outgoing_tx);
    let _ = socket
        .send(frame(torchat_core::relay::RelayServerFrame::Ready {
            installation_id: installation_id.clone(),
        }))
        .await;

    loop {
        tokio::select! {
            outgoing = outgoing_rx.recv() => {
                let Some(outgoing) = outgoing else { break };
                if socket.send(outgoing).await.is_err() { break; }
            }
            incoming = socket.next() => {
                let Some(Ok(Message::Text(text))) = incoming else { break };
                let result = serde_json::from_str::<torchat_core::relay::RelayClientFrame>(&text)
                    .map_err(|_| "invalid_request".to_string())
                    .and_then(|frame| process_frame(&state, &installation_id, frame));
                if let Err(code) = result {
                    let _ = socket.send(frame(torchat_core::relay::RelayServerFrame::Error { code })).await;
                }
            }
        }
    }
    let mut connections = state.connections.write().await;
    if connections
        .get(&installation_id)
        .is_some_and(|sender| sender.is_closed())
    {
        connections.remove(&installation_id);
    }
}

fn process_frame(
    state: &AppState,
    sender_id: &str,
    incoming_frame: torchat_core::relay::RelayClientFrame,
) -> Result<(), String> {
    let state = state.clone();
    let sender_id = sender_id.to_owned();
    tokio::spawn(async move {
        match incoming_frame {
            torchat_core::relay::RelayClientFrame::Envelope(mut envelope) => {
                if envelope.version != torchat_core::PROTOCOL_VERSION
                    || envelope.sender != sender_id
                    || envelope.recipient.is_empty()
                    || envelope.ciphertext.len() > 128 * 1024
                    || URL_SAFE_NO_PAD.decode(&envelope.ciphertext).is_err()
                {
                    return;
                }
                let recipient = state
                    .connections
                    .read()
                    .await
                    .get(&envelope.recipient)
                    .cloned();
                if let Some(recipient) = recipient {
                    envelope.sender = sender_id.clone();
                    let message_id = envelope.message_id;
                    let _ = recipient.send(frame(torchat_core::relay::RelayServerFrame::Envelope(
                        envelope,
                    )));
                    if let Some(sender) = state.connections.read().await.get(&sender_id).cloned() {
                        let _ =
                            sender.send(frame(torchat_core::relay::RelayServerFrame::Forwarded {
                                message_id,
                            }));
                    }
                } else if let Some(sender) = state.connections.read().await.get(&sender_id).cloned()
                {
                    let _ = sender.send(frame(
                        torchat_core::relay::RelayServerFrame::RecipientOffline {
                            message_id: envelope.message_id,
                        },
                    ));
                }
            }
            torchat_core::relay::RelayClientFrame::DeliveryReceipt { message_id, sender } => {
                if let Some(target) = state.connections.read().await.get(&sender).cloned() {
                    let _ = target.send(frame(
                        torchat_core::relay::RelayServerFrame::DeliveryReceipt { message_id },
                    ));
                }
            }
            torchat_core::relay::RelayClientFrame::Ping => {}
        }
    });
    Ok(())
}

fn frame<T: Serialize>(value: T) -> Message {
    Message::Text(
        serde_json::to_string(&value)
            .expect("server frame must serialize")
            .into(),
    )
}

async fn authorize(
    state: &AppState,
    headers: &HeaderMap,
) -> Result<String, (StatusCode, Json<serde_json::Value>)> {
    let value = headers.get("authorization").and_then(|v| v.to_str().ok());
    let Some(token) = value.and_then(|v| v.strip_prefix("Bearer ")) else {
        return Err(error(StatusCode::UNAUTHORIZED, "invalid_request"));
    };
    let mut hash = sha2::Sha256::new();
    hash.update(token.as_bytes());
    let token_hash = URL_SAFE_NO_PAD.encode(hash.finalize());
    let row = state.db.query_opt(
        "SELECT installation_id FROM sessions WHERE token_hash = $1 AND revoked_at IS NULL AND expires_at > NOW()",
        &[&token_hash],
    ).await.map_err(|_| error(StatusCode::INTERNAL_SERVER_ERROR, "database error"))?;
    row.map(|row| row.get(0))
        .ok_or_else(|| error(StatusCode::UNAUTHORIZED, "invalid_request"))
}

async fn take_valid_challenge(
    state: &AppState,
    id: Uuid,
) -> Result<Challenge, (StatusCode, Json<serde_json::Value>)> {
    let challenge = state.challenges.write().await.remove(&id).ok_or_else(|| {
        error(
            StatusCode::BAD_REQUEST,
            "challenge not found or already used",
        )
    })?;
    if challenge.expires_at < now() {
        return Err(error(StatusCode::BAD_REQUEST, "challenge expired"));
    }
    Ok(challenge)
}

async fn issue_session(state: &AppState, installation_id: &str) -> String {
    let mut bytes = [0u8; 32];
    rng().fill(&mut bytes);
    let token = URL_SAFE_NO_PAD.encode(bytes);
    let mut hash = sha2::Sha256::new();
    hash.update(token.as_bytes());
    let token_hash = URL_SAFE_NO_PAD.encode(hash.finalize());
    let _ = state.db.execute(
        "INSERT INTO sessions (token_hash, installation_id, expires_at) VALUES ($1, $2, NOW() + INTERVAL '24 hours')",
        &[&token_hash, &installation_id],
    ).await;
    state
        .sessions
        .write()
        .await
        .insert(token.clone(), installation_id.to_owned());
    token
}

fn now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or(Duration::ZERO)
        .as_secs()
}
fn error(status: StatusCode, message: &str) -> (StatusCode, Json<serde_json::Value>) {
    (status, Json(serde_json::json!({ "error": message })))
}
