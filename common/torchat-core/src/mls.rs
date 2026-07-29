//! MLS boundary. Application code must not implement a second ratchet.
//!
//! The MVP keeps this boundary narrow; OpenMLS owns the wire format and
//! cryptographic state. Conversation persistence and Android bindings are
//! added around this type, never by exposing private key bytes.

use openmls::{
    credentials::{BasicCredential, CredentialWithKey},
    framing::{MlsMessageBodyIn, MlsMessageIn, ProcessedMessageContent},
    group::{MlsGroup, MlsGroupCreateConfig, MlsGroupJoinConfig, StagedWelcome},
    prelude::{
        Ciphersuite, KeyPackage,
        tls_codec::{Deserialize, Serialize},
    },
};
use openmls_basic_credential::SignatureKeyPair;
use openmls_rust_crypto::{MemoryStorage, RustCrypto};
use openmls_traits::OpenMlsProvider;

const SUITE: Ciphersuite = Ciphersuite::MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519;

/// A local MLS identity and its provider-backed cryptographic state.
///
/// The provider owns private key material. Callers only receive serialized
/// protocol messages and public KeyPackages.
pub struct MlsMember {
    provider: PersistentProvider,
    signer: SignatureKeyPair,
    credential: CredentialWithKey,
}

pub struct DirectConversation {
    provider: PersistentProvider,
    signer: SignatureKeyPair,
    group: MlsGroup,
}

#[derive(Default)]
struct PersistentProvider {
    crypto: RustCrypto,
    storage: MemoryStorage,
}

impl OpenMlsProvider for PersistentProvider {
    type CryptoProvider = RustCrypto;
    type RandProvider = RustCrypto;
    type StorageProvider = MemoryStorage;

    fn storage(&self) -> &Self::StorageProvider {
        &self.storage
    }
    fn crypto(&self) -> &Self::CryptoProvider {
        &self.crypto
    }
    fn rand(&self) -> &Self::RandProvider {
        &self.crypto
    }
}

impl MlsMember {
    pub fn create(identity: &[u8]) -> Result<Self, String> {
        let provider = PersistentProvider::default();
        let signer = SignatureKeyPair::new(SUITE.signature_algorithm())
            .map_err(|e| format!("create MLS signer: {e}"))?;
        signer
            .store(provider.storage())
            .map_err(|e| format!("store MLS signer: {e}"))?;
        let credential = CredentialWithKey {
            credential: BasicCredential::new(identity.to_vec()).into(),
            signature_key: signer.to_public_vec().into(),
        };
        Ok(Self {
            provider,
            signer,
            credential,
        })
    }

    pub fn key_package(&self) -> Result<Vec<u8>, String> {
        let package = KeyPackage::builder()
            .build(SUITE, &self.provider, &self.signer, self.credential.clone())
            .map_err(|e| format!("create MLS KeyPackage: {e}"))?;
        package
            .key_package()
            .tls_serialize_detached()
            .map_err(|e| format!("serialize KeyPackage: {e}"))
    }

    /// Serializes the provider state that owns private KeyPackage material.
    ///
    /// The returned bytes contain secrets and must only be stored in the
    /// client's encrypted local storage.
    pub fn snapshot(&self) -> Result<Vec<u8>, String> {
        let signer = self.signer.to_public_vec();
        let values = self
            .provider
            .storage
            .values
            .read()
            .map_err(|_| "MLS storage lock poisoned")?;
        let mut output = Vec::with_capacity(32 + values.len() * 32);
        output.extend_from_slice(b"TCMEM1");
        write_blob(&mut output, signer.as_slice());
        output.extend_from_slice(&(values.len() as u32).to_be_bytes());
        for (key, value) in values.iter() {
            write_blob(&mut output, key);
            write_blob(&mut output, value);
        }
        Ok(output)
    }

    pub fn restore(snapshot: &[u8], identity: &[u8]) -> Result<Self, String> {
        let mut input = snapshot;
        if take(&mut input, 6)? != b"TCMEM1" {
            return Err("invalid MLS member snapshot header".into());
        }
        let signer_public = take_blob(&mut input)?;
        let count = u32::from_be_bytes(
            take(&mut input, 4)?
                .try_into()
                .map_err(|_| "invalid MLS member snapshot count")?,
        ) as usize;
        let provider = PersistentProvider::default();
        {
            let mut values = provider
                .storage
                .values
                .write()
                .map_err(|_| "MLS storage lock poisoned")?;
            for _ in 0..count {
                values.insert(take_blob(&mut input)?, take_blob(&mut input)?);
            }
        }
        if !input.is_empty() {
            return Err("trailing MLS member snapshot data".into());
        }
        let signer = SignatureKeyPair::read(
            &provider.storage,
            &signer_public,
            SUITE.signature_algorithm(),
        )
        .ok_or_else(|| "MLS signer missing from member snapshot".to_string())?;
        let credential = CredentialWithKey {
            credential: BasicCredential::new(identity.to_vec()).into(),
            signature_key: signer.to_public_vec().into(),
        };
        Ok(Self {
            provider,
            signer,
            credential,
        })
    }

