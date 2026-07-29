use crate::InviteState;
use std::cmp::max;
use std::fmt;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum PairingAction {
    Accept,
    Reject,
    Complete,
    Expire,
    Archive,
    Cancel,
}

pub trait RuntimePairingStateLike {
    fn runtime_pairing_state(&self) -> InviteState;
}

pub trait RuntimePairingIdLike {
    fn runtime_pairing_id(&self) -> String;
}

impl RuntimePairingIdLike for crate::PairingItem {
    fn runtime_pairing_id(&self) -> String {
        self.pairing_id.clone()
    }
}

impl RuntimePairingIdLike for &crate::PairingItem {
    fn runtime_pairing_id(&self) -> String {
        self.pairing_id.clone()
    }
}

pub trait RuntimePairingUuidLike {
    fn runtime_pairing_uuid(&self) -> uuid::Uuid;
}

pub trait RuntimePairingExpiryLike: RuntimePairingStateLike {
    fn runtime_pairing_expires_at(&self) -> i64;
    fn runtime_set_pairing_state(&mut self, state: InviteState);
}

pub trait RuntimePairingTransitionLike {
    fn runtime_pairing_transition_id(&self) -> uuid::Uuid;
    fn runtime_pairing_transition_state(&self) -> InviteState;
    fn runtime_set_pairing_transition_state(&mut self, state: InviteState);
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RuntimePairingTransitionError {
    NotFound,
    InvalidTransition,
}

impl fmt::Display for RuntimePairingTransitionError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            RuntimePairingTransitionError::NotFound => write!(f, "pairing request does not exist"),
            RuntimePairingTransitionError::InvalidTransition => {
                write!(
                    f,
                    "pairing request cannot be transitioned from its current state"
                )
            }
        }
    }
}

impl std::error::Error for RuntimePairingTransitionError {}

pub fn pairing_is_active(state: InviteState) -> bool {
    state.is_pending() || state.is_accepted()
}

pub fn pairing_has_outstanding_request<I, T>(items: I) -> bool
where
    I: IntoIterator<Item = T>,
    T: RuntimePairingStateLike,
{
    items
        .into_iter()
        .any(|item| pairing_is_active(item.runtime_pairing_state()))
}

pub fn pairing_items_contains_id<I, T>(items: I, pairing_id: &str) -> bool
where
    I: IntoIterator<Item = T>,
    T: RuntimePairingIdLike,
{
    items
        .into_iter()
        .any(|item| item.runtime_pairing_id() == pairing_id)
}

pub fn pairing_items_contains_uuid<I, T>(items: I, pairing_id: uuid::Uuid) -> bool
where
    I: IntoIterator<Item = T>,
    T: RuntimePairingUuidLike,
{
    items
        .into_iter()
        .any(|item| item.runtime_pairing_uuid() == pairing_id)
}

pub fn pairing_items_transition_after_action<I, T>(
    items: I,
    pairing_id: uuid::Uuid,
    action: PairingAction,
) -> Option<InviteState>
where
    I: IntoIterator<Item = T>,
    T: RuntimePairingUuidLike + RuntimePairingStateLike,
{
    items.into_iter().find_map(|item| {
        if item.runtime_pairing_uuid() == pairing_id {
            pairing_state_after_action(item.runtime_pairing_state(), action)
        } else {
            None
        }
    })
}

pub fn pairing_items_can_archive<I, T>(items: I, pairing_id: uuid::Uuid) -> bool
where
    I: IntoIterator<Item = T>,
    T: RuntimePairingUuidLike + RuntimePairingStateLike,
{
    items.into_iter().any(|item| {
        item.runtime_pairing_uuid() == pairing_id
            && pairing_can_archive(item.runtime_pairing_state())
    })
}

