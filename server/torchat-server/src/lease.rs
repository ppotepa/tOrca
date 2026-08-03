use std::time::Duration;
use tokio_postgres::Client;
use uuid::Uuid;

#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) struct ConnectionLease {
    pub(crate) instance_id: Uuid,
    pub(crate) connection_id: Uuid,
    pub(crate) expires_at: u64,
}

impl ConnectionLease {
    pub(crate) fn new(instance_id: Uuid, connection_id: Uuid, now: u64, ttl: Duration) -> Self {
        Self {
            instance_id,
            connection_id,
            expires_at: now.saturating_add(ttl.as_secs()),
        }
    }

    #[allow(dead_code)]
    pub(crate) fn renew(&mut self, now: u64, ttl: Duration) {
        self.expires_at = now.saturating_add(ttl.as_secs());
    }

    #[allow(dead_code)]
    pub(crate) fn is_active(&self, now: u64) -> bool {
        self.expires_at > now
    }
}

pub(crate) async fn acquire_shared_lease(
    db: &Client,
    installation_id: &str,
    instance_id: Uuid,
    connection_id: Uuid,
    now: u64,
    ttl: Duration,
) -> Result<bool, tokio_postgres::Error> {
    let changed = db
        .execute(
            "INSERT INTO connection_leases
                 (installation_id, instance_id, connection_id, expires_at)
             VALUES ($1, $2, $3, $4)
             ON CONFLICT (installation_id) DO UPDATE
             SET instance_id = EXCLUDED.instance_id,
                 connection_id = EXCLUDED.connection_id,
                 expires_at = EXCLUDED.expires_at,
                 updated_at = NOW()
             WHERE connection_leases.expires_at <= $5
                OR connection_leases.instance_id = $2
                OR connection_leases.connection_id = $3",
            &[
                &installation_id,
                &instance_id,
                &connection_id,
                &(now.saturating_add(ttl.as_secs()) as i64),
                &(now as i64),
            ],
        )
        .await?;
    Ok(changed == 1)
}

pub(crate) async fn release_shared_lease(
    db: &Client,
    installation_id: &str,
    instance_id: Uuid,
    connection_id: Uuid,
) -> Result<(), tokio_postgres::Error> {
    db.execute(
        "DELETE FROM connection_leases
         WHERE installation_id = $1 AND instance_id = $2 AND connection_id = $3",
        &[&installation_id, &instance_id, &connection_id],
    )
    .await?;
    Ok(())
}

pub(crate) async fn active_shared_lease(
    db: &Client,
    installation_id: &str,
    now: u64,
) -> Result<Option<ConnectionLease>, tokio_postgres::Error> {
    let row = db
        .query_opt(
            "SELECT instance_id, connection_id, expires_at
             FROM connection_leases
             WHERE installation_id = $1 AND expires_at > $2",
            &[&installation_id, &(now as i64)],
        )
        .await?;
    Ok(row.map(|row| ConnectionLease {
        instance_id: row.get(0),
        connection_id: row.get(1),
        expires_at: row.get::<_, i64>(2) as u64,
    }))
}

#[allow(dead_code, clippy::too_many_arguments)]
pub(crate) async fn publish_route(
    db: &Client,
    route_id: Uuid,
    installation_id: &str,
    instance_id: Uuid,
    connection_id: Uuid,
    payload: &[u8],
    created_at: u64,
    expires_at: u64,
) -> Result<(), tokio_postgres::Error> {
    db.execute(
        "INSERT INTO connection_route_stream
             (route_id, installation_id, instance_id, connection_id,
              payload, created_at, expires_at)
         VALUES ($1, $2, $3, $4, $5, $6, $7)
         ON CONFLICT (route_id) DO NOTHING",
        &[
            &route_id,
            &installation_id,
            &instance_id,
            &connection_id,
            &payload,
            &(created_at as i64),
            &(expires_at as i64),
        ],
    )
    .await?;
    Ok(())
}

#[allow(dead_code)]
pub(crate) async fn claim_route(
    db: &Client,
    installation_id: &str,
    instance_id: Uuid,
    now: u64,
    claim_ttl: Duration,
) -> Result<Option<(Uuid, Vec<u8>)>, tokio_postgres::Error> {
    let row = db
        .query_opt(
            "WITH candidate AS (
                 SELECT route_id
                 FROM connection_route_stream
                 WHERE installation_id = $1
                   AND expires_at > $2
                   AND (claimed_until IS NULL OR claimed_until <= $2)
                 ORDER BY created_at, route_id
                 FOR UPDATE SKIP LOCKED
                 LIMIT 1
             )
             UPDATE connection_route_stream route
             SET claimed_by = $3, claimed_until = $4
             FROM candidate
             WHERE route.route_id = candidate.route_id
             RETURNING route.route_id, route.payload",
            &[
                &installation_id,
                &(now as i64),
                &instance_id,
                &(now.saturating_add(claim_ttl.as_secs()) as i64),
            ],
        )
        .await?;
    row.map(|value| Ok((value.get(0), value.get(1))))
        .transpose()
}

pub(crate) async fn complete_route(
    db: &Client,
    route_id: Uuid,
    instance_id: Uuid,
) -> Result<(), tokio_postgres::Error> {
    db.execute(
        "DELETE FROM connection_route_stream WHERE route_id = $1 AND claimed_by = $2",
        &[&route_id, &instance_id],
    )
    .await?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn lease_expires_and_renewal_extends_owner_window() {
        let instance = Uuid::from_u128(1);
        let connection = Uuid::from_u128(2);
        let mut lease = ConnectionLease::new(instance, connection, 100, Duration::from_secs(30));
        assert!(lease.is_active(129));
        assert!(!lease.is_active(130));
        lease.renew(130, Duration::from_secs(30));
        assert!(lease.is_active(159));
        assert!(!lease.is_active(160));
        assert_eq!(lease.instance_id, instance);
        assert_eq!(lease.connection_id, connection);
    }
}
