use axum::{Json, http::StatusCode};

pub(crate) fn error(status: StatusCode, message: &str) -> (StatusCode, Json<serde_json::Value>) {
    (status, Json(serde_json::json!({ "error": message })))
}

pub(crate) fn validate_nickname(
    value: String,
) -> Result<String, (StatusCode, Json<serde_json::Value>)> {
    let value = value.trim().to_owned();
    let valid_length = (2..=32).contains(&value.chars().count());
    let valid_chars = value
        .chars()
        .all(|character| character.is_alphanumeric() || matches!(character, ' ' | '_' | '-' | '.'));
    if !valid_length || !valid_chars {
        return Err(error(
            StatusCode::BAD_REQUEST,
            "nickname must be 2-32 letters, numbers, spaces, _-.",
        ));
    }
    Ok(value)
}

pub(crate) fn fallback_contact_nickname(installation_id: &str) -> String {
    let trimmed = installation_id.trim();
    if trimmed.starts_with("peer-") && trimmed.chars().count() >= 2 {
        return trimmed.chars().take(32).collect();
    }
    let suffix = installation_id.chars().take(8).collect::<String>();
    format!("peer-{suffix}")
}

#[cfg(test)]
mod tests {
    use super::{fallback_contact_nickname, validate_nickname};

    #[test]
    fn validates_nickname_and_has_stable_fallback() {
        assert_eq!(validate_nickname(" Alice ".to_owned()).unwrap(), "Alice");
        assert!(validate_nickname("x".to_owned()).is_err());
        assert_eq!(fallback_contact_nickname("peer-example"), "peer-example");
    }
}
