UPDATE messages
SET state = 'QUEUED'
WHERE UPPER(TRIM(state)) = 'PENDING';

UPDATE messages
SET state = 'DELIVERED'
WHERE UPPER(TRIM(state)) = 'RECEIVED';

UPDATE conversations
SET status = 'PENDING'
WHERE UPPER(TRIM(status)) = 'NEW';
