#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum CircuitState {
    Closed,
    Open { retry_at_ms: i64 },
    HalfOpen,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct CircuitBreaker {
    state: CircuitState,
    failures: u32,
    failure_threshold: u32,
    reset_timeout_ms: i64,
}

impl CircuitBreaker {
    pub const fn new(failure_threshold: u32, reset_timeout_ms: i64) -> Self {
        Self {
            state: CircuitState::Closed,
            failures: 0,
            failure_threshold,
            reset_timeout_ms,
        }
    }

    pub const fn state(&self) -> CircuitState {
        self.state
    }

    pub fn allow(&mut self, now_ms: i64) -> bool {
        match self.state {
            CircuitState::Closed | CircuitState::HalfOpen => true,
            CircuitState::Open { retry_at_ms } if now_ms >= retry_at_ms => {
                self.state = CircuitState::HalfOpen;
                true
            }
            CircuitState::Open { .. } => false,
        }
    }

    pub fn record_success(&mut self) {
        self.failures = 0;
        self.state = CircuitState::Closed;
    }

    pub fn record_failure(&mut self, now_ms: i64) {
        self.failures = self.failures.saturating_add(1);
        if self.state == CircuitState::HalfOpen || self.failures >= self.failure_threshold {
            self.state = CircuitState::Open {
                retry_at_ms: now_ms.saturating_add(self.reset_timeout_ms),
            };
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn circuit_opens_after_threshold_and_recovers_half_open() {
        let mut circuit = CircuitBreaker::new(2, 1_000);
        circuit.record_failure(100);
        assert_eq!(circuit.state(), CircuitState::Closed);
        circuit.record_failure(100);
        assert_eq!(
            circuit.state(),
            CircuitState::Open { retry_at_ms: 1_100 },
        );
        assert!(!circuit.allow(1_099));
        assert!(circuit.allow(1_100));
        assert_eq!(circuit.state(), CircuitState::HalfOpen);
        circuit.record_success();
        assert_eq!(circuit.state(), CircuitState::Closed);
    }
}
