use anyhow::{Context, Result};
use crate::sql;
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

fn migrate(connection: &Connection) -> Result<()> {
    let (_, migration_table) = sql::MIGRATIONS
        .first()
        .context("desktop migration list is empty")?;
    connection.execute_batch(migration_table)?;
    for (name, migration) in sql::MIGRATIONS.iter().skip(1) {
        let checksum = format!("{:x}", Sha256::digest(migration.as_bytes()));
        let applied: Option<String> = connection
            .query_row(sql::MIGRATION_LOOKUP, [name], |row| row.get(0))
            .optional()?;
        if let Some(applied) = applied {
            anyhow::ensure!(
                applied == checksum,
                "desktop migration checksum changed: {name}"
            );
            continue;
        }

        // Versions 002 and 003 were previously applied ad hoc by the store.
        // Inspect the schema before executing them so existing installations
        // are upgraded without hiding unrelated migration errors.
        let already_present = match *name {
            "002_messages_relay_payload.sql" => has_column(connection, "messages", "relay_payload")?,
            "003_contacts_verification.sql" => has_column(connection, "contacts", "verification")?,
            _ => false,
        };
        if !already_present {
            connection.execute_batch(migration)?;
        }
        connection.execute(sql::MIGRATION_INSERT, params![name, checksum])?;
    }
    Ok(())
}

fn has_column(connection: &Connection, table: &str, column: &str) -> Result<bool> {
    let mut statement = connection.prepare(sql::TABLE_COLUMNS)?;
    let columns = statement.query_map([table], |row| row.get::<_, String>(0))?;
    Ok(columns.collect::<rusqlite::Result<Vec<_>>>()?.iter().any(|value| value == column))
}

impl LocalStore {
    pub fn open(path: &Path, identity: &Identity) -> Result<Self> {
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent).context("create desktop state directory")?;
        }
        let connection = Connection::open(path).context("open desktop state database")?;
        migrate(&connection)?;
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
            sql::CONTACT_UPSERT,
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
        let mut statement = self.connection.prepare(sql::CONTACTS_LIST)?;
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

    pub fn verify_contact(&self, installation_id: &str) -> Result<()> {
        self.connection.execute(sql::CONTACT_VERIFY, [installation_id])?;
        Ok(())
    }

    pub fn contact_is_verified(&self, installation_id: &str) -> Result<bool> {
        let value: Option<String> = self
            .connection
            .query_row(sql::CONTACT_VERIFICATION, [installation_id], |row| row.get(0))
            .optional()?;
        Ok(value.as_deref() == Some("VERIFIED"))
    }

    pub fn put_conversation(&self, peer: &str, snapshot: &[u8], unread_count: u32) -> Result<()> {
        let encrypted = self.encrypt(snapshot)?;
        self.connection.execute(
            sql::CONVERSATION_UPSERT,
            params![peer, encrypted, unread_count],
        )?;
        Ok(())
    }

    pub fn conversation(&self, peer: &str) -> Result<Option<Vec<u8>>> {
        let encrypted: Option<Vec<u8>> = self
            .connection
            .query_row(sql::CONVERSATION_GET, [peer], |row| row.get(0))
            .optional()?;
        encrypted.map(|value| self.decrypt(&value)).transpose()
    }

    pub fn conversation_peers(&self) -> Result<Vec<String>> {
        let mut statement = self.connection.prepare(sql::CONVERSATIONS_LIST)?;
        Ok(statement
            .query_map([], |row| row.get(0))?
            .collect::<rusqlite::Result<Vec<_>>>()?)
    }

    pub fn put_secret(&self, key: &str, value: &[u8]) -> Result<()> {
        self.connection.execute(
            sql::SETTING_UPSERT,
            params![key, self.encrypt(value)?],
        )?;
        Ok(())
    }

    pub fn secret(&self, key: &str) -> Result<Option<Vec<u8>>> {
        let value: Option<Vec<u8>> = self
            .connection
            .query_row(sql::SETTING_GET, [key], |row| row.get(0))
            .optional()?;
        value.map(|value| self.decrypt(&value)).transpose()
    }

    pub fn put_message(&self, message: &StoredMessage) -> Result<()> {
        self.connection.execute(
            sql::MESSAGE_UPSERT,
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
        self.connection
            .execute(sql::MESSAGE_STATE_UPDATE, params![state, id])?;
        Ok(())
    }

    pub fn consume_invite(&self, invite_id: &str) -> Result<bool> {
        let exists: Option<String> = self
            .connection
            .query_row(sql::INVITE_LOOKUP, [invite_id], |row| row.get(0))
            .optional()?;
        if exists.is_some() {
            return Ok(false);
        }
        self.connection.execute(sql::INVITE_INSERT, [invite_id])?;
        Ok(true)
    }

    pub fn messages(&self, peer: &str) -> Result<Vec<StoredMessage>> {
        let mut statement = self.connection.prepare(sql::MESSAGES_LIST)?;
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
        let mut statement = self.connection.prepare(sql::MESSAGES_PENDING)?;
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
