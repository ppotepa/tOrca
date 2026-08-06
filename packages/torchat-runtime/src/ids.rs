use std::fmt;

use serde::{Deserialize, Serialize};

macro_rules! typed_id {
    ($name:ident) => {
        #[derive(Debug, Clone, Eq, PartialEq, Ord, PartialOrd, Hash, Serialize, Deserialize)]
        #[serde(transparent)]
        pub struct $name(String);

        impl $name {
            pub fn parse(value: impl Into<String>) -> Result<Self, crate::RuntimeError> {
                let value = value.into();
                if value.trim().is_empty() {
                    return Err(crate::RuntimeError::InvalidParams(
                        concat!(stringify!($name), " must not be empty").to_owned(),
                    ));
                }
                Ok(Self(value))
            }

            pub fn as_str(&self) -> &str {
                &self.0
            }

            pub fn into_string(self) -> String {
                self.0
            }
        }

        impl fmt::Display for $name {
            fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
                formatter.write_str(&self.0)
            }
        }

        impl AsRef<str> for $name {
            fn as_ref(&self) -> &str {
                self.as_str()
            }
        }
    };
}

typed_id!(InstallationId);
typed_id!(ContactId);
typed_id!(ConversationId);
typed_id!(MessageId);
typed_id!(PairingId);
typed_id!(CommandId);
typed_id!(OperationId);
typed_id!(RemovalId);
typed_id!(CapabilityId);
