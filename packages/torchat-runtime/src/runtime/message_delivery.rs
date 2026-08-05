use crate::{ReceiptSendEffect, RuntimeError, RuntimeResult};

/// Pure input boundary for durable message delivery. Persistence, MLS and
/// transport remain owned by `ClientRuntime`.
pub(crate) fn validate_message_text(text: &str) -> RuntimeResult<String> {
    let normalized = text.trim();
    if normalized.is_empty() {
        return Err(RuntimeError::InvalidParams(
            "message text must not be empty".to_owned(),
        ));
    }
    Ok(normalized.to_owned())
}

/// Validates the durable receipt boundary before the actor hands it to a
/// transport. Storage owns selection of due rows; the workflow owns the
/// invariant that an incomplete row can never become a wire effect.
pub(crate) fn validate_receipt_effect(
    effect: ReceiptSendEffect,
) -> RuntimeResult<ReceiptSendEffect> {
    if effect.envelope_id.trim().is_empty()
        || effect.message_id.trim().is_empty()
        || effect.conversation_id.trim().is_empty()
        || effect.recipient_installation_id.trim().is_empty()
    {
        return Err(RuntimeError::Storage(
            "durable receipt contains an empty identity".to_owned(),
        ));
    }
    if effect.received_at < 0 {
        return Err(RuntimeError::Storage(
            "durable receipt timestamp must not be negative".to_owned(),
        ));
    }
    Ok(effect)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn message_text_is_trimmed_before_queueing() {
        assert_eq!(validate_message_text("  hello  ").unwrap(), "hello");
        assert!(validate_message_text(" \t ").is_err());
    }
}
