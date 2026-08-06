INSERT INTO messages (id, conversation_id, sender_id, body, state)
VALUES (?1, ?2, ?3, ?4, ?5)
ON CONFLICT(id) DO UPDATE SET
  conversation_id=excluded.conversation_id,
  sender_id=excluded.sender_id,
  body=excluded.body,
  state=excluded.state;
