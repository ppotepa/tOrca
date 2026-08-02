use std::collections::BTreeSet;

use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD};
use hmac::{Hmac, Mac};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use uuid::Uuid;

use crate::{Identity, PROTOCOL_VERSION, is_valid_onion_address, verify_signature};

pub const PEER_VIRTUAL_PORT: u16 = 443;
pub const PEER_PATH: &str = "/v1/peer";
/// Maximum serialized ciphertext accepted by every message transport. Keeping
/// this below the relay limit prevents a P2P-accepted message from becoming a
/// permanently retrying relay-fallback payload.
pub const MAX_TRANSPORT_CIPHERTEXT_BYTES: usize = 128 * 1024;
pub const MAX_PEER_FRAME_BYTES: usize = 256 * 1024;
pub const MAX_PREAUTH_FRAME_BYTES: usize = 8 * 1024;
type CapabilityHmac = Hmac<Sha256>;

const ENDPOINT_DOMAIN: &[u8] = b"torchat-peer-endpoint-v1";
const HANDSHAKE_DOMAIN: &[u8] = b"torchat-peer-handshake-v1";
const MESSAGE_DOMAIN: &[u8] = b"torchat-peer-message-v1";

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PeerCiphertextPayload {
    pub protocol_version: u16,
    pub ciphertext: String,
}

impl PeerCiphertextPayload {
    pub fn new(ciphertext: &[u8]) -> Self {
        Self {
            protocol_version: PROTOCOL_VERSION,
            ciphertext: URL_SAFE_NO_PAD.encode(ciphertext),
        }
    }

    pub fn encode(&self) -> Result<String, String> {
        serde_json::to_vec(self)
            .map(|value| URL_SAFE_NO_PAD.encode(value))
            .map_err(|error| format!("encode peer ciphertext payload: {error}"))
    }

    pub fn decode(value: &str) -> Result<Vec<u8>, String> {
        let bytes = URL_SAFE_NO_PAD
            .decode(value)
            .map_err(|_| "invalid peer ciphertext payload encoding")?;
        let payload: Self = serde_json::from_slice(&bytes)
            .map_err(|error| format!("invalid peer ciphertext payload: {error}"))?;
        if payload.protocol_version != PROTOCOL_VERSION {
            return Err("unsupported peer ciphertext payload version".into());
        }
        URL_SAFE_NO_PAD
            .decode(payload.ciphertext)
            .map_err(|_| "invalid peer ciphertext encoding".into())
    }
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PeerEndpointBundle {
    pub protocol_version: u16,
    pub installation_id: String,
    pub onion_address: String,
    pub virtual_port: u16,
    pub identity_public_key: String,
    #[serde(default)]
    pub capabilities: Vec<String>,
    pub sequence: u64,
    pub issued_at: i64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub expires_at: Option<i64>,
    pub signature: String,
}

impl PeerEndpointBundle {
    pub fn new(
        identity: &Identity,
        onion_address: impl Into<String>,
        sequence: u64,
        issued_at: i64,
        expires_at: Option<i64>,
    ) -> Self {
        let mut endpoint = Self {
            protocol_version: PROTOCOL_VERSION,
            installation_id: identity.installation_id(),
            onion_address: onion_address.into().trim().to_ascii_lowercase(),
            virtual_port: PEER_VIRTUAL_PORT,
            identity_public_key: identity.public_key(),
            capabilities: vec!["peer_message_v1".to_owned(), "peer_receipt_v1".to_owned()],
            sequence,
            issued_at,
            expires_at,
            signature: String::new(),
        };
        endpoint.signature = identity.sign(&endpoint.signing_bytes());
        endpoint
    }

    pub fn signing_bytes(&self) -> Vec<u8> {
        let mut bytes = Vec::new();
        push_bytes(&mut bytes, ENDPOINT_DOMAIN);
        push_u16(&mut bytes, self.protocol_version);
        push_str(&mut bytes, &self.installation_id);
        push_str(&mut bytes, &self.onion_address);
        push_u16(&mut bytes, self.virtual_port);
        push_str(&mut bytes, &self.identity_public_key);
        push_u32(&mut bytes, self.capabilities.len() as u32);
        for capability in &self.capabilities {
            push_str(&mut bytes, capability);
        }
        push_u64(&mut bytes, self.sequence);
        push_i64(&mut bytes, self.issued_at);
        match self.expires_at {
            Some(value) => {
                bytes.push(1);
                push_i64(&mut bytes, value);
            }
            None => bytes.push(0),
        }
        bytes
    }

