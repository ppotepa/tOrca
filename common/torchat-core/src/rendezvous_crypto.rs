use chacha20poly1305::{
    ChaCha20Poly1305, Key, Nonce,
    aead::{Aead, KeyInit},
};
use hkdf::Hkdf;
use rand_core::{OsRng, RngCore};
use sha2::Sha256;
use x25519_dalek::{PublicKey, StaticSecret};

const NONCE_BYTES: usize = 12;
const KEY_BYTES: usize = 32;

pub fn public_key(private_key: [u8; 32]) -> [u8; 32] {
    PublicKey::from(&StaticSecret::from(private_key)).to_bytes()
}

pub fn seal(
    private_key: [u8; 32],
    recipient_public_key: [u8; 32],
    plaintext: &[u8],
) -> Result<Vec<u8>, String> {
    let shared =
        StaticSecret::from(private_key).diffie_hellman(&PublicKey::from(recipient_public_key));
    let mut key = [0_u8; KEY_BYTES];
    Hkdf::<Sha256>::new(None, shared.as_bytes())
        .expand(b"torchat rendezvous blob v1", &mut key)
        .map_err(|_| "rendezvous key derivation failed")?;
    let cipher = ChaCha20Poly1305::new(Key::from_slice(&key));
    let mut nonce = [0_u8; NONCE_BYTES];
    OsRng.fill_bytes(&mut nonce);
    let ciphertext = cipher
        .encrypt(Nonce::from_slice(&nonce), plaintext)
        .map_err(|_| "rendezvous encryption failed")?;
    let mut output = nonce.to_vec();
    output.extend_from_slice(&ciphertext);
    Ok(output)
}

pub fn open(
    private_key: [u8; 32],
    sender_public_key: [u8; 32],
    blob: &[u8],
) -> Result<Vec<u8>, String> {
    if blob.len() < NONCE_BYTES {
        return Err("rendezvous blob is truncated".into());
    }
    let shared =
        StaticSecret::from(private_key).diffie_hellman(&PublicKey::from(sender_public_key));
    let mut key = [0_u8; KEY_BYTES];
    Hkdf::<Sha256>::new(None, shared.as_bytes())
        .expand(b"torchat rendezvous blob v1", &mut key)
        .map_err(|_| "rendezvous key derivation failed")?;
    ChaCha20Poly1305::new(Key::from_slice(&key))
        .decrypt(
            Nonce::from_slice(&blob[..NONCE_BYTES]),
            &blob[NONCE_BYTES..],
        )
        .map_err(|_| "rendezvous authentication failed".into())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sealed_blob_round_trips_and_rejects_tampering() {
        let owner = [7_u8; 32];
        let joiner = [9_u8; 32];
        let blob = seal(joiner, public_key(owner), b"opaque pairing offer").unwrap();
        assert_eq!(
            open(owner, public_key(joiner), &blob).unwrap(),
            b"opaque pairing offer"
        );
        let mut tampered = blob.clone();
        *tampered.last_mut().unwrap() ^= 1;
        assert!(open(owner, public_key(joiner), &tampered).is_err());
    }
}
