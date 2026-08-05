use std::fmt;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum RelayUnavailableReason {
    ActorNotAttached,
}

impl fmt::Display for RelayUnavailableReason {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::ActorNotAttached => f.write_str("engine relay actor is not attached"),
        }
    }
}
