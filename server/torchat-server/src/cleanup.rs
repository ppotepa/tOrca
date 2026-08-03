use crate::{auth, bootstrap};
use std::{collections::HashMap, sync::Arc};
use tokio::sync::RwLock;
use tokio_postgres::Client;
use uuid::Uuid;

#[derive(Clone, Copy)]
pub(crate) struct PairingAttemptWindow {
    pub(crate) started_at: u64,
    pub(crate) count: u32,
}

impl PairingAttemptWindow {
    pub(crate) fn consume(&mut self, now: u64, window_seconds: u64, limit: u32) -> bool {
        if now.saturating_sub(self.started_at) >= window_seconds {
            self.started_at = now;
            self.count = 0;
        }
        if self.count >= limit {
            return false;
        }
        self.count += 1;
        true
    }
}

pub(crate) fn spawn(
    db: Arc<Client>,
    challenges: Arc<RwLock<HashMap<Uuid, auth::Challenge>>>,
    pairing_attempts: Arc<RwLock<HashMap<String, PairingAttemptWindow>>>,
    challenge_budgets: Arc<RwLock<HashMap<String, PairingAttemptWindow>>>,
    attempt_window_seconds: u64,
) {
    tokio::spawn(async move {
        let mut interval = tokio::time::interval(std::time::Duration::from_secs(60));
        loop {
            interval.tick().await;
            if let Err(error) = bootstrap::prune_server_metadata(&db).await {
                tracing::error!(%error, "periodic server metadata cleanup failed");
            }
            let current = auth::now();
            challenges
                .write()
                .await
                .retain(|_, challenge| challenge.expires_at >= current);
            pairing_attempts.write().await.retain(|_, attempt| {
                current.saturating_sub(attempt.started_at) < attempt_window_seconds
            });
            challenge_budgets.write().await.retain(|_, attempt| {
                current.saturating_sub(attempt.started_at) < attempt_window_seconds
            });
        }
    });
}

#[cfg(test)]
mod tests {
    use super::PairingAttemptWindow;

    #[test]
    fn ttl_window_is_atomic_and_resets_after_expiry() {
        let mut window = PairingAttemptWindow {
            started_at: 100,
            count: 0,
        };
        assert!(window.consume(100, 60, 2));
        assert!(window.consume(101, 60, 2));
        assert!(!window.consume(102, 60, 2));
        assert!(window.consume(160, 60, 2));
        assert_eq!(window.count, 1);
    }
}
