use torchat_client_runtime::VerificationState;

pub(super) fn verification_state_sql(state: VerificationState) -> &'static str {
    match state {
        VerificationState::Verified => "VERIFIED",
        VerificationState::Unverified => "UNVERIFIED",
    }
}

#[cfg(test)]
mod tests {
    use super::verification_state_sql;

    #[test]
    fn maps_verification_states_to_sql_names() {
        assert_eq!(
            verification_state_sql(torchat_client_runtime::VerificationState::Verified),
            "VERIFIED"
        );
        assert_eq!(
            verification_state_sql(torchat_client_runtime::VerificationState::Unverified),
            "UNVERIFIED"
        );
    }
}
