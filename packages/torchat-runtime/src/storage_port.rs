use crate::{
    CapabilityStorage, ContactStorage, ConversationStorage, DeliveryStorage, IdentityStorage,
    MessageStorage, OperationStorage, PairingStorage, PointLookupStorage, ProfileStorage,
    ReceiptStorage, RelationshipStorage,
};

/// Canonical composite boundary for infrastructure code that genuinely needs
/// access to the complete persistence surface.
///
/// Domain features should prefer the narrow capability traits directly. This
/// trait exists for composition roots and transactional adapters, replacing
/// direct dependencies on the transitional `RuntimeStorage` aggregate.
pub trait RuntimeStoragePort:
    IdentityStorage
    + ProfileStorage
    + PairingStorage
    + ContactStorage
    + RelationshipStorage
    + ConversationStorage
    + MessageStorage
    + ReceiptStorage
    + DeliveryStorage
    + CapabilityStorage
    + PointLookupStorage
    + OperationStorage
{
}

impl<T> RuntimeStoragePort for T where
    T: IdentityStorage
        + ProfileStorage
        + PairingStorage
        + ContactStorage
        + RelationshipStorage
        + ConversationStorage
        + MessageStorage
        + ReceiptStorage
        + DeliveryStorage
        + CapabilityStorage
        + PointLookupStorage
        + OperationStorage
{
}
