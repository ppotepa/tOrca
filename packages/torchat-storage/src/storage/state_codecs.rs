use torchat_runtime::{
    ConversationState, InviteState, MessageState, RuntimeError, RuntimeResult, VerificationState,
};

pub(super) fn verification(value: String) -> RuntimeResult<VerificationState> {
    match value.trim().to_ascii_uppercase().as_str() {
        "VERIFIED" => Ok(VerificationState::Verified),
        "UNVERIFIED" => Ok(VerificationState::Unverified),
        other => Err(RuntimeError::Storage(format!(
            "unknown verification state: {other}"
        ))),
    }
}

pub(super) fn conversation(value: String) -> RuntimeResult<ConversationState> {
    ConversationState::try_from(value.as_str()).map_err(RuntimeError::Storage)
}

pub(super) fn message(value: String) -> RuntimeResult<MessageState> {
    match value.trim().to_ascii_uppercase().as_str() {
        "QUEUED" => Ok(MessageState::Queued),
        "SENDING" => Ok(MessageState::Sending),
        "SENT" => Ok(MessageState::Sent),
        "DELIVERED" => Ok(MessageState::Delivered),
        "READ" => Ok(MessageState::Read),
        "FAILED" => Ok(MessageState::Failed),
        other => Err(RuntimeError::Storage(format!(
            "unknown message state: {other}"
        ))),
    }
}

pub(super) fn invite(value: String) -> RuntimeResult<InviteState> {
    match value.trim().to_ascii_uppercase().as_str() {
        "PENDING" => Ok(InviteState::Pending),
        "ACCEPTED" => Ok(InviteState::Accepted),
        "REJECTED" => Ok(InviteState::Rejected),
        "COMPLETED" => Ok(InviteState::Completed),
        "EXPIRED" => Ok(InviteState::Expired),
        "ARCHIVED" => Ok(InviteState::Archived),
        "CANCELLED" => Ok(InviteState::Cancelled),
        other => Err(RuntimeError::Storage(format!(
            "unknown invite state: {other}"
        ))),
    }
}

#[cfg(test)]
mod tests {
    use super::{invite, message, verification};

    #[test]
    fn codecs_are_case_insensitive_and_reject_unknown_values() {
        assert_eq!(
            verification(" verified ".to_owned()).unwrap(),
            torchat_runtime::VerificationState::Verified
        );
        assert_eq!(
            message("READ".to_owned()).unwrap(),
            torchat_runtime::MessageState::Read
        );
        assert_eq!(
            invite("cancelled".to_owned()).unwrap(),
            torchat_runtime::InviteState::Cancelled
        );
        assert!(message("UNKNOWN".to_owned()).is_err());
    }
}
