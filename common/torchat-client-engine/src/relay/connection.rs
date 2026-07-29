use std::time::Duration;

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RelayConnectionConfig {
    pub connect_timeout: Duration,
    pub ready_timeout: Duration,
    pub socks5_url: Option<String>,
    pub relay_onion_url: String,
}