    pub fn validate(&self, now: i64) -> Result<(), String> {
        if self.protocol_version != PROTOCOL_VERSION {
            return Err("unsupported peer endpoint protocol version".into());
        }
        if self.sequence == 0 {
            return Err("peer endpoint sequence must be positive".into());
        }
        if self.virtual_port != PEER_VIRTUAL_PORT {
            return Err("unsupported peer endpoint virtual port".into());
        }
        if !is_valid_onion_address(&self.onion_address) {
            return Err("invalid Tor v3 peer endpoint".into());
        }
        if self.expires_at.is_some_and(|expires_at| expires_at < now) {
            return Err("peer endpoint has expired".into());
        }
        if self.capabilities.is_empty()
            || self
                .capabilities
                .iter()
                .any(|capability| capability.trim().is_empty() || capability.len() > 64)
        {
            return Err("invalid peer endpoint capabilities".into());
        }
        let unique = self.capabilities.iter().collect::<BTreeSet<_>>();
        if unique.len() != self.capabilities.len() {
            return Err("duplicate peer endpoint capability".into());
        }
        let public_key = decode_public_key(&self.identity_public_key)?;
        let installation_id = installation_id_from_public_key(&public_key);
        if installation_id != self.installation_id {
            return Err("peer endpoint installation ID does not match identity key".into());
        }
        if !verify_signature(
            &self.identity_public_key,
            &self.signing_bytes(),
            &self.signature,
        ) {
            return Err("peer endpoint signature is invalid".into());
        }
        Ok(())
    }

