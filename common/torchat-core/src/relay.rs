use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::{Identity, PROTOCOL_VERSION, fingerprint_from_public_key, verify_signature};

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct ContactCard {
    pub installation_id: String,
    pub public_key: String,
    pub fingerprint: String,
    pub nickname: String,
}

impl ContactCard {
    pub fn from_identity(identity: &Identity, nickname: impl Into<String>) -> Self {
        Self {
            installation_id: identity.installation_id(),
            public_key: identity.public_key(),
            fingerprint: identity.fingerprint(),
            nickname: nickname.into(),
        }
    }

    pub fn validate(&self) -> Result<(), String> {
        let public = URL_SAFE_NO_PAD
            .decode(&self.public_key)
            .map_err(|_| "invalid contact public key")?;
        let public: [u8; 32] = public
            .as_slice()
            .try_into()
            .map_err(|_| "invalid contact public key length")?;
        let installation_id = {
            use sha2::{Digest, Sha256};
            URL_SAFE_NO_PAD.encode(Sha256::digest(public))
        };
        if installation_id != self.installation_id {
            return Err("contact installation ID does not match public key".into());
        }
        if fingerprint_from_public_key(&public) != self.fingerprint {
            return Err("contact fingerprint does not match public key".into());
        }
        let nickname = self.nickname.trim();
        if nickname.len() < 2 || nickname.chars().count() > 32 {
            return Err("contact nickname is invalid".into());
        }
        Ok(())
    }
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum RelayPayloadV1 {
    PairingOffer {
        version: u16,
        pairing_id: String,
        capability: String,
        invite: String,
    },
    PairingRejected {
        version: u16,
        pairing_id: String,
    },
    Welcome {
        version: u16,
        sender: ContactCard,
        recipient: String,
        invite_id: String,
        welcome: String,
        ratchet_tree: String,
        signature: String,
    },
    Application {
        version: u16,
        ciphertext: String,
    },
}

impl RelayPayloadV1 {
    pub fn pairing_offer(pairing_id: String, capability: String, invite: String) -> Self {
        Self::PairingOffer {
            version: PROTOCOL_VERSION,
            pairing_id,
            capability,
            invite,
        }
    }

    pub fn pairing_rejected(pairing_id: String) -> Self {
        Self::PairingRejected {
            version: PROTOCOL_VERSION,
            pairing_id,
        }
    }
    pub fn welcome(
        identity: &Identity,
        nickname: &str,
        recipient: String,
        invite_id: String,
        welcome: &[u8],
        ratchet_tree: &[u8],
    ) -> Self {
        let sender = ContactCard::from_identity(identity, nickname.trim());
        let welcome = URL_SAFE_NO_PAD.encode(welcome);
        let ratchet_tree = URL_SAFE_NO_PAD.encode(ratchet_tree);
        let signature = identity.sign(&welcome_signing_bytes(
            &sender,
            &recipient,
            &invite_id,
            &welcome,
            &ratchet_tree,
        ));
        Self::Welcome {
            version: PROTOCOL_VERSION,
            sender,
            recipient,
            invite_id,
            welcome,
            ratchet_tree,
            signature,
        }
    }

    pub fn application(ciphertext: &[u8]) -> Self {
        Self::Application {
            version: PROTOCOL_VERSION,
            ciphertext: URL_SAFE_NO_PAD.encode(ciphertext),
        }
    }

    pub fn encode(&self) -> Result<String, String> {
        serde_json::to_vec(self)
            .map(|value| URL_SAFE_NO_PAD.encode(value))
            .map_err(|error| format!("encode relay payload: {error}"))
    }

    pub fn decode(value: &str) -> Result<Self, String> {
        let bytes = URL_SAFE_NO_PAD
            .decode(value)
            .map_err(|_| "invalid relay payload encoding")?;
        let payload: Self = serde_json::from_slice(&bytes)
            .map_err(|error| format!("invalid relay payload: {error}"))?;
        let version = match &payload {
            Self::PairingOffer { version, .. }
            | Self::PairingRejected { version, .. }
            | Self::Welcome { version, .. }
            | Self::Application { version, .. } => *version,
        };
        if version != PROTOCOL_VERSION {
            return Err("unsupported relay payload version".into());
        }
        Ok(payload)
    }

