package org.torchat.mobile

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

class RuntimeContractManifestTest {
    private fun manifest(): JSONObject {
        val candidates = listOf(
            File("../../common/client-runtime-contract.json"),
            File("../../../common/client-runtime-contract.json"),
        )
        val file = candidates.firstOrNull { it.isFile }
            ?: error("common/client-runtime-contract.json not found from ${File(".").absolutePath}")
        return JSONObject(file.readText())
    }

    private fun strings(json: JSONObject, key: String): List<String> {
        val array = json.getJSONArray(key)
        return (0 until array.length()).map { index -> array.getString(index) }
    }

    @Test
    fun runtime_contract_constants_match_shared_manifest() {
        val contract = manifest()
        val methods = contract.getJSONObject("methods")

        assertEquals(
            listOf(
                RuntimeContract.CONNECT,
                RuntimeContract.IDENTITY,
                RuntimeContract.PROFILE,
                RuntimeContract.SET_NICKNAME,
                RuntimeContract.REFRESH_PAIRING_CODE,
                RuntimeContract.SUBMIT_PAIRING_CODE,
                RuntimeContract.PAIRING_INBOX,
                RuntimeContract.PAIRING_OUTBOX,
                RuntimeContract.ACCEPT_PAIRING,
                RuntimeContract.REJECT_PAIRING,
                RuntimeContract.ARCHIVE_PAIRING,
                RuntimeContract.CANCEL_PAIRING,
                RuntimeContract.VERIFY_CONTACT,
                RuntimeContract.CONTACTS,
                RuntimeContract.CONVERSATIONS,
                RuntimeContract.MESSAGES,
                RuntimeContract.OPEN_CONVERSATION,
                RuntimeContract.CLOSE_CONVERSATION,
                RuntimeContract.START_CONVERSATION,
                RuntimeContract.SEND_MESSAGE,
            ),
            strings(methods, "public"),
        )

        val internal = strings(methods, "internal")
        assertTrue(internal.contains(RuntimeContract.BOOTSTRAP_RUNTIME))
        assertTrue(internal.contains(RuntimeContract.BOOTSTRAP_CONTACT))
        assertTrue(internal.contains(RuntimeContract.APPLY_MESSAGE_TRANSPORT_OUTCOME))
        assertTrue(internal.contains(RuntimeContract.APPLY_PAIRING_PEER_OUTCOME))

        assertEquals(
            listOf(
                RuntimeContract.RUNTIME_READY,
                RuntimeContract.TOR_STATUS,
                RuntimeContract.PROFILE_READY,
                RuntimeContract.INVITE_RECEIVED,
                RuntimeContract.INVITE_STATE_CHANGED,
                RuntimeContract.MESSAGE_RECEIVED,
                RuntimeContract.MESSAGE_STATE_CHANGED,
                RuntimeContract.CONVERSATION_READ_CHANGED,
                RuntimeContract.CHANGED,
                RuntimeContract.RUNTIME_ERROR,
                RuntimeContract.RUNTIME_LOG,
            ),
            strings(contract, "events"),
        )
    }

    @Test
    fun canonical_transport_and_pairing_outcomes_match_manifest() {
        val contract = manifest()

        assertEquals(
            listOf(
                RuntimeContract.OUTCOME_FORWARDED,
                RuntimeContract.OUTCOME_DELIVERED,
                RuntimeContract.OUTCOME_RECIPIENT_OFFLINE,
                RuntimeContract.OUTCOME_RETRYABLE_FAILURE,
                RuntimeContract.OUTCOME_PERMANENT_FAILURE,
            ),
            strings(contract, "messageTransportOutcomes"),
        )
        assertEquals(
            listOf(
                RuntimeContract.PAIRING_OUTCOME_OFFER_RECEIVED,
                RuntimeContract.PAIRING_OUTCOME_REJECTION_RECEIVED,
                RuntimeContract.PAIRING_OUTCOME_WELCOME_PREPARED,
            ),
            strings(contract, "pairingPeerOutcomes"),
        )
    }
}
