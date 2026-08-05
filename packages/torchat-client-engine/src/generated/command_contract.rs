// Generated from common/client-engine-contract.json. Do not edit manually.

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct CommandContract {
    pub public_method: &'static str,
    pub wire_name: &'static str,
    pub category: &'static str,
    pub durable: bool,
    pub requires_command_id: bool,
    pub idempotent: bool,
    pub handler_key: &'static str,
}

macro_rules! command {
    ($public:literal, $wire:literal, $category:literal, $durable:literal, $requires:literal, $handler:literal) => {
        CommandContract {
            public_method: $public,
            wire_name: $wire,
            category: $category,
            durable: $durable,
            requires_command_id: $requires,
            idempotent: true,
            handler_key: $handler,
        }
    };
}

pub const COMMANDS: &[CommandContract] = &[
    command!("bootstrap", "bootstrap", "lifecycle", false, false, "bootstrap"),
    command!("connect", "connect", "lifecycle", false, false, "connect"),
    command!("getIdentity", "get_identity", "query", false, false, "get_identity"),
    command!("getProfile", "get_profile", "query", false, false, "get_profile"),
    command!("getStartupReadiness", "get_startup_readiness", "query", false, false, "get_startup_readiness"),
    command!("getApplicationSnapshot", "get_application_snapshot", "query", false, false, "get_application_snapshot"),
    command!("listPairings", "list_pairings", "query", false, false, "list_pairings"),
    command!("pairingInbox", "pairing_inbox", "query", false, false, "pairing_inbox"),
    command!("pairingOutbox", "pairing_outbox", "query", false, false, "pairing_outbox"),
    command!("listContacts", "list_contacts", "query", false, false, "list_contacts"),
    command!("listConversations", "list_conversations", "query", false, false, "list_conversations"),
    command!("listMessages", "list_messages", "query", false, false, "list_messages"),
    command!("getPeerEndpoint", "get_peer_endpoint", "query", false, false, "get_peer_endpoint"),
    command!("retryPeerConnection", "retry_peer_connection", "workflow", false, false, "retry_peer_connection"),
    command!("rotatePeerEndpoint", "rotate_peer_endpoint", "workflow", true, true, "rotate_peer_endpoint"),
    command!("getContactEndpointCapability", "get_contact_endpoint_capability", "query", false, false, "get_contact_endpoint_capability"),
    command!("rotateContactEndpointCapability", "rotate_contact_endpoint_capability", "workflow", true, true, "rotate_contact_endpoint_capability"),
    command!("revokeContactEndpointCapability", "revoke_contact_endpoint_capability", "mutation", true, true, "revoke_contact_endpoint_capability"),
    command!("setNickname", "set_nickname", "mutation", true, true, "set_nickname"),
    command!("refreshPairingCode", "refresh_pairing_code", "workflow", true, true, "refresh_pairing_code"),
    command!("submitPairingCode", "submit_pairing_code", "workflow", true, true, "submit_pairing_code"),
    command!("acceptPairing", "accept_pairing", "workflow", true, true, "accept_pairing"),
    command!("rejectPairing", "reject_pairing", "workflow", true, true, "reject_pairing"),
    command!("archivePairing", "archive_pairing", "mutation", true, true, "archive_pairing"),
    command!("cancelPairing", "cancel_pairing", "workflow", true, true, "cancel_pairing"),
    command!("verifyContact", "verify_contact", "mutation", true, true, "verify_contact"),
    command!("updateContactSettings", "update_contact_settings", "mutation", true, true, "update_contact_settings"),
    command!("removeRelationship", "request_relationship_removal", "workflow", true, true, "request_relationship_removal"),
    command!("startConversation", "start_conversation", "mutation", true, true, "start_conversation"),
    command!("openConversation", "open_conversation", "mutation", false, false, "open_conversation"),
    command!("closeConversation", "close_conversation", "mutation", false, false, "close_conversation"),
    command!("sendMessage", "send_message", "workflow", true, true, "send_message"),
    command!("retryMessage", "retry_message", "workflow", true, true, "retry_message"),
    command!("retryDeadLetter", "retry_dead_letter", "workflow", true, true, "retry_dead_letter"),
    command!("listDeadLetters", "list_dead_letters", "query", false, false, "list_dead_letters"),
    command!("deleteMessageLocal", "delete_message_local", "mutation", true, true, "delete_message_local"),
    command!("setTyping", "set_typing", "mutation", false, false, "set_typing"),
    command!("setConversationFocus", "set_conversation_focus", "mutation", false, false, "set_conversation_focus"),
    command!("setPresence", "set_presence", "mutation", false, false, "set_presence"),
    command!("sendReadReceipts", "send_read_receipts", "workflow", true, true, "send_read_receipts"),
    command!("platformFact", "platform_fact", "platform_fact", false, false, "platform_fact"),
    command!("shutdown", "shutdown", "lifecycle", false, false, "shutdown"),
];

pub fn command_contract(wire_name: &str) -> Option<&'static CommandContract> {
    COMMANDS.iter().find(|command| command.wire_name == wire_name)
}
