UPDATE messages SET state = 'QUEUED' WHERE UPPER(state) = 'PENDING';
UPDATE messages SET state = 'DELIVERED' WHERE UPPER(state) = 'RECEIVED';

UPDATE conversations SET status = 'PENDING' WHERE UPPER(status) = 'NEW';

UPDATE pairing_inbox SET state = 'CANCELLED' WHERE UPPER(state) = 'CANCELED';
UPDATE pairing_outbox SET state = 'CANCELLED' WHERE UPPER(state) = 'CANCELED';
