use axum::{
    Json,
    body::Body,
    http::{Request, StatusCode},
    middleware::Next,
    response::{IntoResponse, Response},
};
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use tokio::sync::Semaphore;

pub(crate) const MAX_PENDING_CHALLENGES: usize = 10_000;
pub(crate) const MAX_JSON_REQUEST_BYTES: usize = 16 * 1024;
pub(crate) const MAX_ACTIVE_WEBSOCKET_CONNECTIONS: usize = 10_000;
pub(crate) const CRYPTO_BOOTSTRAP_PERMITS: usize = 64;
pub(crate) const DB_OPERATION_PERMITS: usize = 128;
pub(crate) const REQUEST_DEADLINE: std::time::Duration = std::time::Duration::from_secs(30);
static DB_REJECTIONS: AtomicU64 = AtomicU64::new(0);

pub(crate) fn db_rejections() -> u64 {
    DB_REJECTIONS.load(Ordering::Relaxed)
}

pub(crate) async fn request_deadline(request: Request<Body>, next: Next) -> Response {
    match tokio::time::timeout(REQUEST_DEADLINE, next.run(request)).await {
        Ok(response) => response,
        Err(_) => StatusCode::REQUEST_TIMEOUT.into_response(),
    }
}

pub(crate) fn websocket_capacity_available(active_count: usize, replacing_existing: bool) -> bool {
    replacing_existing || active_count < MAX_ACTIVE_WEBSOCKET_CONNECTIONS
}

pub(crate) fn try_db_permit(
    budget: &Arc<Semaphore>,
) -> Result<tokio::sync::OwnedSemaphorePermit, (StatusCode, Json<serde_json::Value>)> {
    budget.clone().try_acquire_owned().map_err(|_| {
        DB_REJECTIONS.fetch_add(1, Ordering::Relaxed);
        crate::http_support::error(StatusCode::TOO_MANY_REQUESTS, "database capacity reached")
    })
}

#[cfg(test)]
mod tests {
    use super::{CRYPTO_BOOTSTRAP_PERMITS, DB_OPERATION_PERMITS, try_db_permit};
    use std::sync::Arc;
    use tokio::sync::Semaphore;

    #[test]
    fn admission_budgets_are_bounded() {
        const {
            assert!(CRYPTO_BOOTSTRAP_PERMITS > 0);
            assert!(DB_OPERATION_PERMITS > CRYPTO_BOOTSTRAP_PERMITS);
        }
    }

    #[tokio::test]
    async fn legal_client_survives_db_admission_flood() {
        let budget = Arc::new(Semaphore::new(4));
        let held = (0..4)
            .map(|_| try_db_permit(&budget).expect("flood can fill finite capacity"))
            .collect::<Vec<_>>();

        let rejected = (0..128).filter(|_| try_db_permit(&budget).is_err()).count();
        assert_eq!(rejected, 128);
        assert!(try_db_permit(&budget).is_err());

        drop(held);
        let legal = try_db_permit(&budget).expect("legal client admitted after capacity recovers");
        drop(legal);
    }
}
