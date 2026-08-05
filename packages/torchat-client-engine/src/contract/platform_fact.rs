use serde::{Deserialize, Serialize};

use super::TorPhase;

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum PlatformFact {
    TorStatus {
        phase: TorPhase,
        progress: u8,
        detail: String,
    },
    TorEndpointAvailable {
        socks5_url: String,
    },
    TorEndpointLost {
        reason: String,
    },
    OnionServiceAvailable {
        onion_address: String,
        virtual_port: u16,
        generation: u64,
    },
    OnionServiceLost {
        reason: String,
    },
    AppVisibilityChanged {
        foreground: bool,
    },
    NetworkChanged {
        #[serde(default = "default_true")]
        online: bool,
    },
    PowerModeChanged {
        #[serde(default)]
        battery_saver: bool,
        #[serde(default)]
        device_idle: bool,
    },
    BackgroundExecutionRestricted {
        restricted: bool,
    },
}

const fn default_true() -> bool {
    true
}
