use crate::{ContactRecord, PairingItem, PairingPreparation, RuntimeError, RuntimeResult};
use crate::{InviteState, pairing_rules::PairingAction};

/// Pure boundary for the pairing-code workflow.
///
/// The runtime owns persistence and transport orchestration; this module owns
/// only input normalization so the workflow can be tested independently.
pub(crate) fn normalize_pairing_code(code: &str) -> RuntimeResult<String> {
    let normalized = code
        .chars()
        .filter(|value| !value.is_ascii_whitespace())
        .collect::<String>();
    if normalized.len() != 8 || !normalized.bytes().all(|value| value.is_ascii_digit()) {
        return Err(RuntimeError::InvalidParams(
            "pairing code must contain exactly eight digits".to_owned(),
        ));
    }
    Ok(normalized)
}

pub(crate) fn has_outstanding_request(items: &[PairingItem]) -> bool {
    items.iter().any(|item| item.state.is_outstanding())
}

pub(crate) fn require_profile_ready(profile: Option<&crate::RuntimeProfile>) -> RuntimeResult<()> {
    let profile = profile
        .ok_or_else(|| RuntimeError::Unavailable("runtime profile is not ready".to_owned()))?;
    if profile.nickname.trim().chars().count() < 2 {
        return Err(RuntimeError::Conflict(
            "set nickname before generating a pairing code".to_owned(),
        ));
    }
    Ok(())
}

/// Pure state transition boundary for pairing commands.
pub(crate) fn transition_invite_state(
    state: &InviteState,
    action: PairingAction,
) -> RuntimeResult<InviteState> {
    use InviteState::*;
    match (state, action) {
        (Pending, PairingAction::Accept) => Ok(Accepted),
        (Pending, PairingAction::Reject) => Ok(Rejected),
        (Pending, PairingAction::Expire) => Ok(Expired),
        (Pending, PairingAction::Cancel) => Ok(Cancelled),
        (Accepted, PairingAction::Complete) => Ok(Completed),
        (Accepted, PairingAction::Cancel) => Ok(Cancelled),
        (Accepted | Rejected | Completed | Expired | Cancelled, PairingAction::Archive) => {
            Ok(Archived)
        }
        _ => Err(RuntimeError::Conflict(
            "pairing request cannot be transitioned from its current state".to_owned(),
        )),
    }
}

pub(crate) fn transition_item(
    mut item: PairingItem,
    action: PairingAction,
) -> RuntimeResult<PairingItem> {
    item.state = transition_invite_state(&item.state, action)?;
    Ok(crate::pairing_rules::normalize_pairing_item(item))
}

pub(crate) fn send_effect(
    pairing_id: String,
    recipient_installation_id: String,
    kind: crate::PairingSendKind,
    payload: Option<String>,
) -> crate::RuntimeSendEffect {
    crate::RuntimeSendEffect {
        message: None,
        receipt: None,
        pairing: Some(crate::PairingSendEffect {
            pairing_id,
            recipient_installation_id,
            kind,
            payload,
        }),
    }
}

pub(crate) fn pending_send_effects(
    items: Vec<PairingItem>,
    now_secs: i64,
) -> RuntimeResult<Vec<crate::RuntimeSendEffect>> {
    let mut effects = Vec::new();
    for item in items {
        let Some(sender) = item.sender.as_ref() else {
            if matches!(item.state, InviteState::Accepted | InviteState::Rejected) {
                return Err(RuntimeError::Conflict(
                    "pairing sender does not exist".to_owned(),
                ));
            }
            continue;
        };
        let recipient_installation_id = sender.installation_id.clone();
        match item.state {
            InviteState::Accepted => {
                if item.expires_at < now_secs {
                    continue;
                }
                if item.offer_payload.is_none() {
                    return Err(RuntimeError::Conflict(
                        "accepted pairing offer payload does not exist".to_owned(),
                    ));
                }
                effects.push(send_effect(
                    item.pairing_id,
                    recipient_installation_id,
                    crate::PairingSendKind::Offer,
                    item.offer_payload,
                ));
            }
            InviteState::Rejected => effects.push(send_effect(
                item.pairing_id,
                recipient_installation_id,
                crate::PairingSendKind::Rejection,
                None,
            )),
            _ => {}
        }
    }
    effects.sort_by_key(|effect| effect.recipient_installation_id().to_owned());
    Ok(effects)
}

