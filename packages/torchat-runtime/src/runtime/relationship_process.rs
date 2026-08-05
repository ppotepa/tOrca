use crate::{RuntimeError, RuntimeResult};

pub(crate) fn validate_removal_identifiers(
    installation_id: &str,
    removal_id: Option<&str>,
) -> RuntimeResult<()> {
    if installation_id.trim().is_empty() {
        return Err(RuntimeError::InvalidParams(
            "contact installation id must not be empty".to_owned(),
        ));
    }
    if removal_id.is_some_and(|value| value.trim().is_empty()) {
        return Err(RuntimeError::InvalidParams(
            "relationship removal identifiers must not be empty".to_owned(),
        ));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn removal_requires_non_empty_contact_and_optional_id() {
        assert!(validate_removal_identifiers("peer", None).is_ok());
        assert!(validate_removal_identifiers("peer", Some("removal")).is_ok());
        assert!(validate_removal_identifiers("", None).is_err());
        assert!(validate_removal_identifiers("peer", Some(" ")).is_err());
    }
}
