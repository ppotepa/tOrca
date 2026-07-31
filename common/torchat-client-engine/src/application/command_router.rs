use crate::EngineCommand;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum CommandFamily {
    Bootstrap,
    Profile,
    Contacts,
    Pairing,
    Conversations,
    Messages,
    Peer,
    Ephemeral,
    Lifecycle,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct CommandRoute {
    pub family: CommandFamily,
    pub mutating: bool,
    pub durable: bool,
}

pub struct CommandRouter;

impl CommandRouter {
    pub const fn route(command: &EngineCommand) -> CommandRoute {
        match command {
            EngineCommand::Bootstrap | EngineCommand::Connect | EngineCommand::Shutdown => {
                CommandRoute {
                    family: CommandFamily::Bootstrap,
                    mutating: true,
                    durable: false,
                }
            }
            EngineCommand::GetIdentity | EngineCommand::GetProfile => CommandRoute {
                family: CommandFamily::Profile,
                mutating: false,
                durable: false,
            },
            EngineCommand::SetNickname { .. } => CommandRoute {
                family: CommandFamily::Profile,
                mutating: true,
                durable: true,
            },
            EngineCommand::ListContacts => CommandRoute {
                family: CommandFamily::Contacts,
                mutating: false,
                durable: false,
            },
            EngineCommand::VerifyContact { .. } | EngineCommand::UpdateContactSettings { .. } => {
                CommandRoute {
                    family: CommandFamily::Contacts,
                    mutating: true,
                    durable: true,
                }
            }
            EngineCommand::PairingInbox | EngineCommand::PairingOutbox => CommandRoute {
                family: CommandFamily::Pairing,
                mutating: true,
                durable: true,
            },
            EngineCommand::RefreshPairingCode
            | EngineCommand::SubmitPairingCode { .. }
            | EngineCommand::AcceptPairing { .. }
            | EngineCommand::RejectPairing { .. }
            | EngineCommand::CancelPairing { .. }
            | EngineCommand::ArchivePairing { .. } => CommandRoute {
                family: CommandFamily::Pairing,
                mutating: true,
                durable: true,
            },
            EngineCommand::ListConversations => CommandRoute {
                family: CommandFamily::Conversations,
                mutating: false,
                durable: false,
            },
            EngineCommand::StartConversation { .. }
            | EngineCommand::OpenConversation { .. }
            | EngineCommand::CloseConversation => CommandRoute {
                family: CommandFamily::Conversations,
                mutating: true,
                durable: true,
            },
            EngineCommand::ListMessages { .. } => CommandRoute {
                family: CommandFamily::Messages,
                mutating: false,
                durable: false,
            },
            EngineCommand::SendMessage { .. }
            | EngineCommand::RetryMessage { .. }
            | EngineCommand::DeleteMessageLocal { .. }
            | EngineCommand::SendReadReceipts { .. } => CommandRoute {
                family: CommandFamily::Messages,
                mutating: true,
                durable: true,
            },
            EngineCommand::GetPeerEndpoint => CommandRoute {
                family: CommandFamily::Peer,
                mutating: false,
                durable: false,
            },
            EngineCommand::RetryPeerConnection { .. } | EngineCommand::RotatePeerEndpoint => {
                CommandRoute {
                    family: CommandFamily::Peer,
                    mutating: true,
                    durable: true,
                }
            }
            EngineCommand::SetTyping { .. } | EngineCommand::SetPresence { .. } => CommandRoute {
                family: CommandFamily::Ephemeral,
                mutating: true,
                durable: false,
            },
            EngineCommand::PlatformFact { .. } => CommandRoute {
                family: CommandFamily::Lifecycle,
                mutating: true,
                durable: false,
            },
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn message_query_and_message_command_have_distinct_routes() {
        let query = CommandRouter::route(&EngineCommand::ListMessages {
            conversation_id: "conversation".to_owned(),
        });
        let command = CommandRouter::route(&EngineCommand::SendMessage {
            conversation_id: "conversation".to_owned(),
            body: "hello".to_owned(),
            reply_to_message_id: None,
        });

        assert_eq!(query.family, CommandFamily::Messages);
        assert!(!query.mutating);
        assert!(!query.durable);
        assert!(command.mutating);
        assert!(command.durable);
    }

    #[test]
    fn ephemeral_commands_are_never_marked_durable() {
        let route = CommandRouter::route(&EngineCommand::SetTyping {
            conversation_id: "conversation".to_owned(),
            typing: true,
        });

        assert_eq!(route.family, CommandFamily::Ephemeral);
        assert!(route.mutating);
        assert!(!route.durable);
    }
}