pub(crate) fn merge_remote_items(
    local: &mut Vec<PairingItem>,
    remote: Vec<PairingItem>,
) -> Vec<crate::pairing_rules::PairingMerge> {
    remote
        .into_iter()
        .map(|remote_item| {
            let local_item = local
                .iter()
                .position(|item| item.pairing_id == remote_item.pairing_id)
                .map(|index| local.remove(index));
            let merge = crate::pairing_rules::merge_pairing_item(local_item, remote_item);
            local.push(merge.item.clone());
            merge
        })
        .collect()
}

pub(crate) fn prepare_accept(
    item: PairingItem,
    contacts: &[ContactRecord],
    now_secs: i64,
) -> RuntimeResult<PairingPreparation> {
    let sender = item
        .sender
        .ok_or_else(|| RuntimeError::Conflict("pairing sender does not exist".to_owned()))?;
    if contacts
        .iter()
        .any(|contact| contact.installation_id == sender.installation_id && !contact.blocked)
    {
        return Err(RuntimeError::Conflict(
            "contact already exists; remove it before pairing again".to_owned(),
        ));
    }
    let capability = item
        .capability
        .ok_or_else(|| RuntimeError::Conflict("pairing capability does not exist".to_owned()))?;
    if item.expires_at < now_secs {
        return Err(RuntimeError::Conflict(
            "pairing request is expired".to_owned(),
        ));
    }
    if !item.state.is_pending() {
        return Err(RuntimeError::Conflict(
            "pairing request cannot be prepared from its current state".to_owned(),
        ));
    }
    Ok(PairingPreparation {
        pairing_id: item.pairing_id,
        recipient_installation_id: sender.installation_id,
        capability,
    })
}

/// Applies the pure part of accepting an invite and prepares the transport
/// effect. Storage and event publication stay in the runtime orchestration.
pub(crate) fn commit_accept(
    mut item: PairingItem,
    offer_invite_id: String,
    offer_payload: String,
    now_secs: i64,
) -> RuntimeResult<(PairingItem, crate::RuntimeSendEffect)> {
    if offer_invite_id.trim().is_empty() {
        return Err(RuntimeError::InvalidParams(
            "offerInviteId must not be empty".to_owned(),
        ));
    }
    if offer_payload.trim().is_empty() {
        return Err(RuntimeError::InvalidParams(
            "offerPayload must not be empty".to_owned(),
        ));
    }
    let sender_installation_id = item
        .sender
        .as_ref()
        .ok_or_else(|| RuntimeError::Conflict("pairing sender does not exist".to_owned()))?
        .installation_id
        .clone();
    if item.state == InviteState::Accepted {
        if item.offer_invite_id.as_deref() == Some(offer_invite_id.as_str())
            && item.offer_payload.as_deref() == Some(offer_payload.as_str())
        {
            let effect = send_effect(
                item.pairing_id.clone(),
                sender_installation_id.clone(),
                crate::PairingSendKind::Offer,
                item.offer_payload.clone(),
            );
            return Ok((item, effect));
        }
        return Err(RuntimeError::Conflict(
            "accepted pairing has different offer artifacts".to_owned(),
        ));
    }
    if item.expires_at < now_secs {
        return Err(RuntimeError::Conflict(
            "pairing request is expired".to_owned(),
        ));
    }
    item.state = transition_invite_state(&item.state, PairingAction::Accept)?;
    item.offer_invite_id = Some(offer_invite_id);
    item.offer_payload = Some(offer_payload);
    item = crate::pairing_rules::normalize_pairing_item(item);
    let effect = send_effect(
        item.pairing_id.clone(),
        sender_installation_id,
        crate::PairingSendKind::Offer,
        item.offer_payload.clone(),
    );
    Ok((item, effect))
}

