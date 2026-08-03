pub(crate) const SQL_INSTALLATION_NICKNAME: &str =
    include_str!("../sql/queries/installation_nickname.sql");
pub(crate) const SQL_FIND_BY_NORMALIZED_NICKNAME: &str =
    include_str!("../sql/queries/installations/find_by_normalized_nickname.sql");
pub(crate) const SQL_TRY_ADVISORY_LOCK: &str =
    include_str!("../sql/queries/instance/try_advisory_lock.sql");
pub(crate) const SQL_RENEW_LEASE: &str = include_str!("../sql/commands/leases/renew.sql");
pub(crate) const SQL_INSTALLATION_UPSERT: &str =
    include_str!("../sql/commands/installations/upsert.sql");
pub(crate) const SQL_INSTALLATION_PROFILE: &str =
    include_str!("../sql/queries/installation_profile.sql");
pub(crate) const SQL_PROFILE_UPDATE_NICKNAME: &str =
    include_str!("../sql/commands/installations/update_nickname.sql");
pub(crate) const SQL_PAIRING_CODE_DELETE_FOR_INSTALLATION: &str =
    include_str!("../sql/commands/pairing/delete_code_for_installation.sql");
pub(crate) const SQL_PAIRING_CODE_INSERT: &str =
    include_str!("../sql/commands/pairing/insert_code.sql");
pub(crate) const SQL_PAIRING_CODE_LOOKUP: &str =
    include_str!("../sql/queries/pairing_code_lookup.sql");
pub(crate) const SQL_PAIRING_CODE_CONSUME: &str =
    include_str!("../sql/commands/pairing/consume_code.sql");
pub(crate) const SQL_PAIRING_REQUEST_LOOKUP: &str =
    include_str!("../sql/queries/pairing_request_lookup.sql");
pub(crate) const SQL_PAIRING_REQUEST_INSERT: &str =
    include_str!("../sql/commands/pairing/insert_request.sql");
pub(crate) const SQL_PAIRING_INBOX_LIST: &str =
    include_str!("../sql/queries/pairing_inbox_list.sql");
pub(crate) const SQL_PAIRING_REQUEST_ACK: &str =
    include_str!("../sql/commands/pairing/ack_request.sql");
pub(crate) const SQL_PAIRING_REQUEST_CANCEL: &str =
    include_str!("../sql/commands/pairing/cancel_request.sql");
pub(crate) const SQL_CONTACTS_CONFIRM: &str = include_str!("../sql/commands/contacts/confirm.sql");
pub(crate) const SQL_CONTACTS_LIST: &str = include_str!("../sql/queries/contacts_list.sql");
pub(crate) const SQL_CONTACT_DELETE: &str = include_str!("../sql/commands/contacts/delete.sql");
pub(crate) const SQL_SESSION_AUTHORIZE: &str = include_str!("../sql/queries/session_authorize.sql");
pub(crate) const SQL_SESSION_INSERT: &str = include_str!("../sql/commands/sessions/insert.sql");
pub(crate) const SQL_LEASE_ACQUIRE: &str = include_str!("../sql/commands/leases/acquire.sql");
pub(crate) const SQL_LEASE_RELEASE: &str = include_str!("../sql/commands/leases/release.sql");
pub(crate) const SQL_LEASE_GET_ACTIVE: &str = include_str!("../sql/queries/leases/get_active.sql");
pub(crate) const SQL_ROUTE_PUBLISH: &str = include_str!("../sql/commands/leases/publish_route.sql");
pub(crate) const SQL_ROUTE_CLAIM: &str = include_str!("../sql/queries/leases/claim_route.sql");
pub(crate) const SQL_ROUTE_COMPLETE: &str =
    include_str!("../sql/commands/leases/complete_route.sql");
