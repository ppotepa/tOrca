use crate::{EngineError, EngineResult};

use super::InboundEnvelope;

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ValidatedInbound {
    pub envelope: InboundEnvelope,
}

pub trait InboundValidator {
    fn validate(&self, envelope: InboundEnvelope) -> EngineResult<ValidatedInbound>;
}

#[derive(Clone, Copy, Debug)]
pub struct BasicInboundValidator {
    pub supported_protocol: u32,
}

impl InboundValidator for BasicInboundValidator {
    fn validate(&self, envelope: InboundEnvelope) -> EngineResult<ValidatedInbound> {
        if envelope.sender_id.trim().is_empty() {
            return Err(EngineError::InvalidCommand(
                "inbound sender is empty".to_owned(),
            ));
        }
        if envelope.recipient_id.trim().is_empty() {
            return Err(EngineError::InvalidCommand(
                "inbound recipient is empty".to_owned(),
            ));
        }
        if envelope.envelope_id.trim().is_empty() {
            return Err(EngineError::InvalidCommand(
                "inbound envelope id is empty".to_owned(),
            ));
        }
        if envelope.protocol_version != self.supported_protocol {
            return Err(EngineError::InvalidCommand(format!(
                "unsupported inbound protocol version: {}",
                envelope.protocol_version,
            )));
        }
        Ok(ValidatedInbound { envelope })
    }
}
