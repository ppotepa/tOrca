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
use tokio::sync::{RwLock, mpsc};
use tracing::info;
use uuid::Uuid;

const CHALLENGE_TTL_SECONDS: u64 = 300;
const PAIRING_CODE_TTL_SECONDS: u64 = 60;
const PAIRING_REQUEST_TTL_SECONDS: u64 = 600;
const PAIRING_ATTEMPT_WINDOW_SECONDS: u64 = 60;
const PAIRING_ATTEMPT_LIMIT: u32 = 5;
const DATABASE_MIGRATIONS: &[(&str, &str)] = &[
    (
        "004_schema_sql_files.sql",
        include_str!("../../../infra/db/migrations/004_schema_sql_files.sql"),
    ),
    (
        "005_pairing_sql_file.sql",
        include_str!("../../../infra/db/migrations/005_pairing_sql_file.sql"),
    ),
];

const SQL_SCHEMA_MIGRATIONS: &str = include_str!("../sql/schema_migrations.sql");
const SQL_SCHEMA_MIGRATION_LOOKUP: &str =
    include_str!("../sql/queries/schema_migration_lookup.sql");
const SQL_SCHEMA_MIGRATION_INSERT: &str =
    include_str!("../sql/queries/schema_migration_insert.sql");
const SQL_PRUNE_SESSIONS: &str = include_str!("../sql/queries/prune_sessions.sql");
const SQL_PRUNE_PAIRING_CODES: &str = include_str!("../sql/queries/prune_pairing_codes.sql");
const SQL_PRUNE_PENDING_PAIRINGS: &str =
    include_str!("../sql/queries/prune_pending_pairings.sql");
const SQL_INSTALLATION_NICKNAME: &str =
    include_str!("../sql/queries/installation_nickname.sql");
const SQL_INSTALLATION_UPSERT: &str = include_str!("../sql/queries/installation_upsert.sql");
const SQL_INSTALLATION_PROFILE: &str = include_str!("../sql/queries/installation_profile.sql");
const SQL_PROFILE_UPDATE_NICKNAME: &str =
    include_str!("../sql/queries/profile_update_nickname.sql");
const SQL_PAIRING_CODE_DELETE_FOR_INSTALLATION: &str =
    include_str!("../sql/queries/pairing_code_delete_for_installation.sql");
const SQL_PAIRING_CODE_INSERT: &str = include_str!("../sql/queries/pairing_code_insert.sql");
const SQL_PAIRING_CODE_CONSUME: &str = include_str!("../sql/queries/pairing_code_consume.sql");
const SQL_PAIRING_REQUEST_INSERT: &str =
    include_str!("../sql/queries/pairing_request_insert.sql");
const SQL_PAIRING_INBOX_LIST: &str = include_str!("../sql/queries/pairing_inbox_list.sql");
const SQL_PAIRING_REQUEST_ACK: &str = include_str!("../sql/queries/pairing_request_ack.sql");
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
    connections: Arc<RwLock<HashMap<String, mpsc::UnboundedSender<Message>>>>,
    pairing_secret: Arc<String>,
    pairing_attempts: Arc<RwLock<HashMap<String, PairingAttemptWindow>>>,
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

#[derive(Deserialize)]
struct CreatePairingRequest {
    code: String,
}

#[derive(Serialize)]
struct PairingRequestCreated {
    pairing_id: Uuid,
    expires_at: i64,
}

#[derive(Serialize)]
struct PairingInboxItem {
    pairing_id: Uuid,
    sender: ContactCardView,
    capability: String,
    expires_at: i64,
}

