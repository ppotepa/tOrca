use anyhow::{Context, Result};
use chacha20poly1305::{
    XChaCha20Poly1305, XNonce,
    aead::{Aead, KeyInit},
};
use rand::RngCore;
use rusqlite::{Connection, OptionalExtension, params};
use sha2::{Digest, Sha256};
use std::path::Path;
use torchat_core::{Identity, relay::ContactCard};

#[derive(Clone, Debug)]
pub struct StoredMessage {
    pub id: String,
    pub peer: String,
    pub outgoing: bool,
    pub body: String,
    pub state: String,
    pub created_at: i64,
    pub relay_payload: Option<String>,
}

pub struct LocalStore {
    connection: Connection,
    cipher: XChaCha20Poly1305,
}

impl LocalStore {
    pub fn open(path: &Path, identity: &Identity) -> Result<Self> {
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent).context("create desktop state directory")?;
        }
        let connection = Connection::open(path).context("open desktop state database")?;
        connection.execute_batch(
            "
            PRAGMA journal_mode=WAL;
            PRAGMA foreign_keys=ON;
            CREATE TABLE IF NOT EXISTS contacts (
                installation_id TEXT PRIMARY KEY,
                public_key TEXT NOT NULL,
                fingerprint TEXT NOT NULL,
                nickname TEXT NOT NULL,
                source TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS conversations (
                peer TEXT PRIMARY KEY,
                mls_state BLOB NOT NULL,
                unread_count INTEGER NOT NULL DEFAULT 0,
                updated_at INTEGER NOT NULL
            );
            CREATE TABLE IF NOT EXISTS messages (
                id TEXT PRIMARY KEY,
                peer TEXT NOT NULL,
                outgoing INTEGER NOT NULL,
                body BLOB NOT NULL,
                state TEXT NOT NULL,
                created_at INTEGER NOT NULL
            );
            CREATE INDEX IF NOT EXISTS messages_peer_time
                ON messages(peer, created_at);
            CREATE TABLE IF NOT EXISTS settings (
                key TEXT PRIMARY KEY,
                value BLOB NOT NULL
            );
            CREATE TABLE IF NOT EXISTS used_invites (
                invite_id TEXT PRIMARY KEY,
                used_at INTEGER NOT NULL
            );
            ",
        )?;
        let _ = connection.execute("ALTER TABLE messages ADD COLUMN relay_payload BLOB", []);
        let mut hash = Sha256::new();
        hash.update(b"torchat-desktop-local-store-v1");
        hash.update(identity.private_key_bytes());
        Ok(Self {
            connection,
            cipher: XChaCha20Poly1305::new((&hash.finalize()).into()),
        })
    }

    pub fn put_contact(&self, card: &ContactCard, source: &str) -> Result<()> {
        card.validate().map_err(anyhow::Error::msg)?;
        self.connection.execute(
            "INSERT OR REPLACE INTO contacts
             (installation_id, public_key, fingerprint, nickname, source)
             VALUES (?1, ?2, ?3, ?4, ?5)",
            params![
                card.installation_id,
                card.public_key,
                card.fingerprint,
                card.nickname,
                source
            ],
        )?;
        Ok(())
    }

    pub fn contacts(&self) -> Result<Vec<ContactCard>> {
        let mut statement = self.connection.prepare(
            "SELECT installation_id, public_key, fingerprint, nickname
             FROM contacts ORDER BY nickname COLLATE NOCASE",
        )?;
        let values = statement
            .query_map([], |row| {
                Ok(ContactCard {
                    installation_id: row.get(0)?,
                    public_key: row.get(1)?,
                    fingerprint: row.get(2)?,
                    nickname: row.get(3)?,
                })
            })?
            .collect::<rusqlite::Result<Vec<_>>>()?;
        Ok(values)
    }

    pub fn put_conversation(&self, peer: &str, snapshot: &[u8], unread_count: u32) -> Result<()> {
        let encrypted = self.encrypt(snapshot)?;
        self.connection.execute(
            "INSERT OR REPLACE INTO conversations
             (peer, mls_state, unread_count, updated_at)
             VALUES (?1, ?2, ?3, unixepoch('subsec') * 1000)",
            params![peer, encrypted, unread_count],
        )?;
        Ok(())
    }

    pub fn conversation(&self, peer: &str) -> Result<Option<Vec<u8>>> {
        let encrypted: Option<Vec<u8>> = self
            .connection
            .query_row(
                "SELECT mls_state FROM conversations WHERE peer = ?1",
                [peer],
                |row| row.get(0),
            )
            .optional()?;
        encrypted.map(|value| self.decrypt(&value)).transpose()
    }

    pub fn conversation_peers(&self) -> Result<Vec<String>> {
        let mut statement = self
            .connection
            .prepare("SELECT peer FROM conversations ORDER BY updated_at DESC")?;
        Ok(statement
            .query_map([], |row| row.get(0))?
            .collect::<rusqlite::Result<Vec<_>>>()?)
    }

    pub fn put_secret(&self, key: &str, value: &[u8]) -> Result<()> {
        self.connection.execute(
            "INSERT OR REPLACE INTO settings (key, value) VALUES (?1, ?2)",
            params![key, self.encrypt(value)?],
        )?;
        Ok(())
    }

    pub fn secret(&self, key: &str) -> Result<Option<Vec<u8>>> {
        let value: Option<Vec<u8>> = self
            .connection
            .query_row("SELECT value FROM settings WHERE key = ?1", [key], |row| {
                row.get(0)
            })
            .optional()?;
        value.map(|value| self.decrypt(&value)).transpose()
    }

    pub fn put_message(&self, message: &StoredMessage) -> Result<()> {
        self.connection.execute(
            "INSERT OR REPLACE INTO messages
             (id, peer, outgoing, body, state, created_at, relay_payload)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
            params![
                message.id,
                message.peer,
                message.outgoing,
                self.encrypt(message.body.as_bytes())?,
                message.state,
                message.created_at,
                message
                    .relay_payload
                    .as_ref()
                    .map(|value| self.encrypt(value.as_bytes()))
                    .transpose()?,
            ],
        )?;
        Ok(())
    }

    pub fn set_message_state(&self, id: &str, state: &str) -> Result<()> {
        self.connection.execute(
            "UPDATE messages SET state = ?1 WHERE id = ?2",
            params![state, id],
        )?;
        Ok(())
    }

    pub fn consume_invite(&self, invite_id: &str) -> Result<bool> {
        let exists: Option<String> = self
            .connection
            .query_row(
                "SELECT invite_id FROM used_invites WHERE invite_id = ?1",
                [invite_id],
                |row| row.get(0),
            )
            .optional()?;
        if exists.is_some() {
            return Ok(false);
        }
        self.connection.execute(
            "INSERT OR IGNORE INTO used_invites (invite_id, used_at) VALUES (?1, unixepoch())",
            [invite_id],
        )?;
        Ok(true)
    }

    pub fn messages(&self, peer: &str) -> Result<Vec<StoredMessage>> {
        let mut statement = self.connection.prepare(
            "SELECT id, peer, outgoing, body, state, created_at, relay_payload
             FROM messages WHERE peer = ?1 ORDER BY created_at",
        )?;
        let rows = statement.query_map([peer], |row| {
            Ok((
                row.get::<_, String>(0)?,
                row.get::<_, String>(1)?,
                row.get::<_, bool>(2)?,
                row.get::<_, Vec<u8>>(3)?,
                row.get::<_, String>(4)?,
                row.get::<_, i64>(5)?,
                row.get::<_, Option<Vec<u8>>>(6)?,
            ))
        })?;
        rows.map(|row| {
            let (id, peer, outgoing, body, state, created_at, relay_payload) = row?;
            Ok(StoredMessage {
                id,
                peer,
                outgoing,
                body: String::from_utf8(self.decrypt(&body)?).context("message is not UTF-8")?,
                state,
                created_at,
                relay_payload: relay_payload
                    .map(|value| self.decrypt(&value))
                    .transpose()?
                    .map(|value| String::from_utf8(value).context("relay payload is not UTF-8"))
                    .transpose()?,
            })
        })
        .collect()
    }

    /// Returns outgoing messages which still need a relay attempt. `sending`
    /// is included so a process/reconnect interruption can resume the queue.
    pub fn pending_outgoing(&self) -> Result<Vec<StoredMessage>> {
        let mut statement = self.connection.prepare(
            "SELECT id, peer, outgoing, body, state, created_at, relay_payload
             FROM messages
             WHERE outgoing = 1 AND state IN ('pending', 'sending')
             ORDER BY created_at",
        )?;
        let rows = statement.query_map([], |row| {
            Ok((
                row.get::<_, String>(0)?,
                row.get::<_, String>(1)?,
                row.get::<_, bool>(2)?,
                row.get::<_, Vec<u8>>(3)?,
                row.get::<_, String>(4)?,
                row.get::<_, i64>(5)?,
                row.get::<_, Option<Vec<u8>>>(6)?,
            ))
        })?;
        rows.map(|row| {
            let (id, peer, outgoing, body, state, created_at, relay_payload) = row?;
            Ok(StoredMessage {
                id,
                peer,
                outgoing,
                body: String::from_utf8(self.decrypt(&body)?).context("message is not UTF-8")?,
                state,
                created_at,
                relay_payload: relay_payload
                    .map(|value| self.decrypt(&value))
                    .transpose()?
                    .map(|value| String::from_utf8(value).context("relay payload is not UTF-8"))
                    .transpose()?,
            })
        })
        .collect()
    }

    fn encrypt(&self, plaintext: &[u8]) -> Result<Vec<u8>> {
        let mut nonce = [0_u8; 24];
        rand::rng().fill_bytes(&mut nonce);
        let ciphertext = self
            .cipher
            .encrypt(XNonce::from_slice(&nonce), plaintext)
            .map_err(|_| anyhow::anyhow!("encrypt local state"))?;
        Ok([nonce.as_slice(), ciphertext.as_slice()].concat())
    }

    fn decrypt(&self, ciphertext: &[u8]) -> Result<Vec<u8>> {
        if ciphertext.len() < 24 {
            anyhow::bail!("truncated encrypted local state")
        }
        self.cipher
            .decrypt(XNonce::from_slice(&ciphertext[..24]), &ciphertext[24..])
            .map_err(|_| anyhow::anyhow!("decrypt local state"))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn encrypted_state_round_trip() {
        let path = std::env::temp_dir().join(format!("torchat-store-{}.db", uuid::Uuid::new_v4()));
        let identity = Identity::generate();
        let store = LocalStore::open(&path, &identity).unwrap();
        store
            .put_message(&StoredMessage {
                id: "one".into(),
                peer: "bob".into(),
                outgoing: true,
                body: "sekret".into(),
                state: "sent".into(),
                created_at: 1,
                relay_payload: None,
            })
            .unwrap();
        assert_eq!(store.messages("bob").unwrap()[0].body, "sekret");
        drop(store);
        let bytes = std::fs::read(&path).unwrap();
        assert!(!bytes.windows(6).any(|part| part == b"sekret"));
        let _ = std::fs::remove_file(path);
    }
}
