use serde::{Deserialize, Serialize, de::DeserializeOwned};

use crate::{ClientEngine, EngineCommand, EngineResult};
use torchat_runtime::{
    ChatMessage, ContactRecord, ConversationSummary, PairingItem, RuntimeSendEffect,
};

#[derive(Clone, Debug, Default, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PairingList {
    pub inbox: Vec<PairingItem>,
    pub outbox: Vec<PairingItem>,
}

impl ClientEngine {
    pub async fn list_pairings(&self) -> EngineResult<PairingList> {
        self.request_json(EngineCommand::ListPairings).await
    }

    pub async fn list_contacts(&self) -> EngineResult<Vec<ContactRecord>> {
        self.request_json(EngineCommand::ListContacts).await
    }

    pub async fn list_conversations(&self) -> EngineResult<Vec<ConversationSummary>> {
        self.request_json(EngineCommand::ListConversations).await
    }

    pub async fn list_messages(
        &self,
        conversation_id: impl Into<String>,
    ) -> EngineResult<Vec<ChatMessage>> {
        self.request_json(EngineCommand::ListMessages {
            conversation_id: conversation_id.into(),
        })
        .await
    }

    async fn request_json<T: DeserializeOwned>(&self, command: EngineCommand) -> EngineResult<T> {
        let result = self.submit_and_wait(command).await?;
        Self::decode_json(result)
    }

    async fn request_mutation_json<T: DeserializeOwned>(
        &self,
        command: EngineCommand,
        command_id: impl Into<String>,
    ) -> EngineResult<T> {
        let result = self
            .submit_mutation_and_wait(command, command_id.into())
            .await?;
        Self::decode_json(result)
    }

    fn decode_json<T: DeserializeOwned>(result: crate::ResponseResult) -> EngineResult<T> {
        let value = match result {
            crate::ResponseResult::Ok {
                payload: crate::ResponsePayload::Json { value },
            } => value,
            crate::ResponseResult::Ok { .. } => {
                return Err(crate::EngineError::InvalidCommand(
                    "engine returned an empty response for a typed query".to_owned(),
                ));
            }
            crate::ResponseResult::Error { code, message, .. } => {
                return Err(crate::EngineError::InvalidCommand(format!(
                    "{code}: {message}"
                )));
            }
        };
        serde_json::from_value(value).map_err(|error| {
            crate::EngineError::InvalidCommand(format!("invalid typed engine response: {error}"))
        })
    }
}

impl ClientEngine {
    pub async fn accept_pairing(
        &self,
        command_id: impl Into<String>,
        pairing_id: impl Into<String>,
    ) -> EngineResult<()> {
        self.submit_mutation_and_wait(
            EngineCommand::AcceptPairing {
                pairing_id: pairing_id.into(),
            },
            command_id.into(),
        )
        .await
        .map(|_| ())
    }

    pub async fn reject_pairing(
        &self,
        command_id: impl Into<String>,
        pairing_id: impl Into<String>,
    ) -> EngineResult<()> {
        self.submit_mutation_and_wait(
            EngineCommand::RejectPairing {
                pairing_id: pairing_id.into(),
            },
            command_id.into(),
        )
        .await
        .map(|_| ())
    }

    pub async fn send_message(
        &self,
        command_id: impl Into<String>,
        conversation_id: impl Into<String>,
        body: impl Into<String>,
        reply_to_message_id: Option<String>,
    ) -> EngineResult<RuntimeSendEffect> {
        self.request_mutation_json(
            EngineCommand::SendMessage {
                conversation_id: conversation_id.into(),
                body: body.into(),
                reply_to_message_id,
            },
            command_id,
        )
        .await
    }

    pub async fn mark_conversation_read(
        &self,
        command_id: impl Into<String>,
        conversation_id: impl Into<String>,
    ) -> EngineResult<()> {
        self.submit_mutation_and_wait(
            EngineCommand::SendReadReceipts {
                conversation_id: conversation_id.into(),
            },
            command_id.into(),
        )
        .await
        .map(|_| ())
    }
}