pub(crate) fn prepare_reject(
    mut item: PairingItem,
    now_secs: i64,
) -> RuntimeResult<(PairingItem, String)> {
    let recipient = item
        .sender
        .as_ref()
        .ok_or_else(|| RuntimeError::Conflict("pairing sender does not exist".to_owned()))?
        .installation_id
        .clone();
    if item.state != crate::InviteState::Rejected {
        if item.expires_at < now_secs {
            return Err(RuntimeError::Conflict(
                "pairing request is expired".to_owned(),
            ));
        }
        item.state = transition_invite_state(&item.state, PairingAction::Reject)?;
        item = crate::pairing_rules::normalize_pairing_item(item);
    }
    Ok((item, recipient))
}

pub(crate) fn prepare_cancel(item: &PairingItem) -> RuntimeResult<crate::PairingCancelEffect> {
    if !matches!(
        item.state,
        crate::InviteState::Pending | crate::InviteState::Accepted
    ) {
        return Err(RuntimeError::Conflict(
            "pairing request cannot be cancelled from its current state".to_owned(),
        ));
    }
    Ok(crate::PairingCancelEffect {
        pairing_id: item.pairing_id.clone(),
    })
}

pub(crate) fn commit_cancel(item: PairingItem) -> RuntimeResult<PairingItem> {
    if item.state == crate::InviteState::Cancelled {
        return Ok(item);
    }
    if !matches!(
        item.state,
        crate::InviteState::Pending | crate::InviteState::Accepted
    ) {
        return Err(RuntimeError::Conflict(
            "pairing request cannot be cancelled from its current state".to_owned(),
        ));
    }
    let mut item = item;
    item.state = crate::InviteState::Cancelled;
    Ok(crate::pairing_rules::normalize_pairing_item(item))
}

pub(crate) fn confirm_cancel(item: PairingItem) -> RuntimeResult<Option<PairingItem>> {
    if item.state == crate::InviteState::Cancelled {
        return Ok(None);
    }
    commit_cancel(item).map(Some)
}

pub(crate) fn next_state_for_peer_outcome(
    state: crate::InviteState,
    outcome: crate::PairingPeerOutcome,
) -> RuntimeResult<crate::InviteState> {
    use crate::InviteState;
    match outcome {
        crate::PairingPeerOutcome::OfferReceived => match state {
            InviteState::Pending | InviteState::Accepted => Ok(InviteState::Accepted),
            InviteState::Completed => Ok(InviteState::Completed),
            _ => Err(RuntimeError::Conflict(
                "pairing peer outcome is invalid for the current state".to_owned(),
            )),
        },
        crate::PairingPeerOutcome::RejectionReceived => match state {
            InviteState::Pending | InviteState::Accepted | InviteState::Rejected => {
                Ok(InviteState::Rejected)
            }
            InviteState::Completed => Ok(InviteState::Completed),
            _ => Err(RuntimeError::Conflict(
                "pairing peer outcome is invalid for the current state".to_owned(),
            )),
        },
        crate::PairingPeerOutcome::WelcomePrepared => match state {
            InviteState::Accepted | InviteState::Completed => Ok(InviteState::Completed),
            _ => Err(RuntimeError::Conflict(
                "pairing peer outcome is invalid for the current state".to_owned(),
            )),
        },
    }
}

pub(crate) fn complete_welcome(
    mut item: PairingItem,
    peer_installation_id: String,
) -> RuntimeResult<(PairingItem, crate::PairingConfirmContactEffect)> {
    let capability = item
        .capability
        .clone()
        .ok_or_else(|| RuntimeError::Conflict("pairing capability does not exist".to_owned()))?;
    match item.state {
        crate::InviteState::Accepted => {
            item.state = crate::InviteState::Completed;
            item = crate::pairing_rules::normalize_pairing_item(item);
        }
        crate::InviteState::Completed => {}
        _ => {
            return Err(RuntimeError::Conflict(
                "welcome cannot complete pairing from its current state".to_owned(),
            ));
        }
    }
    Ok((
        item.clone(),
        crate::PairingConfirmContactEffect {
            pairing_id: item.pairing_id,
            capability,
            peer_installation_id,
        },
    ))
}

