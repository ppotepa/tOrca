mod cli;
mod identity_store;
mod model;
mod runtime_adapter;
#[cfg(test)]
mod runtime_conformance;
mod runtime_flow;
mod runtime_headless;
mod runtime_state;
mod runtime_stdio;
mod runtime_storage;
mod runtime_support;
mod runtime_wire;
mod sql;
mod store;
mod tor_runtime;
mod transport;

use anyhow::Result;
use clap::Parser;
use cli::Cli;
pub(crate) use runtime_state::DesktopState;

fn main() -> Result<()> {
    let cli = Cli::parse();
    if cli.stdio_runtime {
        return runtime_stdio::run_stdio_runtime(cli);
    }
    if cli.headless_smoke
        || cli.headless_pairing_code
        || cli.headless_submit_pairing_code.is_some()
        || cli.headless_send.is_some()
    {
        return runtime_headless::run_headless(cli);
    }
    anyhow::bail!("The desktop frontend is Flutter. Run scripts/torchat.ps1 run -Target windows.")
}

#[cfg(test)]
mod tests {
    use base64::Engine;
    use base64::engine::general_purpose::URL_SAFE_NO_PAD;
    use torchat_client_runtime::contact_record_from_card;
    use torchat_core::{
        mls::DirectConversation,
        relay::{ContactCard, RelayPayloadV1},
    };

    fn fixture_snapshot(field: &str) -> Vec<u8> {
        let fixture: serde_json::Value = serde_json::from_str(include_str!(
            "../../protocol/dev-fixtures/android-peer.json"
        ))
        .unwrap();
        URL_SAFE_NO_PAD
            .decode(fixture[field].as_str().unwrap())
            .unwrap()
    }

    #[test]
    fn checked_in_mobile_desktop_fixture_exchanges_messages_both_ways() {
        let mut mobile =
            DirectConversation::restore(&fixture_snapshot("android_snapshot")).unwrap();
        let mut desktop = DirectConversation::restore(&fixture_snapshot("peer_snapshot")).unwrap();

        let mobile_ciphertext = mobile.encrypt(b"hello desktop").unwrap();
        let mobile_payload = RelayPayloadV1::application(&mobile_ciphertext)
            .encode()
            .unwrap();
        let decoded = RelayPayloadV1::decode(&mobile_payload)
            .unwrap()
            .decode_application()
            .unwrap();
        assert_eq!(desktop.decrypt(&decoded).unwrap(), b"hello desktop");

        let desktop_ciphertext = desktop.encrypt(b"hello mobile").unwrap();
        let desktop_payload = RelayPayloadV1::application(&desktop_ciphertext)
            .encode()
            .unwrap();
        let decoded = RelayPayloadV1::decode(&desktop_payload)
            .unwrap()
            .decode_application()
            .unwrap();
        assert_eq!(mobile.decrypt(&decoded).unwrap(), b"hello mobile");

        assert!(DirectConversation::restore(&mobile.snapshot().unwrap()).is_ok());
        assert!(DirectConversation::restore(&desktop.snapshot().unwrap()).is_ok());
    }

    #[test]
    fn runtime_contact_uses_canonical_dto_keys() {
        let contact = ContactCard {
            installation_id: "installation-bob".into(),
            nickname: "Bob".into(),
            public_key: "bob-public-key".into(),
            fingerprint: "bb11 cc22 dd33 ee44 ff55 0066 1122 3344".into(),
        };
        let value = serde_json::to_value(contact_record_from_card(&contact, true)).unwrap();
        assert_eq!(value["installationId"], "installation-bob");
        assert_eq!(value["nickname"], "Bob");
        assert_eq!(value["publicKey"], "bob-public-key");
        assert_eq!(
            value["fingerprint"],
            "bb11 cc22 dd33 ee44 ff55 0066 1122 3344"
        );
    }

    #[test]
    fn stdio_cancel_pairing_waits_for_cancelled_outbox_state() {
        let source = include_str!("runtime_stdio.rs");
        let cancel_arm = source
            .split("\"cancelPairing\" =>")
            .nth(1)
            .and_then(|value| value.split("\"acceptPairing\" =>").next())
            .expect("cancelPairing runtime arm exists");
        assert!(cancel_arm.contains("RelayCommand::CancelPairing"));
        assert!(cancel_arm.contains("is_cancelled()"));
        assert!(cancel_arm.contains("dispatch_local"));
        assert!(cancel_arm.contains("cancelPairing"));
    }

    #[test]
    fn stdio_waiting_relay_commands_abort_on_actor_error() {
        let runtime_source = include_str!("runtime_stdio.rs");
        let support_source = include_str!("runtime_support.rs");

        assert!(
            runtime_source.contains("wait_for_pairing_code"),
            "refreshPairingCode must use the shared pairing-code wait helper"
        );
        assert!(
            runtime_source.contains("wait_for_pairing_request"),
            "submitPairingCode must use the shared pairing-request wait helper"
        );
        assert!(
            runtime_source.contains("bail_on_relay_command_error"),
            "cancelPairing must still abort promptly on relay errors"
        );
        assert!(
            support_source.contains("bail_on_relay_command_error"),
            "shared pairing wait helpers must abort promptly on relay errors"
        );
    }

    #[test]
    fn desktop_receipts_report_transport_outcomes_to_runtime() {
        let state_source = include_str!("runtime_state.rs");
        let transport_source = include_str!("transport.rs");
        let flow_source = include_str!("runtime_flow.rs");
        let storage_source = include_str!("runtime_storage.rs");
        let store_source = include_str!("store.rs");
        let wire_source = include_str!("runtime_wire.rs");

        assert!(state_source.contains("applyMessageTransportOutcome"));
        assert!(transport_source.contains("MessageTransportOutcome::Delivered"));
        assert!(transport_source.contains("MessageTransportOutcome::Forwarded"));
        assert!(!flow_source.contains("set_message_state"));
        assert!(!state_source.contains(&("\"updateMessage".to_owned() + "State\"")));
        assert!(storage_source.contains("impl RuntimeStorage for DesktopRuntimeStorage"));
        assert!(!store_source.contains("impl RuntimeStorage for DesktopRuntimeStorage"));
        assert!(!store_source.contains("ConversationPreview"));
        assert!(!store_source.contains(&("conversation_".to_owned() + "unread(")));
        assert!(!store_source.contains(&("conversation_".to_owned() + "peers(")));
        assert!(!store_source.contains(&("conversation_".to_owned() + "preview(")));
        assert!(!wire_source.contains("state.conversations.contains_key(peer)"));
    }
}
