use tokio::time::Instant;

use crate::input::EngineTimerKind;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) struct EngineSchedulerPlan {
    pub generation: u64,
    pub relay_poll_at: Option<Instant>,
    pub peer_probe_at: Option<Instant>,
    pub retry_at: Option<Instant>,
}

impl EngineSchedulerPlan {
    pub(super) fn next_deadline(self) -> Option<Instant> {
        [self.relay_poll_at, self.peer_probe_at, self.retry_at]
            .into_iter()
            .flatten()
            .min()
    }

    pub(super) fn due_kinds(self, now: Instant) -> impl Iterator<Item = EngineTimerKind> {
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