pub fn expire_pairing_items<T>(items: &mut [T], now_secs: i64) -> bool
where
    T: RuntimePairingExpiryLike,
{
    let mut changed = false;
    for item in items.iter_mut() {
        let next = expire_pairing_state(
            item.runtime_pairing_state(),
            item.runtime_pairing_expires_at(),
            now_secs,
        );
        if next != item.runtime_pairing_state() {
            item.runtime_set_pairing_state(next);
            changed = true;
        }
    }
    changed
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PairingMerge {
    pub item: crate::PairingItem,
    pub inserted: bool,
    pub changed: bool,
}

pub fn merge_invite_state(
    local: crate::InviteState,
    remote: crate::InviteState,
) -> crate::InviteState {
    use crate::InviteState::*;

    if local == remote {
        return local;
    }
    if matches!(local, Archived | Completed) {
        return local;
    }
    if matches!(remote, Archived | Completed) {
        return remote;
    }
    if matches!(local, Rejected | Cancelled | Expired | Accepted) && matches!(remote, Pending) {
        return local;
    }
    if matches!(local, Pending) {
        return remote;
    }
    local
}

pub fn merge_pairing_item(
    local: Option<crate::PairingItem>,
    remote: crate::PairingItem,
) -> PairingMerge {
    match local {
        None => {
            let item = normalize_pairing_item(remote);
            PairingMerge {
                item,
                inserted: true,
                changed: true,
            }
        }
        Some(local) => {
            let local = normalize_pairing_item(local);
            let remote = normalize_pairing_item(remote);
            let mut item = local.clone();
            if item.sender.is_none() {
                item.sender = remote.sender;
            }
            if item.capability.as_deref().unwrap_or_default().is_empty() {
                item.capability = remote.capability;
            }
            if item.offer_invite_id.is_none() {
                item.offer_invite_id = remote.offer_invite_id;
            }
            if item.offer_payload.is_none() {
                item.offer_payload = remote.offer_payload;
            }
            item.expires_at = max(item.expires_at, remote.expires_at);
            item.received = item.received || remote.received;
            item.state = merge_invite_state(item.state, remote.state);
            item = normalize_pairing_item(item);
            let changed = item != local;
            PairingMerge {
                item,
                inserted: false,
                changed,
            }
        }
    }
}

pub fn normalize_pairing_item(mut item: crate::PairingItem) -> crate::PairingItem {
    item.available_actions = crate::pairing_available_actions(item.state, item.received);
    item
}

pub fn normalize_pairing_items(items: Vec<crate::PairingItem>) -> Vec<crate::PairingItem> {
    items.into_iter().map(normalize_pairing_item).collect()
}

pub fn transition_pairing_record<T>(
    items: &mut [T],
    pairing_id: uuid::Uuid,
    action: PairingAction,
) -> Result<bool, RuntimePairingTransitionError>
where
    T: RuntimePairingTransitionLike,
{
    let target = pairing_target_state(action);
    let Some(item) = items
        .iter_mut()
        .find(|item| item.runtime_pairing_transition_id() == pairing_id)
    else {
        return Err(RuntimePairingTransitionError::NotFound);
    };
    if item.runtime_pairing_transition_state() == target {
        return Ok(true);
    }
    item.runtime_set_pairing_transition_state(
        pairing_state_after_action(item.runtime_pairing_transition_state(), action)
            .ok_or(RuntimePairingTransitionError::InvalidTransition)?,
    );
    Ok(true)
}

pub fn pairing_can_archive(state: InviteState) -> bool {
    state.can_archive()
}

pub fn expire_pairing_state(state: InviteState, expires_at: i64, now_secs: i64) -> InviteState {
    if state.is_pending() && expires_at < now_secs {
        InviteState::Expired
    } else {
        state
    }
}

pub fn pairing_state_after_action(
    state: InviteState,
    action: PairingAction,
) -> Option<InviteState> {
    transition(state, action)
}

pub fn pairing_state_on_accept(state: InviteState) -> Option<InviteState> {
    pairing_state_after_action(state, PairingAction::Accept)
}

pub fn pairing_state_on_reject(state: InviteState) -> Option<InviteState> {
    pairing_state_after_action(state, PairingAction::Reject)
}

pub fn pairing_state_on_archive(state: InviteState) -> Option<InviteState> {
    pairing_state_after_action(state, PairingAction::Archive)
}

pub fn pairing_state_on_cancel(state: InviteState) -> Option<InviteState> {
    pairing_state_after_action(state, PairingAction::Cancel)
}

pub fn pairing_target_state(action: PairingAction) -> InviteState {
    match action {
        PairingAction::Accept => InviteState::Accepted,
        PairingAction::Reject => InviteState::Rejected,
        PairingAction::Complete => InviteState::Completed,
        PairingAction::Expire => InviteState::Expired,
        PairingAction::Archive => InviteState::Archived,
        PairingAction::Cancel => InviteState::Cancelled,
    }
}

fn transition(state: InviteState, action: PairingAction) -> Option<InviteState> {
    match (state, action) {
        (InviteState::Pending, PairingAction::Accept) => Some(InviteState::Accepted),
        (InviteState::Pending, PairingAction::Reject) => Some(InviteState::Rejected),
        (InviteState::Pending, PairingAction::Expire) => Some(InviteState::Expired),
        (InviteState::Pending, PairingAction::Cancel) => Some(InviteState::Cancelled),
        (InviteState::Accepted, PairingAction::Complete) => Some(InviteState::Completed),
        (InviteState::Accepted, PairingAction::Cancel) => Some(InviteState::Cancelled),
        (
            InviteState::Accepted
            | InviteState::Rejected
            | InviteState::Completed
            | InviteState::Expired
            | InviteState::Cancelled,
            PairingAction::Archive,
        ) => Some(InviteState::Archived),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[derive(Clone, Copy)]
    struct StateItem(InviteState);

    impl RuntimePairingStateLike for StateItem {
        fn runtime_pairing_state(&self) -> InviteState {
            self.0
        }
    }

    #[derive(Clone, Copy)]
    struct ExpiryItem {
        state: InviteState,
        expires_at: i64,
    }

    impl RuntimePairingStateLike for ExpiryItem {
        fn runtime_pairing_state(&self) -> InviteState {
            self.state
        }
    }

    impl RuntimePairingExpiryLike for ExpiryItem {
        fn runtime_pairing_expires_at(&self) -> i64 {
            self.expires_at
        }

        fn runtime_set_pairing_state(&mut self, state: InviteState) {
            self.state = state;
        }
    }

    #[derive(Clone, Copy)]
    struct TransitionItem {
        id: uuid::Uuid,
        state: InviteState,
    }

    impl RuntimePairingTransitionLike for TransitionItem {
        fn runtime_pairing_transition_id(&self) -> uuid::Uuid {
            self.id
        }

        fn runtime_pairing_transition_state(&self) -> InviteState {
            self.state
        }

        fn runtime_set_pairing_transition_state(&mut self, state: InviteState) {
            self.state = state;
        }
    }

    #[test]
    fn active_states_match_runtime_rules() {
        assert!(pairing_is_active(InviteState::Pending));
        assert!(pairing_is_active(InviteState::Accepted));
        assert!(!pairing_is_active(InviteState::Rejected));
    }

    #[test]
    fn expiry_only_applies_to_pending_pairings() {
        assert_eq!(
            expire_pairing_state(InviteState::Pending, 10, 11),
            InviteState::Expired
        );
        assert_eq!(
            expire_pairing_state(InviteState::Accepted, 10, 11),
            InviteState::Accepted
        );
    }

    #[test]
    fn transition_helpers_match_core_rules() {
        assert_eq!(
            pairing_state_on_accept(InviteState::Pending),
            Some(InviteState::Accepted)
        );
        assert_eq!(
            pairing_state_on_reject(InviteState::Pending),
            Some(InviteState::Rejected)
        );
        assert_eq!(
            pairing_state_on_archive(InviteState::Accepted),
            Some(InviteState::Archived)
        );
        assert_eq!(
            pairing_state_on_cancel(InviteState::Accepted),
            Some(InviteState::Cancelled)
        );
    }

    #[test]
    fn outstanding_request_helper_matches_active_states() {
        assert!(pairing_has_outstanding_request([
            StateItem(InviteState::Pending),
            StateItem(InviteState::Rejected),
        ]));
        assert!(pairing_has_outstanding_request([StateItem(
            InviteState::Accepted
        )]));
        assert!(!pairing_has_outstanding_request([
            StateItem(InviteState::Rejected),
            StateItem(InviteState::Archived),
        ]));
    }

    #[test]
    fn id_helper_detects_matching_pairing_ids() {
        let items = [IdItem { id: "one" }, IdItem { id: "two" }];
        assert!(pairing_items_contains_id(items.iter(), "one"));
        assert!(!pairing_items_contains_id(items.iter(), "three"));
    }

    #[test]
    fn uuid_helper_detects_matching_pairing_ids() {
        let items = [
            UuidItem {
                id: uuid::Uuid::from_u128(1),
            },
            UuidItem {
                id: uuid::Uuid::from_u128(2),
            },
        ];
        assert!(pairing_items_contains_uuid(
            items.iter(),
            uuid::Uuid::from_u128(1)
        ));
        assert!(!pairing_items_contains_uuid(
            items.iter(),
            uuid::Uuid::from_u128(3)
        ));
    }

    #[test]
    fn transition_helper_finds_state_for_matching_uuid() {
        let items = [
            UuidStateItem {
                id: uuid::Uuid::from_u128(1),
                state: InviteState::Pending,
            },
            UuidStateItem {
                id: uuid::Uuid::from_u128(2),
                state: InviteState::Rejected,
            },
        ];
        assert_eq!(
            pairing_items_transition_after_action(
                items.iter(),
                uuid::Uuid::from_u128(1),
                PairingAction::Cancel,
            ),
            Some(InviteState::Cancelled)
        );
        assert_eq!(
            pairing_items_transition_after_action(
                items.iter(),
                uuid::Uuid::from_u128(2),
                PairingAction::Cancel,
            ),
            None
        );
    }

    #[test]
    fn archive_helper_requires_matching_archivable_uuid() {
        let items = [
            UuidStateItem {
                id: uuid::Uuid::from_u128(1),
                state: InviteState::Accepted,
            },
            UuidStateItem {
                id: uuid::Uuid::from_u128(2),
                state: InviteState::Pending,
            },
        ];
        assert!(pairing_items_can_archive(
            items.iter(),
            uuid::Uuid::from_u128(1)
        ));
        assert!(!pairing_items_can_archive(
            items.iter(),
            uuid::Uuid::from_u128(2)
        ));
        assert!(!pairing_items_can_archive(
            items.iter(),
            uuid::Uuid::from_u128(3)
        ));
    }

    #[test]
    fn expire_pairing_items_updates_only_pending_expired_items() {
        let mut items = [
            ExpiryItem {
                state: InviteState::Pending,
                expires_at: 10,
            },
            ExpiryItem {
                state: InviteState::Accepted,
                expires_at: 10,
            },
        ];

        assert!(expire_pairing_items(&mut items, 11));
        assert_eq!(items[0].state, InviteState::Expired);
        assert_eq!(items[1].state, InviteState::Accepted);
    }

    #[derive(Clone)]
    struct IdItem {
        id: &'static str,
    }

    impl RuntimePairingIdLike for IdItem {
        fn runtime_pairing_id(&self) -> String {
            self.id.to_owned()
        }
    }

    impl RuntimePairingIdLike for &IdItem {
        fn runtime_pairing_id(&self) -> String {
            self.id.to_owned()
        }
    }

    #[derive(Clone, Copy)]
    struct UuidItem {
        id: uuid::Uuid,
    }

    impl RuntimePairingUuidLike for UuidItem {
        fn runtime_pairing_uuid(&self) -> uuid::Uuid {
            self.id
        }
    }

    impl RuntimePairingUuidLike for &UuidItem {
        fn runtime_pairing_uuid(&self) -> uuid::Uuid {
            self.id
        }
    }

    #[derive(Clone, Copy)]
    struct UuidStateItem {
        id: uuid::Uuid,
        state: InviteState,
    }

    impl RuntimePairingUuidLike for UuidStateItem {
        fn runtime_pairing_uuid(&self) -> uuid::Uuid {
            self.id
        }
    }

    impl RuntimePairingUuidLike for &UuidStateItem {
        fn runtime_pairing_uuid(&self) -> uuid::Uuid {
            self.id
        }
    }

    impl RuntimePairingStateLike for UuidStateItem {
        fn runtime_pairing_state(&self) -> InviteState {
            self.state
        }
    }

    impl RuntimePairingStateLike for &UuidStateItem {
        fn runtime_pairing_state(&self) -> InviteState {
            self.state
        }
    }

    #[test]
    fn merge_invite_state_keeps_terminal_local_state() {
        assert_eq!(
            merge_invite_state(crate::InviteState::Accepted, crate::InviteState::Pending),
            crate::InviteState::Accepted
        );
        assert_eq!(
            merge_invite_state(crate::InviteState::Pending, crate::InviteState::Rejected),
            crate::InviteState::Rejected
        );
        assert_eq!(
            merge_invite_state(crate::InviteState::Archived, crate::InviteState::Pending),
            crate::InviteState::Archived
        );
    }

    #[test]
    fn merge_pairing_item_preserves_local_artifacts() {
        let local = crate::PairingItem {
            pairing_id: "pairing-1".into(),
            sender: None,
            capability: Some(String::new()),
            expires_at: 10,
            state: crate::InviteState::Pending,
            received: false,
            available_actions: crate::pairing_available_actions(crate::InviteState::Pending, false),
            offer_invite_id: Some("invite-1".into()),
            offer_payload: Some("payload-1".into()),
        };
        let remote = crate::PairingItem {
            pairing_id: "pairing-1".into(),
            sender: Some(crate::ContactRecord {
                installation_id: "peer-1".into(),
                nickname: "Peer".into(),
                public_key: "pk".into(),
                fingerprint: "fp".into(),
                local_alias: None,
                muted: false,
                blocked: false,
                verification: crate::VerificationState::Unverified,
                dev: None,
            }),
            capability: Some("cap".into()),
            expires_at: 12,
            state: crate::InviteState::Accepted,
            received: true,
            available_actions: crate::pairing_available_actions(crate::InviteState::Accepted, true),
            offer_invite_id: None,
            offer_payload: None,
        };
        let merge = merge_pairing_item(Some(local), remote);
        assert!(!merge.inserted);
        assert!(merge.changed);
        assert_eq!(merge.item.expires_at, 12);
        assert_eq!(merge.item.offer_invite_id.as_deref(), Some("invite-1"));
        assert_eq!(merge.item.offer_payload.as_deref(), Some("payload-1"));
        assert!(merge.item.sender.is_some());
        assert_eq!(merge.item.state, crate::InviteState::Accepted);
    }

    #[test]
    fn merge_pairing_item_derives_actions_for_new_incoming_item() {
        let remote = crate::PairingItem {
            pairing_id: "pairing-1".into(),
            sender: Some(crate::ContactRecord {
                installation_id: "peer-1".into(),
                nickname: "Peer".into(),
                public_key: "pk".into(),
                fingerprint: "fp".into(),
                local_alias: None,
                muted: false,
                blocked: false,
                verification: crate::VerificationState::Unverified,
                dev: None,
            }),
            capability: Some("chat".into()),
            expires_at: 12,
            state: crate::InviteState::Pending,
            received: true,
            available_actions: Vec::new(),
            offer_invite_id: None,
            offer_payload: None,
        };

        let merge = merge_pairing_item(None, remote);

        assert!(merge.inserted);
        assert_eq!(
            merge.item.available_actions,
            vec![
                crate::PairingAvailableAction::Accept,
                crate::PairingAvailableAction::Reject
            ]
        );
    }

    #[test]
    fn merge_pairing_item_refreshes_actions_after_state_merge() {
        let local = crate::PairingItem {
            pairing_id: "pairing-1".into(),
            sender: None,
            capability: Some("chat".into()),
            expires_at: 10,
            state: crate::InviteState::Pending,
            received: false,
            available_actions: Vec::new(),
            offer_invite_id: None,
            offer_payload: None,
        };
        let remote = crate::PairingItem {
            pairing_id: "pairing-1".into(),
            sender: None,
            capability: Some("chat".into()),
            expires_at: 12,
            state: crate::InviteState::Rejected,
            received: false,
            available_actions: Vec::new(),
            offer_invite_id: None,
            offer_payload: None,
        };

        let merge = merge_pairing_item(Some(local), remote);

        assert_eq!(merge.item.state, crate::InviteState::Rejected);
        assert_eq!(
            merge.item.available_actions,
            vec![crate::PairingAvailableAction::Archive]
        );
    }

    #[test]
    fn transition_pairing_record_updates_matching_item() {
        let pairing_id = uuid::Uuid::from_u128(1);
        let mut items = [
            TransitionItem {
                id: pairing_id,
                state: InviteState::Pending,
            },
            TransitionItem {
                id: uuid::Uuid::from_u128(2),
                state: InviteState::Rejected,
            },
        ];

        assert!(transition_pairing_record(&mut items, pairing_id, PairingAction::Cancel).unwrap());
        assert_eq!(items[0].state, InviteState::Cancelled);
    }

    #[test]
    fn transition_pairing_record_reports_missing_item() {
        let mut items = [TransitionItem {
            id: uuid::Uuid::from_u128(1),
            state: InviteState::Pending,
        }];

        assert_eq!(
            transition_pairing_record(&mut items, uuid::Uuid::from_u128(2), PairingAction::Cancel)
                .unwrap_err(),
            RuntimePairingTransitionError::NotFound
        );
    }
}
