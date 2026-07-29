package org.torchat.data

import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

class AndroidSqlMigrationAssetsTest {
    private val sqlRoot: File
        get() {
            val candidates = listOf(
                File("src/main/assets/sql"),
                File("app/src/main/assets/sql"),
            )
            return candidates.firstOrNull { it.isDirectory }
                ?: error("Android SQL asset root not found from ${File(".").absolutePath}")
        }

    @Test
    fun canonical_state_migration_removes_legacy_aliases_from_storage_rows() {
        val migration = sqlRoot.resolve("migrations/006_canonical_state_values.sql").readText()

        assertTrue(migration.contains("PENDING"))
        assertTrue(migration.contains("QUEUED"))
        assertTrue(migration.contains("RECEIVED"))
        assertTrue(migration.contains("DELIVERED"))
        assertTrue(migration.contains("NEW"))
        assertTrue(migration.contains("CANCELED"))
        assertTrue(migration.contains("CANCELLED"))
    }

    @Test
    fun expiry_migration_converts_millis_to_seconds_for_pairing_tables() {
        val migration = sqlRoot.resolve("migrations/007_expiry_seconds.sql").readText()

        assertTrue(migration.contains("pairing_inbox"))
        assertTrue(migration.contains("pairing_outbox"))
        assertTrue(migration.contains("expires_at = expires_at / 1000"))
        assertTrue(migration.contains("expires_at > 9999999999"))
    }
}
