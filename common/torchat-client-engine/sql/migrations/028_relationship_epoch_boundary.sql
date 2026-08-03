-- Keep the relationship epoch after a tombstone is cleared by a fresh pairing.
ALTER TABLE relationship_boundaries
    ADD COLUMN relationship_epoch INTEGER NOT NULL DEFAULT 0;

UPDATE relationship_boundaries
SET relationship_epoch = COALESCE(
    (SELECT relationship_epoch
       FROM relationship_tombstones
      WHERE relationship_tombstones.contact_installation_id = relationship_boundaries.contact_installation_id),
    0
);
