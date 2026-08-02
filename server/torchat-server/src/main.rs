//! TorChat delivery server bootstrap API.
//!
//! This process routes authenticated opaque envelopes. It must not contain
//! message decryption code or receive client private keys.

use axum::{
    Json, Router,
    body::Bytes,
    extract::{
        DefaultBodyLimit, State, WebSocketUpgrade,
        ws::{Message, WebSocket},
    },
    http::{HeaderMap, StatusCode},
    response::{Html, Redirect, Response},
    routing::{get, post},
};
use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD};
use futures_util::{SinkExt, StreamExt};
use hmac::{Hmac, Mac};
use rand::{Rng, random, rng};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::{
    collections::HashMap,
    env,
    net::SocketAddr,
    sync::Arc,
    time::{Duration, SystemTime, UNIX_EPOCH},
};
use tokio::sync::{RwLock, mpsc, oneshot};
use tracing::info;
use uuid::Uuid;

const CHALLENGE_TTL_SECONDS: u64 = 300;
const PAIRING_CODE_TTL_SECONDS: u64 = 60;
const PAIRING_REQUEST_TTL_SECONDS: u64 = 600;
const PAIRING_ATTEMPT_WINDOW_SECONDS: u64 = 60;
const PAIRING_ATTEMPT_LIMIT: u32 = 5;
const MAX_PENDING_CHALLENGES: usize = 10_000;
const MAX_JSON_REQUEST_BYTES: usize = 16 * 1024;
const DATABASE_MIGRATIONS: &[(&str, &str)] = &[
    (
        "004_schema_sql_files.sql",
        include_str!("../../../infra/db/migrations/004_schema_sql_files.sql"),
    ),
    (
        "005_pairing_sql_file.sql",
        include_str!("../../../infra/db/migrations/005_pairing_sql_file.sql"),
    ),
    (
        "006_pairing_request_deduplication.sql",
        include_str!("../../../infra/db/migrations/006_pairing_request_deduplication.sql"),
    ),
    (
        "007_contacts.sql",
        include_str!("../../../infra/db/migrations/007_contacts.sql"),
    ),
];

const SQL_SCHEMA_MIGRATIONS: &str = include_str!("../sql/schema_migrations.sql");
const SQL_SCHEMA_MIGRATION_LOOKUP: &str =
    include_str!("../sql/queries/schema_migration_lookup.sql");
const SQL_SCHEMA_MIGRATION_INSERT: &str =
    include_str!("../sql/queries/schema_migration_insert.sql");
const SQL_PRUNE_SESSIONS: &str = include_str!("../sql/queries/prune_sessions.sql");
const SQL_PRUNE_PAIRING_CODES: &str = include_str!("../sql/queries/prune_pairing_codes.sql");
const SQL_PRUNE_PENDING_PAIRINGS: &str = include_str!("../sql/queries/prune_pending_pairings.sql");
const SQL_INSTALLATION_NICKNAME: &str = include_str!("../sql/queries/installation_nickname.sql");
const SQL_INSTALLATION_UPSERT: &str = include_str!("../sql/queries/installation_upsert.sql");
const SQL_INSTALLATION_PROFILE: &str = include_str!("../sql/queries/installation_profile.sql");
const SQL_PROFILE_UPDATE_NICKNAME: &str =
    include_str!("../sql/queries/profile_update_nickname.sql");
const SQL_PAIRING_CODE_DELETE_FOR_INSTALLATION: &str =
    include_str!("../sql/queries/pairing_code_delete_for_installation.sql");
const SQL_PAIRING_CODE_INSERT: &str = include_str!("../sql/queries/pairing_code_insert.sql");
const SQL_PAIRING_CODE_LOOKUP: &str = include_str!("../sql/queries/pairing_code_lookup.sql");
const SQL_PAIRING_CODE_CONSUME: &str = include_str!("../sql/queries/pairing_code_consume.sql");
const SQL_PAIRING_REQUEST_LOOKUP: &str = include_str!("../sql/queries/pairing_request_lookup.sql");
const SQL_PAIRING_REQUEST_INSERT: &str = include_str!("../sql/queries/pairing_request_insert.sql");
const SQL_PAIRING_INBOX_LIST: &str = include_str!("../sql/queries/pairing_inbox_list.sql");
const SQL_PAIRING_REQUEST_ACK: &str = include_str!("../sql/queries/pairing_request_ack.sql");
const SQL_PAIRING_REQUEST_CANCEL: &str = include_str!("../sql/queries/pairing_request_cancel.sql");
const SQL_CONTACTS_CONFIRM: &str = include_str!("../sql/queries/contacts_confirm.sql");
const SQL_CONTACTS_LIST: &str = include_str!("../sql/queries/contacts_list.sql");
const SQL_CONTACT_DELETE: &str = include_str!("../sql/queries/contact_delete.sql");
const SQL_SESSION_AUTHORIZE: &str = include_str!("../sql/queries/session_authorize.sql");
const SQL_SESSION_INSERT: &str = include_str!("../sql/queries/session_insert.sql");

#[derive(Clone)]
struct AppState {
    db: Arc<tokio_postgres::Client>,
    challenges: Arc<RwLock<HashMap<Uuid, Challenge>>>,
    installations: Arc<RwLock<HashMap<String, Installation>>>,
    connections: Arc<RwLock<HashMap<String, Connection>>>,
    pairing_secret: Arc<String>,
    pairing_attempts: Arc<RwLock<HashMap<String, PairingAttemptWindow>>>,
    dev_reserved_pairing_nickname: Arc<Option<String>>,
    dev_reserved_pairing_code: Arc<Option<String>>,
}

