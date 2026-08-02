-- P2P is the product default for every contact. Migration 008 intentionally
-- kept existing contacts on RELAY_ONLY while the peer endpoint rollout settled;
-- normalize that transitional default now. Users can still opt into relay
-- fallback or relay-only explicitly from contact settings.
UPDATE contacts
SET transport_policy = 'PEER_ONLY'
WHERE transport_policy IS NULL
   OR transport_policy = 'RELAY_ONLY';
