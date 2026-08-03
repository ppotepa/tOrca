use axum::{
    Json,
    http::{HeaderMap, StatusCode},
};
use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD};
use rand::{Rng, rng};
use sha2::{Digest, Sha256};
use std::{
    collections::HashMap,
    sync::Arc,
    time::{Duration, SystemTime, UNIX_EPOCH},
};
use tokio::sync::RwLock;
use uuid::Uuid;

#[derive(Clone)]
pub(crate) struct Challenge {
    pub(crate) value: String,
    pub(crate) expires_at: u64,
}

pub(crate) fn now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or(Duration::ZERO)
        .as_secs()
}

pub(crate) fn new_session_token() -> (String, String) {
    let mut bytes = [0u8; 32];
    rng().fill(&mut bytes);
    let token = URL_SAFE_NO_PAD.encode(bytes);
    (token.clone(), hash_session_token(&token))
}

pub(crate) fn hash_session_token(token: &str) -> String {
    let mut hash = Sha256::new();
    hash.update(token.as_bytes());
    URL_SAFE_NO_PAD.encode(hash.finalize())
}

pub(crate) async fn authorize(
    db: &tokio_postgres::Client,
    headers: &HeaderMap,
) -> Result<String, (StatusCode, Json<serde_json::Value>)> {
    let value = headers.get("authorization").and_then(|v| v.to_str().ok());
    let Some(token) = value.and_then(|v| v.strip_prefix("Bearer ")) else {
        return Err(crate::http_support::error(
            StatusCode::UNAUTHORIZED,
            "invalid_request",
        ));
    };
    let token_hash = hash_session_token(token);
    let row = db
        .query_opt(crate::queries::SQL_SESSION_AUTHORIZE, &[&token_hash])
        .await
        .map_err(|_| {
            crate::http_support::error(StatusCode::INTERNAL_SERVER_ERROR, "database error")
        })?;
    row.map(|row| row.get(0))
        .ok_or_else(|| crate::http_support::error(StatusCode::UNAUTHORIZED, "invalid_request"))
}

pub(crate) async fn issue_session(
    db: &tokio_postgres::Client,
    installation_id: &str,
) -> Result<String, tokio_postgres::Error> {
    let (token, token_hash) = new_session_token();
    db.execute(
        crate::queries::SQL_SESSION_INSERT,
        &[&token_hash, &installation_id],
    )
    .await
    .map(|_| token)
}

pub(crate) async fn take_valid_challenge(
    challenges: &Arc<RwLock<HashMap<Uuid, Challenge>>>,
    id: Uuid,
) -> Result<Challenge, (StatusCode, Json<serde_json::Value>)> {
    let challenge = challenges.write().await.remove(&id).ok_or_else(|| {
        crate::http_support::error(
            StatusCode::BAD_REQUEST,
            "challenge not found or already used",
        )
    })?;
    if challenge.expires_at < now() {
        return Err(crate::http_support::error(
            StatusCode::BAD_REQUEST,
            "challenge expired",
        ));
    }
    Ok(challenge)
}

#[cfg(test)]
mod tests {
    use super::{Challenge, hash_session_token, new_session_token, take_valid_challenge};
    use std::{collections::HashMap, sync::Arc};
    use tokio::sync::RwLock;
    use uuid::Uuid;

    #[tokio::test]
    async fn challenge_is_consumed_once() {
        let id = Uuid::new_v4();
        let challenges = Arc::new(RwLock::new(HashMap::from([(
            id,
            Challenge {
                value: "value".into(),
                expires_at: u64::MAX,
            },
        )])));
        assert!(take_valid_challenge(&challenges, id).await.is_ok());
        assert!(take_valid_challenge(&challenges, id).await.is_err());
    }

    #[test]
    fn session_token_hash_is_stable_without_exposing_token() {
        let (token, hash) = new_session_token();
        assert_ne!(token, hash);
        assert_eq!(hash, hash_session_token(&token));
    }
}
