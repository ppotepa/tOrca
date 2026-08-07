package org.torchat.mobile

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Test
import org.torchat.generated.EngineContract
import java.io.File

class RuntimeContractManifestTest {
    private fun manifest(): JSONObject {
        val candidates = listOf(
            File("../../../../../common/client-engine-contract.json"),
            File("../../common/client-engine-contract.json"),
            File("../../../common/client-engine-contract.json"),
        )
        val file = candidates.firstOrNull { it.isFile }
            ?: error("common/client-engine-contract.json not found from ${File(".").absolutePath}")
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
                EngineContract.BOOTSTRAP,
                EngineContract.CONNECT,
                EngineContract.GET_IDENTITY,
                EngineContract.GET_PROFILE,
                EngineContract.GET_STARTUP_READINESS,
                EngineContract.GET_APPLICATION_SNAPSHOT,
                EngineContract.LIST_PAIRINGS,
                EngineContract.PAIRING_INBOX,
                EngineContract.PAIRING_OUTBOX,
                EngineContract.LIST_CONTACTS,
                EngineContract.LIST_CONVERSATIONS,
                EngineContract.LIST_MESSAGES,
                EngineContract.GET_PEER_ENDPOINT,
                EngineContract.RETRY_PEER_CONNECTION,
                EngineContract.ROTATE_PEER_ENDPOINT,
                EngineContract.GET_CONTACT_ENDPOINT_CAPABILITY,
                EngineContract.ROTATE_CONTACT_ENDPOINT_CAPABILITY,
                EngineContract.REVOKE_CONTACT_ENDPOINT_CAPABILITY,
                EngineContract.SET_NICKNAME,
                EngineContract.REFRESH_PAIRING_CODE,
                EngineContract.SUBMIT_PAIRING_CODE,
                EngineContract.ACCEPT_PAIRING,
                EngineContract.REJECT_PAIRING,
                EngineContract.ARCHIVE_PAIRING,
                EngineContract.CANCEL_PAIRING,
                EngineContract.VERIFY_CONTACT,
                EngineContract.UPDATE_CONTACT_SETTINGS,
                EngineContract.REMOVE_RELATIONSHIP,
                EngineContract.START_CONVERSATION,
                EngineContract.OPEN_CONVERSATION,
                EngineContract.CLOSE_CONVERSATION,
                EngineContract.SEND_MESSAGE,
                EngineContract.RETRY_MESSAGE,
                EngineContract.RETRY_DEAD_LETTER,
                EngineContract.LIST_DEAD_LETTERS,
                EngineContract.DELETE_MESSAGE_LOCAL,
                EngineContract.SET_TYPING,
                EngineContract.SET_CONVERSATION_FOCUS,
                EngineContract.SET_PRESENCE,
                EngineContract.SEND_READ_RECEIPTS,
                EngineContract.PLATFORM_FACT,
                EngineContract.SHUTDOWN,
            ),
            strings(methods, "public"),
        )
        assertEquals(
            listOf(
                EngineContract.RUNTIME_READY,
                EngineContract.TOR_STATUS,
                EngineContract.TRANSPORT_STATUS_CHANGED,
                EngineContract.PROFILE_READY,
                EngineContract.INVITE_RECEIVED,
                EngineContract.INVITE_STATE_CHANGED,
                EngineContract.MESSAGE_RECEIVED,
                EngineContract.MESSAGE_STATE_CHANGED,
                EngineContract.CONVERSATION_READ_CHANGED,
                EngineContract.TYPING_CHANGED,
                EngineContract.CONVERSATION_FOCUS_CHANGED,
                EngineContract.PRESENCE_CHANGED,
                EngineContract.PEER_ENDPOINT_CHANGED,
                EngineContract.PEER_CONNECTION_CHANGED,
                EngineContract.CONTACT_CAPABILITY_CHANGED,
                EngineContract.CHANGED,
                EngineContract.RUNTIME_ERROR,
                EngineContract.RUNTIME_LOG,
                EngineContract.PROJECTION_CHANGED,
            ),
            strings(contract, "events"),
        )
    }

    @Test
    fun canonical_transport_and_pairing_outcomes_match_manifest() {
        val contract = manifest()

        assertEquals(
            listOf(
                EngineContract.OUTCOME_DELIVERED,
                EngineContract.OUTCOME_PEER_PERSISTED,
                EngineContract.OUTCOME_PEER_DELIVERED,
                EngineContract.OUTCOME_PEER_UNAVAILABLE,
                EngineContract.OUTCOME_PEER_AUTHENTICATION_FAILED,
                EngineContract.OUTCOME_PEER_REJECTED,
                EngineContract.OUTCOME_RETRYABLE_FAILURE,
                EngineContract.OUTCOME_PERMANENT_FAILURE,
            ),
            strings(contract, "messageTransportOutcomes"),
        )
        assertEquals(
            listOf(
                EngineContract.PAIRING_OUTCOME_OFFER_RECEIVED,
                EngineContract.PAIRING_OUTCOME_REJECTION_RECEIVED,
                EngineContract.PAIRING_OUTCOME_WELCOME_PREPARED,
            ),
            strings(contract, "pairingPeerOutcomes"),
        )
    }
}
