use std::time::{SystemTime, UNIX_EPOCH};

pub trait RuntimeClock {
    fn now_ms(&self) -> i64;

    fn now_secs(&self) -> i64 {
        self.now_ms() / 1_000
    }
}

#[derive(Clone, Copy, Debug, Default)]
pub struct SystemRuntimeClock;

impl RuntimeClock for SystemRuntimeClock {
    fn now_ms(&self) -> i64 {
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|value| value.as_millis() as i64)
            .unwrap_or_default()
    }
}
