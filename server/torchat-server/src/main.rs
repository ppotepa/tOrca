//! TorChat delivery server bootstrap API.
//!
//! This process routes authenticated opaque envelopes. It must not contain
//! message decryption code or receive client private keys.

use axum::{
    Json, Router,
    extract::{
        DefaultBodyLimit, State, WebSocketUpgrade,
        ws::{Message, WebSocket},
    },
    http::{HeaderMap, StatusCode},
    middleware,
    response::{Html, Redirect, Response},
    routing::{get, post},
};
use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD};
use futures_util::{SinkExt, StreamExt};
use rand::{Rng, random, rng};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::{
    collections::HashMap,
    env,
    net::SocketAddr,
    sync::{
        Arc,
        atomic::{AtomicU64, Ordering},
    },
    time::Duration,
};
use tokio::sync::{RwLock, Semaphore, mpsc, oneshot};
use tracing::info;
use uuid::Uuid;

mod auth;
mod bootstrap;
mod cleanup;
mod config;
mod http_support;
mod lease;
mod limits;
mod queries;
mod security;
mod ws;

use auth::*;
use cleanup::*;
use http_support::*;
use lease::*;
use limits::*;
use queries::*;
use security::*;
use ws::*;

const CHALLENGE_TTL_SECONDS: u64 = 300;
const PAIRING_CODE_TTL_SECONDS: u64 = 60;
const PAIRING_REQUEST_TTL_SECONDS: u64 = 600;
const PAIRING_ATTEMPT_WINDOW_SECONDS: u64 = 60;
const PAIRING_ATTEMPT_LIMIT: u32 = 5;
const CHALLENGE_BUDGET_LIMIT: u32 = 10;
const MAX_ADMISSION_BUCKETS: usize = 10_000;
const SINGLE_INSTANCE_ADVISORY_LOCK: i64 = 0x544f524348415430;

#[derive(Clone)]
struct AppState {
    db: Arc<tokio_postgres::Client>,
    challenges: Arc<RwLock<HashMap<Uuid, Challenge>>>,
    installations: Arc<RwLock<HashMap<String, Installation>>>,
    connections: Arc<RwLock<HashMap<String, Connection>>>,
    connection_leases: Arc<RwLock<HashMap<String, ConnectionLease>>>,
    instance_id: Uuid,
    pairing_secret: Arc<String>,
    log_secret: Arc<String>,
    crypto_bootstrap_budget: Arc<Semaphore>,
    db_operation_budget: Arc<Semaphore>,
    pairing_attempts: Arc<RwLock<HashMap<String, PairingAttemptWindow>>>,
    challenge_budgets: Arc<RwLock<HashMap<String, PairingAttemptWindow>>>,
    admission_metrics: Arc<AdmissionMetrics>,
    dev_reserved_pairing_nickname: Arc<Option<String>>,
    dev_reserved_pairing_code: Arc<Option<String>>,
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
    deployment_mode: &'static str,
    instance_guard: &'static str,
    admission_rejections: AdmissionRejectionSnapshot,
}

#[derive(Default)]
struct AdmissionMetrics {
    challenge_capacity: AtomicU64,
    challenge_budget: AtomicU64,
    crypto_bootstrap: AtomicU64,
    pairing_attempt: AtomicU64,
    websocket_capacity: AtomicU64,
}

#[derive(Serialize)]
struct AdmissionRejectionSnapshot {
    challenge_capacity: u64,
    challenge_budget: u64,
    crypto_bootstrap: u64,
    pairing_attempt: u64,
    websocket_capacity: u64,
    database_capacity: u64,
}

impl AdmissionMetrics {
    fn snapshot(&self) -> AdmissionRejectionSnapshot {
        AdmissionRejectionSnapshot {
            challenge_capacity: self.challenge_capacity.load(Ordering::Relaxed),
            challenge_budget: self.challenge_budget.load(Ordering::Relaxed),
            crypto_bootstrap: self.crypto_bootstrap.load(Ordering::Relaxed),
            pairing_attempt: self.pairing_attempt.load(Ordering::Relaxed),
            websocket_capacity: self.websocket_capacity.load(Ordering::Relaxed),
            database_capacity: limits::db_rejections(),
        }
    }
}

