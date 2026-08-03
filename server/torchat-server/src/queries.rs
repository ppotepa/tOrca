pub(crate) const SQL_INSTALLATION_NICKNAME: &str =
    include_str!("../sql/queries/installation_nickname.sql");
pub(crate) const SQL_INSTALLATION_UPSERT: &str =
    include_str!("../sql/queries/installation_upsert.sql");
pub(crate) const SQL_INSTALLATION_PROFILE: &str =
    include_str!("../sql/queries/installation_profile.sql");
pub(crate) const SQL_PROFILE_UPDATE_NICKNAME: &str =
    include_str!("../sql/queries/profile_update_nickname.sql");
pub(crate) const SQL_PAIRING_CODE_DELETE_FOR_INSTALLATION: &str =
    include_str!("../sql/queries/pairing_code_delete_for_installation.sql");
pub(crate) const SQL_PAIRING_CODE_INSERT: &str =
    include_str!("../sql/queries/pairing_code_insert.sql");
pub(crate) const SQL_PAIRING_CODE_LOOKUP: &str =
    include_str!("../sql/queries/pairing_code_lookup.sql");
pub(crate) const SQL_PAIRING_CODE_CONSUME: &str =
    include_str!("../sql/queries/pairing_code_consume.sql");
pub(crate) const SQL_PAIRING_REQUEST_LOOKUP: &str =
    include_str!("../sql/queries/pairing_request_lookup.sql");
pub(crate) const SQL_PAIRING_REQUEST_INSERT: &str =
    include_str!("../sql/queries/pairing_request_insert.sql");
pub(crate) const SQL_PAIRING_INBOX_LIST: &str =
    include_str!("../sql/queries/pairing_inbox_list.sql");
pub(crate) const SQL_PAIRING_REQUEST_ACK: &str =
    include_str!("../sql/queries/pairing_request_ack.sql");
pub(crate) const SQL_PAIRING_REQUEST_CANCEL: &str =
    include_str!("../sql/queries/pairing_request_cancel.sql");
pub(crate) const SQL_CONTACTS_CONFIRM: &str = include_str!("../sql/queries/contacts_confirm.sql");
pub(crate) const SQL_CONTACTS_LIST: &str = include_str!("../sql/queries/contacts_list.sql");
pub(crate) const SQL_CONTACT_DELETE: &str = include_str!("../sql/queries/contact_delete.sql");
pub(crate) const SQL_SESSION_AUTHORIZE: &str = include_str!("../sql/queries/session_authorize.sql");
pub(crate) const SQL_SESSION_INSERT: &str = include_str!("../sql/queries/session_insert.sql");
