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

pub(super) fn parse_uuid(value: &str) -> RuntimeResult<Uuid> {
    Uuid::parse_str(value).map_err(|_| RuntimeError::InvalidParams("invalid messageId".to_owned()))
}