    pub fn create_conversation(self) -> Result<DirectConversation, String> {
        let group = MlsGroup::new(
            &self.provider,
            &self.signer,
            &MlsGroupCreateConfig::builder().ciphersuite(SUITE).build(),
            self.credential,
        )
        .map_err(|e| format!("create MLS group: {e}"))?;
        Ok(DirectConversation {
            provider: self.provider,
            signer: self.signer,
            group,
        })
    }

    pub fn accept_conversation(
        self,
        welcome: &[u8],
        ratchet_tree: &[u8],
    ) -> Result<DirectConversation, String> {
        let mut input = welcome;
        let message = MlsMessageIn::tls_deserialize(&mut input)
            .map_err(|e| format!("decode Welcome: {e}"))?;
        let welcome = match message.extract() {
            MlsMessageBodyIn::Welcome(value) => value,
            _ => return Err("MLS message is not a Welcome".into()),
        };
        let mut ratchet_tree = ratchet_tree;
        let tree = openmls::prelude::RatchetTreeIn::tls_deserialize(&mut ratchet_tree)
            .map_err(|e| format!("decode ratchet tree: {e}"))?;
        let group = StagedWelcome::new_from_welcome(
            &self.provider,
            &MlsGroupJoinConfig::default(),
            welcome,
            Some(tree),
        )
        .map_err(|e| format!("stage Welcome: {e}"))?
        .into_group(&self.provider)
        .map_err(|e| format!("join MLS group: {e}"))?;
        Ok(DirectConversation {
            provider: self.provider,
            signer: self.signer,
            group,
        })
    }
}

impl DirectConversation {
    /// Serializes the complete OpenMLS provider/group state for encrypted client storage.
    pub fn snapshot(&self) -> Result<Vec<u8>, String> {
        let group_id = self.group.group_id().as_slice();
        let signer = self.signer.to_public_vec();
        let values = self
            .provider
            .storage
            .values
            .read()
            .map_err(|_| "MLS storage lock poisoned")?;
        let mut output = Vec::with_capacity(32 + values.len() * 32);
        output.extend_from_slice(b"TCMLS1");
        write_blob(&mut output, signer.as_slice());
        write_blob(&mut output, group_id);
        output.extend_from_slice(&(values.len() as u32).to_be_bytes());
        for (key, value) in values.iter() {
            write_blob(&mut output, key);
            write_blob(&mut output, value);
        }
        Ok(output)
    }

    pub fn restore(snapshot: &[u8]) -> Result<Self, String> {
        let mut input = snapshot;
        if take(&mut input, 6)? != b"TCMLS1" {
            return Err("invalid MLS snapshot header".into());
        }
        let signer_public = take_blob(&mut input)?;
        let group_id = take_blob(&mut input)?;
        let count_bytes = take(&mut input, 4)?;
        let count = u32::from_be_bytes(
            count_bytes
                .try_into()
                .map_err(|_| "invalid MLS snapshot count")?,
        ) as usize;
        let provider = PersistentProvider::default();
        {
            let mut values = provider
                .storage
                .values
                .write()
                .map_err(|_| "MLS storage lock poisoned")?;
            for _ in 0..count {
                values.insert(take_blob(&mut input)?, take_blob(&mut input)?);
            }
        }
        let signer = SignatureKeyPair::read(
            &provider.storage,
            &signer_public,
            SUITE.signature_algorithm(),
        )
        .ok_or_else(|| "MLS signer missing from snapshot".to_string())?;
        let group = MlsGroup::load(
            &provider.storage,
            &openmls::group::GroupId::from_slice(&group_id),
        )
        .map_err(|e| format!("load MLS group: {e}"))?
        .ok_or_else(|| "MLS group missing from snapshot".to_string())?;
        Ok(Self {
            provider,
            signer,
            group,
        })
    }

