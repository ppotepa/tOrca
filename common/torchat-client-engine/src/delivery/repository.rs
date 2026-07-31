use uuid::Uuid;

use crate::EngineResult;

use super::{DeliveryJob, DeliveryJobState};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct DeliveryLease {
    pub job_id: Uuid,
    pub lease_generation: u64,
    pub expires_at_ms: i64,
}

pub trait DeliveryJobRepository {
    type Transaction;

    fn enqueue(
        &mut self,
        transaction: &mut Self::Transaction,
        job: DeliveryJob,
    ) -> EngineResult<()>;

    fn due_deliveries(&self, now_ms: i64, limit: usize) -> EngineResult<Vec<DeliveryJob>>;

    fn acquire_lease(
        &mut self,
        transaction: &mut Self::Transaction,
        job_id: Uuid,
        lease_generation: u64,
        expires_at_ms: i64,
    ) -> EngineResult<Option<DeliveryLease>>;

    fn set_state(
        &mut self,
        transaction: &mut Self::Transaction,
        job_id: Uuid,
        state: DeliveryJobState,
        updated_at_ms: i64,
    ) -> EngineResult<()>;
}

#[cfg(test)]
mod tests {
    use std::collections::BTreeMap;

    use crate::{EngineError, EngineResult};

    use super::*;
    use crate::delivery::{
        AggregateType, DeliveryDurability, DeliveryKind,
    };

    #[derive(Default)]
    struct MemoryRepository {
        jobs: BTreeMap<Uuid, DeliveryJob>,
        idempotency: BTreeMap<String, Uuid>,
        leases: BTreeMap<Uuid, DeliveryLease>,
    }

    impl DeliveryJobRepository for MemoryRepository {
        type Transaction = ();

        fn enqueue(&mut self, _: &mut (), job: DeliveryJob) -> EngineResult<()> {
            if let Some(existing) = self.idempotency.get(&job.idempotency_key) {
                if *existing == job.job_id {
                    return Ok(());
                }
                return Err(EngineError::Storage(
                    "delivery idempotency conflict".to_owned(),
                ));
            }
            self.idempotency
                .insert(job.idempotency_key.clone(), job.job_id);
            self.jobs.insert(job.job_id, job);
            Ok(())
        }

        fn due_deliveries(&self, now_ms: i64, limit: usize) -> EngineResult<Vec<DeliveryJob>> {
            let mut jobs = self
                .jobs
                .values()
                .filter(|job| job.due(now_ms))
                .cloned()
                .collect::<Vec<_>>();
            jobs.sort_by_key(|job| (job.next_attempt_at, job.created_at));
            jobs.truncate(limit);
            Ok(jobs)
        }

        fn acquire_lease(
            &mut self,
            _: &mut (),
            job_id: Uuid,
            lease_generation: u64,
            expires_at_ms: i64,
        ) -> EngineResult<Option<DeliveryLease>> {
            if self.leases.contains_key(&job_id) {
                return Ok(None);
            }
            let lease = DeliveryLease {
                job_id,
                lease_generation,
                expires_at_ms,
            };
            self.leases.insert(job_id, lease);
            Ok(Some(lease))
        }

        fn set_state(
            &mut self,
            _: &mut (),
            job_id: Uuid,
            state: DeliveryJobState,
            updated_at_ms: i64,
        ) -> EngineResult<()> {
            let job = self
                .jobs
                .get_mut(&job_id)
                .ok_or_else(|| EngineError::Storage("delivery job missing".to_owned()))?;
            job.state = state;
            job.updated_at = updated_at_ms;
            Ok(())
        }
    }

    fn job(id: u128, key: &str) -> DeliveryJob {
        DeliveryJob {
            job_id: Uuid::from_u128(id),
            idempotency_key: key.to_owned(),
            aggregate_type: AggregateType::Message,
            aggregate_id: key.to_owned(),
            kind: DeliveryKind::Message,
            recipient_id: "peer".to_owned(),
            payload_reference: key.to_owned(),
            durability: DeliveryDurability::Persistent,
            state: DeliveryJobState::Queued,
            selected_route: None,
            attempt_count: 0,
            next_attempt_at: 1,
            ack_deadline: None,
            last_error: None,
            created_at: 1,
            updated_at: 1,
        }
    }

    #[test]
    fn repository_rejects_two_jobs_with_the_same_idempotency_key() {
        let mut repository = MemoryRepository::default();
        repository.enqueue(&mut (), job(1, "message:1")).unwrap();
        let error = repository
            .enqueue(&mut (), job(2, "message:1"))
            .unwrap_err();

        assert!(matches!(error, EngineError::Storage(_)));
    }

    #[test]
    fn lease_prevents_parallel_execution_of_one_job() {
        let mut repository = MemoryRepository::default();
        repository.enqueue(&mut (), job(1, "message:1")).unwrap();

        assert!(repository.acquire_lease(&mut (), Uuid::from_u128(1), 1, 100).unwrap().is_some());
        assert!(repository.acquire_lease(&mut (), Uuid::from_u128(1), 2, 200).unwrap().is_none());
    }
}