    pub fn validate_successor(
        &self,
        previous: &PeerEndpointBundle,
        now: i64,
    ) -> Result<(), String> {
        self.validate(now)?;
        if self.installation_id != previous.installation_id
            || self.identity_public_key != previous.identity_public_key
        {
            return Err("peer endpoint update changed contact identity".into());
        }
        if self.sequence <= previous.sequence {
            return Err("peer endpoint sequence did not advance".into());
        }
        Ok(())
    }
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PeerEndpointUpdate {
    pub previous_sequence: u64,
    pub endpoint: PeerEndpointBundle,
}

impl PeerEndpointUpdate {
    pub fn validate(&self, previous: &PeerEndpointBundle, now: i64) -> Result<(), String> {
        if self.previous_sequence != previous.sequence {
            return Err("peer endpoint update does not reference current sequence".into());
        }
        self.endpoint.validate_successor(previous, now)
    }
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PeerClientHello {
    pub protocol_version: u16,
    pub installation_id: String,
    pub endpoint_sequence: u64,
    #[serde(default)]
    pub capability_id: String,
    #[serde(default)]
    pub capability_proof: String,
    pub nonce: [u8; 32],
}

pub fn capability_proof(secret: &[u8], hello: &PeerClientHello) -> String {
    let mut mac = CapabilityHmac::new_from_slice(secret).expect("HMAC accepts arbitrary keys");
    mac.update(b"torchat-peer-capability-v1");
    mac.update(hello.installation_id.as_bytes());
    mac.update(&hello.endpoint_sequence.to_be_bytes());
    mac.update(hello.capability_id.as_bytes());
    mac.update(&hello.nonce);
    URL_SAFE_NO_PAD.encode(mac.finalize().into_bytes())
}

pub fn verify_capability_proof(secret: &[u8], hello: &PeerClientHello) -> bool {
    let Ok(proof) = URL_SAFE_NO_PAD.decode(&hello.capability_proof) else {
        return false;
    };
    let mut mac = CapabilityHmac::new_from_slice(secret).expect("HMAC accepts arbitrary keys");
    mac.update(b"torchat-peer-capability-v1");
    mac.update(hello.installation_id.as_bytes());
    mac.update(&hello.endpoint_sequence.to_be_bytes());
    mac.update(hello.capability_id.as_bytes());
    mac.update(&hello.nonce);
    mac.verify_slice(&proof).is_ok()
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PeerServerChallenge {
    pub protocol_version: u16,
    pub installation_id: String,
    pub endpoint_sequence: u64,
    pub nonce: [u8; 32],
    pub session_id: Uuid,
    pub signature: String,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PeerClientProof {
    pub session_id: Uuid,
    pub signature: String,
}

pub fn handshake_transcript(
    client: &PeerClientHello,
    server_installation_id: &str,
    server_endpoint_sequence: u64,
    server_nonce: &[u8; 32],
    session_id: Uuid,
    onion_address: &str,
) -> Vec<u8> {
    let mut bytes = Vec::new();
    push_bytes(&mut bytes, HANDSHAKE_DOMAIN);
    push_u16(&mut bytes, client.protocol_version);
    push_str(&mut bytes, &client.installation_id);
    push_u64(&mut bytes, client.endpoint_sequence);
    push_str(&mut bytes, &client.capability_id);
    push_bytes(&mut bytes, &client.nonce);
    push_str(&mut bytes, server_installation_id);
    push_u64(&mut bytes, server_endpoint_sequence);
    push_bytes(&mut bytes, server_nonce);
    push_bytes(&mut bytes, session_id.as_bytes());
    push_str(&mut bytes, onion_address);
    bytes
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PeerMessageEnvelope {
    pub protocol_version: u16,
    pub session_id: Uuid,
    pub message_id: Uuid,
    pub conversation_id: String,
    pub sender_installation_id: String,
    pub sequence: u64,
    pub created_at: i64,
    #[serde(with = "base64_bytes")]
    pub ciphertext: Vec<u8>,
    pub signature: String,
}

mod base64_bytes {
    use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD};
    use serde::{Deserialize, Deserializer, Serializer};

    pub fn serialize<S>(value: &[u8], serializer: S) -> Result<S::Ok, S::Error>
    where
        S: Serializer,
    {
        serializer.serialize_str(&URL_SAFE_NO_PAD.encode(value))
    }

    pub fn deserialize<'de, D>(deserializer: D) -> Result<Vec<u8>, D::Error>
    where
        D: Deserializer<'de>,
    {
        let value = String::deserialize(deserializer)?;
        URL_SAFE_NO_PAD
            .decode(value)
            .map_err(serde::de::Error::custom)
    }
}

impl PeerMessageEnvelope {
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        identity: &Identity,
        session_id: Uuid,
        message_id: Uuid,
        conversation_id: impl Into<String>,
        sequence: u64,
        created_at: i64,
        ciphertext: Vec<u8>,
    ) -> Self {
        let mut envelope = Self {
            protocol_version: PROTOCOL_VERSION,
            session_id,
            message_id,
            conversation_id: conversation_id.into(),
            sender_installation_id: identity.installation_id(),
            sequence,
            created_at,
            ciphertext,
            signature: String::new(),
        };
        envelope.signature = identity.sign(&envelope.signing_bytes());
        envelope
    }

    pub fn ciphertext_hash(&self) -> [u8; 32] {
        Sha256::digest(&self.ciphertext).into()
    }

    pub fn signing_bytes(&self) -> Vec<u8> {
        let mut bytes = Vec::new();
        push_bytes(&mut bytes, MESSAGE_DOMAIN);
        push_u16(&mut bytes, self.protocol_version);
        push_bytes(&mut bytes, self.session_id.as_bytes());
        push_bytes(&mut bytes, self.message_id.as_bytes());
        push_str(&mut bytes, &self.conversation_id);
        push_str(&mut bytes, &self.sender_installation_id);
        push_u64(&mut bytes, self.sequence);
        push_i64(&mut bytes, self.created_at);
        push_bytes(&mut bytes, &self.ciphertext_hash());
        bytes
    }

    pub fn verify(&self, expected_sender: &str, public_key: &str) -> Result<(), String> {
        if self.protocol_version != PROTOCOL_VERSION {
            return Err("unsupported peer message protocol version".into());
        }
        if self.sender_installation_id != expected_sender {
            return Err("peer message sender does not match authenticated session".into());
        }
        if self.sequence == 0 || self.ciphertext.is_empty() {
            return Err("invalid peer message envelope".into());
        }
        if !verify_signature(public_key, &self.signing_bytes(), &self.signature) {
            return Err("peer message signature is invalid".into());
        }
        Ok(())
    }
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
pub enum PeerAckKind {
    Received,
    Persisted,
    Delivered,
    Rejected,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PeerAck {
    pub session_id: Uuid,
    pub message_id: Uuid,
    pub kind: PeerAckKind,
    pub ciphertext_hash: [u8; 32],
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
pub enum PeerPresenceState {
    Online,
    Away,
    Offline,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(
    tag = "type",
    rename_all = "snake_case",
    rename_all_fields = "camelCase"
)]
pub enum PeerFrame {
    ClientHello {
        hello: PeerClientHello,
    },
    ServerChallenge {
        challenge: PeerServerChallenge,
    },
    ClientProof {
        proof: PeerClientProof,
    },
    HandshakeAccepted {
        session_id: Uuid,
    },
    Message {
        envelope: PeerMessageEnvelope,
    },
    Ack {
        ack: PeerAck,
    },
    EndpointUpdate {
        update: PeerEndpointUpdate,
    },
    Ping {
        nonce: u64,
    },
    Pong {
        nonce: u64,
    },
    Presence {
        state: PeerPresenceState,
        sent_at: i64,
        expires_at: i64,
        nonce: u64,
    },
    Typing {
        typing: bool,
        sent_at: i64,
        expires_at: i64,
        nonce: u64,
    },
    ProbeRequest {
        nonce: u64,
    },
    ProbeResponse {
        nonce: u64,
        presence: PeerPresenceState,
        observed_at: i64,
    },
    ProtocolError {
        code: String,
    },
}

pub fn encode_frame(frame: &PeerFrame) -> Result<Vec<u8>, String> {
    serde_json::to_vec(frame).map_err(|error| format!("encode peer frame: {error}"))
}

pub fn decode_frame(bytes: &[u8], authenticated: bool) -> Result<PeerFrame, String> {
    let limit = if authenticated {
        MAX_PEER_FRAME_BYTES
    } else {
        MAX_PREAUTH_FRAME_BYTES
    };
    if bytes.len() > limit {
        return Err("peer frame exceeds size limit".into());
    }
    serde_json::from_slice(bytes).map_err(|error| format!("decode peer frame: {error}"))
}

fn decode_public_key(value: &str) -> Result<[u8; 32], String> {
    use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD};
    let decoded = URL_SAFE_NO_PAD
        .decode(value)
        .map_err(|_| "invalid endpoint identity public key")?;
    decoded
        .as_slice()
        .try_into()
        .map_err(|_| "invalid endpoint identity public key length".into())
}

fn installation_id_from_public_key(public_key: &[u8; 32]) -> String {
    use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD};
    URL_SAFE_NO_PAD.encode(Sha256::digest(public_key))
}

fn push_bytes(output: &mut Vec<u8>, value: &[u8]) {
    push_u32(output, value.len() as u32);
    output.extend_from_slice(value);
}

fn push_str(output: &mut Vec<u8>, value: &str) {
    push_bytes(output, value.as_bytes());
}

fn push_u16(output: &mut Vec<u8>, value: u16) {
    output.extend_from_slice(&value.to_be_bytes());
}

fn push_u32(output: &mut Vec<u8>, value: u32) {
    output.extend_from_slice(&value.to_be_bytes());
}

fn push_u64(output: &mut Vec<u8>, value: u64) {
    output.extend_from_slice(&value.to_be_bytes());
}

fn push_i64(output: &mut Vec<u8>, value: i64) {
    output.extend_from_slice(&value.to_be_bytes());
}

#[cfg(test)]
mod tests {
    use super::*;

    fn onion(fill: char) -> String {
        format!("{}.onion", fill.to_string().repeat(56))
    }

    #[test]
    fn signed_endpoint_rejects_tampering_and_stale_update() {
        let identity = Identity::generate();
        let endpoint = PeerEndpointBundle::new(&identity, onion('a'), 1, 10, None);
        endpoint.validate(11).unwrap();

        let mut tampered = endpoint.clone();
        tampered.onion_address = onion('b');
        assert!(tampered.validate(11).is_err());

        let successor = PeerEndpointBundle::new(&identity, onion('b'), 2, 12, None);
        successor.validate_successor(&endpoint, 12).unwrap();
        assert!(endpoint.validate_successor(&successor, 12).is_err());
    }

    #[test]
    fn handshake_transcript_binds_onion_and_both_identities() {
        let client = Identity::generate();
        let server = Identity::generate();
        let hello = PeerClientHello {
            protocol_version: PROTOCOL_VERSION,
            installation_id: client.installation_id(),
            endpoint_sequence: 1,
            capability_id: String::new(),
            capability_proof: String::new(),
            nonce: [7; 32],
        };
        let session_id = Uuid::new_v4();
        let first = handshake_transcript(
            &hello,
            &server.installation_id(),
            2,
            &[9; 32],
            session_id,
            &onion('a'),
        );
        let second = handshake_transcript(
            &hello,
            &server.installation_id(),
            2,
            &[9; 32],
            session_id,
            &onion('b'),
        );
        assert_ne!(first, second);
        let signature = server.sign(&first);
        assert!(verify_signature(&server.public_key(), &first, &signature));
        assert!(!verify_signature(&server.public_key(), &second, &signature));
    }

    #[test]
    fn capability_proof_binds_hello_and_secret() {
        let identity = Identity::generate();
        let mut hello = PeerClientHello {
            protocol_version: PROTOCOL_VERSION,
            installation_id: identity.installation_id(),
            endpoint_sequence: 1,
            capability_id: "1234567890abcdef".to_owned(),
            capability_proof: String::new(),
            nonce: [4; 32],
        };
        hello.capability_proof = capability_proof(b"secret", &hello);
        assert!(verify_capability_proof(b"secret", &hello));
        assert!(!verify_capability_proof(b"wrong-secret", &hello));
        hello.nonce[0] ^= 1;
        assert!(!verify_capability_proof(b"secret", &hello));
    }

    #[test]
    fn signed_message_reuses_ciphertext_and_detects_changes() {
        let identity = Identity::generate();
        let envelope = PeerMessageEnvelope::new(
            &identity,
            Uuid::new_v4(),
            Uuid::new_v4(),
            "conversation",
            1,
            42,
            b"ciphertext".to_vec(),
        );
        envelope
            .verify(&identity.installation_id(), &identity.public_key())
            .unwrap();
        let mut changed = envelope.clone();
        changed.ciphertext.push(1);
        assert!(
            changed
                .verify(&identity.installation_id(), &identity.public_key())
                .is_err()
        );
    }

    #[test]
    fn attachment_sized_ciphertext_stays_within_peer_frame_limit() {
        let identity = Identity::generate();
        let envelope = PeerMessageEnvelope::new(
            &identity,
            Uuid::new_v4(),
            Uuid::new_v4(),
            "conversation",
            1,
            42,
            vec![7; 96 * 1024],
        );
        let encoded = encode_frame(&PeerFrame::Message { envelope }).unwrap();
        assert!(encoded.len() < MAX_PEER_FRAME_BYTES);
        assert!(decode_frame(&encoded, true).is_ok());
    }

    #[test]
    fn preauth_frame_limit_is_stricter() {
        let frame = PeerFrame::ProtocolError {
            code: "x".repeat(MAX_PREAUTH_FRAME_BYTES),
        };
        let encoded = encode_frame(&frame).unwrap();
        assert!(decode_frame(&encoded, false).is_err());
        assert!(decode_frame(&encoded, true).is_ok());
    }

    #[test]
    fn rejected_ack_round_trips_with_message_identity() {
        let ack = PeerAck {
            session_id: Uuid::new_v4(),
            message_id: Uuid::new_v4(),
            kind: PeerAckKind::Rejected,
            ciphertext_hash: [7; 32],
        };
        let encoded = encode_frame(&PeerFrame::Ack { ack: ack.clone() }).unwrap();
        let decoded = decode_frame(&encoded, true).unwrap();
        assert_eq!(decoded, PeerFrame::Ack { ack });
    }
}
