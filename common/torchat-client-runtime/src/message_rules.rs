use crate::{MessageState, MessageTransportOutcome};

pub fn message_state_on_send_prepare(current: &MessageState) -> Option<MessageState> {
    match current {
        MessageState::Queued | MessageState::Sending | MessageState::Sent => {
            Some(MessageState::Sending)
        }
        MessageState::Delivered | MessageState::Failed => None,
    }
}

pub fn message_state_after_transport_outcome(
    current: &MessageState,
    outcome: MessageTransportOutcome,
) -> Option<MessageState> {
    use MessageState::{Delivered, Failed, Queued, Sending, Sent};
    use MessageTransportOutcome::{
        Delivered as OutcomeDelivered, Forwarded, PermanentFailure, RecipientOffline,
        RetryableFailure,
    };

    match outcome {
        Forwarded => match current {
            Sending => Some(Sent),
            Sent => Some(Sent),
            Delivered => Some(Delivered),
            Queued | Failed => None,
        },
        OutcomeDelivered => match current {
            Sending | Sent | Delivered => Some(Delivered),
            Queued | Failed => None,
        },
        RecipientOffline | RetryableFailure => match current {
            Queued | Sending | Sent => Some(Queued),
            Delivered | Failed => None,
        },
        PermanentFailure => match current {
            Queued | Sending | Sent | Failed => Some(Failed),
            Delivered => None,
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
        assert_eq!(
            message_state_on_send_prepare(&MessageState::Sent),
            Some(MessageState::Sending)
        );
        assert_eq!(
            message_state_on_send_prepare(&MessageState::Delivered),
            None
        );
    }

    #[test]
    fn forwarded_is_the_only_transport_outcome_that_creates_sent() {
        assert_eq!(
            message_state_after_transport_outcome(
                &MessageState::Sending,
                MessageTransportOutcome::Forwarded,
            ),
            Some(MessageState::Sent)
        );
        assert_eq!(
            message_state_after_transport_outcome(
                &MessageState::Sending,
                MessageTransportOutcome::RecipientOffline,
            ),
            Some(MessageState::Queued)
        );
    }

    #[test]
    fn receipt_can_race_forwarded_without_downgrading_delivery() {
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
                MessageTransportOutcome::Forwarded
            ),
            Some(MessageState::Delivered)
        );
    }

    #[test]
    fn live_only_relay_failures_return_message_to_local_queue() {
        for outcome in [
            MessageTransportOutcome::RecipientOffline,
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
