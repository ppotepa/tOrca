ALTER TABLE messages ADD COLUMN claimed_until INTEGER;
ALTER TABLE messages ADD COLUMN last_error_code TEXT;
ALTER TABLE messages ADD COLUMN dead_lettered_at INTEGER;

ALTER TABLE outbound_deliveries ADD COLUMN claimed_until INTEGER;
ALTER TABLE outbound_deliveries ADD COLUMN last_error_code TEXT;
ALTER TABLE outbound_deliveries ADD COLUMN dead_lettered_at INTEGER;

ALTER TABLE delivery_receipts ADD COLUMN claimed_until INTEGER;
ALTER TABLE delivery_receipts ADD COLUMN last_error_code TEXT;
ALTER TABLE delivery_receipts ADD COLUMN dead_lettered_at INTEGER;
