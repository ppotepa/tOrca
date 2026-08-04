use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD};
use serde::{Deserialize, Serialize};

use crate::{
    Identity, PROTOCOL_VERSION, fingerprint_from_public_key, peer_protocol::PeerEndpointBundle,
    verify_signature,
};

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
        #[serde(default, skip_serializing_if = "Option::is_none")]
        peer_endpoint: Option<PeerEndpointBundle>,
        signature: String,
    },
    WelcomeApplied {
        version: u16,
        sender: ContactCard,
        recipient: String,
        invite_id: String,
        signature: String,
    },
    PeerEndpointBootstrap {
        version: u16,
        sender: ContactCard,
        recipient: String,
        endpoint: PeerEndpointBundle,
    },
    RelationshipRemovalApplied {
        version: u16,
        sender: ContactCard,
        recipient_installation_id: String,
        removal_id: String,
        relationship_epoch: i64,
        applied_at: i64,
        signature: String,
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
        Self::welcome_with_endpoint(
            identity,
            nickname,
            recipient,
            invite_id,
            welcome,
            ratchet_tree,
            None,
        )
    }

    pub fn welcome_with_endpoint(
        identity: &Identity,
        nickname: &str,
        recipient: String,
        invite_id: String,
        welcome: &[u8],
        ratchet_tree: &[u8],
        peer_endpoint: Option<PeerEndpointBundle>,
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
            peer_endpoint.as_ref(),
        ));
        Self::Welcome {
            version: PROTOCOL_VERSION,
            sender,
            recipient,
            invite_id,
            welcome,
            ratchet_tree,
            peer_endpoint,
            signature,
        }
    }

    pub fn welcome_applied(
        identity: &Identity,
        nickname: &str,
        recipient: String,
        invite_id: String,
    ) -> Self {
        let sender = ContactCard::from_identity(identity, nickname.trim());
        let signature = identity.sign(&welcome_applied_signing_bytes(
            &sender, &recipient, &invite_id,
        ));
        Self::WelcomeApplied {
            version: PROTOCOL_VERSION,
            sender,
            recipient,
            invite_id,
            signature,
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
            | Self::WelcomeApplied { version, .. }
            | Self::PeerEndpointBootstrap { version, .. } => *version,
            Self::RelationshipRemovalApplied { version, .. } => *version,
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
            peer_endpoint,
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
            &welcome_signing_bytes(
                sender,
                recipient,
                invite_id,
                welcome,
                ratchet_tree,
                peer_endpoint.as_ref(),
            ),
            signature,
        ) {
            return Err("invalid Welcome signature".into());
        }
        Ok(())
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

    pub fn welcome_peer_endpoint(&self) -> Option<&PeerEndpointBundle> {
        match self {
            Self::Welcome { peer_endpoint, .. } => peer_endpoint.as_ref(),
            _ => None,
        }
    }

    pub fn verify_welcome_applied(
        &self,
        expected_sender: &str,
        expected_recipient: &str,
    ) -> Result<String, String> {
        let Self::WelcomeApplied {
            sender,
            recipient,
            invite_id,
            signature,
            ..
        } = self
        else {
            return Err("relay payload is not a WelcomeApplied acknowledgement".into());
        };
        sender.validate()?;
        if sender.installation_id != expected_sender {
            return Err("WelcomeApplied sender does not match relay sender".into());
        }
        if recipient != expected_recipient {
            return Err("WelcomeApplied recipient does not match local identity".into());
        }
        if !verify_signature(
            &sender.public_key,
            &welcome_applied_signing_bytes(sender, recipient, invite_id),
            signature,
        ) {
            return Err("invalid WelcomeApplied signature".into());
        }
        Ok(invite_id.clone())
    }

    pub fn peer_endpoint_bootstrap(
        identity: &Identity,
        nickname: &str,
        recipient: String,
        endpoint: PeerEndpointBundle,
    ) -> Self {
        Self::PeerEndpointBootstrap {
            version: PROTOCOL_VERSION,
            sender: ContactCard::from_identity(identity, nickname.trim()),
            recipient,
            endpoint,
        }
    }

    pub fn relationship_removal_applied(
        identity: &Identity,
        recipient_installation_id: String,
        removal_id: String,
        relationship_epoch: i64,
        applied_at: i64,
    ) -> Self {
        let sender = ContactCard::from_identity(identity, "TorChat");
        let signature = identity.sign(&relationship_removal_applied_signing_bytes(
            &sender,
            &recipient_installation_id,
            &removal_id,
            relationship_epoch,
            applied_at,
        ));
        Self::RelationshipRemovalApplied {
            version: PROTOCOL_VERSION,
            sender,
            recipient_installation_id,
            removal_id,
            relationship_epoch,
            applied_at,
            signature,
        }
    }

    pub fn verify_relationship_removal_applied(
        &self,
        expected_sender: &str,
        expected_recipient: &str,
    ) -> Result<String, String> {
        let Self::RelationshipRemovalApplied {
            sender,
            recipient_installation_id,
            removal_id,
            relationship_epoch,
            applied_at,
            signature,
            ..
        } = self
        else {
            return Err("relay payload is not a relationship removal acknowledgement".into());
        };
        sender.validate()?;
        if sender.installation_id != expected_sender {
            return Err("relationship removal ACK sender mismatch".into());
        }
        if recipient_installation_id != expected_recipient {
            return Err("relationship removal ACK recipient mismatch".into());
        }
        if !verify_signature(
            &sender.public_key,
            &relationship_removal_applied_signing_bytes(
                sender,
                recipient_installation_id,
                removal_id,
                *relationship_epoch,
                *applied_at,
            ),
            signature,
        ) {
            return Err("invalid relationship removal ACK signature".into());
        }
        Ok(removal_id.clone())
    }

    pub fn verify_peer_endpoint_bootstrap(
        &self,
        expected_sender: &str,
        expected_recipient: &str,
    ) -> Result<PeerEndpointBundle, String> {
        let Self::PeerEndpointBootstrap {
            sender,
            recipient,
            endpoint,
            ..
        } = self
        else {
            return Err("relay payload is not a peer endpoint bootstrap".into());
        };
        sender.validate()?;
        if sender.installation_id != expected_sender {
            return Err("peer endpoint bootstrap sender does not match relay sender".into());
        }
        if recipient != expected_recipient {
            return Err("peer endpoint bootstrap recipient does not match local identity".into());
        }
        if endpoint.installation_id != sender.installation_id
            || endpoint.identity_public_key != sender.public_key
        {
            return Err("peer endpoint bootstrap does not match sender identity".into());
        }
        Ok(endpoint.clone())
    }
}

