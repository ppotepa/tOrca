use super::{DeliveryKind, DeliveryOutcomeClass};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct RetryContext {
    pub kind: DeliveryKind,
    pub attempt: u32,
    pub network_online: bool,
    pub app_foreground: bool,
    pub battery_saver: bool,
    pub last_outcome: DeliveryOutcomeClass,
    pub now_ms: i64,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum RetryDecision {
    RetryNow,
    RetryAt(i64),
    WaitForNetwork,
    WaitForPeerEndpoint,
    WaitForRelay,
    PermanentFailure,
}

pub trait RetryPolicy {
    fn decide(&self, context: RetryContext) -> RetryDecision;
}

#[derive(Clone, Copy, Debug)]
pub struct ExponentialRetryPolicy {
    pub base_delay_ms: i64,
    pub maximum_delay_ms: i64,
    pub maximum_attempts: u32,
}

impl Default for ExponentialRetryPolicy {
    fn default() -> Self {
        Self {
            base_delay_ms: 1_000,
            maximum_delay_ms: 300_000,
            maximum_attempts: 12,
        }
    }
}

impl RetryPolicy for ExponentialRetryPolicy {
    fn decide(&self, context: RetryContext) -> RetryDecision {
        if context.last_outcome == DeliveryOutcomeClass::Permanent
            || context.attempt >= self.maximum_attempts
        {
            return RetryDecision::PermanentFailure;
        }
        if !context.network_online {
            return RetryDecision::WaitForNetwork;
        }
        if context.attempt == 0 {
            return RetryDecision::RetryNow;
        }

        let exponent = context.attempt.saturating_sub(1).min(20);
        let multiplier = 1_i64.checked_shl(exponent).unwrap_or(i64::MAX);
        let mut delay = self.base_delay_ms.saturating_mul(multiplier);
        delay = delay.min(self.maximum_delay_ms);
        if context.battery_saver || !context.app_foreground {
            delay = delay.saturating_mul(2).min(self.maximum_delay_ms);
        }
        RetryDecision::RetryAt(context.now_ms.saturating_add(delay))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn context(attempt: u32) -> RetryContext {
        RetryContext {
            kind: DeliveryKind::Message,
            attempt,
            network_online: true,
            app_foreground: true,
            battery_saver: false,
            last_outcome: DeliveryOutcomeClass::Retryable,
            now_ms: 10_000,
        }
    }

    #[test]
    fn retry_backoff_is_deterministic_and_capped() {
        let policy = ExponentialRetryPolicy::default();
        assert_eq!(policy.decide(context(1)), RetryDecision::RetryAt(11_000));
        assert_eq!(policy.decide(context(4)), RetryDecision::RetryAt(18_000));
        assert_eq!(policy.decide(context(30)), RetryDecision::PermanentFailure);
    }

    #[test]
    fn offline_retry_waits_for_network_instead_of_spinning() {
        let policy = ExponentialRetryPolicy::default();
        let mut value = context(2);
        value.network_online = false;
        assert_eq!(policy.decide(value), RetryDecision::WaitForNetwork);
    }
}
