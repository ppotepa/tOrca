use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD};
use hmac::{Hmac, Mac};
use sha2::Sha256;

pub(crate) fn pairing_mac(secret: &str, body: &str) -> String {
    let mut mac = Hmac::<Sha256>::new_from_slice(secret.as_bytes())
        .expect("HMAC accepts secrets of any length");
    mac.update(body.as_bytes());
    URL_SAFE_NO_PAD.encode(mac.finalize().into_bytes())
}

pub(crate) fn pseudonymous_id_with_secret(secret: &str, value: &str) -> String {
    pairing_mac(secret, value).chars().take(16).collect()
}

pub(crate) fn constant_time_equal(left: &[u8], right: &[u8]) -> bool {
    left.len() == right.len()
        && left
            .iter()
            .zip(right)
            .fold(0_u8, |value, (a, b)| value | (a ^ b))
            == 0
}

pub(crate) fn fingerprint_for_public_key(value: String) -> Option<String> {
    let bytes = URL_SAFE_NO_PAD.decode(value).ok()?;
    let bytes: [u8; 32] = bytes.try_into().ok()?;
    Some(torchat_core::fingerprint_from_public_key(&bytes))
}

#[cfg(test)]
mod tests {
    use super::{constant_time_equal, pseudonymous_id_with_secret};

    #[test]
    fn security_helpers_are_deterministic_and_safe() {
        assert_eq!(
            pseudonymous_id_with_secret("secret", "value"),
            pseudonymous_id_with_secret("secret", "value")
        );
        assert!(constant_time_equal(b"same", b"same"));
        assert!(!constant_time_equal(b"same", b"other"));
    }
}
