use serde::{Deserialize, Serialize};

use super::EngineCommand;

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct EngineCommandEnvelope {
    pub request_id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub command_id: Option<String>,
    pub command: EngineCommand,
}
