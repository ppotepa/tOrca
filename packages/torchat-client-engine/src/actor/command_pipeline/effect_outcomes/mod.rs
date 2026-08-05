use super::super::*;

pub(in crate::actor) type RelayCommitResult = EngineResult<(
    ResponsePayload,
    Vec<torchat_runtime::RuntimeEvent>,
)>;

mod pairing_cancelled;
mod pairing_code_refreshed;
mod pairing_submitted;
