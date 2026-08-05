use super::*;

pub(super) fn is_cryptographic_inbound_error(error: &EngineError) -> bool {
    matches!(
        error,
        EngineError::InvalidCommand(message)
            if message.contains("decrypt")
                || message.contains("MLS")
                || message.contains("ciphertext")
                || message.contains("authentication")
                || message.contains("hash")
    )
}

#[cfg(test)]
mod tests {
    use super::is_cryptographic_inbound_error;
    use crate::EngineError;

    #[test]
    fn only_cryptographic_inbound_errors_are_blocking() {
        for message in [
            "MLS decrypt failed",
            "ciphertext authentication failed",
            "application hash mismatch",
        ] {
            assert!(is_cryptographic_inbound_error(
                &EngineError::InvalidCommand(message.to_owned())
            ));
        }
        for error in [
            EngineError::Storage("receipt retry unavailable".to_owned()),
            EngineError::Transport("relay timeout".to_owned()),
            EngineError::InvalidCommand("receipt effect failed".to_owned()),
        ] {
            assert!(!is_cryptographic_inbound_error(&error));
        }
    }
}
