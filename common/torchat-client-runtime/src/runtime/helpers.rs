use super::*;

pub(super) fn validate_nickname(nickname: String) -> RuntimeResult<String> {
    let nickname = nickname.trim();
    if nickname.len() < 2 || nickname.chars().count() > 32 {
        return Err(RuntimeError::InvalidParams(
            "nickname must contain 2-32 characters".to_owned(),
        ));
    }
    Ok(nickname.to_owned())
}

pub(super) fn transition_invite_state(
    state: &InviteState,
    action: PairingAction,
) -> RuntimeResult<InviteState> {
    use InviteState::*;
    match (state, action) {
        (Pending, PairingAction::Accept) => Ok(Accepted),
        (Pending, PairingAction::Reject) => Ok(Rejected),
        (Pending, PairingAction::Expire) => Ok(Expired),
        (Pending, PairingAction::Cancel) => Ok(Cancelled),
        (Accepted, PairingAction::Complete) => Ok(Completed),
        (Accepted, PairingAction::Cancel) => Ok(Cancelled),
        (Accepted | Rejected | Completed | Expired | Cancelled, PairingAction::Archive) => {
            Ok(Archived)
        }
        _ => Err(RuntimeError::Conflict(
            "pairing request cannot be transitioned from its current state".to_owned(),
        )),
    }
}

pub(super) fn parse_uuid(value: &str) -> RuntimeResult<Uuid> {
    Uuid::parse_str(value).map_err(|_| RuntimeError::InvalidParams("invalid messageId".to_owned()))
}

pub(super) fn pairing_send_effect(
    pairing_id: String,
    recipient_installation_id: String,
    kind: crate::PairingSendKind,
    payload: Option<String>,
) -> RuntimeSendEffect {
    RuntimeSendEffect {
        message: None,
        receipt: None,
        pairing: Some(crate::PairingSendEffect {
            pairing_id,
            recipient_installation_id,
            kind,
            payload,
        }),
    }
}
