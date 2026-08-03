use std::{env, net::SocketAddr};

pub(crate) fn required_secret_from_environment() -> String {
    let value = match env::var("TORCHAT_PAIRING_SECRET_FILE") {
        Ok(path) => std::fs::read_to_string(&path).unwrap_or_else(|error| {
            panic!("TORCHAT_PAIRING_SECRET_FILE must be readable: {error}")
        }),
        Err(_) => env::var("TORCHAT_PAIRING_SECRET")
            .expect("TORCHAT_PAIRING_SECRET or TORCHAT_PAIRING_SECRET_FILE is required"),
    };
    validate_secret(value.trim()).unwrap_or_else(|error| panic!("{error}"))
}

pub(crate) fn validate_secret(value: &str) -> Result<String, &'static str> {
    let value = value.trim();
    if value.len() < 32 {
        return Err("pairing secret must contain at least 32 characters");
    }
    Ok(value.to_owned())
}

pub(crate) fn database_url() -> String {
    match env::var("TORCHAT_DATABASE_URL_FILE") {
        Ok(path) => std::fs::read_to_string(path)
            .expect("TORCHAT_DATABASE_URL_FILE must be readable")
            .trim()
            .to_owned(),
        Err(_) => env::var("TORCHAT_DATABASE_URL").unwrap_or_else(|_| {
            "postgres://torchat:local-development-only@127.0.0.1:5432/torchat".into()
        }),
    }
}

pub(crate) fn bind_address() -> SocketAddr {
    env::var("TORCHAT_BIND")
        .unwrap_or_else(|_| "127.0.0.1:8080".into())
        .parse()
        .expect("TORCHAT_BIND must be a valid socket address")
}

#[cfg(test)]
mod tests {
    use super::validate_secret;

    #[test]
    fn secret_validation_is_trimmed_and_has_minimum_length() {
        assert!(validate_secret("short").is_err());
        assert_eq!(
            validate_secret("  12345678901234567890123456789012  ")
                .unwrap()
                .len(),
            32
        );
    }
}
