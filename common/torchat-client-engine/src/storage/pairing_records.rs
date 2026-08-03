use torchat_client_runtime::{InviteState, PairingItem};

pub(super) fn finalize(mut item: PairingItem) -> PairingItem {
    item.available_actions =
        torchat_client_runtime::pairing_available_actions(item.state, item.received);
    item
}

pub(super) fn state_sql(state: InviteState) -> &'static str {
    match state {
        InviteState::Pending => "PENDING",
        InviteState::Accepted => "ACCEPTED",
        InviteState::Rejected => "REJECTED",
        InviteState::Completed => "COMPLETED",
        InviteState::Expired => "EXPIRED",
        InviteState::Archived => "ARCHIVED",
        InviteState::Cancelled => "CANCELLED",
    }
}

#[cfg(test)]
mod tests {
    use super::state_sql;

    #[test]
    fn maps_all_invite_states_to_sql_names() {
        assert_eq!(
            state_sql(torchat_client_runtime::InviteState::Pending),
            "PENDING"
        );
        assert_eq!(
            state_sql(torchat_client_runtime::InviteState::Cancelled),
            "CANCELLED"
        );
    }
}