    pub fn invite(&mut self, key_package: &[u8]) -> Result<(Vec<u8>, Vec<u8>), String> {
        let mut input = key_package;
        let package = openmls::prelude::KeyPackageIn::tls_deserialize(&mut input)
            .map_err(|e| format!("decode KeyPackage: {e}"))?;
        let package = package
            .validate(
                self.provider.crypto(),
                openmls::prelude::ProtocolVersion::Mls10,
            )
            .map_err(|e| format!("validate KeyPackage: {e}"))?;
        let (_, welcome, _) = self
            .group
            .add_members(&self.provider, &self.signer, &[package])
            .map_err(|e| format!("add MLS member: {e}"))?;
        self.group
            .merge_pending_commit(&self.provider)
            .map_err(|e| format!("merge MLS commit: {e}"))?;
        let welcome = welcome
            .tls_serialize_detached()
            .map_err(|e| format!("serialize Welcome: {e}"))?;
        let tree = self
            .group
            .export_ratchet_tree()
            .tls_serialize_detached()
            .map_err(|e| format!("serialize ratchet tree: {e}"))?;
        Ok((welcome, tree))
    }

    pub fn encrypt(&mut self, plaintext: &[u8]) -> Result<Vec<u8>, String> {
        self.group
            .create_message(&self.provider, &self.signer, plaintext)
            .map_err(|e| format!("encrypt MLS message: {e}"))?
            .tls_serialize_detached()
            .map_err(|e| format!("serialize MLS message: {e}"))
    }

    pub fn decrypt(&mut self, message: &[u8]) -> Result<Vec<u8>, String> {
        let mut input = message;
        let incoming = MlsMessageIn::tls_deserialize(&mut input)
            .map_err(|e| format!("decode MLS message: {e}"))?
            .try_into_protocol_message()
            .map_err(|e| format!("not a protocol message: {e}"))?;
        let processed = self
            .group
            .process_message(&self.provider, incoming)
            .map_err(|e| format!("decrypt MLS message: {e}"))?;
        match processed.into_content() {
            ProcessedMessageContent::ApplicationMessage(message) => Ok(message.into_bytes()),
            _ => Err("MLS message is not an application message".into()),
        }
    }
}

fn write_blob(output: &mut Vec<u8>, value: &[u8]) {
    output.extend_from_slice(&(value.len() as u32).to_be_bytes());
    output.extend_from_slice(value);
}

fn take<'a>(input: &mut &'a [u8], length: usize) -> Result<&'a [u8], String> {
    if input.len() < length {
        return Err("truncated MLS snapshot".into());
    }
    let (head, tail) = input.split_at(length);
    *input = tail;
    Ok(head)
}

fn take_blob(input: &mut &[u8]) -> Result<Vec<u8>, String> {
    let length = u32::from_be_bytes(
        take(input, 4)?
            .try_into()
            .map_err(|_| "invalid MLS blob length")?,
    ) as usize;
    Ok(take(input, length)?.to_vec())
}

