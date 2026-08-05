use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TorPhase {
    Starting,
    Bootstrapping,
    Ready,
    Failed,
}
