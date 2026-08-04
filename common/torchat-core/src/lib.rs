//! Shared identity and protocol boundary for TorChat clients.

use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD};
use ed25519_dalek::{Signature, Signer, SigningKey, Verifier, VerifyingKey};
use rand_core::OsRng;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

pub mod application;
pub mod mls;
pub mod peer_protocol;
pub mod relay;
pub mod rendezvous;
pub mod rendezvous_crypto;

pub const PROTOCOL_VERSION: u16 = 1;

pub fn protocol_version() -> u16 {
    PROTOCOL_VERSION
}

pub fn is_valid_onion_address(value: &str) -> bool {
    let value = value.trim().to_ascii_lowercase();
    let Some(host) = value.strip_suffix(".onion") else {
        return false;
    };
    host.len() == 56
        && host
            .bytes()
            .all(|byte: u8| byte.is_ascii_lowercase() || (b'2'..=b'7').contains(&byte))
}

/// Private key is intentionally not serializable or exposed as bytes.
pub struct Identity(SigningKey);

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct InvitePayload {
    pub version: u16,
    pub installation_id: String,
    pub public_key: String,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct ContactInvite {
    pub version: u16,
    pub installation_id: String,
    pub public_key: String,
    pub fingerprint: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub nickname: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub recipient_installation_id: Option<String>,
    pub key_package: String,
    pub invite_id: String,
    pub expires_at: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub peer_endpoint: Option<peer_protocol::PeerEndpointBundle>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub peer_capability_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub peer_capability_secret: Option<String>,
    pub signature: Option<String>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct InviteValidationPolicy {
    pub max_future_lifetime_secs: u64,
}

impl Default for InviteValidationPolicy {
    fn default() -> Self {
        Self {
            max_future_lifetime_secs: 15 * 60 + 120,
        }
    }
}

impl ContactInvite {
    pub fn from_identity(
        identity: &Identity,
        nickname: Option<String>,
        recipient_installation_id: Option<String>,
        key_package: String,
        invite_id: String,
        expires_at: u64,
    ) -> Self {
        Self {
            version: PROTOCOL_VERSION,
            installation_id: identity.installation_id(),
            public_key: identity.public_key(),
            fingerprint: identity.fingerprint(),
            nickname,
            recipient_installation_id,
            key_package,
            invite_id,
            expires_at,
            peer_endpoint: None,
            peer_capability_id: None,
            peer_capability_secret: None,
            signature: None,
        }
    }

    pub fn signing_bytes(&self) -> Result<Vec<u8>, serde_json::Error> {
        let mut unsigned = self.clone();
        unsigned.signature = None;
        serde_json::to_vec(&unsigned)
    }

    pub fn parse(value: &str) -> Result<Self, String> {
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_err(|_| "system clock is invalid".to_string())?
            .as_secs();
        Self::parse_at(value, now)
    }

    /// Parse and validate an invite against an injected wall-clock value.
    /// Production callers use `parse`; deterministic runtimes and skew tests
    /// use this boundary instead of reading the process clock internally.
    pub fn parse_at(value: &str, now: u64) -> Result<Self, String> {
        Self::parse_at_with_policy(value, now, InviteValidationPolicy::default())
    }

    pub fn parse_at_with_policy(
        value: &str,
        now: u64,
        policy: InviteValidationPolicy,
    ) -> Result<Self, String> {
        let invite: Self =
            serde_json::from_str(value).map_err(|e| format!("invalid invite JSON: {e}"))?;
        if invite.version != PROTOCOL_VERSION {
            return Err("unsupported invite version".into());
        }
        let public = URL_SAFE_NO_PAD
            .decode(&invite.public_key)
            .map_err(|_| "invalid invite public key".to_string())?;
        let public: [u8; 32] = public
            .as_slice()
            .try_into()
            .map_err(|_| "invalid invite public key length".to_string())?;
        let mut hash = Sha256::new();
        hash.update(public);
        if invite.installation_id != URL_SAFE_NO_PAD.encode(hash.finalize()) {
            return Err("invite installation ID does not match public key".into());
        }
        if invite.fingerprint != fingerprint_from_public_key(&public) {
            return Err("invite fingerprint does not match public key".into());
        }
        if invite.key_package.is_empty() {
            return Err("invite has no MLS KeyPackage".into());
        }
        if invite
            .recipient_installation_id
            .as_deref()
            .is_some_and(|value| value.is_empty())
        {
            return Err("invite recipient is invalid".into());
        }
        if uuid::Uuid::parse_str(&invite.invite_id).is_err() {
            return Err("invite ID is invalid".into());
        }
        if invite.expires_at < now {
            return Err("invite has expired".into());
        }
        if invite.expires_at.saturating_sub(now) > policy.max_future_lifetime_secs {
            return Err("invite lifetime exceeds clock-skew policy".into());
        }
        let signature = invite
            .signature
            .as_deref()
            .filter(|value| !value.is_empty())
            .ok_or_else(|| "invite has no signature".to_string())?;
        if !verify_signature(
            &invite.public_key,
            &invite
                .signing_bytes()
                .map_err(|_| "invite serialization failed")?,
            signature,
        ) {
            return Err("invite signature is invalid".into());
        }
        if invite
            .nickname
            .as_deref()
            .is_some_and(|value| value.trim().is_empty() || value.chars().count() > 32)
        {
            return Err("invite nickname is invalid".into());
        }
        if let Some(endpoint) = &invite.peer_endpoint {
            endpoint.validate(now as i64)?;
            if endpoint.installation_id != invite.installation_id
                || endpoint.identity_public_key != invite.public_key
            {
                return Err("invite peer endpoint does not match invite identity".into());
            }
        }
        match (
            invite.peer_capability_id.as_deref(),
            invite.peer_capability_secret.as_deref(),
        ) {
            (Some(id), Some(secret)) => {
                if id.len() != 16 || !id.bytes().all(|byte| byte.is_ascii_hexdigit()) {
                    return Err("invite capability ID is invalid".into());
                }
                let secret = URL_SAFE_NO_PAD
                    .decode(secret)
                    .map_err(|_| "invite capability secret is invalid")?;
                if secret.len() < 16 {
                    return Err("invite capability secret is too short".into());
                }
                let endpoint = invite
                    .peer_endpoint
                    .as_ref()
                    .ok_or("invite capability has no peer endpoint")?;
                if !endpoint
                    .capabilities
                    .iter()
                    .any(|value| value == &format!("contact_endpoint_v1:{id}"))
                {
                    return Err("invite capability is not advertised by endpoint".into());
                }
            }
            (None, None) => {}
            _ => return Err("invite capability credentials are incomplete".into()),
        }
        Ok(invite)
    }

    pub fn sign(&mut self, identity: &Identity) -> Result<(), serde_json::Error> {
        self.signature = None;
        self.signature = Some(identity.sign(&self.signing_bytes()?));
        Ok(())
    }
}

impl Identity {
    pub fn generate() -> Self {
        Self(SigningKey::generate(&mut OsRng))
    }

    /// Rehydrates an identity inside a trusted platform storage adapter.
    /// Callers must not transmit these bytes or expose them to UI code.
    pub fn from_private_key_bytes(bytes: [u8; 32]) -> Self {
        Self(SigningKey::from_bytes(&bytes))
    }

    /// Used only by a platform storage adapter to persist the opaque identity.
    pub fn private_key_bytes(&self) -> [u8; 32] {
        self.0.to_bytes()
    }

    pub fn public_key(&self) -> String {
        URL_SAFE_NO_PAD.encode(self.0.verifying_key().to_bytes())
    }

    pub fn installation_id(&self) -> String {
        let mut hash = Sha256::new();
        hash.update(self.0.verifying_key().to_bytes());
        URL_SAFE_NO_PAD.encode(hash.finalize())
    }

    pub fn fingerprint(&self) -> String {
        fingerprint_from_public_key(&self.0.verifying_key().to_bytes())
    }

    pub fn invite_payload(&self) -> Result<String, serde_json::Error> {
        serde_json::to_string(&InvitePayload {
            version: PROTOCOL_VERSION,
            installation_id: self.installation_id(),
            public_key: self.public_key(),
        })
    }

    pub fn contact_invite_payload(
        &self,
        nickname: Option<String>,
        recipient_installation_id: Option<String>,
        key_package: String,
        invite_id: String,
        expires_at: u64,
    ) -> Result<String, serde_json::Error> {
        let mut invite = ContactInvite::from_identity(
            self,
            nickname,
            recipient_installation_id,
            key_package,
            invite_id,
            expires_at,
        );
        invite.sign(self)?;
        serde_json::to_string(&invite)
    }

    pub fn pairing_code_digits(value: &str) -> Result<String, String> {
        let code = value.trim();
        if code.len() != 8 || !code.bytes().all(|byte| byte.is_ascii_digit()) {
            return Err("pairing code must have exactly 8 digits".into());
        }
        Ok(code.to_owned())
    }

    pub fn sign(&self, message: &[u8]) -> String {
        URL_SAFE_NO_PAD.encode(self.0.sign(message).to_bytes())
    }
}

pub fn fingerprint_from_public_key(public_key: &[u8; 32]) -> String {
    let mut hash = Sha256::new();
    hash.update(public_key);
    let digest = hash.finalize();
    digest[..16]
        .chunks(2)
        .map(|part| format!("{:02x}{:02x}", part[0], part[1]))
        .collect::<Vec<_>>()
        .join(" ")
}

pub fn verify_signature(public_key: &str, message: &[u8], signature: &str) -> bool {
    let Ok(public_bytes) = URL_SAFE_NO_PAD.decode(public_key) else {
        return false;
    };
    let Ok(signature_bytes) = URL_SAFE_NO_PAD.decode(signature) else {
        return false;
    };
    let Ok(public_bytes) = <[u8; 32]>::try_from(public_bytes.as_slice()) else {
        return false;
    };
    let Ok(signature_bytes) = <[u8; 64]>::try_from(signature_bytes.as_slice()) else {
        return false;
    };
    let Ok(key) = VerifyingKey::from_bytes(&public_bytes) else {
        return false;
    };
    key.verify(message, &Signature::from_bytes(&signature_bytes))
        .is_ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn identity_derivation_and_signature() {
        let identity = Identity::generate();
        assert_eq!(identity.public_key().len(), 43);
        assert_eq!(identity.installation_id().len(), 43);
        assert_eq!(identity.fingerprint().split_whitespace().count(), 8);
        let signature = identity.sign(b"challenge-v1");
        assert!(verify_signature(
            &identity.public_key(),
            b"challenge-v1",
            &signature
        ));
        assert!(!verify_signature(
            &identity.public_key(),
            b"changed",
            &signature
        ));
    }

    #[test]
    fn invite_payload_has_public_data_only() {
        let identity = Identity::generate();
        let payload: InvitePayload =
            serde_json::from_str(&identity.invite_payload().unwrap()).unwrap();
        assert_eq!(payload.version, PROTOCOL_VERSION);
        assert_eq!(payload.installation_id, identity.installation_id());
        assert_eq!(payload.public_key, identity.public_key());
    }

    #[test]
    fn contact_invite_from_identity_uses_identity_fields_and_signs() {
        let identity = Identity::generate();
        let mut invite = ContactInvite::from_identity(
            &identity,
            Some("Alice".into()),
            Some("recipient-1".into()),
            "key-package".into(),
            "00000000-0000-4000-8000-000000000000".into(),
            4_102_444_800,
        );
        invite.sign(&identity).unwrap();
        assert_eq!(invite.installation_id, identity.installation_id());
        assert_eq!(invite.public_key, identity.public_key());
        assert_eq!(invite.fingerprint, identity.fingerprint());
        assert_eq!(invite.nickname.as_deref(), Some("Alice"));
        assert!(verify_signature(
            &identity.public_key(),
            &invite.signing_bytes().unwrap(),
            invite.signature.as_deref().unwrap()
        ));
    }

    #[test]
    fn contact_invite_parse_at_is_deterministic_at_expiry_boundary() {
        let identity = Identity::generate();
        let mut invite = ContactInvite::from_identity(
            &identity,
            Some("Alice".into()),
            None,
            "key-package".into(),
            "00000000-0000-4000-8000-000000000000".into(),
            1_000,
        );
        invite.sign(&identity).unwrap();
        let encoded = serde_json::to_string(&invite).unwrap();
        assert!(ContactInvite::parse_at(&encoded, 999).is_ok());
        assert!(ContactInvite::parse_at(&encoded, 1_000).is_ok());
        assert_eq!(
            ContactInvite::parse_at(&encoded, 1_001).unwrap_err(),
            "invite has expired"
        );
    }

    #[test]
    fn contact_invite_rejects_fingerprint_tampering() {
        let identity = Identity::generate();
        let value = serde_json::json!({
            "version": PROTOCOL_VERSION,
            "installation_id": identity.installation_id(),
            "public_key": identity.public_key(),
            "fingerprint": "00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00",
            "nickname": "Alice",
            "recipient_installation_id": null,
            "key_package": "base64-key-package"
            ,"invite_id": "00000000-0000-4000-8000-000000000000"
            ,"expires_at": 4102444800u64
            ,"signature": "invalid"
        })
        .to_string();
        assert!(ContactInvite::parse(&value).is_err());
    }

    #[test]
    fn pairing_code_digits_trims_and_rejects_invalid_values() {
        assert_eq!(
            Identity::pairing_code_digits(" 12345678 ").unwrap(),
            "12345678"
        );
        assert!(Identity::pairing_code_digits("1234").is_err());
    }

    #[test]
    fn onion_validation_is_strict() {
        assert!(is_valid_onion_address(&format!("{}.onion", "a".repeat(56))));
        assert!(!is_valid_onion_address("example.onion"));
        assert!(!is_valid_onion_address(&format!(
            "{}.onion",
            "1".repeat(56)
        )));
    }
}
