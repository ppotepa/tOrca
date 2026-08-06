use crate::{MessageState, MessageTransportOutcome};

pub fn message_state_on_send_prepare(current: &MessageState) -> Option<MessageState> {
    match current {
        MessageState::Queued | MessageState::Sending => Some(MessageState::Sending),
        MessageState::Sent
        | MessageState::Delivered
        | MessageState::Read
        | MessageState::Failed => None,
    }
}

pub fn message_state_after_transport_outcome(
    current: &MessageState,
    outcome: MessageTransportOutcome,
) -> Option<MessageState> {
    use MessageState::{Delivered, Failed, Queued, Read, Sending, Sent};
    use MessageTransportOutcome::{
        Delivered as OutcomeDelivered, PeerAuthenticationFailed, PeerDelivered, PeerPersisted,
        PeerRejected, PeerUnavailable, PermanentFailure, RetryableFailure,
    };

    match outcome {
        PeerPersisted => match current {
            Sending => Some(Sent),
            Sent => Some(Sent),
            Delivered => Some(Delivered),
            Read => Some(Read),
            Queued | Failed => None,
        },
        OutcomeDelivered | PeerDelivered => match current {
            Sending | Sent | Delivered => Some(Delivered),
            Read => Some(Read),
            Queued | Failed => None,
        },
        PeerUnavailable | RetryableFailure => match current {
            Queued | Sending | Sent => Some(Queued),
            Delivered | Read | Failed => None,
        },
        PermanentFailure | PeerAuthenticationFailed | PeerRejected => match current {
            Queued | Sending | Sent | Failed => Some(Failed),
            Delivered | Read => None,
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn preparing_send_moves_only_retryable_local_states_to_sending() {
        assert_eq!(
            message_state_on_send_prepare(&MessageState::Queued),
            Some(MessageState::Sending)
        );
        assert_eq!(message_state_on_send_prepare(&MessageState::Failed), None);
        assert_eq!(
            message_state_on_send_prepare(&MessageState::Sending),
            Some(MessageState::Sending)
        );
        assert_eq!(message_state_on_send_prepare(&MessageState::Sent), None);
        assert_eq!(
            message_state_on_send_prepare(&MessageState::Delivered),
            None
        );
    }

    #[test]
    fn peer_persisted_is_the_transport_outcome_that_creates_sent() {
        assert_eq!(
            message_state_after_transport_outcome(
                &MessageState::Sending,
                MessageTransportOutcome::PeerPersisted,
            ),
            Some(MessageState::Sent)
        );
        assert_eq!(
            message_state_after_transport_outcome(
                &MessageState::Sending,
                MessageTransportOutcome::PeerUnavailable,
            ),
            Some(MessageState::Queued)
        );
    }

    #[test]
    fn receipt_can_race_peer_persisted_without_downgrading_delivery() {
        assert_eq!(
            message_state_after_transport_outcome(
                &MessageState::Sending,
                MessageTransportOutcome::Delivered
            ),
            Some(MessageState::Delivered)
        );
        assert_eq!(
            message_state_after_transport_outcome(
                &MessageState::Delivered,
                MessageTransportOutcome::PeerPersisted
            ),
            Some(MessageState::Delivered)
        );
    }

    #[test]
    fn peer_unavailable_failures_return_message_to_local_queue() {
        for outcome in [
            MessageTransportOutcome::PeerUnavailable,
            MessageTransportOutcome::RetryableFailure,
        ] {
            assert_eq!(
                message_state_after_transport_outcome(&MessageState::Sent, outcome),
                Some(MessageState::Queued)
            );
        }
    }

    #[test]
    fn delivered_message_is_never_failed_or_requeued() {
        assert_eq!(
            message_state_after_transport_outcome(
                &MessageState::Delivered,
                MessageTransportOutcome::PermanentFailure,
            ),
            None
        );
        assert_eq!(
            message_state_after_transport_outcome(
                &MessageState::Delivered,
                MessageTransportOutcome::RetryableFailure,
            ),
            None
        );
    }
}
