#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum QueueClass {
    Critical,
    Acknowledgement,
    Message,
    Pairing,
    Endpoint,
    Projection,
    Ephemeral,
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct QueuePressure {
    pub command_depth: usize,
    pub worker_outcome_depth: usize,
    pub delivery_due: usize,
    pub projection_depth: usize,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum BackpressureDecision {
    Accept,
    Conflate,
    PersistOnly,
    RejectBusy,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct BackpressurePolicy {
    pub command_high_watermark: usize,
    pub worker_high_watermark: usize,
    pub delivery_high_watermark: usize,
    pub projection_high_watermark: usize,
}

impl Default for BackpressurePolicy {
    fn default() -> Self {
        Self {
            command_high_watermark: 48,
            worker_high_watermark: 192,
            delivery_high_watermark: 1_000,
            projection_high_watermark: 192,
        }
    }
}

impl BackpressurePolicy {
    pub fn decide(
        self,
        class: QueueClass,
        pressure: QueuePressure,
    ) -> BackpressureDecision {
        if class == QueueClass::Critical {
            return BackpressureDecision::Accept;
        }
        let command_busy = pressure.command_depth >= self.command_high_watermark;
        let worker_busy = pressure.worker_outcome_depth >= self.worker_high_watermark;
        let delivery_busy = pressure.delivery_due >= self.delivery_high_watermark;
        let projection_busy = pressure.projection_depth >= self.projection_high_watermark;
        let overloaded = command_busy || worker_busy || delivery_busy || projection_busy;

        if !overloaded {
            return BackpressureDecision::Accept;
        }
        match class {
            QueueClass::Ephemeral | QueueClass::Projection => BackpressureDecision::Conflate,
            QueueClass::Acknowledgement
            | QueueClass::Message
            | QueueClass::Pairing
            | QueueClass::Endpoint => BackpressureDecision::PersistOnly,
            QueueClass::Critical => BackpressureDecision::Accept,
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct PriorityBudget {
    acknowledgements: usize,
    messages: usize,
    pairing: usize,
    endpoints: usize,
}

impl Default for PriorityBudget {
    fn default() -> Self {
        Self {
            acknowledgements: 8,
            messages: 8,
            pairing: 4,
            endpoints: 4,
        }
    }
}

impl PriorityBudget {
    pub fn take(&mut self, class: QueueClass) -> bool {
        let remaining = match class {
            QueueClass::Acknowledgement => &mut self.acknowledgements,
            QueueClass::Message => &mut self.messages,
            QueueClass::Pairing => &mut self.pairing,
            QueueClass::Endpoint => &mut self.endpoints,
            QueueClass::Critical | QueueClass::Projection | QueueClass::Ephemeral => return true,
        };
        if *remaining == 0 {
            return false;
        }
        *remaining -= 1;
        true
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ConflatedValue<T> {
    value: Option<T>,
}

impl<T> Default for ConflatedValue<T> {
    fn default() -> Self {
        Self { value: None }
    }
}

impl<T> ConflatedValue<T> {
    pub fn publish(&mut self, value: T) {
        self.value = Some(value);
    }

    pub fn take(&mut self) -> Option<T> {
        self.value.take()
    }
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct DeadlineSet {
    pub delivery_retry_ms: Option<i64>,
    pub relay_heartbeat_ms: Option<i64>,
    pub relay_reconnect_ms: Option<i64>,
    pub acknowledgement_timeout_ms: Option<i64>,
    pub pairing_expiration_ms: Option<i64>,
    pub onion_rotation_timeout_ms: Option<i64>,
}

impl DeadlineSet {
    pub fn next_wakeup_ms(self) -> Option<i64> {
        [
            self.delivery_retry_ms,
            self.relay_heartbeat_ms,
            self.relay_reconnect_ms,
            self.acknowledgement_timeout_ms,
            self.pairing_expiration_ms,
            self.onion_rotation_timeout_ms,
        ]
        .into_iter()
        .flatten()
        .min()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn overload_conflates_ephemeral_but_persists_messages() {
        let policy = BackpressurePolicy::default();
        let pressure = QueuePressure {
            command_depth: 64,
            ..QueuePressure::default()
        };
        assert_eq!(
            policy.decide(QueueClass::Ephemeral, pressure),
            BackpressureDecision::Conflate
        );
        assert_eq!(
            policy.decide(QueueClass::Message, pressure),
            BackpressureDecision::PersistOnly
        );
        assert_eq!(
            policy.decide(QueueClass::Critical, pressure),
            BackpressureDecision::Accept
        );
    }

    #[test]
    fn conflated_value_keeps_only_latest_presence() {
        let mut value = ConflatedValue::default();
        value.publish(true);
        value.publish(false);
        assert_eq!(value.take(), Some(false));
        assert_eq!(value.take(), None);
    }

    #[test]
    fn deadline_set_selects_real_nearest_deadline() {
        let deadlines = DeadlineSet {
            delivery_retry_ms: Some(500),
            relay_heartbeat_ms: Some(100),
            onion_rotation_timeout_ms: Some(2_000),
            ..DeadlineSet::default()
        };
        assert_eq!(deadlines.next_wakeup_ms(), Some(100));
    }

    #[test]
    fn priority_budget_prevents_one_class_from_consuming_round() {
        let mut budget = PriorityBudget::default();
        for _ in 0..8 {
            assert!(budget.take(QueueClass::Message));
        }
        assert!(!budget.take(QueueClass::Message));
        assert!(budget.take(QueueClass::Acknowledgement));
        assert!(budget.take(QueueClass::Pairing));
    }
}