pub fn validate_mls_message(bytes: &[u8]) -> Result<(), String> {
    let mut input = bytes;
    MlsMessageIn::tls_deserialize(&mut input)
        .map(|_| ())
        .map_err(|error| format!("invalid MLS message: {error}"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use openmls::prelude::tls_codec::{Deserialize as TlsDeserialize, Serialize as TlsSerialize};
    use openmls::{
        credentials::{BasicCredential, CredentialWithKey},
        framing::{MlsMessageBodyIn, MlsMessageIn, ProcessedMessageContent},
        group::{MlsGroup, MlsGroupCreateConfig, MlsGroupJoinConfig, StagedWelcome},
        prelude::{Ciphersuite, KeyPackage},
    };
    use openmls_basic_credential::SignatureKeyPair;
    use openmls_rust_crypto::OpenMlsRustCrypto;
    use openmls_traits::OpenMlsProvider;

    #[test]
    fn malformed_input_is_rejected_by_openmls() {
        assert!(validate_mls_message(b"not-an-mls-message").is_err());
    }

    #[test]
    fn two_member_group_encrypts_and_decrypts_text() {
        let suite = Ciphersuite::MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519;
        let alice_provider = OpenMlsRustCrypto::default();
        let bob_provider = OpenMlsRustCrypto::default();
        let alice_signer = SignatureKeyPair::new(suite.signature_algorithm()).unwrap();
        let bob_signer = SignatureKeyPair::new(suite.signature_algorithm()).unwrap();
        alice_signer.store(alice_provider.storage()).unwrap();
        bob_signer.store(bob_provider.storage()).unwrap();
        let alice_credential = CredentialWithKey {
            credential: BasicCredential::new(b"alice".to_vec()).into(),
            signature_key: alice_signer.to_public_vec().into(),
        };
        let bob_credential = CredentialWithKey {
            credential: BasicCredential::new(b"bob".to_vec()).into(),
            signature_key: bob_signer.to_public_vec().into(),
        };
        let bob_key_package = KeyPackage::builder()
            .build(suite, &bob_provider, &bob_signer, bob_credential)
            .unwrap();
        let mut alice = MlsGroup::new(
            &alice_provider,
            &alice_signer,
            &MlsGroupCreateConfig::builder().ciphersuite(suite).build(),
            alice_credential,
        )
        .unwrap();
        let (_, welcome, _) = alice
            .add_members(
                &alice_provider,
                &alice_signer,
                &[bob_key_package.key_package().clone()],
            )
            .unwrap();
        alice.merge_pending_commit(&alice_provider).unwrap();
        let welcome_bytes = welcome.tls_serialize_detached().unwrap();
        let welcome_message = MlsMessageIn::tls_deserialize(&mut welcome_bytes.as_slice()).unwrap();
        let welcome = match welcome_message.extract() {
            MlsMessageBodyIn::Welcome(welcome) => welcome,
            _ => panic!("expected welcome message"),
        };
        let mut bob = StagedWelcome::new_from_welcome(
            &bob_provider,
            &MlsGroupJoinConfig::default(),
            welcome,
            Some(alice.export_ratchet_tree().into()),
        )
        .unwrap()
        .into_group(&bob_provider)
        .unwrap();
        let message = alice
            .create_message(&alice_provider, &alice_signer, b"hello from alice")
            .unwrap();
        let serialized = message.tls_serialize_detached().unwrap();
        let incoming = MlsMessageIn::tls_deserialize(&mut serialized.as_slice()).unwrap();
        let processed = bob
            .process_message(&bob_provider, incoming.try_into_protocol_message().unwrap())
            .unwrap();
        let ProcessedMessageContent::ApplicationMessage(message) = processed.into_content() else {
            panic!("expected application message")
        };
        assert_eq!(message.into_bytes(), b"hello from alice");
    }

    #[test]
    fn public_direct_conversation_api_round_trips_messages() {
        let alice = MlsMember::create(b"alice").unwrap();
        let bob = MlsMember::create(b"bob").unwrap();
        let bob_key_package = bob.key_package().unwrap();
        let mut alice_chat = alice.create_conversation().unwrap();
        let (welcome, tree) = alice_chat.invite(&bob_key_package).unwrap();
        let mut bob_chat = bob.accept_conversation(&welcome, &tree).unwrap();

        let outbound = alice_chat.encrypt(b"hello bob").unwrap();
        assert_eq!(bob_chat.decrypt(&outbound).unwrap(), b"hello bob");
        let reply = bob_chat.encrypt(b"hello alice").unwrap();
        assert_eq!(alice_chat.decrypt(&reply).unwrap(), b"hello alice");
    }

    #[test]
    fn direct_conversation_snapshot_restores_state() {
        let alice = MlsMember::create(b"alice").unwrap();
        let bob = MlsMember::create(b"bob").unwrap();
        let mut alice_chat = alice.create_conversation().unwrap();
        let (welcome, tree) = alice_chat.invite(&bob.key_package().unwrap()).unwrap();
        let bob_chat = bob.accept_conversation(&welcome, &tree).unwrap();
        let snapshot = bob_chat.snapshot().unwrap();
        let mut restored = DirectConversation::restore(&snapshot).unwrap();
        let outbound = alice_chat.encrypt(b"after restart").unwrap();
        assert_eq!(restored.decrypt(&outbound).unwrap(), b"after restart");
    }

    #[test]
    fn member_snapshot_preserves_pending_key_package() {
        let alice = MlsMember::create(b"alice").unwrap();
        let bob = MlsMember::create(b"bob").unwrap();
        let bob_key_package = bob.key_package().unwrap();
        let snapshot = bob.snapshot().unwrap();
        let restored_bob = MlsMember::restore(&snapshot, b"bob").unwrap();
        let mut alice_chat = alice.create_conversation().unwrap();
        let (welcome, tree) = alice_chat.invite(&bob_key_package).unwrap();
        let mut bob_chat = restored_bob.accept_conversation(&welcome, &tree).unwrap();
        let encrypted = alice_chat.encrypt(b"persisted invitation").unwrap();
        assert_eq!(
            bob_chat.decrypt(&encrypted).unwrap(),
            b"persisted invitation"
        );
    }
}