#[derive(Deserialize)]
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
        let existing = db
            .query_opt(SQL_SCHEMA_MIGRATION_LOOKUP, &[name])
            .await?;
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
    };
    let app = Router::new()
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
        .route("/v1/contacts", get(list_contacts))
        .route("/v1/contacts/confirm", post(confirm_contact))
        .route("/v1/contacts/{installation_id}", axum::routing::delete(remove_contact))
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
        .execute(SQL_INSTALLATION_UPSERT, &[&installation_id, &request.public_key])
        .await
        .map_err(|_| error(StatusCode::INTERNAL_SERVER_ERROR, "database error"))?;
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
    state
        .db
        .execute(SQL_PAIRING_CODE_DELETE_FOR_INSTALLATION, &[&installation_id])
        .await
        .map_err(|_| error(StatusCode::INTERNAL_SERVER_ERROR, "database error"))?;
    let expires_at = now() + PAIRING_CODE_TTL_SECONDS;
    for _ in 0..8 {
        let code = format!("{:08}", random::<u32>() % 100_000_000);
        let hash = pairing_code_hash(&state, &code);
        let result = state
            .db
            .execute(
                SQL_PAIRING_CODE_INSERT,
                &[&hash, &installation_id, &(expires_at as i64)],
            )
            .await;
        match result {
            Ok(_) => return Ok(Json(PairingCodeResponse { code, expires_at })),
            Err(db_error) if db_error.code().is_some_and(|code| code.code() == "23505") => continue,
            Err(_) => return Err(error(StatusCode::INTERNAL_SERVER_ERROR, "database error")),
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
    let code = request.code.trim();
    if code.len() != 8 || !code.bytes().all(|value| value.is_ascii_digit()) {
        return Err(error(
            StatusCode::BAD_REQUEST,
            "pairing code must have exactly 8 digits",
        ));
    }
    take_pairing_attempt(&state, &sender).await?;
    let hash = pairing_code_hash(&state, code);
    let row = state
        .db
        .query_opt(SQL_PAIRING_CODE_CONSUME, &[&hash])
        .await
        .map_err(|_| error(StatusCode::INTERNAL_SERVER_ERROR, "database error"))?;
    let Some(row) = row else {
        return Err(error(
            StatusCode::NOT_FOUND,
            "pairing code expired or invalid",
        ));
    };
    let recipient: String = row.get(0);
    if recipient == sender {
        return Err(error(StatusCode::BAD_REQUEST, "cannot pair with yourself"));
    }
    let pairing_id = Uuid::new_v4();
    let expires_at = now() + PAIRING_REQUEST_TTL_SECONDS;
    let capability = pairing_capability(&state, pairing_id, &sender, &recipient, expires_at);
    state
        .db
        .execute(
            SQL_PAIRING_REQUEST_INSERT,
            &[&pairing_id, &sender, &recipient, &capability, &(expires_at as i64)],
        )
        .await
        .map_err(|_| error(StatusCode::INTERNAL_SERVER_ERROR, "database error"))?;
    Ok((
        StatusCode::CREATED,
        Json(PairingRequestCreated {
            pairing_id,
            expires_at: expires_at as i64,
        }),
    ))
}

async fn list_pairing_inbox(
    State(state): State<AppState>,
    headers: HeaderMap,
) -> Result<Json<Vec<PairingInboxItem>>, (StatusCode, Json<serde_json::Value>)> {
    let recipient = authorize(&state, &headers).await?;
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
        });
    }
    Ok(Json(result))
}

async fn ack_pairing_request(
    State(state): State<AppState>,
    headers: HeaderMap,
    axum::extract::Path(pairing_id): axum::extract::Path<Uuid>,
) -> Result<StatusCode, (StatusCode, Json<serde_json::Value>)> {
    let recipient = authorize(&state, &headers).await?;
    let changed = state
        .db
        .execute(SQL_PAIRING_REQUEST_ACK, &[&pairing_id, &recipient])
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
    let mut parts = decoded.rsplitn(2, ':');
    let signature = parts.next()?;
    let body = parts.next()?;
    if !constant_time_equal(signature.as_bytes(), pairing_mac(&state.pairing_secret, body).as_bytes()) {
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
        && left.iter().zip(right).fold(0_u8, |value, (a, b)| value | (a ^ b)) == 0
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
        nickname: nickname.unwrap_or_else(|| installation_id.to_owned()),
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

async fn issue_session(state: &AppState, installation_id: &str) -> String {
    let mut bytes = [0u8; 32];
    rng().fill(&mut bytes);
    let token = URL_SAFE_NO_PAD.encode(bytes);
    let mut hash = sha2::Sha256::new();
    hash.update(token.as_bytes());
    let token_hash = URL_SAFE_NO_PAD.encode(hash.finalize());
    let _ = state
        .db
        .execute(SQL_SESSION_INSERT, &[&token_hash, &installation_id])
        .await;
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
