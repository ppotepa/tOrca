use std::time::Duration;

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RelayHeartbeatConfig {
    pub ping_interval: Duration,
    pub pong_timeout: Duration,
}