    pub fn verify_welcome(
        &self,
        expected_sender: &str,
        expected_recipient: &str,
    ) -> Result<(), String> {
        let Self::Welcome {
            sender,
            recipient,
            invite_id,
            welcome,
            ratchet_tree,
            signature,
            ..
        } = self
        else {
            return Err("relay payload is not a Welcome".into());
        };
        sender.validate()?;
        if sender.installation_id != expected_sender {
            return Err("Welcome sender does not match relay sender".into());
        }
        if recipient != expected_recipient {
            return Err("Welcome recipient does not match local identity".into());
        }
        if !verify_signature(
            &sender.public_key,
            &welcome_signing_bytes(sender, recipient, invite_id, welcome, ratchet_tree),
            signature,
        ) {
            return Err("invalid Welcome signature".into());
        }
        Ok(())
    }

    pub fn decode_application(&self) -> Result<Vec<u8>, String> {
        let Self::Application { ciphertext, .. } = self else {
            return Err("relay payload is not an application message".into());
        };
        URL_SAFE_NO_PAD
            .decode(ciphertext)
            .map_err(|_| "invalid application ciphertext encoding".into())
    }

    pub fn decode_welcome(&self) -> Result<(String, Vec<u8>, Vec<u8>), String> {
        let Self::Welcome {
            invite_id,
            welcome,
            ratchet_tree,
            ..
        } = self
        else {
            return Err("relay payload is not a Welcome".into());
        };
        Ok((
            invite_id.clone(),
            URL_SAFE_NO_PAD
                .decode(welcome)
                .map_err(|_| "invalid Welcome encoding")?,
            URL_SAFE_NO_PAD
                .decode(ratchet_tree)
                .map_err(|_| "invalid ratchet tree encoding")?,
        ))
    }
}

fn welcome_signing_bytes(
    sender: &ContactCard,
    recipient: &str,
    invite_id: &str,
    welcome: &str,
    ratchet_tree: &str,
) -> Vec<u8> {
    let mut output = b"torchat-welcome-v1".to_vec();
    for value in [
        sender.installation_id.as_bytes(),
        sender.public_key.as_bytes(),
        sender.fingerprint.as_bytes(),
        sender.nickname.as_bytes(),
        recipient.as_bytes(),
        invite_id.as_bytes(),
        welcome.as_bytes(),
        ratchet_tree.as_bytes(),
    ] {
        output.extend_from_slice(&(value.len() as u32).to_be_bytes());
        output.extend_from_slice(value);
    }
    output
}

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct RelayEnvelope {
    pub version: u16,
    pub message_id: Uuid,
    pub sender: String,
    pub recipient: String,
    pub ciphertext: String,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum RelayClientFrame {
    Envelope(RelayEnvelope),
    DeliveryReceipt { message_id: Uuid, sender: String },
    Ping,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum RelayServerFrame {
    Ready { installation_id: String },
    Envelope(RelayEnvelope),
    Forwarded { message_id: Uuid },
    DeliveryReceipt { message_id: Uuid },
    RecipientOffline { message_id: Uuid },
    Error { code: String },
    Pong,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn signed_welcome_round_trip_rejects_tampering() {
        let alice = Identity::generate();
        let bob = Identity::generate();
        let payload = RelayPayloadV1::welcome(
            &alice,
            "Alice",
            bob.installation_id(),
            "invite".into(),
            b"welcome",
            b"tree",
        );
        let encoded = payload.encode().unwrap();
        let decoded = RelayPayloadV1::decode(&encoded).unwrap();
        decoded
            .verify_welcome(&alice.installation_id(), &bob.installation_id())
            .unwrap();

        let RelayPayloadV1::Welcome {
            mut sender,
            recipient,
            invite_id,
            welcome,
            ratchet_tree,
            signature,
            version,
        } = decoded
        else {
            unreachable!()
        };
        sender.nickname = "Mallory".into();
        let changed = RelayPayloadV1::Welcome {
            version,
            sender,
            recipient,
            invite_id,
            welcome,
            ratchet_tree,
            signature,
        };
        assert!(
            changed
                .verify_welcome(&alice.installation_id(), &bob.installation_id())
                .is_err()
        );
    }
}
