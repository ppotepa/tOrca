#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum InboundTransport {
    Relay,
    Peer,
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct TransportMetadata {
    pub connection_generation: u64,
    pub route_label: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct InboundEnvelope {
    pub transport: InboundTransport,
    pub envelope_id: String,
    pub sender_id: String,
    pub recipient_id: String,
    pub protocol_version: u32,
    pub payload_kind: String,
    pub received_at_ms: i64,
    pub ciphertext: Vec<u8>,
    pub metadata: TransportMetadata,
}

impl InboundEnvelope {
    pub fn dedup_material(&self) -> String {
        format!(
            "{}:{}:{}:{}",
            self.sender_id, self.envelope_id, self.payload_kind, self.protocol_version,
        )
    }
}