#[derive(Clone, Copy)]
struct PairingAttemptWindow {
    started_at: u64,
    count: u32,
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

#[derive(Clone)]
struct Connection {
    id: Uuid,
    sender: mpsc::Sender<OutboundCommand>,
}

enum OutboundCommand {
    Frame {
        frame: torchat_core::relay::RelayServerFrame,
        completion: Option<oneshot::Sender<Result<(), String>>>,
    },
    WebSocketPong(Bytes),
    Close,
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
    session_token: String,
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
struct ContactCardView {
    installation_id: String,
    nickname: String,
    public_key: String,
    fingerprint: String,
}

#[derive(Serialize)]
struct PairingCodeResponse {
    code: String,
    expires_at: u64,
}

#[derive(Deserialize, Serialize)]
struct CreatePairingRequest {
    code: String,
}

#[derive(Serialize)]
struct PairingRequestCreated {
    pairing_id: Uuid,
    expires_at: i64,
    state: &'static str,
    #[serde(skip_serializing_if = "Option::is_none")]
    sender: Option<ContactCardView>,
}

#[derive(Serialize)]
struct PairingInboxItem {
    pairing_id: Uuid,
    sender: ContactCardView,
    capability: String,
    expires_at: i64,
    state: &'static str,
}

#[derive(Deserialize, Serialize)]
struct ConfirmContactRequest {
    capability: String,
    peer_installation_id: String,
}

async fn apply_database_migrations(
    db: &mut tokio_postgres::Client,
) -> Result<(), tokio_postgres::Error> {
    db.batch_execute(SQL_SCHEMA_MIGRATIONS).await?;

    for (name, sql) in DATABASE_MIGRATIONS {
        let checksum = format!("{:x}", Sha256::digest(sql.as_bytes()));
        let existing = db.query_opt(SQL_SCHEMA_MIGRATION_LOOKUP, &[name]).await?;
        if let Some(row) = existing {
            let applied: String = row.get(0);
            if applied != checksum {
                panic!("database migration checksum changed: {name}");
            }
            continue;
        }
        let transaction = db.transaction().await?;
        transaction.batch_execute(sql).await?;
        transaction
            .execute(SQL_SCHEMA_MIGRATION_INSERT, &[name, &checksum])
            .await?;
        transaction.commit().await?;
        info!(migration = *name, "database migration applied");
    }
    Ok(())
}

async fn prune_server_metadata(db: &tokio_postgres::Client) -> Result<(), tokio_postgres::Error> {
    db.execute(SQL_PRUNE_SESSIONS, &[]).await?;
    db.execute(SQL_PRUNE_PAIRING_CODES, &[]).await?;
    db.execute(SQL_PRUNE_PENDING_PAIRINGS, &[]).await?;
    Ok(())
}

#[tokio::main]
async fn main() {
    tracing_subscriber::fmt()
        .with_env_filter(env::var("RUST_LOG").unwrap_or_else(|_| "info".into()))
        .init();
    let database_url = match env::var("TORCHAT_DATABASE_URL_FILE") {
        Ok(path) => std::fs::read_to_string(path)
            .expect("TORCHAT_DATABASE_URL_FILE must be readable")
            .trim()
            .to_owned(),
        Err(_) => env::var("TORCHAT_DATABASE_URL").unwrap_or_else(|_| {
            "postgres://torchat:local-development-only@127.0.0.1:5432/torchat".into()
        }),
    };
    let (mut db, connection) = tokio_postgres::connect(&database_url, tokio_postgres::NoTls)
        .await
        .expect("TORCHAT_DATABASE_URL must point to PostgreSQL");
    tokio::spawn(async move {
        if let Err(error) = connection.await {
            tracing::error!(%error, "postgres connection failed");
        }
    });
    apply_database_migrations(&mut db)
        .await
        .expect("database migration failed");
    prune_server_metadata(&db)
        .await
        .expect("server metadata cleanup failed");
    let state = AppState {
        db: Arc::new(db),
        challenges: Arc::new(RwLock::new(HashMap::new())),
        installations: Arc::new(RwLock::new(HashMap::new())),
        connections: Arc::new(RwLock::new(HashMap::new())),
        pairing_secret: Arc::new(
            env::var("TORCHAT_PAIRING_SECRET").expect("TORCHAT_PAIRING_SECRET is required"),
        ),
        pairing_attempts: Arc::new(RwLock::new(HashMap::new())),
        dev_reserved_pairing_nickname: Arc::new(
            env::var("TORCHAT_DEV_RESERVED_PAIRING_NICKNAME")
                .ok()
                .map(|value| value.trim().to_owned())
                .filter(|value| !value.is_empty()),
        ),
        dev_reserved_pairing_code: Arc::new(
            env::var("TORCHAT_DEV_RESERVED_PAIRING_CODE")
                .ok()
                .map(|value| value.trim().to_owned())
                .filter(|value| value.len() == 8 && value.chars().all(|ch| ch.is_ascii_digit())),
        ),
    };
    let cleanup_state = state.clone();
    tokio::spawn(async move {
        let mut interval = tokio::time::interval(Duration::from_secs(60));
        loop {
            interval.tick().await;
            if let Err(error) = prune_server_metadata(&cleanup_state.db).await {
                tracing::error!(%error, "periodic server metadata cleanup failed");
            }
            let current = now();
            cleanup_state
                .challenges
                .write()
                .await
                .retain(|_, challenge| challenge.expires_at >= current);
            cleanup_state
                .pairing_attempts
                .write()
                .await
                .retain(|_, attempt| {
                    current.saturating_sub(attempt.started_at) < PAIRING_ATTEMPT_WINDOW_SECONDS
                });
        }
    });
    let app = Router::new()
        .route("/", get(status_redirect))
        .route("/status", get(status_page))
        .route("/health", get(health))
        .route("/v1/bootstrap/challenge", post(create_challenge))
        .route("/v1/installations", post(register_installation))
        .route("/v1/sessions", post(create_session))
        .route("/v1/profile", get(get_profile).put(update_profile))
        .route("/v1/pairing-codes/refresh", post(refresh_pairing_code))
        .route("/v1/pairing-requests", post(create_pairing_request))
        .route("/v1/pairing-requests/inbox", get(list_pairing_inbox))
        .route(
            "/v1/pairing-requests/{pairing_id}/ack",
            post(ack_pairing_request),
        )
        .route(
            "/v1/pairing-requests/{pairing_id}",
            axum::routing::delete(cancel_pairing_request),
        )
        .route("/v1/contacts", get(list_contacts))
        .route("/v1/contacts/confirm", post(confirm_contact))
        .route(
            "/v1/contacts/{installation_id}",
            axum::routing::delete(remove_contact),
        )
        .route("/v1/events", get(events))
        // Bootstrap and pairing payloads are small signed metadata. Do not
        // let an unauthenticated caller make Axum buffer arbitrary bodies.
        .layer(DefaultBodyLimit::max(MAX_JSON_REQUEST_BYTES))
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
    info!("health probe ok");
    Json(Health {
        status: "ok",
        protocol_version: torchat_core::protocol_version(),
    })
}

async fn status_redirect() -> Redirect {
    Redirect::temporary("/status")
}

async fn status_page() -> Html<String> {
    let protocol_version = torchat_core::protocol_version();
    let checked_at = now();
    info!(protocol_version, "status page served");
    Html(format!(
        r#"<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <meta http-equiv="refresh" content="10">
  <title>TorChat onion status</title>
  <style>
    :root {{ color-scheme: dark; font-family: system-ui, sans-serif; }}
    body {{ margin: 0; min-height: 100vh; display: grid; place-items: center; background: #111; color: #eee; }}
    main {{ width: min(32rem, calc(100% - 2rem)); border: 1px solid #3a3a3a; padding: 1.5rem; }}
    h1 {{ margin: 0 0 1rem; font-size: 1.35rem; }}
    .ok {{ color: #63d68b; font-size: 1.1rem; font-weight: 700; }}
    dl {{ display: grid; grid-template-columns: auto 1fr; gap: .65rem 1rem; margin: 1.5rem 0 0; }}
    dt {{ color: #aaa; }} dd {{ margin: 0; overflow-wrap: anywhere; }}
    small {{ display: block; margin-top: 1.5rem; color: #888; }}
  </style>
</head>
<body>
  <main>
    <h1>TorChat onion service</h1>
    <div class="ok">Online</div>
    <dl>
      <dt>Protocol</dt><dd>{protocol_version}</dd>
      <dt>Server time</dt><dd>{checked_at} (Unix)</dd>
      <dt>Path</dt><dd>/status via Tor v3 onion</dd>
    </dl>
    <small>Refreshes every 10 seconds. JSON probe: /health</small>
  </main>
</body>
</html>"#
    ))
}

async fn create_challenge(
    State(state): State<AppState>,
) -> Result<Json<ChallengeResponse>, (StatusCode, Json<serde_json::Value>)> {
    let current = now();
    let mut challenges = state.challenges.write().await;
    challenges.retain(|_, challenge| challenge.expires_at >= current);
    if challenges.len() >= MAX_PENDING_CHALLENGES {
        return Err(error(
            StatusCode::TOO_MANY_REQUESTS,
            "bootstrap challenge capacity reached",
        ));
    }
    let challenge_id = Uuid::new_v4();
    let mut bytes = [0u8; 32];
    rng().fill(&mut bytes);
    let challenge = URL_SAFE_NO_PAD.encode(bytes);
    let expires_at = current + CHALLENGE_TTL_SECONDS;
    challenges.insert(
        challenge_id,
        Challenge {
            value: challenge.clone(),
            expires_at,
        },
    );
    Ok(Json(ChallengeResponse {
        challenge_id,
        challenge,
        expires_in_seconds: CHALLENGE_TTL_SECONDS,
    }))
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
            .query_opt(SQL_INSTALLATION_NICKNAME, &[&installation_id])
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
    state
        .db
        .execute(
            SQL_INSTALLATION_UPSERT,
            &[&installation_id, &request.public_key],
        )
        .await
        .map_err(|_| error(StatusCode::INTERNAL_SERVER_ERROR, "database error"))?;
    let session_token = issue_session(&state, &installation_id)
        .await
        .map_err(|_| error(StatusCode::INTERNAL_SERVER_ERROR, "database error"))?;
    Ok((
        StatusCode::CREATED,
        Json(InstallationResponse { session_token }),
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
        let row = state
            .db
            .query_opt(SQL_INSTALLATION_PROFILE, &[&request.installation_id])
            .await
            .map_err(|_| error(StatusCode::INTERNAL_SERVER_ERROR, "database error"))?;
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
    let session_token = issue_session(&state, &request.installation_id)
        .await
        .map_err(|_| error(StatusCode::INTERNAL_SERVER_ERROR, "database error"))?;
    Ok(Json(InstallationResponse { session_token }))
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
        .execute(SQL_PROFILE_UPDATE_NICKNAME, &[&nickname, &installation_id])
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

async fn refresh_pairing_code(
    State(state): State<AppState>,
    headers: HeaderMap,
) -> Result<Json<PairingCodeResponse>, (StatusCode, Json<serde_json::Value>)> {
    let installation_id = authorize(&state, &headers).await?;
    tracing::info!(installation_id = %installation_id, "refresh_pairing_code");
    state
        .db
        .execute(
            SQL_PAIRING_CODE_DELETE_FOR_INSTALLATION,
            &[&installation_id],
        )
        .await
        .map_err(|_| error(StatusCode::INTERNAL_SERVER_ERROR, "database error"))?;
    let expires_at = now() + PAIRING_CODE_TTL_SECONDS;
    if let Some(code) = reserved_pairing_code_for_installation(&state, &installation_id).await {
        let hash = pairing_code_hash(&state, &code);
        state
            .db
            .execute(
                SQL_PAIRING_CODE_INSERT,
                &[&hash, &installation_id, &(expires_at as f64)],
            )
            .await
            .map_err(|db_error| {
                tracing::error!(
                    installation_id = %installation_id,
                    error = %db_error,
                    "reserved pairing code insert failed"
                );
                error(StatusCode::INTERNAL_SERVER_ERROR, "database error")
            })?;
        return Ok(Json(PairingCodeResponse { code, expires_at }));
    }
    for _ in 0..8 {
        let code = format!("{:08}", random::<u32>() % 100_000_000);
        let hash = pairing_code_hash(&state, &code);
        let result = state
            .db
            .execute(
                SQL_PAIRING_CODE_INSERT,
                &[&hash, &installation_id, &(expires_at as f64)],
            )
            .await;
        match result {
            Ok(_) => return Ok(Json(PairingCodeResponse { code, expires_at })),
            Err(db_error) if db_error.code().is_some_and(|code| code.code() == "23505") => continue,
            Err(db_error) => {
                tracing::error!(installation_id = %installation_id, error = %db_error, "pairing code insert failed");
                return Err(error(StatusCode::INTERNAL_SERVER_ERROR, "database error"));
            }
        }
    }
    Err(error(
        StatusCode::SERVICE_UNAVAILABLE,
        "could not allocate pairing code",
    ))
}

async fn create_pairing_request(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(request): Json<CreatePairingRequest>,
) -> Result<(StatusCode, Json<PairingRequestCreated>), (StatusCode, Json<serde_json::Value>)> {
    let sender = authorize(&state, &headers).await?;
    tracing::info!(sender = %sender, "create_pairing_request start");
    let code = torchat_core::Identity::pairing_code_digits(&request.code)
        .map_err(|message| error(StatusCode::BAD_REQUEST, &message))?;
    let reserved_recipient = reserved_pairing_recipient(&state, &code).await;
    let use_reserved_recipient = reserved_recipient.is_some();
    let hash = pairing_code_hash(&state, &code);
    let stored_row = if reserved_recipient.is_none() {
        state
            .db
            .query_opt(SQL_PAIRING_CODE_LOOKUP, &[&hash])
            .await
            .map_err(|_| error(StatusCode::INTERNAL_SERVER_ERROR, "database error"))?
    } else {
        None
    };
    let Some(recipient) = reserved_recipient
        .clone()
        .or_else(|| stored_row.map(|row| row.get(0)))
    else {
        return Err(error(
            StatusCode::NOT_FOUND,
            "pairing code expired or invalid",
        ));
    };
    if recipient == sender {
        return Err(error(StatusCode::BAD_REQUEST, "cannot pair with yourself"));
    }
    let existing = state
        .db
        .query_opt(SQL_PAIRING_REQUEST_LOOKUP, &[&sender, &recipient])
        .await
        .map_err(|_| error(StatusCode::INTERNAL_SERVER_ERROR, "database error"))?;
    if let Some(existing) = existing {
        // Retries of the same sender/recipient request are idempotent. Do not
        // consume the rate-limit budget and do not create a second pending
        // row; return the canonical request so the client can reconcile its
        // local outbox.
        let pairing_id: Uuid = existing.get(0);
        let expires_at: i64 = existing.get(1);
        let recipient_card = contact_card(&state, &recipient).await?;
        return Ok((
            StatusCode::OK,
            Json(PairingRequestCreated {
                pairing_id,
                expires_at,
                state: "PENDING",
                sender: Some(recipient_card),
            }),
        ));
    }
    take_pairing_attempt(&state, &sender).await?;
    if !use_reserved_recipient {
        let consumed = state
            .db
            .execute(SQL_PAIRING_CODE_CONSUME, &[&hash])
            .await
            .map_err(|_| error(StatusCode::INTERNAL_SERVER_ERROR, "database error"))?;
        if consumed != 1 {
            return Err(error(
                StatusCode::NOT_FOUND,
                "pairing code expired or invalid",
            ));
        }
    }
    let pairing_id = Uuid::new_v4();
    let expires_at = now() + PAIRING_REQUEST_TTL_SECONDS;
    let capability = pairing_capability(&state, pairing_id, &sender, &recipient, expires_at);
    let inserted = state
        .db
        .execute(
            SQL_PAIRING_REQUEST_INSERT,
            &[
                &pairing_id,
                &sender,
                &recipient,
                &capability,
                &(expires_at as f64),
            ],
        )
        .await
        .map_err(|db_error| {
            tracing::error!(sender = %sender, error = %db_error, "pairing request insert failed");
            error(StatusCode::INTERNAL_SERVER_ERROR, "database error")
        })?;
    if inserted == 0 {
        // A concurrent request won the unique sender/recipient race. Re-read
        // and return the same idempotent result instead of exposing a retry
        // error to the client.
        let existing = state
            .db
            .query_one(SQL_PAIRING_REQUEST_LOOKUP, &[&sender, &recipient])
            .await
            .map_err(|_| error(StatusCode::INTERNAL_SERVER_ERROR, "database error"))?;
        let recipient_card = contact_card(&state, &recipient).await?;
        return Ok((
            StatusCode::OK,
            Json(PairingRequestCreated {
                pairing_id: existing.get(0),
                expires_at: existing.get(1),
                state: "PENDING",
                sender: Some(recipient_card),
            }),
        ));
    }
    tracing::info!(
        sender = %sender,
        recipient = %recipient,
        pairing_id = %pairing_id,
        "create_pairing_request ok"
    );
    // Pairing data remains in the control-plane inbox. This frame carries no
    // contact or invite payload; it only wakes an online recipient so its
    // shared runtime can synchronize immediately instead of waiting for the
    // recovery poller.
    if let Err(notification_error) = send_server_frame(
        &state,
        &recipient,
        torchat_core::relay::RelayServerFrame::PairingAvailable { pairing_id },
    )
    .await
    {
        tracing::warn!(
            recipient = %recipient,
            pairing_id = %pairing_id,
            error = %notification_error,
            "pairing availability notification failed"
        );
    }
    let recipient_card = contact_card(&state, &recipient).await?;
    Ok((
        StatusCode::CREATED,
        Json(PairingRequestCreated {
            pairing_id,
            expires_at: expires_at as i64,
            state: "PENDING",
            sender: Some(recipient_card),
        }),
    ))
}

async fn list_pairing_inbox(
    State(state): State<AppState>,
    headers: HeaderMap,
) -> Result<Json<Vec<PairingInboxItem>>, (StatusCode, Json<serde_json::Value>)> {
    let recipient = authorize(&state, &headers).await?;
    tracing::info!(recipient = %recipient, "list_pairing_inbox");
    let rows = state
        .db
        .query(SQL_PAIRING_INBOX_LIST, &[&recipient])
        .await
        .map_err(|_| error(StatusCode::INTERNAL_SERVER_ERROR, "database error"))?;
    let mut result = Vec::with_capacity(rows.len());
    for row in rows {
        let sender: String = row.get(1);
        result.push(PairingInboxItem {
            pairing_id: row.get(0),
            sender: contact_card(&state, &sender).await?,
            capability: row.get(2),
            expires_at: row.get(3),
            state: "PENDING",
        });
    }
    tracing::info!(recipient = %recipient, count = result.len(), "list_pairing_inbox ok");
    Ok(Json(result))
}

async fn ack_pairing_request(
    State(state): State<AppState>,
    headers: HeaderMap,
    axum::extract::Path(pairing_id): axum::extract::Path<Uuid>,
) -> Result<StatusCode, (StatusCode, Json<serde_json::Value>)> {
    let recipient = authorize(&state, &headers).await?;
    tracing::info!(recipient = %recipient, pairing_id = %pairing_id, "ack_pairing_request");
    let changed = state
        .db
        .execute(SQL_PAIRING_REQUEST_ACK, &[&pairing_id, &recipient])
        .await
        .map_err(|_| error(StatusCode::INTERNAL_SERVER_ERROR, "database error"))?;
    if changed != 1 {
        return Err(error(StatusCode::NOT_FOUND, "pairing request not found"));
    }
    tracing::info!(recipient = %recipient, pairing_id = %pairing_id, "ack_pairing_request ok");
    Ok(StatusCode::NO_CONTENT)
}

async fn cancel_pairing_request(
    State(state): State<AppState>,
    headers: HeaderMap,
    axum::extract::Path(pairing_id): axum::extract::Path<Uuid>,
) -> Result<StatusCode, (StatusCode, Json<serde_json::Value>)> {
    let sender = authorize(&state, &headers).await?;
    let changed = state
        .db
        .execute(SQL_PAIRING_REQUEST_CANCEL, &[&pairing_id, &sender])
        .await
        .map_err(|_| error(StatusCode::INTERNAL_SERVER_ERROR, "database error"))?;
    if changed != 1 {
        return Err(error(StatusCode::NOT_FOUND, "pairing request not found"));
    }
    Ok(StatusCode::NO_CONTENT)
}

async fn confirm_contact(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(request): Json<ConfirmContactRequest>,
) -> Result<StatusCode, (StatusCode, Json<serde_json::Value>)> {
    let recipient = authorize(&state, &headers).await?;
    let (pairing_id, sender, capability_recipient, expires_at) =
        parse_pairing_capability(&state, &request.capability)
            .ok_or_else(|| error(StatusCode::BAD_REQUEST, "invalid pairing capability"))?;
    if pairing_id.is_nil()
        || recipient != capability_recipient
        || request.peer_installation_id != sender
        || expires_at < now()
    {
        return Err(error(
            StatusCode::BAD_REQUEST,
            "pairing capability does not match contact confirmation",
        ));
    }
    state
        .db
        .execute(SQL_CONTACTS_CONFIRM, &[&sender, &recipient])
        .await
        .map_err(|_| error(StatusCode::INTERNAL_SERVER_ERROR, "database error"))?;
    Ok(StatusCode::NO_CONTENT)
}

async fn take_pairing_attempt(
    state: &AppState,
    installation_id: &str,
) -> Result<(), (StatusCode, Json<serde_json::Value>)> {
    let current = now();
    let mut attempts = state.pairing_attempts.write().await;
    attempts.retain(|_, value| {
        current.saturating_sub(value.started_at) < PAIRING_ATTEMPT_WINDOW_SECONDS
    });
    let entry = attempts
        .entry(installation_id.to_owned())
        .or_insert(PairingAttemptWindow {
            started_at: current,
            count: 0,
        });
    if current.saturating_sub(entry.started_at) >= PAIRING_ATTEMPT_WINDOW_SECONDS {
        *entry = PairingAttemptWindow {
            started_at: current,
            count: 0,
        };
    }
    entry.count += 1;
    if entry.count > PAIRING_ATTEMPT_LIMIT {
        return Err(error(
            StatusCode::TOO_MANY_REQUESTS,
            "too many pairing attempts",
        ));
    }
    Ok(())
}

fn pairing_code_hash(state: &AppState, code: &str) -> String {
    format!(
        "{:x}",
        Sha256::digest(format!("{}:pairing-code:{code}", state.pairing_secret).as_bytes())
    )
}

async fn reserved_pairing_code_for_installation(
    state: &AppState,
    installation_id: &str,
) -> Option<String> {
    let nickname = state.dev_reserved_pairing_nickname.as_ref().as_ref()?;
    let code = state.dev_reserved_pairing_code.as_ref().as_ref()?;
    if installation_matches_reserved_nickname(state, installation_id, nickname).await {
        return Some(code.clone());
    }
    None
}

async fn reserved_pairing_recipient(state: &AppState, code: &str) -> Option<String> {
    let reserved_code = state.dev_reserved_pairing_code.as_ref().as_ref()?;
    if reserved_code != code {
        return None;
    }
    let nickname = state.dev_reserved_pairing_nickname.as_ref().as_ref()?;
    if let Some(found) =
        state
            .installations
            .read()
            .await
            .iter()
            .find_map(|(installation_id, installation)| {
                installation
                    .nickname
                    .as_ref()
                    .filter(|value| value.trim().eq_ignore_ascii_case(nickname))
                    .map(|_| installation_id.clone())
            })
    {
        return Some(found);
    }
    installation_id_for_reserved_nickname(state, nickname).await
}

async fn installation_matches_reserved_nickname(
    state: &AppState,
    installation_id: &str,
    nickname: &str,
) -> bool {
    if state
        .installations
        .read()
        .await
        .get(installation_id)
        .and_then(|installation| installation.nickname.as_ref())
        .is_some_and(|value| value.trim().eq_ignore_ascii_case(nickname))
    {
        return true;
    }
    state
        .db
        .query_opt(SQL_INSTALLATION_NICKNAME, &[&installation_id])
        .await
        .ok()
        .flatten()
        .and_then(|row| row.get::<_, Option<String>>(0))
        .is_some_and(|value| value.trim().eq_ignore_ascii_case(nickname))
}

async fn installation_id_for_reserved_nickname(state: &AppState, nickname: &str) -> Option<String> {
    state
        .db
        .query_opt(
            "SELECT installation_id
             FROM installations
             WHERE LOWER(TRIM(COALESCE(nickname, ''))) = LOWER(TRIM(?1))
             ORDER BY updated_at DESC, installation_id ASC
             LIMIT 1;",
            &[&nickname],
        )
        .await
        .ok()
        .flatten()
        .and_then(|row| row.try_get::<_, String>(0).ok())
}

fn pairing_capability(
    state: &AppState,
    pairing_id: Uuid,
    sender: &str,
    recipient: &str,
    expires_at: u64,
) -> String {
    let body = format!("{pairing_id}:{sender}:{recipient}:{expires_at}");
    let signature = pairing_mac(&state.pairing_secret, &body);
    URL_SAFE_NO_PAD.encode(format!("{body}:{signature}"))
}

fn parse_pairing_capability(state: &AppState, value: &str) -> Option<(Uuid, String, String, u64)> {
    let decoded = String::from_utf8(URL_SAFE_NO_PAD.decode(value).ok()?).ok()?;
    let (body, signature) = decoded.rsplit_once(':')?;
    if !constant_time_equal(
        signature.as_bytes(),
        pairing_mac(&state.pairing_secret, body).as_bytes(),
    ) {
        return None;
    }
    let mut fields = body.splitn(4, ':');
    Some((
        Uuid::parse_str(fields.next()?).ok()?,
        fields.next()?.to_owned(),
        fields.next()?.to_owned(),
        fields.next()?.parse().ok()?,
    ))
}

fn pairing_mac(secret: &str, body: &str) -> String {
    let mut mac = Hmac::<Sha256>::new_from_slice(secret.as_bytes())
        .expect("HMAC accepts secrets of any length");
    mac.update(body.as_bytes());
    URL_SAFE_NO_PAD.encode(mac.finalize().into_bytes())
}

fn constant_time_equal(left: &[u8], right: &[u8]) -> bool {
    left.len() == right.len()
        && left
            .iter()
            .zip(right)
            .fold(0_u8, |value, (a, b)| value | (a ^ b))
            == 0
}

async fn contact_card(
    state: &AppState,
    installation_id: &str,
) -> Result<ContactCardView, (StatusCode, Json<serde_json::Value>)> {
    let (public_key, nickname) = profile_row(state, installation_id).await?;
    Ok(ContactCardView {
        installation_id: installation_id.to_owned(),
        public_key: public_key.clone(),
        fingerprint: fingerprint_for_public_key(&public_key)?,
        nickname: nickname.unwrap_or_else(|| fallback_contact_nickname(installation_id)),
    })
}

async fn list_contacts(
    State(state): State<AppState>,
    headers: HeaderMap,
) -> Result<Json<Vec<ContactCardView>>, (StatusCode, Json<serde_json::Value>)> {
    let owner = authorize(&state, &headers).await?;
    let rows = state
        .db
        .query(SQL_CONTACTS_LIST, &[&owner])
        .await
        .map_err(|_| error(StatusCode::INTERNAL_SERVER_ERROR, "database error"))?;
    let entries = rows
        .into_iter()
        .filter_map(|row| {
            let nickname: Option<String> = row.get(2);
            nickname.map(|nickname| ContactCardView {
                installation_id: row.get(0),
                public_key: row.get(1),
                fingerprint: fingerprint_for_public_key_value(row.get(1)).unwrap_or_default(),
                nickname,
            })
        })
        .collect();
    Ok(Json(entries))
}

async fn remove_contact(
    State(state): State<AppState>,
    headers: HeaderMap,
    axum::extract::Path(installation_id): axum::extract::Path<String>,
) -> Result<StatusCode, (StatusCode, Json<serde_json::Value>)> {
    let owner = authorize(&state, &headers).await?;
    state
        .db
        .execute(SQL_CONTACT_DELETE, &[&owner, &installation_id])
        .await
        .map_err(|_| error(StatusCode::INTERNAL_SERVER_ERROR, "database error"))?;
    Ok(StatusCode::NO_CONTENT)
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
        .query_opt(SQL_INSTALLATION_PROFILE, &[&installation_id])
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

fn fallback_contact_nickname(installation_id: &str) -> String {
    let trimmed = installation_id.trim();
    if trimmed.starts_with("peer-") && trimmed.chars().count() >= 2 {
        return trimmed.chars().take(32).collect();
    }
    let suffix = installation_id.chars().take(8).collect::<String>();
    format!("peer-{suffix}")
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

async fn websocket_session(state: AppState, installation_id: String, socket: WebSocket) {
    const OUTBOUND_CAPACITY: usize = 256;
    let (outgoing_tx, mut outgoing_rx) = mpsc::channel(OUTBOUND_CAPACITY);
    let connection_id = Uuid::new_v4();
    let previous = state.connections.write().await.insert(
        installation_id.clone(),
        Connection {
            id: connection_id,
            sender: outgoing_tx.clone(),
        },
    );
    if let Some(previous) = previous {
        tracing::info!(
            installation_id = %installation_id,
            connection_id = %connection_id,
            previous_connection_id = %previous.id,
            "websocket replacing previous connection"
        );
        let _ = previous.sender.try_send(OutboundCommand::Close);
    }
    tracing::info!(
        installation_id = %installation_id,
        connection_id = %connection_id,
        "websocket session registered"
    );

    let (mut socket_writer, mut socket_reader) = socket.split();
    let writer_task = tokio::spawn(async move {
        while let Some(command) = outgoing_rx.recv().await {
            match command {
                OutboundCommand::Frame { frame, completion } => {
                    let result = socket_writer
                        .send(frame_message(frame))
                        .await
                        .map_err(|error| error.to_string());

                    if let Some(completion) = completion {
                        let _ = completion.send(result.as_ref().map(|_| ()).map_err(Clone::clone));
                    }

                    if result.is_err() {
                        break;
                    }
                }
                OutboundCommand::WebSocketPong(payload) => {
                    if socket_writer.send(Message::Pong(payload)).await.is_err() {
                        break;
                    }
                }
                OutboundCommand::Close => break,
            }
        }
    });

    let _ = outgoing_tx
        .send(OutboundCommand::Frame {
            frame: torchat_core::relay::RelayServerFrame::Ready {
                installation_id: installation_id.clone(),
            },
            completion: None,
        })
        .await;
    tracing::info!(
        installation_id = %installation_id,
        connection_id = %connection_id,
        "websocket ready queued"
    );

    loop {
        match socket_reader.next().await {
            Some(Ok(Message::Text(text))) => {
                let still_active = state
                    .connections
                    .read()
                    .await
                    .get(&installation_id)
                    .is_some_and(|connection| connection.id == connection_id);
                if !still_active {
                    break;
                }
                let result =
                    match serde_json::from_str::<torchat_core::relay::RelayClientFrame>(&text) {
                        Ok(frame) => process_frame(&state, &installation_id, frame).await,
                        Err(_) => Err("invalid_request".to_string()),
                    };
                if let Err(code) = result {
                    let _ = outgoing_tx
                        .send(OutboundCommand::Frame {
                            frame: torchat_core::relay::RelayServerFrame::Error { code },
                            completion: None,
                        })
                        .await;
                }
            }
            Some(Ok(Message::Ping(payload))) => {
                tracing::debug!(
                    installation_id = %installation_id,
                    connection_id = %connection_id,
                    bytes = payload.len(),
                    "websocket ping received"
                );
                if outgoing_tx
                    .send(OutboundCommand::WebSocketPong(payload))
                    .await
                    .is_err()
                {
                    break;
                }
            }
            Some(Ok(Message::Pong(payload))) => {
                tracing::debug!(
                    installation_id = %installation_id,
                    connection_id = %connection_id,
                    bytes = payload.len(),
                    "websocket pong received"
                );
            }
            Some(Ok(Message::Close(frame))) => {
                tracing::info!(
                    installation_id = %installation_id,
                    ?frame,
                    "websocket closed by peer"
                );
                break;
            }
            Some(Ok(Message::Binary(_))) => {
                tracing::warn!(
                    installation_id = %installation_id,
                    "unsupported binary websocket frame"
                );
                let _ = outgoing_tx
                    .send(OutboundCommand::Frame {
                        frame: torchat_core::relay::RelayServerFrame::Error {
                            code: "invalid_request".to_string(),
                        },
                        completion: None,
                    })
                    .await;
                break;
            }
            Some(Err(error)) => {
                tracing::warn!(
                    installation_id = %installation_id,
                    %error,
                    "websocket read failed"
                );
                break;
            }
            None => break,
        }
    }
    let mut connections = state.connections.write().await;
    if connections
        .get(&installation_id)
        .is_some_and(|connection| connection.id == connection_id)
    {
        connections.remove(&installation_id);
    }
    let _ = outgoing_tx.send(OutboundCommand::Close).await;
    let _ = writer_task.await;
    tracing::info!(
        installation_id = %installation_id,
        connection_id = %connection_id,
        "websocket session ended"
    );
}

async fn process_frame(
    state: &AppState,
    sender_id: &str,
    incoming_frame: torchat_core::relay::RelayClientFrame,
) -> Result<(), String> {
    match incoming_frame {
        torchat_core::relay::RelayClientFrame::Envelope(envelope) => {
            tracing::info!(
                sender = %sender_id,
                recipient = %envelope.recipient,
                message_id = %envelope.message_id,
                "relay envelope received"
            );
            route_envelope(&state.connections, sender_id, envelope).await?;
        }
        torchat_core::relay::RelayClientFrame::DeliveryReceipt { message_id, sender } => {
            if let Some(target) = state.connections.read().await.get(&sender).cloned() {
                let _ = target.sender.try_send(OutboundCommand::Frame {
                    frame: torchat_core::relay::RelayServerFrame::DeliveryReceipt { message_id },
                    completion: None,
                });
            }
        }
        torchat_core::relay::RelayClientFrame::Ping => {
            tracing::debug!(sender = %sender_id, "relay application ping received");
            send_server_frame(
                state,
                sender_id,
                torchat_core::relay::RelayServerFrame::Pong,
            )
            .await?;
        }
    }
    Ok(())
}

async fn route_envelope(
    connections: &Arc<RwLock<HashMap<String, Connection>>>,
    sender_id: &str,
    mut envelope: torchat_core::relay::RelayEnvelope,
) -> Result<(), String> {
    if envelope.version != torchat_core::PROTOCOL_VERSION
        || envelope.sender != sender_id
        || envelope.recipient.is_empty()
        || envelope.ciphertext.len() > torchat_core::peer_protocol::MAX_TRANSPORT_CIPHERTEXT_BYTES
        || !relay_ciphertext_allowed(&envelope.ciphertext)
    {
        tracing::warn!(
            sender = %sender_id,
            message_id = %envelope.message_id,
            "relay envelope rejected by validation"
        );
        return Ok(());
    }
    let recipient = connections.read().await.get(&envelope.recipient).cloned();
    let message_id = envelope.message_id;
    if let Some(recipient) = recipient {
        envelope.sender = sender_id.to_owned();
        let recipient_id = envelope.recipient.clone();
        let (completion_tx, completion_rx) = oneshot::channel();
        let queued = recipient.sender.try_send(OutboundCommand::Frame {
            frame: torchat_core::relay::RelayServerFrame::Envelope(envelope),
            completion: Some(completion_tx),
        });
        if queued.is_err() {
            tracing::warn!(
                sender = %sender_id,
                recipient = %recipient_id,
                message_id = %message_id,
                "relay recipient queue full"
            );
            let _ = recipient.sender.try_send(OutboundCommand::Close);
            send_server_frame_to_connections(
                connections,
                sender_id,
                torchat_core::relay::RelayServerFrame::RecipientOffline { message_id },
            )
            .await?;
            return Ok(());
        }

        let written = matches!(
            tokio::time::timeout(Duration::from_secs(30), completion_rx).await,
            Ok(Ok(Ok(())))
        );
        let outcome = if written {
            tracing::info!(
                sender = %sender_id,
                recipient = %recipient_id,
                message_id = %message_id,
                "relay envelope forwarded"
            );
            torchat_core::relay::RelayServerFrame::Forwarded { message_id }
        } else {
            tracing::warn!(
                sender = %sender_id,
                recipient = %recipient_id,
                message_id = %message_id,
                "relay envelope write failed"
            );
            torchat_core::relay::RelayServerFrame::RecipientOffline { message_id }
        };
        send_server_frame_to_connections(connections, sender_id, outcome).await?;
    } else {
        tracing::info!(
            sender = %sender_id,
            recipient = %envelope.recipient,
            message_id = %message_id,
            "relay recipient offline"
        );
        send_server_frame_to_connections(
            connections,
            sender_id,
            torchat_core::relay::RelayServerFrame::RecipientOffline { message_id },
        )
        .await?;
    }
    Ok(())
}

fn relay_ciphertext_allowed(ciphertext: &str) -> bool {
    match torchat_core::relay::RelayPayloadV1::decode(ciphertext) {
        Ok(
            torchat_core::relay::RelayPayloadV1::PairingOffer { .. }
            | torchat_core::relay::RelayPayloadV1::PairingRejected { .. }
            | torchat_core::relay::RelayPayloadV1::Welcome { .. }
            | torchat_core::relay::RelayPayloadV1::WelcomeApplied { .. }
            | torchat_core::relay::RelayPayloadV1::PeerEndpointBootstrap { .. },
        ) => true,
        Err(_) => torchat_core::peer_protocol::PeerCiphertextPayload::decode(ciphertext).is_ok(),
    }
}

async fn send_server_frame(
    state: &AppState,
    target_id: &str,
    frame_value: torchat_core::relay::RelayServerFrame,
) -> Result<(), String> {
    send_server_frame_to_connections(&state.connections, target_id, frame_value).await
}

async fn send_server_frame_to_connections(
    connections: &Arc<RwLock<HashMap<String, Connection>>>,
    target_id: &str,
    frame_value: torchat_core::relay::RelayServerFrame,
) -> Result<(), String> {
    if let Some(target) = connections.read().await.get(target_id).cloned() {
        let _ = target.sender.try_send(OutboundCommand::Frame {
            frame: frame_value,
            completion: None,
        });
    }
    Ok(())
}

fn frame_message<T: Serialize>(value: T) -> Message {
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
    let row = state
        .db
        .query_opt(SQL_SESSION_AUTHORIZE, &[&token_hash])
        .await
        .map_err(|_| error(StatusCode::INTERNAL_SERVER_ERROR, "database error"))?;
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

async fn issue_session(
    state: &AppState,
    installation_id: &str,
) -> Result<String, tokio_postgres::Error> {
    let mut bytes = [0u8; 32];
    rng().fill(&mut bytes);
    let token = URL_SAFE_NO_PAD.encode(bytes);
    let mut hash = sha2::Sha256::new();
    hash.update(token.as_bytes());
    let token_hash = URL_SAFE_NO_PAD.encode(hash.finalize());
    state
        .db
        .execute(SQL_SESSION_INSERT, &[&token_hash, &installation_id])
        .await
        .map(|_| token)
}

fn now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or(Duration::ZERO)
        .as_secs()
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[cfg(test)]
enum WebSocketFrameAction {
    Continue,
    Close,
}

#[cfg(test)]
fn websocket_frame_action(message: &Message) -> WebSocketFrameAction {
    match message {
        Message::Text(_) | Message::Ping(_) | Message::Pong(_) => WebSocketFrameAction::Continue,
        Message::Close(_) | Message::Binary(_) => WebSocketFrameAction::Close,
    }
}

fn error(status: StatusCode, message: &str) -> (StatusCode, Json<serde_json::Value>) {
    (status, Json(serde_json::json!({ "error": message })))
}

#[cfg(test)]
mod tests {
    use super::{
        ConfirmContactRequest, ContactCardView, CreatePairingRequest, PairingInboxItem,
        PairingRequestCreated, SQL_PAIRING_CODE_INSERT, SQL_PAIRING_REQUEST_INSERT,
    };
    use super::{
        Connection, OutboundCommand, WebSocketFrameAction, relay_ciphertext_allowed,
        route_envelope, websocket_frame_action,
    };
    use axum::extract::ws::Message;
    use std::{collections::HashMap, sync::Arc};
    use tokio::sync::{RwLock, mpsc};
    use uuid::Uuid;

    #[test]
    fn pairing_expiry_queries_declare_the_postgres_timestamp_input_type() {
        assert!(SQL_PAIRING_CODE_INSERT.contains("$3::double precision"));
        assert!(SQL_PAIRING_REQUEST_INSERT.contains("$5::double precision"));
    }

    #[test]
    fn pairing_created_response_exposes_canonical_state() {
        let value = serde_json::to_value(PairingRequestCreated {
            pairing_id: Uuid::nil(),
            expires_at: 1,
            state: "PENDING",
            sender: Some(ContactCardView {
                installation_id: "installation-torka".into(),
                nickname: "Torka".into(),
                public_key: "public-key".into(),
                fingerprint: "fingerprint".into(),
            }),
        })
        .unwrap();

        assert_eq!(value["state"], "PENDING");
        assert_eq!(value["sender"]["nickname"], "Torka");
    }

    #[test]
    fn pairing_inbox_response_exposes_canonical_state() {
        let value = serde_json::to_value(PairingInboxItem {
            pairing_id: Uuid::nil(),
            sender: ContactCardView {
                installation_id: "installation-bob".into(),
                nickname: "Bob".into(),
                public_key: "public-key".into(),
                fingerprint: "fingerprint".into(),
            },
            capability: "capability".into(),
            expires_at: 1,
            state: "PENDING",
        })
        .unwrap();

        assert_eq!(value["state"], "PENDING");
    }

    #[test]
    fn fallback_contact_nickname_stays_within_protocol_limit() {
        let nickname = super::fallback_contact_nickname(
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789",
        );
        assert!(nickname.chars().count() <= 32);
        assert!(nickname.chars().count() >= 2);
    }

    #[test]
    fn fallback_contact_nickname_keeps_existing_peer_prefix() {
        assert_eq!(super::fallback_contact_nickname("peer-1"), "peer-1");
    }

    #[test]
    fn pairing_request_insert_is_conflict_safe_for_duplicate_sender_recipient_pairs() {
        assert!(
            SQL_PAIRING_REQUEST_INSERT.contains(
                "ON CONFLICT (sender_installation_id, recipient_installation_id) DO UPDATE"
            )
        );
        assert!(SQL_PAIRING_REQUEST_INSERT.contains("pending_pairings.expires_at < NOW()"));
    }

    #[test]
    fn pairing_code_validation_trims_and_rejects_invalid_values() {
        assert_eq!(
            torchat_core::Identity::pairing_code_digits(" 12345678 ").unwrap(),
            "12345678"
        );
        assert!(torchat_core::Identity::pairing_code_digits("1234").is_err());
    }

    #[test]
    fn pairing_request_body_uses_canonical_code_field() {
        let value = serde_json::to_value(CreatePairingRequest {
            code: "12345678".into(),
        })
        .unwrap();
        assert_eq!(value["code"], "12345678");
        assert!(value.get("pairingCode").is_none());
    }

    #[test]
    fn confirm_contact_request_uses_canonical_body_fields() {
        let value = serde_json::to_value(ConfirmContactRequest {
            capability: "capability".into(),
            peer_installation_id: "installation-bob".into(),
        })
        .unwrap();
        assert_eq!(value["capability"], "capability");
        assert_eq!(value["peer_installation_id"], "installation-bob");
    }

    #[test]
    fn websocket_ping_and_pong_do_not_close_session() {
        assert_eq!(
            websocket_frame_action(&Message::Ping(vec![1, 2, 3].into())),
            WebSocketFrameAction::Continue
        );
        assert_eq!(
            websocket_frame_action(&Message::Pong(vec![4, 5, 6].into())),
            WebSocketFrameAction::Continue
        );
    }

    #[test]
    fn relay_accepts_p2p_endpoint_bootstrap_and_opaque_fallback_ciphertext() {
        let alice = torchat_core::Identity::generate();
        let bob = torchat_core::Identity::generate();
        let endpoint = torchat_core::peer_protocol::PeerEndpointBundle::new(
            &alice,
            format!("{}.onion", "a".repeat(56)),
            1,
            10,
            None,
        );
        let bootstrap = torchat_core::relay::RelayPayloadV1::peer_endpoint_bootstrap(
            &alice,
            "Alice",
            bob.installation_id(),
            endpoint,
        )
        .encode()
        .unwrap();
        let ciphertext = torchat_core::peer_protocol::PeerCiphertextPayload::new(b"opaque")
            .encode()
            .unwrap();

        assert!(relay_ciphertext_allowed(&bootstrap));
        assert!(relay_ciphertext_allowed(&ciphertext));
        assert!(!relay_ciphertext_allowed("not-a-relay-payload"));
    }

    fn envelope(message_id: Uuid) -> torchat_core::relay::RelayEnvelope {
        torchat_core::relay::RelayEnvelope {
            version: torchat_core::PROTOCOL_VERSION,
            message_id,
            sender: "sender".to_owned(),
            recipient: "recipient".to_owned(),
            ciphertext: torchat_core::relay::RelayPayloadV1::pairing_rejected(
                message_id.to_string(),
            )
            .encode()
            .expect("control-plane payload encodes"),
        }
    }

    fn connection(sender: mpsc::Sender<OutboundCommand>) -> Connection {
        Connection {
            id: Uuid::new_v4(),
            sender,
        }
    }

    #[tokio::test]
    async fn forwarded_is_sent_only_after_writer_completion() {
        let (sender_tx, mut sender_rx) = mpsc::channel(4);
        let (recipient_tx, mut recipient_rx) = mpsc::channel(4);
        let connections = Arc::new(RwLock::new(HashMap::from([
            ("sender".to_owned(), connection(sender_tx)),
            ("recipient".to_owned(), connection(recipient_tx)),
        ])));
        let message_id = Uuid::new_v4();
        let route_task = tokio::spawn({
            let connections = connections.clone();
            async move { route_envelope(&connections, "sender", envelope(message_id)).await }
        });

        let command = recipient_rx
            .recv()
            .await
            .expect("recipient receives envelope");
        let completion = match command {
            OutboundCommand::Frame {
                frame: torchat_core::relay::RelayServerFrame::Envelope(envelope),
                completion: Some(completion),
            } => {
                assert_eq!(envelope.message_id, message_id);
                completion
            }
            _ => panic!("expected recipient envelope with completion"),
        };

        assert!(sender_rx.try_recv().is_err());
        completion.send(Ok(())).unwrap();
        route_task.await.unwrap().unwrap();

        let command = sender_rx.recv().await.expect("sender receives forwarded");
        match command {
            OutboundCommand::Frame {
                frame:
                    torchat_core::relay::RelayServerFrame::Forwarded {
                        message_id: forwarded,
                    },
                completion: None,
            } => assert_eq!(forwarded, message_id),
            _ => panic!("expected forwarded after writer completion"),
        }
    }

    #[tokio::test]
    async fn full_recipient_queue_reports_offline_to_sender() {
        let (sender_tx, mut sender_rx) = mpsc::channel(4);
        let (recipient_tx, mut recipient_rx) = mpsc::channel(1);
        recipient_tx
            .try_send(OutboundCommand::Close)
            .expect("fill recipient queue");
        let connections = Arc::new(RwLock::new(HashMap::from([
            ("sender".to_owned(), connection(sender_tx)),
            ("recipient".to_owned(), connection(recipient_tx)),
        ])));
        let message_id = Uuid::new_v4();

        route_envelope(&connections, "sender", envelope(message_id))
            .await
            .unwrap();

        assert!(matches!(
            recipient_rx.try_recv(),
            Ok(OutboundCommand::Close)
        ));
        let command = sender_rx.recv().await.expect("sender receives offline");
        match command {
            OutboundCommand::Frame {
                frame:
                    torchat_core::relay::RelayServerFrame::RecipientOffline {
                        message_id: offline,
                    },
                completion: None,
            } => assert_eq!(offline, message_id),
            _ => panic!("expected recipient offline for full queue"),
        }
    }
}
