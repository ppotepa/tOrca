use std::fmt;

#[derive(Debug, Clone, Eq, PartialEq)]
pub enum RuntimeError {
    InvalidCommand(String),
    InvalidParams(String),
    NotFound(String),
    Conflict(String),
    Timeout(String),
    Transport(String),
    Storage(String),
    Crypto(String),
    Unavailable(String),
}

impl RuntimeError {
    pub fn technical_message(&self) -> String {
        self.to_string()
    }
}

impl fmt::Display for RuntimeError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::InvalidCommand(message)
            | Self::InvalidParams(message)
            | Self::NotFound(message)
            | Self::Conflict(message)
            | Self::Timeout(message)
            | Self::Transport(message)
            | Self::Storage(message)
            | Self::Crypto(message)
            | Self::Unavailable(message) => write!(f, "{message}"),
        }
    }
}

impl std::error::Error for RuntimeError {}

impl From<serde_json::Error> for RuntimeError {
    fn from(error: serde_json::Error) -> Self {
        Self::InvalidParams(error.to_string())
    }
}

pub type RuntimeResult<T> = Result<T, RuntimeError>;
