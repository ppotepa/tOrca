use super::*;

pub(in crate::actor) type CommandHandlerResult = EngineResult<(
    ResponsePayload,
    Vec<torchat_runtime::RuntimeEvent>,
    Option<ConnectionSnapshot>,
)>;

pub(in crate::actor) mod capabilities;
pub(in crate::actor) mod contacts;
pub(in crate::actor) mod conversations;
pub(in crate::actor) mod ephemeral;
pub(in crate::actor) mod lifecycle;
pub(in crate::actor) mod messages;
pub(in crate::actor) mod pairing;
pub(in crate::actor) mod peer;
pub(in crate::actor) mod profile;
pub(in crate::actor) mod queries;
