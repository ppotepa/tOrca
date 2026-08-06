use std::collections::hash_map::DefaultHasher;
use std::hash::{Hash, Hasher};

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RetryClass {
    Immediate,
    ShortBackoff,
    NetworkBackoff,
    TorBackoff,
    ManualOnly,
    PermanentFailure,
}

#[derive(Debug, Clone, Copy, Eq, PartialEq)]
pub struct RetryDecision {
    pub retry_at: Option<i64>,
    pub terminal: bool,
}

#[derive(Debug, Clone, Copy, Eq, PartialEq)]
pub struct RetryPolicy {
    pub short_base_ms: i64,
    pub network_base_ms: i64,
    pub tor_base_ms: i64,
    pub maximum_ms: i64,
}

impl Default for RetryPolicy {
    fn default() -> Self {
        Self {
            short_base_ms: 1_000,
            network_base_ms: 2_000,
            tor_base_ms: 5_000,
            maximum_ms: 5 * 60 * 1_000,
        }
    }
}

impl RetryPolicy {
    pub fn decide(
        self,
        class: RetryClass,
        now_ms: i64,
        attempt: u32,
        jitter_seed: u64,
    ) -> RetryDecision {
        match class {
            RetryClass::Immediate => RetryDecision {
                retry_at: Some(now_ms),
                terminal: false,
            },
            RetryClass::ShortBackoff => RetryDecision {
                retry_at: Some(now_ms.saturating_add(self.delay(
                    self.short_base_ms,
                    attempt,
                    jitter_seed,
                ))),
                terminal: false,
            },
            RetryClass::NetworkBackoff => RetryDecision {
                retry_at: Some(now_ms.saturating_add(self.delay(
                    self.network_base_ms,
                    attempt,
                    jitter_seed,
                ))),
                terminal: false,
            },
            RetryClass::TorBackoff => RetryDecision {
                retry_at: Some(now_ms.saturating_add(self.delay(
                    self.tor_base_ms,
                    attempt,
                    jitter_seed,
                ))),
                terminal: false,
            },
            RetryClass::ManualOnly => RetryDecision {
                retry_at: None,
                terminal: false,
            },
            RetryClass::PermanentFailure => RetryDecision {
                retry_at: None,
                terminal: true,
            },
        }
    }

    fn delay(self, base_ms: i64, attempt: u32, jitter_seed: u64) -> i64 {
        let exponent = attempt.min(8);
        let raw = base_ms.saturating_mul(1_i64 << exponent);
        let capped = raw.min(self.maximum_ms);
        let jitter_percent = (jitter_seed % 41) as i64 - 20;
        capped.saturating_add(capped.saturating_mul(jitter_percent) / 100)
    }
}

pub fn retry_delay_ms(attempt: u32, jitter_seed: u64) -> i64 {
    RetryPolicy::default()
        .decide(RetryClass::NetworkBackoff, 0, attempt, jitter_seed)
        .retry_at
        .unwrap_or_default()
}

pub fn retry_jitter_seed(entity_id: &str, attempt: u32) -> u64 {
    let mut hasher = DefaultHasher::new();
    entity_id.hash(&mut hasher);
    attempt.hash(&mut hasher);
    hasher.finish()
}