fn welcome_signing_bytes(
    sender: &ContactCard,
    recipient: &str,
    invite_id: &str,
    welcome: &str,
    ratchet_tree: &str,
    peer_endpoint: Option<&PeerEndpointBundle>,
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
    let endpoint = peer_endpoint
        .map(|value| serde_json::to_vec(value).expect("peer endpoint must serialize"))
        .unwrap_or_default();
    output.extend_from_slice(&(endpoint.len() as u32).to_be_bytes());
    output.extend_from_slice(&endpoint);
    output
}

fn welcome_applied_signing_bytes(
    sender: &ContactCard,
    recipient: &str,
    invite_id: &str,
) -> Vec<u8> {
    let mut output = b"torchat-welcome-applied-v1".to_vec();
    for value in [
        sender.installation_id.as_bytes(),
        sender.public_key.as_bytes(),
        sender.fingerprint.as_bytes(),
        sender.nickname.as_bytes(),
        recipient.as_bytes(),
        invite_id.as_bytes(),
    ] {
        output.extend_from_slice(&(value.len() as u32).to_be_bytes());
        output.extend_from_slice(value);
    }
    output
}

fn relationship_removal_applied_signing_bytes(
    sender: &ContactCard,
    recipient_installation_id: &str,
    removal_id: &str,
    relationship_epoch: i64,
    applied_at: i64,
) -> Vec<u8> {
    format!(
        "torchat.relationship-removal-applied.v1|{}|{}|{}|{}|{}|{}",
        PROTOCOL_VERSION,
        sender.installation_id,
        recipient_installation_id,
        removal_id,
        relationship_epoch,
        applied_at,
    )
    .into_bytes()
}

#[path = "relay_frames.rs"]
mod relay_frames;
pub use relay_frames::{RelayClientFrame, RelayEnvelope, RelayServerFrame};

#[cfg(test)]
#[path = "relay_tests.rs"]
mod tests;
