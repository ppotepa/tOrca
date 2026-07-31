use crate::EngineEvent;

use super::EngineEffect;

pub trait EffectExecutor {
    fn execute(&mut self, effect: EngineEffect) -> Option<EngineEvent>;

    fn execute_all(
        &mut self,
        effects: impl IntoIterator<Item = EngineEffect>,
    ) -> Vec<EngineEvent> {
        effects
            .into_iter()
            .filter_map(|effect| self.execute(effect))
            .collect()
    }
}

#[derive(Default)]
pub struct InlineEffectExecutor;

impl EffectExecutor for InlineEffectExecutor {
    fn execute(&mut self, effect: EngineEffect) -> Option<EngineEvent> {
        match effect {
            EngineEffect::PublishPlatformAction { action } => {
                Some(EngineEvent::PlatformAction { action })
            }
            EngineEffect::PublishNotification { notification } => {
                Some(EngineEvent::NotificationRequested { notification })
            }
            EngineEffect::DispatchDelivery { .. }
            | EngineEffect::WakeRetryScheduler
            | EngineEffect::WakeDeliveryScheduler
            | EngineEffect::Noop => None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::NotificationRequest;

    #[test]
    fn inline_executor_materializes_notification_effects() {
        let mut executor = InlineEffectExecutor;
        let event = executor.execute(EngineEffect::PublishNotification {
            notification: NotificationRequest {
                id: "notification-1".to_owned(),
                title: "TorChat".to_owned(),
                body: "New message".to_owned(),
                conversation_id: Some("conversation-1".to_owned()),
            },
        });

        assert!(matches!(event, Some(EngineEvent::NotificationRequested { .. })));
    }
}
