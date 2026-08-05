use std::collections::hash_map::DefaultHasher;
use std::hash::{Hash, Hasher};

pub fn retry_delay_ms(attempt: u32, jitter_seed: u64) -> i64 {
    const BASE_MS: i64 = 2_000;
    const MAX_MS: i64 = 5 * 60 * 1_000;

    let exponent = attempt.min(8);
    let raw = BASE_MS.saturating_mul(1_i64 << exponent);
    let capped = raw.min(MAX_MS);
    let jitter_percent = (jitter_seed % 41) as i64 - 20;

    capped + capped * jitter_percent / 100
}

pub fn retry_jitter_seed(message_id: &str, attempt: u32) -> u64 {
    let mut hasher = DefaultHasher::new();
    message_id.hash(&mut hasher);
    attempt.hash(&mut hasher);
    hasher.finish()
}
