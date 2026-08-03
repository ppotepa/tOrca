DELETE FROM pending_application_envelopes
                 WHERE sender_installation_id = ?1 AND message_id = ?2;
