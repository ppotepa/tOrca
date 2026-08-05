use tokio::sync::{mpsc, watch};
use tokio::time::{Instant, sleep_until};
use tokio_util::sync::CancellationToken;

use crate::input::{EngineInputEnvelope, EngineTimerKind};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) struct EngineSchedulerPlan {
    pub generation: u64,
    pub relay_poll_at: Option<Instant>,
    pub peer_probe_at: Option<Instant>,
    pub retry_at: Option<Instant>,
}

impl EngineSchedulerPlan {
    pub(crate) fn idle(generation: u64) -> Self {
        Self {
            generation,
            relay_poll_at: None,
            peer_probe_at: None,
            retry_at: None,
        }
    }

    fn next_deadline(self) -> Option<Instant> {
        [self.relay_poll_at, self.peer_probe_at, self.retry_at]
            .into_iter()
            .flatten()
            .min()
    }

    fn due_kinds(self, now: Instant) -> impl Iterator<Item = EngineTimerKind> {
        [
            self.relay_poll_at
                .filter(|deadline| *deadline <= now)
                .map(|_| EngineTimerKind::RelayPoll),
            self.peer_probe_at
                .filter(|deadline| *deadline <= now)
                .map(|_| EngineTimerKind::PeerProbeRound),
            self.retry_at
                .filter(|deadline| *deadline <= now)
                .map(|_| EngineTimerKind::RetryDue),
        ]
        .into_iter()
        .flatten()
    }
}

pub(crate) fn spawn_engine_scheduler(
    mut plans: watch::Receiver<EngineSchedulerPlan>,
    inbox: mpsc::Sender<EngineInputEnvelope>,
    shutdown: CancellationToken,
) {
    tokio::spawn(async move {
        loop {
            let plan = *plans.borrow_and_update();
            let Some(deadline) = plan.next_deadline() else {
                tokio::select! {
                    _ = shutdown.cancelled() => break,
                    changed = plans.changed() => {
                        if changed.is_err() {
                            break;
                        }
                    }
                }
                continue;
            };

            tokio::select! {
                _ = shutdown.cancelled() => break,
                changed = plans.changed() => {
                    if changed.is_err() {
                        break;
                    }
                    continue;
                }
                _ = sleep_until(deadline) => {}
            }

            let now = Instant::now();
            for kind in plan.due_kinds(now) {
                let input = EngineInputEnvelope::timer(unix_ms(), kind, plan.generation);
                if inbox.send(input).await.is_err() {
                    return;
                }
            }

            loop {
                if shutdown.is_cancelled() {
                    return;
                }
                if plans.borrow().generation != plan.generation {
                    break;
                }
                if plans.changed().await.is_err() {
                    return;
                }
            }
        }
    });
}

fn unix_ms() -> i64 {
    use std::time::{SystemTime, UNIX_EPOCH};
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis()
        .min(i64::MAX as u128) as i64
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::time::Duration;

    #[test]
    fn plan_selects_earliest_deadline() {
        let now = Instant::now();
        let plan = EngineSchedulerPlan {
            generation: 3,
            relay_poll_at: Some(now + Duration::from_secs(3)),
            peer_probe_at: Some(now + Duration::from_secs(1)),
            retry_at: Some(now + Duration::from_secs(2)),
        };

        assert_eq!(plan.next_deadline(), plan.peer_probe_at);
    }

    #[test]
    fn due_plan_emits_each_due_timer_once() {
        let now = Instant::now();
        let plan = EngineSchedulerPlan {
            generation: 4,
            relay_poll_at: Some(now),
            peer_probe_at: Some(now + Duration::from_secs(1)),
            retry_at: Some(now),
        };

        assert_eq!(
            plan.due_kinds(now).collect::<Vec<_>>(),
            vec![EngineTimerKind::RelayPoll, EngineTimerKind::RetryDue]
        );
    }
}
