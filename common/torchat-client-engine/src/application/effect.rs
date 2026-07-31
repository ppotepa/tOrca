use uuid::Uuid;

use crate::{NotificationRequest, PlatformAction};

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum EngineEffect {
    DispatchDelivery {
        delivery_id: Uuid,
    },
    PublishPlatformAction {
        action: PlatformAction,
    },
    PublishNotification {
        notification: NotificationRequest,
    },
    WakeRetryScheduler,
    WakeDeliveryScheduler,
    Noop,
}