pub(crate) fn visible_items(mut items: Vec<PairingItem>) -> Vec<PairingItem> {
    items.retain(|item| item.state != crate::InviteState::Archived);
    items.sort_by(|a, b| {
        b.expires_at
            .cmp(&a.expires_at)
            .then(a.pairing_id.cmp(&b.pairing_id))
    });
    items
}

pub(crate) fn expire_item(mut item: PairingItem, now_secs: i64) -> Option<PairingItem> {
    if item.state != crate::InviteState::Pending || item.expires_at >= now_secs {
        return None;
    }
    item.state = crate::InviteState::Expired;
    Some(crate::pairing_rules::normalize_pairing_item(item))
}

pub(crate) fn expire_items(items: &mut [PairingItem], now_secs: i64) -> Vec<PairingItem> {
    let mut changed = Vec::new();
    for item in items.iter_mut() {
        if let Some(expired) = expire_item(item.clone(), now_secs) {
            *item = expired.clone();
            changed.push(expired);
        }
    }
    changed
}

pub(crate) fn complete_for_existing_contact(
    mut item: PairingItem,
    contact_ids: &std::collections::BTreeSet<String>,
) -> Option<PairingItem> {
    let target_is_contact = item
        .sender
        .as_ref()
        .is_some_and(|target| contact_ids.contains(&target.installation_id));
    if !item.state.is_outstanding() || !target_is_contact {
        return None;
    }
    item.state = InviteState::Completed;
    Some(crate::pairing_rules::normalize_pairing_item(item))
}

pub(crate) fn reconcile_outbox_item(
    mut item: PairingItem,
    contact: &ContactRecord,
    installation_id: &str,
    allow_single_unbound_repair: bool,
) -> Option<PairingItem> {
    if !item.state.is_outstanding() {
        return None;
    }
    let matches_contact = item
        .sender
        .as_ref()
        .is_some_and(|sender| sender.installation_id == installation_id);
    if !matches_contact && !allow_single_unbound_repair {
        return None;
    }
    item.sender = Some(contact.clone());
    item.state = InviteState::Completed;
    Some(crate::pairing_rules::normalize_pairing_item(item))
}

