use std::fmt;

use torchat_client_runtime::MessageState;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum MessageDeliveryEvent {
    Queued,
    AttemptStarted,
    RelayForwarded,
    PeerPersisted,
    Delivered,
    Read,
    RetryableFailure,
    PermanentFailure,
    ManualRetry,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct InvalidMessageTransition {
    pub current: MessageState,
    pub event: MessageDeliveryEvent,
}

impl fmt::Display for InvalidMessageTransition {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            formatter,
            "invalid message transition: {:?} + {:?}",
            self.current, self.event,
        )
    }
}

impl std::error::Error for InvalidMessageTransition {}

pub fn transition_message(
    current: &MessageState,
    event: MessageDeliveryEvent,
) -> Result<MessageState, InvalidMessageTransition> {
    use MessageDeliveryEvent as Event;
    use MessageState as State;

    let next = match (current, event) {
        (_, Event::Queued) => State::Queued,
        (State::Queued, Event::AttemptStarted) => State::Sending,
        (State::Sending, Event::RelayForwarded | Event::PeerPersisted) => State::Sent,
        (State::Sent, Event::RelayForwarded | Event::PeerPersisted) => State::Sent,
        (
            State::Queued | State::Sending | State::Sent,
            Event::Delivered,
        ) => State::Delivered,
        (State::Delivered, Event::Delivered) => State::Delivered,
        (State::Read, Event::Delivered | Event::Read) => State::Read,
        (State::Delivered, Event::Read) => State::Read,
        (
            State::Queued | State::Sending | State::Sent,
            Event::RetryableFailure,
        ) => State::Queued,
        (
            State::Queued | State::Sending | State::Sent,
            Event::PermanentFailure,
        ) => State::Failed,
        (State::Failed, Event::ManualRetry) => State::Queued,
        _ => {
            return Err(InvalidMessageTransition {
                current: current.clone(),
                event,
            })
        }
    };
    Ok(next)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn canonical_delivery_path_is_valid() {
        let mut state = MessageState::Queued;
        for event in [
            MessageDeliveryEvent::AttemptStarted,
            MessageDeliveryEvent::RelayForwarded,
            MessageDeliveryEvent::Delivered,
            MessageDeliveryEvent::Read,
        ] {
            state = transition_message(&state, event).unwrap();
        }
        assert_eq!(state, MessageState::Read);
    }

    #[test]
    fn delivered_message_cannot_be_requeued_by_transport_failure() {
        let error = transition_message(
            &MessageState::Delivered,
            MessageDeliveryEvent::RetryableFailure,
        )
        .unwrap_err();
        assert_eq!(error.current, MessageState::Delivered);
    }
}
