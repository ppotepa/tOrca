ALTER TABLE durable_operations
    ADD COLUMN command_descriptor TEXT;

UPDATE durable_operations
SET operation_type = 'pairing_cancellation'
WHERE operation_type = 'pairing'
  AND state IN ('pending', 'running', 'waiting_for_retry');
