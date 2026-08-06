use super::*;

impl ClientEngineActor {
    pub(crate) fn handle_command(
        &mut self,
        command: EngineCommand,
        idempotency: Option<&IdempotencyCommitContext>,
    ) -> crate::actor::commands::CommandHandlerResult {
        match command {
            EngineCommand::Bootstrap => self.command_bootstrap(idempotency),
            EngineCommand::Connect => self.command_connect(),
            EngineCommand::GetIdentity => self.command_get_identity(),
            EngineCommand::GetProfile => self.command_get_profile(),
            EngineCommand::GetStartupReadiness => self.command_get_startup_readiness(),
            EngineCommand::GetApplicationSnapshot => self.command_get_application_snapshot(),
            EngineCommand::ListPairings => self.command_list_pairings(),
            EngineCommand::PairingInbox => self.command_pairing_inbox(),
            EngineCommand::PairingOutbox => self.command_pairing_outbox(),
            EngineCommand::ListContacts => self.command_list_contacts(),
            EngineCommand::ListConversations => self.command_list_conversations(),
            EngineCommand::ListMessages { conversation_id } => {
                self.command_list_messages(conversation_id)
            }
            EngineCommand::GetPeerEndpoint => self.command_get_peer_endpoint(),
            EngineCommand::RetryPeerConnection { installation_id } => {
                self.command_retry_peer_connection(installation_id)
            }
            EngineCommand::RotatePeerEndpoint => self.command_rotate_peer_endpoint(),
            EngineCommand::GetContactEndpointCapability { installation_id } => {
                self.command_get_contact_endpoint_capability(installation_id)
            }
            EngineCommand::RotateContactEndpointCapability { installation_id } => {
                self.command_rotate_contact_endpoint_capability(installation_id)
            }
            EngineCommand::RevokeContactEndpointCapability { installation_id } => {
                self.command_revoke_contact_endpoint_capability(installation_id)
            }
            EngineCommand::SetNickname { nickname } => {
                self.command_set_nickname(idempotency, nickname)
            }
            EngineCommand::AcceptPairing { pairing_id } => {
                self.command_accept_pairing(idempotency, pairing_id)
            }
            EngineCommand::RejectPairing { pairing_id } => {
                self.command_reject_pairing(idempotency, pairing_id)
            }
            EngineCommand::ArchivePairing { pairing_id } => {
                self.command_archive_pairing(idempotency, pairing_id)
            }
            EngineCommand::VerifyContact { installation_id } => {
                self.command_verify_contact(idempotency, installation_id)
            }
            EngineCommand::UpdateContactSettings {
                installation_id,
                local_alias,
                muted,
                blocked,
                transport_policy,
            } => self.command_update_contact_settings(
                idempotency,
                installation_id,
                local_alias,
                muted,
                blocked,
                transport_policy,
            ),
            EngineCommand::RequestRelationshipRemoval {
                installation_id,
                preserve_history,
            } => self.command_request_relationship_removal(
                idempotency,
                installation_id,
                preserve_history,
            ),
            EngineCommand::StartConversation { contact_id } => {
                self.command_start_conversation(idempotency, contact_id)
            }
            EngineCommand::OpenConversation { conversation_id } => {
                self.command_open_conversation(idempotency, conversation_id)
            }
            EngineCommand::CloseConversation => self.command_close_conversation(idempotency),
            EngineCommand::SendMessage {
                conversation_id,
                body,
                reply_to_message_id,
            } => self.command_send_message(idempotency, conversation_id, body, reply_to_message_id),
            EngineCommand::RetryMessage { message_id } => {
                self.command_retry_message(idempotency, message_id)
            }
            EngineCommand::RetryDeadLetter { kind, id } => self.command_retry_dead_letter(kind, id),
            EngineCommand::ListDeadLetters => self.command_list_dead_letters(),
            EngineCommand::DeleteMessageLocal { message_id } => {
                self.command_delete_message_local(idempotency, message_id)
            }
            EngineCommand::SetTyping {
                conversation_id,
                typing,
            } => self.command_set_typing(conversation_id, typing),
            EngineCommand::SetConversationFocus {
                conversation_id,
                focused,
            } => self.command_set_conversation_focus(conversation_id, focused),
            EngineCommand::SetPresence { online } => self.command_set_presence(online),
            EngineCommand::SendReadReceipts { conversation_id } => {
                self.command_send_read_receipts(conversation_id)
            }
            EngineCommand::Shutdown => self.command_shutdown(),
            EngineCommand::RefreshPairingCode
            | EngineCommand::SubmitPairingCode { .. }
            | EngineCommand::CancelPairing { .. } => Err(EngineError::InvalidCommand(
                "deferred relay command reached the synchronous command router".to_owned(),
            )),
            EngineCommand::PlatformFact { .. } => Err(EngineError::InvalidCommand(
                "platform fact reached the command router instead of unified input dispatch"
                    .to_owned(),
            )),
        }
    }
}
