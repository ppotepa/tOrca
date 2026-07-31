use std::collections::BTreeSet;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum OnionRotationState {
    Idle,
    StoppingPrevious,
    Creating,
    Publishing,
    Distributing,
    WaitingForConfirmations,
    Completed,
    Failed,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum OnionRotationEvent {
    Requested { contacts: BTreeSet<String> },
    PreviousStopped { generation: u64 },
    ServiceCreated { generation: u64 },
    Published { generation: u64 },
    DistributionQueued { generation: u64 },
    ContactConfirmed { generation: u64, contact_id: String },
    Timeout { generation: u64 },
    Failed { generation: u64, reason: String },
    Reset,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum OnionRotationAction {
    StopPrevious { generation: u64 },
    ConfigureOnion { generation: u64 },
    PublishEndpoint { generation: u64 },
    EnqueueEndpointDistribution {
        generation: u64,
        contacts: BTreeSet<String>,
    },
    ScheduleTimeout { generation: u64 },
    Complete { generation: u64 },
    NotifyFailure { generation: u64, reason: String },
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum OnionRotationApply {
    Applied(Vec<OnionRotationAction>),
    IgnoredStale,
    Invalid,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct OnionRotationProcess {
    pub state: OnionRotationState,
    pub generation: u64,
    pub expected_contacts: BTreeSet<String>,
    pub confirmed_contacts: BTreeSet<String>,
    pub last_error: Option<String>,
}

impl Default for OnionRotationProcess {
    fn default() -> Self {
        Self {
            state: OnionRotationState::Idle,
            generation: 0,
            expected_contacts: BTreeSet::new(),
            confirmed_contacts: BTreeSet::new(),
            last_error: None,
        }
    }
}

impl OnionRotationProcess {
    pub fn apply(&mut self, event: OnionRotationEvent) -> OnionRotationApply {
        use OnionRotationAction as Action;
        use OnionRotationApply as Apply;
        use OnionRotationEvent as Event;
        use OnionRotationState as State;

        match event {
            Event::Reset => {
                let generation = self.generation;
                *self = Self::default();
                self.generation = generation;
                Apply::Applied(Vec::new())
            }
            Event::Requested { contacts } => {
                if !matches!(self.state, State::Idle | State::Completed | State::Failed) {
                    return Apply::Invalid;
                }
                self.generation = self.generation.saturating_add(1);
                self.expected_contacts = contacts;
                self.confirmed_contacts.clear();
                self.last_error = None;
                self.state = State::StoppingPrevious;
                Apply::Applied(vec![Action::StopPrevious {
                    generation: self.generation,
                }])
            }
            Event::PreviousStopped { generation } => {
                if generation != self.generation {
                    return Apply::IgnoredStale;
                }
                if self.state != State::StoppingPrevious {
                    return Apply::Invalid;
                }
                self.state = State::Creating;
                Apply::Applied(vec![Action::ConfigureOnion { generation }])
            }
            Event::ServiceCreated { generation } => {
                if generation != self.generation {
                    return Apply::IgnoredStale;
                }
                if self.state != State::Creating {
                    return Apply::Invalid;
                }
                self.state = State::Publishing;
                Apply::Applied(vec![Action::PublishEndpoint { generation }])
            }
            Event::Published { generation } => {
                if generation != self.generation {
                    return Apply::IgnoredStale;
                }
                if self.state != State::Publishing {
                    return Apply::Invalid;
                }
                self.state = State::Distributing;
                Apply::Applied(vec![Action::EnqueueEndpointDistribution {
                    generation,
                    contacts: self.expected_contacts.clone(),
                }])
            }
            Event::DistributionQueued { generation } => {
                if generation != self.generation {
                    return Apply::IgnoredStale;
                }
                if self.state != State::Distributing {
                    return Apply::Invalid;
                }
                if self.expected_contacts.is_empty() {
                    self.state = State::Completed;
                    Apply::Applied(vec![Action::Complete { generation }])
                } else {
                    self.state = State::WaitingForConfirmations;
                    Apply::Applied(vec![Action::ScheduleTimeout { generation }])
                }
            }
            Event::ContactConfirmed {
                generation,
                contact_id,
            } => {
                if generation != self.generation {
                    return Apply::IgnoredStale;
                }
                if self.state != State::WaitingForConfirmations {
                    return Apply::Invalid;
                }
                if self.expected_contacts.contains(&contact_id) {
                    self.confirmed_contacts.insert(contact_id);
                }
                if self.confirmed_contacts == self.expected_contacts {
                    self.state = State::Completed;
                    Apply::Applied(vec![Action::Complete { generation }])
                } else {
                    Apply::Applied(Vec::new())
                }
            }
            Event::Timeout { generation } => {
                if generation != self.generation {
                    return Apply::IgnoredStale;
                }
                let reason = "onion endpoint confirmation timed out".to_owned();
                self.state = State::Failed;
                self.last_error = Some(reason.clone());
                Apply::Applied(vec![Action::NotifyFailure { generation, reason }])
            }
            Event::Failed { generation, reason } => {
                if generation != self.generation {
                    return Apply::IgnoredStale;
                }
                self.state = State::Failed;
                self.last_error = Some(reason.clone());
                Apply::Applied(vec![Action::NotifyFailure { generation, reason }])
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn contacts() -> BTreeSet<String> {
        ["alice".to_owned(), "bob".to_owned()]
            .into_iter()
            .collect()
    }

    #[test]
    fn rotation_completes_after_all_contact_confirmations() {
        let mut process = OnionRotationProcess::default();
        process.apply(OnionRotationEvent::Requested {
            contacts: contacts(),
        });
        process.apply(OnionRotationEvent::PreviousStopped { generation: 1 });
        process.apply(OnionRotationEvent::ServiceCreated { generation: 1 });
        process.apply(OnionRotationEvent::Published { generation: 1 });
        process.apply(OnionRotationEvent::DistributionQueued { generation: 1 });
        process.apply(OnionRotationEvent::ContactConfirmed {
            generation: 1,
            contact_id: "alice".to_owned(),
        });
        let result = process.apply(OnionRotationEvent::ContactConfirmed {
            generation: 1,
            contact_id: "bob".to_owned(),
        });

        assert_eq!(process.state, OnionRotationState::Completed);
        assert_eq!(
            result,
            OnionRotationApply::Applied(vec![OnionRotationAction::Complete { generation: 1 }])
        );
    }

    #[test]
    fn stale_generation_cannot_complete_new_rotation() {
        let mut process = OnionRotationProcess::default();
        process.apply(OnionRotationEvent::Requested {
            contacts: BTreeSet::new(),
        });
        process.apply(OnionRotationEvent::Reset);
        process.apply(OnionRotationEvent::Requested {
            contacts: BTreeSet::new(),
        });

        assert_eq!(process.generation, 2);
        assert_eq!(
            process.apply(OnionRotationEvent::PreviousStopped { generation: 1 }),
            OnionRotationApply::IgnoredStale
        );
    }
}