#[derive(Serialize)]
struct ChallengeResponse {
    challenge_id: Uuid,
    challenge: String,
    expires_in_seconds: u64,
    budget_token: String,
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

#[tokio::main]
async fn main() {
    tracing_subscriber::fmt()
        .with_env_filter(env::var("RUST_LOG").unwrap_or_else(|_| "info".into()))
        .init();
    // Validate the pairing secret before opening the database or binding the
    // listener. Misconfiguration must fail during preflight.
    let pairing_secret = config::required_secret_from_environment();
    let database_url = config::database_url();
    let (mut db, connection) = tokio_postgres::connect(&database_url, tokio_postgres::NoTls)
        .await
        .expect("TORCHAT_DATABASE_URL must point to PostgreSQL");
    tokio::spawn(async move {
        if let Err(error) = connection.await {
            tracing::error!(%error, "postgres connection failed");
        }
    });
    bootstrap::apply_database_migrations(&mut db)
        .await
        .expect("database migration failed");
    let instance_lock = db
        .query_one(
            "SELECT pg_try_advisory_lock($1)",
            &[&SINGLE_INSTANCE_ADVISORY_LOCK],
        )
        .await
        .expect("single-instance advisory lock query failed")
        .get::<_, bool>(0);
    if !instance_lock {
        panic!("TorChat relay already has an active instance for this database");
    }
    bootstrap::prune_server_metadata(&db)
        .await
        .expect("server metadata cleanup failed");
    let state = AppState {
        db: Arc::new(db),
        challenges: Arc::new(RwLock::new(HashMap::new())),
        installations: Arc::new(RwLock::new(HashMap::new())),
        connections: Arc::new(RwLock::new(HashMap::new())),
        connection_leases: Arc::new(RwLock::new(HashMap::new())),
        instance_id: Uuid::new_v4(),
        pairing_secret: Arc::new(pairing_secret),
        log_secret: Arc::new(Uuid::new_v4().to_string()),
        crypto_bootstrap_budget: Arc::new(Semaphore::new(CRYPTO_BOOTSTRAP_PERMITS)),
        db_operation_budget: Arc::new(Semaphore::new(DB_OPERATION_PERMITS)),
        pairing_attempts: Arc::new(RwLock::new(HashMap::new())),
        challenge_budgets: Arc::new(RwLock::new(HashMap::new())),
        admission_metrics: Arc::new(AdmissionMetrics::default()),
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
    cleanup::spawn(
        state.db.clone(),
        state.challenges.clone(),
        state.pairing_attempts.clone(),
        state.challenge_budgets.clone(),
        PAIRING_ATTEMPT_WINDOW_SECONDS,
    );
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
        .layer(middleware::from_fn(limits::request_deadline))
        .with_state(state);
    let address: SocketAddr = config::bind_address();
    let listener = tokio::net::TcpListener::bind(address)
        .await
        .expect("bind failed");
    info!(%address, "torchat server listening");
    axum::serve(listener, app).await.expect("server failed");
}

async fn health(State(state): State<AppState>) -> Json<Health> {
    info!("health probe ok");
    Json(Health {
        status: "ok",
        protocol_version: torchat_core::protocol_version(),
        deployment_mode: "single-instance-v0.1",
        instance_guard: "held",
        admission_rejections: state.admission_metrics.snapshot(),
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
    Json(request): Json<ChallengeRequest>,
) -> Result<Json<ChallengeResponse>, (StatusCode, Json<serde_json::Value>)> {
    let current = now();
    if request.public_key.len() > 256 || request.public_key.trim().is_empty() {
        return Err(error(
            StatusCode::BAD_REQUEST,
            "bootstrap public key is required",
        ));
    }
    if request.client_nonce.len() > 128 || request.client_nonce.trim().is_empty() {
        return Err(error(
            StatusCode::BAD_REQUEST,
            "bootstrap client nonce is required",
        ));
    }
    if request.protocol_version != torchat_core::PROTOCOL_VERSION {
        return Err(error(
            StatusCode::BAD_REQUEST,
            "unsupported bootstrap protocol version",
        ));
    }
    let mut challenges = state.challenges.write().await;
    challenges.retain(|_, challenge| challenge.expires_at >= current);
    if challenges.len() >= MAX_PENDING_CHALLENGES {
        state
            .admission_metrics
            .challenge_capacity
            .fetch_add(1, Ordering::Relaxed);
        return Err(error(
            StatusCode::TOO_MANY_REQUESTS,
            "bootstrap challenge capacity reached",
        ));
    }
    // Bind the budget before any challenge material is generated. The public
    // key is only an admission identity here; proof verification happens at
    // installation registration.
    let budget_token = format!("public-key:{}", request.public_key);
    let budget_key = pseudonymous_id(&state, &budget_token);
    let mut budgets = state.challenge_budgets.write().await;
    budgets.retain(|_, value| {
        current.saturating_sub(value.started_at) < PAIRING_ATTEMPT_WINDOW_SECONDS
    });
    if !budgets.contains_key(&budget_key) && budgets.len() >= MAX_ADMISSION_BUCKETS {
        state
            .admission_metrics
            .challenge_budget
            .fetch_add(1, Ordering::Relaxed);
        return Err(error(
            StatusCode::TOO_MANY_REQUESTS,
            "challenge budget capacity reached",
        ));
    }
    let entry = budgets.entry(budget_key).or_insert(PairingAttemptWindow {
        started_at: current,
        count: 0,
    });
    if !entry.consume(
        current,
        PAIRING_ATTEMPT_WINDOW_SECONDS,
        CHALLENGE_BUDGET_LIMIT,
    ) {
        state
            .admission_metrics
            .challenge_budget
            .fetch_add(1, Ordering::Relaxed);
        return Err(error(
            StatusCode::TOO_MANY_REQUESTS,
            "challenge budget exhausted",
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
        budget_token,
    }))
}

async fn register_installation(
    State(state): State<AppState>,
    Json(request): Json<InstallationRequest>,
) -> Result<(StatusCode, Json<InstallationResponse>), (StatusCode, Json<serde_json::Value>)> {
    let _db_permit = try_db_permit(&state.db_operation_budget)?;
    let challenge = take_valid_challenge(&state.challenges, request.challenge_id).await?;
    let _crypto_permit = state.crypto_bootstrap_budget.try_acquire().map_err(|_| {
        state
            .admission_metrics
            .crypto_bootstrap
            .fetch_add(1, Ordering::Relaxed);
        error(
            StatusCode::TOO_MANY_REQUESTS,
            "crypto bootstrap capacity reached",
        )
    })?;
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
    let session_token = issue_session(&state.db, &installation_id)
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
    let _db_permit = try_db_permit(&state.db_operation_budget)?;
    let challenge = take_valid_challenge(&state.challenges, request.challenge_id).await?;
    let _crypto_permit = state.crypto_bootstrap_budget.try_acquire().map_err(|_| {
        state
            .admission_metrics
            .crypto_bootstrap
            .fetch_add(1, Ordering::Relaxed);
        error(
            StatusCode::TOO_MANY_REQUESTS,
            "crypto bootstrap capacity reached",
        )
    })?;
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
    let session_token = issue_session(&state.db, &request.installation_id)
        .await
        .map_err(|_| error(StatusCode::INTERNAL_SERVER_ERROR, "database error"))?;
    Ok(Json(InstallationResponse { session_token }))
}

async fn get_profile(
    State(state): State<AppState>,
    headers: HeaderMap,
) -> Result<Json<ProfileResponse>, (StatusCode, Json<serde_json::Value>)> {
    let installation_id = authorize(&state.db, &headers).await?;
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
    let _db_permit = try_db_permit(&state.db_operation_budget)?;
    let installation_id = authorize(&state.db, &headers).await?;
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
    let _db_permit = try_db_permit(&state.db_operation_budget)?;
    let installation_id = authorize(&state.db, &headers).await?;
    tracing::info!(installation_id_hash = %pseudonymous_id(&state, &installation_id), "refresh_pairing_code");
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
                    installation_id_hash = %pseudonymous_id(&state, &installation_id),
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
                tracing::error!(installation_id_hash = %pseudonymous_id(&state, &installation_id), error = %db_error, "pairing code insert failed");
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
    let _db_permit = try_db_permit(&state.db_operation_budget)?;
    let sender = authorize(&state.db, &headers).await?;
    tracing::info!(sender_hash = %pseudonymous_id(&state, &sender), "create_pairing_request start");
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
            tracing::error!(sender_hash = %pseudonymous_id(&state, &sender), error = %db_error, "pairing request insert failed");
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
        sender_hash = %pseudonymous_id(&state, &sender),
        recipient_hash = %pseudonymous_id(&state, &recipient),
        pairing_id_hash = %pseudonymous_id(&state, &pairing_id.to_string()),
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
            recipient_hash = %pseudonymous_id(&state, &recipient),
            pairing_id_hash = %pseudonymous_id(&state, &pairing_id.to_string()),
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
    let _db_permit = try_db_permit(&state.db_operation_budget)?;
    let recipient = authorize(&state.db, &headers).await?;
    tracing::info!(recipient_hash = %pseudonymous_id(&state, &recipient), "list_pairing_inbox");
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
    tracing::info!(recipient_hash = %pseudonymous_id(&state, &recipient), count = result.len(), "list_pairing_inbox ok");
    Ok(Json(result))
}

async fn ack_pairing_request(
    State(state): State<AppState>,
    headers: HeaderMap,
    axum::extract::Path(pairing_id): axum::extract::Path<Uuid>,
) -> Result<StatusCode, (StatusCode, Json<serde_json::Value>)> {
    let _db_permit = try_db_permit(&state.db_operation_budget)?;
    let recipient = authorize(&state.db, &headers).await?;
    tracing::info!(recipient_hash = %pseudonymous_id(&state, &recipient), pairing_id_hash = %pseudonymous_id(&state, &pairing_id.to_string()), "ack_pairing_request");
    let changed = state
        .db
        .execute(SQL_PAIRING_REQUEST_ACK, &[&pairing_id, &recipient])
        .await
        .map_err(|_| error(StatusCode::INTERNAL_SERVER_ERROR, "database error"))?;
    if changed != 1 {
        return Err(error(StatusCode::NOT_FOUND, "pairing request not found"));
    }
    tracing::info!(recipient_hash = %pseudonymous_id(&state, &recipient), pairing_id_hash = %pseudonymous_id(&state, &pairing_id.to_string()), "ack_pairing_request ok");
    Ok(StatusCode::NO_CONTENT)
}

async fn cancel_pairing_request(
    State(state): State<AppState>,
    headers: HeaderMap,
    axum::extract::Path(pairing_id): axum::extract::Path<Uuid>,
) -> Result<StatusCode, (StatusCode, Json<serde_json::Value>)> {
    let _db_permit = try_db_permit(&state.db_operation_budget)?;
    let sender = authorize(&state.db, &headers).await?;
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
    let _db_permit = try_db_permit(&state.db_operation_budget)?;
    let recipient = authorize(&state.db, &headers).await?;
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
    if !attempts.contains_key(installation_id) && attempts.len() >= MAX_ADMISSION_BUCKETS {
        state
            .admission_metrics
            .pairing_attempt
            .fetch_add(1, Ordering::Relaxed);
        return Err(error(
            StatusCode::TOO_MANY_REQUESTS,
            "pairing attempt capacity reached",
        ));
    }
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
        state
            .admission_metrics
            .pairing_attempt
            .fetch_add(1, Ordering::Relaxed);
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

fn pseudonymous_id(state: &AppState, value: &str) -> String {
    pseudonymous_id_with_secret(&state.log_secret, value)
}

#[derive(Deserialize)]
struct ChallengeRequest {
    public_key: String,
    client_nonce: String,
    protocol_version: u16,
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
    let _db_permit = try_db_permit(&state.db_operation_budget)?;
    let owner = authorize(&state.db, &headers).await?;
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
                fingerprint: security::fingerprint_for_public_key(row.get(1)).unwrap_or_default(),
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
    let _db_permit = try_db_permit(&state.db_operation_budget)?;
    let owner = authorize(&state.db, &headers).await?;
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

fn fingerprint_for_public_key(
    value: &str,
) -> Result<String, (StatusCode, Json<serde_json::Value>)> {
    security::fingerprint_for_public_key(value.to_owned())
        .ok_or_else(|| error(StatusCode::INTERNAL_SERVER_ERROR, "invalid public key"))
}

async fn events(
    State(state): State<AppState>,
    headers: HeaderMap,
    upgrade: WebSocketUpgrade,
) -> Result<Response, (StatusCode, Json<serde_json::Value>)> {
    let _db_permit = try_db_permit(&state.db_operation_budget)?;
    let installation_id = authorize(&state.db, &headers).await?;
    let connections = state.connections.read().await;
    if !websocket_capacity_available(
        connections.len(),
        connections.contains_key(&installation_id),
    ) {
        state
            .admission_metrics
            .websocket_capacity
            .fetch_add(1, Ordering::Relaxed);
        return Err(error(
            StatusCode::TOO_MANY_REQUESTS,
            "websocket capacity reached",
        ));
    }
    drop(connections);
    Ok(upgrade.on_upgrade(move |socket| websocket_session(state, installation_id, socket)))
}

async fn websocket_session(state: AppState, installation_id: String, socket: WebSocket) {
    const OUTBOUND_CAPACITY: usize = 256;
    let (outgoing_tx, mut outgoing_rx) = mpsc::channel(OUTBOUND_CAPACITY);
    let connection_id = Uuid::new_v4();
    let lease_acquired = match acquire_shared_lease(
        &state.db,
        &installation_id,
        state.instance_id,
        connection_id,
        auth::now(),
        std::time::Duration::from_secs(30),
    )
    .await
    {
        Ok(acquired) => acquired,
        Err(error) => {
            tracing::error!(%error, "connection lease acquisition failed");
            return;
        }
    };
    if !lease_acquired {
        tracing::warn!(
            installation_id_hash = %pseudonymous_id(&state, &installation_id),
            "connection lease held by another instance"
        );
        return;
    }
    let previous = state.connections.write().await.insert(
        installation_id.clone(),
        Connection {
            id: connection_id,
            sender: outgoing_tx.clone(),
        },
    );
    state.connection_leases.write().await.insert(
        installation_id.clone(),
        ConnectionLease::new(
            state.instance_id,
            connection_id,
            auth::now(),
            std::time::Duration::from_secs(30),
        ),
    );
    if let Some(previous) = previous {
        tracing::info!(
            installation_id_hash = %pseudonymous_id(&state, &installation_id),
            connection_id_hash = %pseudonymous_id(&state, &connection_id.to_string()),
            previous_connection_id_hash = %pseudonymous_id(&state, &previous.id.to_string()),
            "websocket replacing previous connection"
        );
        let _ = previous.sender.try_send(OutboundCommand::Close);
    }
    tracing::info!(
        installation_id_hash = %pseudonymous_id(&state, &installation_id),
        connection_id_hash = %pseudonymous_id(&state, &connection_id.to_string()),
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
        installation_id_hash = %pseudonymous_id(&state, &installation_id),
        connection_id_hash = %pseudonymous_id(&state, &connection_id.to_string()),
        "websocket ready queued"
    );

    let mut lease_tick = tokio::time::interval(Duration::from_secs(10));
    loop {
        tokio::select! {
        _ = lease_tick.tick() => {
            let now = auth::now();
            let expires_at = now.saturating_add(30) as i64;
            let _ = state.db.execute(
                "UPDATE connection_leases SET expires_at = $4, updated_at = NOW()
                 WHERE installation_id = $1 AND instance_id = $2 AND connection_id = $3",
                &[&installation_id, &state.instance_id, &connection_id, &expires_at],
            ).await;
            if let Ok(Some((route_id, payload))) = claim_route(
                &state.db, &installation_id, state.instance_id, now, Duration::from_secs(10)
            ).await
                && let Ok(frame) = serde_json::from_slice::<torchat_core::relay::RelayServerFrame>(&payload)
                && outgoing_tx.send(OutboundCommand::Frame { frame, completion: None }).await.is_ok()
            {
                let _ = complete_route(&state.db, route_id, state.instance_id).await;
            }
        }
        message = socket_reader.next() => match message {
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
                    installation_id_hash = %pseudonymous_id(&state, &installation_id),
                    connection_id_hash = %pseudonymous_id(&state, &connection_id.to_string()),
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
                    installation_id_hash = %pseudonymous_id(&state, &installation_id),
                    connection_id_hash = %pseudonymous_id(&state, &connection_id.to_string()),
                    bytes = payload.len(),
                    "websocket pong received"
                );
            }
            Some(Ok(Message::Close(frame))) => {
                tracing::info!(
                    installation_id_hash = %pseudonymous_id(&state, &installation_id),
                    ?frame,
                    "websocket closed by peer"
                );
                break;
            }
            Some(Ok(Message::Binary(_))) => {
                tracing::warn!(
                    installation_id_hash = %pseudonymous_id(&state, &installation_id),
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
                    installation_id_hash = %pseudonymous_id(&state, &installation_id),
                    %error,
                    "websocket read failed"
                );
                break;
            }
            None => break,
        }
        }
    }
    let mut connections = state.connections.write().await;
    if connections
        .get(&installation_id)
        .is_some_and(|connection| connection.id == connection_id)
    {
        connections.remove(&installation_id);
    }
    drop(connections);
    let mut leases = state.connection_leases.write().await;
    if leases
        .get(&installation_id)
        .is_some_and(|lease| lease.connection_id == connection_id)
    {
        leases.remove(&installation_id);
    }
    let _ = release_shared_lease(
        &state.db,
        &installation_id,
        state.instance_id,
        connection_id,
    )
    .await;
    let _ = outgoing_tx.send(OutboundCommand::Close).await;
    let _ = writer_task.await;
    tracing::info!(
                installation_id_hash = %pseudonymous_id(&state, &installation_id),
                connection_id_hash = %pseudonymous_id(&state, &connection_id.to_string()),
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
                sender_hash = %pseudonymous_id(state, sender_id),
                recipient_hash = %pseudonymous_id(state, &envelope.recipient),
                message_id_hash = %pseudonymous_id(state, &envelope.message_id.to_string()),
                "relay envelope received"
            );
            route_envelope(
                &state.connections,
                sender_id,
                envelope,
                Some(&state.db),
                Some(state.instance_id),
            )
            .await?;
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
            tracing::debug!(sender_hash = %pseudonymous_id(state, sender_id), "relay application ping received");
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
    db: Option<&tokio_postgres::Client>,
    instance_id: Option<Uuid>,
) -> Result<(), String> {
    // A per-envelope trace is intentionally unrelated to installation,
    // recipient, pairing or message identifiers.
    let route_trace_id = Uuid::new_v4();
    if envelope.version != torchat_core::PROTOCOL_VERSION
        || envelope.sender != sender_id
        || envelope.recipient.is_empty()
        || envelope.ciphertext.len() > torchat_core::peer_protocol::MAX_TRANSPORT_CIPHERTEXT_BYTES
        || !relay_ciphertext_allowed(&envelope.ciphertext)
    {
        tracing::warn!(
            route_trace_id = %route_trace_id,
            payload_size = envelope.ciphertext.len(),
            "relay envelope rejected by validation"
        );
        return Ok(());
    }
    let recipient = connections.read().await.get(&envelope.recipient).cloned();
    let message_id = envelope.message_id;
    if let Some(recipient) = recipient {
        envelope.sender = sender_id.to_owned();
        let (completion_tx, completion_rx) = oneshot::channel();
        let queued = recipient.sender.try_send(OutboundCommand::Frame {
            frame: torchat_core::relay::RelayServerFrame::Envelope(envelope),
            completion: Some(completion_tx),
        });
        if queued.is_err() {
            tracing::warn!(
                route_trace_id = %route_trace_id,
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
                route_trace_id = %route_trace_id,
                "relay envelope forwarded"
            );
            torchat_core::relay::RelayServerFrame::Forwarded { message_id }
        } else {
            tracing::warn!(
                route_trace_id = %route_trace_id,
                "relay envelope write failed"
            );
            torchat_core::relay::RelayServerFrame::RecipientOffline { message_id }
        };
        send_server_frame_to_connections(connections, sender_id, outcome).await?;
    } else {
        tracing::info!(
        route_trace_id = %route_trace_id,
            "relay recipient offline"
        );
        let recipient_id = envelope.recipient.clone();
        let lease = match db {
            Some(db) => active_shared_lease(db, &recipient_id, auth::now())
                .await
                .map_err(|error| error.to_string())?,
            None => None,
        };
        if let Some(lease) = lease.filter(|lease| Some(lease.instance_id) != instance_id) {
            let frame = torchat_core::relay::RelayServerFrame::Envelope(envelope);
            let payload = serde_json::to_vec(&frame).map_err(|error| error.to_string())?;
            publish_route(
                db.expect("database is required for shared routing"),
                message_id,
                &recipient_id,
                lease.instance_id,
                lease.connection_id,
                &payload,
                auth::now(),
                auth::now().saturating_add(30),
            )
            .await
            .map_err(|error| error.to_string())?;
            send_server_frame_to_connections(
                connections,
                sender_id,
                torchat_core::relay::RelayServerFrame::Forwarded { message_id },
            )
            .await?;
        } else {
            send_server_frame_to_connections(
                connections,
                sender_id,
                torchat_core::relay::RelayServerFrame::RecipientOffline { message_id },
            )
            .await?;
        }
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
            | torchat_core::relay::RelayPayloadV1::PeerEndpointBootstrap { .. }
            | torchat_core::relay::RelayPayloadV1::RelationshipRemovalApplied { .. },
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

#[cfg(test)]
mod tests {
    use super::{
        ConfirmContactRequest, ContactCardView, CreatePairingRequest, DB_OPERATION_PERMITS,
        MAX_ACTIVE_WEBSOCKET_CONNECTIONS, PairingInboxItem, PairingRequestCreated,
        SQL_PAIRING_CODE_INSERT, SQL_PAIRING_REQUEST_INSERT, Semaphore,
        pseudonymous_id_with_secret,
    };
    use super::{
        Connection, OutboundCommand, WebSocketFrameAction, relay_ciphertext_allowed,
        route_envelope, websocket_capacity_available, websocket_frame_action,
    };
    use axum::extract::ws::Message;

    #[test]
    fn pseudonymous_log_identifiers_never_equal_plaintext_values() {
        let secret = "test-pairing-secret-with-at-least-32-bytes";
        let installation = "installation-sensitive-value";
        let first = pseudonymous_id_with_secret(secret, installation);
        let second = pseudonymous_id_with_secret(secret, installation);
        let other = pseudonymous_id_with_secret(secret, "other-installation");

        assert_eq!(first, second);
        assert_ne!(first, installation);
        assert_ne!(first, other);
        assert_eq!(first.len(), 16);
    }

    #[test]
    fn websocket_capacity_rejects_new_connections_but_allows_replacement() {
        assert!(websocket_capacity_available(0, false));
        assert!(!websocket_capacity_available(
            MAX_ACTIVE_WEBSOCKET_CONNECTIONS,
            false
        ));
        assert!(websocket_capacity_available(
            MAX_ACTIVE_WEBSOCKET_CONNECTIONS,
            true
        ));
    }

    #[tokio::test]
    async fn crypto_bootstrap_budget_rejects_work_when_exhausted() {
        let budget = Semaphore::new(1);
        let permit = budget.try_acquire().expect("first proof gets a permit");
        assert!(budget.try_acquire().is_err());
        drop(permit);
        assert!(budget.try_acquire().is_ok());
    }

    #[tokio::test]
    async fn db_operation_budget_has_a_finite_capacity() {
        let budget = Semaphore::new(DB_OPERATION_PERMITS);
        let mut permits = Vec::with_capacity(DB_OPERATION_PERMITS);
        for _ in 0..DB_OPERATION_PERMITS {
            permits.push(budget.try_acquire().expect("capacity permits work"));
        }
        assert!(budget.try_acquire().is_err());
        drop(permits);
        assert!(budget.try_acquire().is_ok());
    }
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
            async move {
                route_envelope(
                    &connections,
                    "sender",
                    envelope(message_id),
                    "test-secret",
                    None,
                    None,
                )
                .await
            }
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

        route_envelope(
            &connections,
            "sender",
            envelope(message_id),
            "test-secret",
            None,
            None,
        )
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