pub(crate) fn reconcile_outbox_items(
    items: Vec<PairingItem>,
    contact: &ContactRecord,
    installation_id: &str,
) -> Vec<PairingItem> {
    let outstanding = items
        .iter()
        .filter(|item| item.state.is_outstanding())
        .cloned()
        .collect::<Vec<_>>();
    let explicit_matches = outstanding
        .iter()
        .filter(|item| {
            item.sender
                .as_ref()
                .is_some_and(|sender| sender.installation_id == installation_id)
        })
        .count();
    let allow_single_unbound_repair = explicit_matches == 0 && outstanding.len() == 1;
    outstanding
        .into_iter()
        .filter_map(|item| {
            reconcile_outbox_item(item, contact, installation_id, allow_single_unbound_repair)
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::{
        commit_accept, commit_cancel, complete_welcome, confirm_cancel, expire_item,
        next_state_for_peer_outcome, normalize_pairing_code, prepare_accept, prepare_cancel,
        transition_invite_state, visible_items,
    };
    use crate::pairing_rules::PairingAction;
    use crate::{ContactRecord, InviteState, PairingItem};

    #[test]
    fn normalizes_grouped_eight_digit_code() {
        assert_eq!(normalize_pairing_code("1234 5678").unwrap(), "12345678");
        assert_eq!(normalize_pairing_code("12345678").unwrap(), "12345678");
    }

    #[test]
    fn rejects_codes_with_wrong_shape() {
        assert!(normalize_pairing_code("1234567").is_err());
        assert!(normalize_pairing_code("123456789").is_err());
        assert!(normalize_pairing_code("1234-5678").is_err());
        assert!(normalize_pairing_code("1234abcd").is_err());
    }

    #[test]
    fn accepts_only_valid_pairing_transitions() {
        assert_eq!(
            transition_invite_state(&crate::InviteState::Pending, PairingAction::Accept).unwrap(),
            crate::InviteState::Accepted
        );
        assert!(
            transition_invite_state(&crate::InviteState::Completed, PairingAction::Accept).is_err()
        );
    }

    #[test]
    fn rejects_expired_pairing_before_transport() {
        let item = PairingItem {
            pairing_id: "pairing-1".to_owned(),
            sender: Some(ContactRecord {
                installation_id: "peer-1".to_owned(),
                nickname: "Peer".to_owned(),
                public_key: "public-key".to_owned(),
                fingerprint: "fingerprint".to_owned(),
                local_alias: None,
                muted: false,
                blocked: false,
                verification: crate::VerificationState::Unverified,
                peer_endpoint_status: crate::PeerEndpointStatus::Missing,
                peer_connection_status: crate::PeerConnectionStatus::Offline,
                transport_policy: crate::ContactTransportPolicy::PeerOnly,
                last_peer_connected_at: None,
                last_seen_at: None,
                dev: None,
            }),
            capability: Some("cap".to_owned()),
            expires_at: 10,
            state: crate::InviteState::Pending,
            received: true,
            available_actions: Vec::new(),
            offer_invite_id: None,
            offer_payload: None,
        };
        assert!(prepare_accept(item, &[], 11).is_err());
    }

    #[test]
    fn cancel_is_allowed_only_for_outstanding_pairing() {
        let item = PairingItem {
            pairing_id: "pairing-1".to_owned(),
            sender: None,
            capability: None,
            expires_at: 10,
            state: crate::InviteState::Pending,
            received: false,
            available_actions: Vec::new(),
            offer_invite_id: None,
            offer_payload: None,
        };
        assert_eq!(prepare_cancel(&item).unwrap().pairing_id, "pairing-1");
        let mut completed = item;
        completed.state = crate::InviteState::Completed;
        assert!(prepare_cancel(&completed).is_err());
    }

    #[test]
    fn commit_accept_is_idempotent_for_same_offer_artifacts() {
        let mut item = PairingItem {
            pairing_id: "pairing-1".to_owned(),
            sender: Some(ContactRecord {
                installation_id: "sender-1".to_owned(),
                nickname: "Sender".to_owned(),
                public_key: "key".to_owned(),
                fingerprint: "fingerprint".to_owned(),
                local_alias: None,
                muted: false,
                blocked: false,
                verification: crate::VerificationState::Unverified,
                peer_endpoint_status: Default::default(),
                peer_connection_status: Default::default(),
                transport_policy: Default::default(),
                last_peer_connected_at: None,
                last_seen_at: None,
                dev: None,
            }),
            capability: Some("capability".to_owned()),
            expires_at: 100,
            state: InviteState::Accepted,
            received: true,
            available_actions: Vec::new(),
            offer_invite_id: Some("invite-1".to_owned()),
            offer_payload: Some("payload-1".to_owned()),
        };
        let (replayed, effect) = commit_accept(
            item.clone(),
            "invite-1".to_owned(),
            "payload-1".to_owned(),
            0,
        )
        .unwrap();
        assert_eq!(replayed.offer_invite_id, item.offer_invite_id);
        assert!(effect.pairing.is_some());
        item.state = InviteState::Pending;
        assert!(commit_accept(item, "".to_owned(), "payload-1".to_owned(), 0).is_err());
    }

    #[test]
    fn commit_cancel_is_idempotent_and_rejects_terminal_state() {
        let item = PairingItem {
            pairing_id: "pairing-1".to_owned(),
            capability: Some("capability".to_owned()),
            expires_at: 100,
            state: InviteState::Pending,
            received: false,
            available_actions: Vec::new(),
            sender: None,
            offer_invite_id: None,
            offer_payload: None,
        };
        let cancelled = commit_cancel(item).unwrap();
        assert_eq!(cancelled.state, InviteState::Cancelled);
        assert_eq!(commit_cancel(cancelled.clone()).unwrap(), cancelled);
        assert!(
            commit_cancel(PairingItem {
                state: InviteState::Completed,
                ..cancelled
            })
            .is_err()
        );
    }

    #[test]
    fn confirm_cancel_returns_only_real_transition() {
        let item = PairingItem {
            pairing_id: "pairing-1".to_owned(),
            capability: Some("capability".to_owned()),
            expires_at: 100,
            state: InviteState::Pending,
            received: false,
            available_actions: Vec::new(),
            sender: None,
            offer_invite_id: None,
            offer_payload: None,
        };
        let cancelled = confirm_cancel(item).unwrap().unwrap();
        assert_eq!(cancelled.state, InviteState::Cancelled);
        assert!(confirm_cancel(cancelled.clone()).unwrap().is_none());
        assert!(
            confirm_cancel(PairingItem {
                state: InviteState::Completed,
                ..cancelled
            })
            .is_err()
        );
    }

    #[test]
    fn expiry_changes_only_pending_items_past_deadline() {
        let item = PairingItem {
            pairing_id: "pairing-1".to_owned(),
            capability: None,
            expires_at: 10,
            state: InviteState::Pending,
            received: false,
            available_actions: Vec::new(),
            sender: None,
            offer_invite_id: None,
            offer_payload: None,
        };
        assert_eq!(expire_item(item.clone(), 10), None);
        assert_eq!(expire_item(item, 11).unwrap().state, InviteState::Expired);
    }

    #[test]
    fn complete_welcome_replays_completed_pairing_without_duplicate_transition() {
        let item = PairingItem {
            pairing_id: "pairing-1".to_owned(),
            capability: Some("capability".to_owned()),
            expires_at: 100,
            state: InviteState::Accepted,
            received: true,
            available_actions: Vec::new(),
            sender: None,
            offer_invite_id: Some("invite-1".to_owned()),
            offer_payload: Some("payload-1".to_owned()),
        };
        let (completed, effect) = complete_welcome(item, "peer-1".to_owned()).unwrap();
        assert_eq!(completed.state, InviteState::Completed);
        assert_eq!(effect.pairing_id, "pairing-1");
        let (replayed, _) = complete_welcome(completed, "peer-1".to_owned()).unwrap();
        assert_eq!(replayed.state, InviteState::Completed);
    }

    #[test]
    fn maps_peer_outcomes_without_allowing_invalid_transitions() {
        assert_eq!(
            next_state_for_peer_outcome(
                crate::InviteState::Pending,
                crate::PairingPeerOutcome::OfferReceived
            )
            .unwrap(),
            crate::InviteState::Accepted
        );
        assert!(
            next_state_for_peer_outcome(
                crate::InviteState::Rejected,
                crate::PairingPeerOutcome::WelcomePrepared
            )
            .is_err()
        );
    }

    #[test]
    fn visible_items_filters_archived_and_sorts_deterministically() {
        let item = |id: &str, expires_at: i64, state| PairingItem {
            pairing_id: id.to_owned(),
            sender: None,
            capability: None,
            expires_at,
            state,
            received: false,
            available_actions: Vec::new(),
            offer_invite_id: None,
            offer_payload: None,
        };
        let items = visible_items(vec![
            item("b", 20, crate::InviteState::Pending),
            item("archived", 30, crate::InviteState::Archived),
            item("a", 20, crate::InviteState::Pending),
        ]);
        assert_eq!(
            items
                .iter()
                .map(|item| item.pairing_id.as_str())
                .collect::<Vec<_>>(),
            vec!["a", "b"]
        );
    }
}
