use std::{error::Error, fmt};

pub type EngineResult<T> = Result<T, EngineError>;

#[derive(Debug, Clone, Eq, PartialEq)]
pub enum EngineError {
    Closed(&'static str),
    InvalidConfig(String),
    InvalidCommand(String),
    Serialization(String),
    Storage(String),
}

impl fmt::Display for EngineError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Closed(message) => write!(f, "{message}"),
            Self::InvalidConfig(message)
            | Self::InvalidCommand(message)
            | Self::Serialization(message)
            | Self::Storage(message) => f.write_str(message),
        }
    }
}

impl Error for EngineError {}

impl From<serde_json::Error> for EngineError {
    fn from(value: serde_json::Error) -> Self {
        Self::Serialization(value.to_string())
    }
}
