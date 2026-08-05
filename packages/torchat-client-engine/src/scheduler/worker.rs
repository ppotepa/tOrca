use tokio::sync::{mpsc, watch};
use tokio::time::{Instant, sleep_until};
use tokio_util::sync::CancellationToken;

use crate::input::EngineInputEnvelope;

use super::EngineSchedulerPlan;

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
