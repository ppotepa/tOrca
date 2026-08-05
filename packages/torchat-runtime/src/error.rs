use std::fmt;

use serde::{Deserialize, Serialize};

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

#[derive(Debug, Clone, Copy, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RuntimeErrorCode {
    InvalidInput,
    NotFound,
    Conflict,
    TemporarilyUnavailable,
    TransportUnavailable,
    StorageFailed,
    CryptoFailed,
    Unsupported,
    Internal,
}

#[derive(Debug, Clone, Copy, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RuntimeErrorCategory {
    Validation,
    Domain,
    Transport,
    Persistence,
    Security,
    Availability,
    Internal,
}

#[derive(Debug, Clone, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RuntimeProblem {
    pub code: RuntimeErrorCode,
    pub category: RuntimeErrorCategory,
    pub retryable: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub operation_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub entity_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub diagnostic_context: Option<String>,
}

impl RuntimeProblem {
    pub fn from_error(error: &RuntimeError) -> Self {
        let (code, category, retryable) = match error {
            RuntimeError::InvalidCommand(_) | RuntimeError::InvalidParams(_) => (
                RuntimeErrorCode::InvalidInput,
                RuntimeErrorCategory::Validation,
                false,
            ),
            RuntimeError::NotFound(_) => (
                RuntimeErrorCode::NotFound,
                RuntimeErrorCategory::Domain,
                false,
            ),
            RuntimeError::Conflict(_) => (
                RuntimeErrorCode::Conflict,
                RuntimeErrorCategory::Domain,
                false,
            ),
            RuntimeError::Timeout(_) => (
                RuntimeErrorCode::TemporarilyUnavailable,
                RuntimeErrorCategory::Availability,
                true,
            ),
            RuntimeError::Transport(_) => (
                RuntimeErrorCode::TransportUnavailable,
                RuntimeErrorCategory::Transport,
                true,
            ),
            RuntimeError::Storage(_) => (
                RuntimeErrorCode::StorageFailed,
                RuntimeErrorCategory::Persistence,
                false,
            ),
            RuntimeError::Crypto(_) => (
                RuntimeErrorCode::CryptoFailed,
                RuntimeErrorCategory::Security,
                false,
            ),
            RuntimeError::Unavailable(_) => (
                RuntimeErrorCode::TemporarilyUnavailable,
                RuntimeErrorCategory::Availability,
                true,
            ),
        };
        Self {
            code,
            category,
            retryable,
            operation_id: None,
            entity_id: None,
            diagnostic_context: Some(error.technical_message()),
        }
    }

    pub fn with_operation_id(mut self, operation_id: impl Into<String>) -> Self {
        self.operation_id = Some(operation_id.into());
        self
    }

    pub fn with_entity_id(mut self, entity_id: impl Into<String>) -> Self {
        self.entity_id = Some(entity_id.into());
        self
    }

    pub fn without_diagnostics(mut self) -> Self {
        self.diagnostic_context = None;
        self
    }
}

impl RuntimeError {
    pub fn technical_message(&self) -> String {
        self.to_string()
    }

    pub fn problem(&self) -> RuntimeProblem {
        RuntimeProblem::from_error(self)
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
