package org.torchat.chat

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import android.util.Log
import org.json.JSONArray
import org.json.JSONObject
import java.security.MessageDigest
import org.torchat.core.NativeConversation
import org.torchat.data.ChatMessage
import org.torchat.data.ContactVerification
import org.torchat.data.DeliveryReceiptRecord
import org.torchat.data.LocalContact
import org.torchat.data.LocalPendingWelcome
import org.torchat.data.MessageStore
import org.torchat.data.RuntimeStateIdentity
import org.torchat.data.applyRuntimeState
import org.torchat.data.runtimeStateSnapshot
import org.torchat.data.RuntimeCommandResult
import org.torchat.data.toRuntimeList
import org.torchat.data.toRuntimeMap
import org.torchat.data.toRuntimePairingItemJson
import org.torchat.mobile.RuntimeContract
import org.torchat.mobile.RuntimeTransportFact
import org.torchat.mobile.RuntimeSendEffect
import org.torchat.transport.AndroidRelayTransport
import org.torchat.transport.PairingRequestCreated
import org.torchat.transport.ProfileResponse
import org.torchat.core.NativeIdentity
import org.torchat.core.NativeClientRuntime
import org.torchat.runtime.RuntimeSessionHost
import java.io.Closeable
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import kotlin.math.min
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/** Owns the Android-side chat flow; MLS state remains in Rust through C ABI. */
class ChatController(
    private val identity: NativeIdentity,
    private val store: MessageStore,
    private val relay: AndroidRelayTransport,
    private val devFixtures: Map<String, ByteArray> = emptyMap(),
    initialNickname: String = "",
) : Closeable {
    private val conversations = ConcurrentHashMap<String, NativeConversation>()
    private val conversationLocks = ConcurrentHashMap<String, Mutex>()
    private val localRuntimeEvents = java.util.concurrent.ConcurrentLinkedQueue<Map<String, Any?>>()
    private val runtimeSession: RuntimeSessionHost
    @Volatile private var activeConversationId: String? = null
    @Volatile private var ownNickname: String = initialNickname

    init {
        store.conversations().forEach { saved ->
            val state = saved.state ?: return@forEach
            runCatching { identity.restoreConversation(state) }
                .onSuccess { conversations[saved.contactInstallationId] = it }
        }
        runtimeSession = RuntimeSessionHost(
            NativeClientRuntime.create(
                installationId = identity.installationId(),
                publicKey = identity.publicKey(),
                fingerprint = identity.fingerprint(),
                nickname = ownNickname,
            ),
        )
        runtimeSession.initialize(
            store.runtimeStateSnapshot(
                identity = RuntimeStateIdentity(
                    installationId = identity.installationId(),
                    publicKey = identity.publicKey(),
                    fingerprint = identity.fingerprint(),
                ),
                nickname = ownNickname,
            ),
        )
    }

    fun contactInvitePayload(): String = identity.contactInvitePayload(ownNickname).also {
        store.putMlsInbox(identity.mlsSnapshot())
    }

    private fun pairingLog(message: String) {
        Log.i("TorChat-Pairing", message)
    }

    private fun conversationMutex(conversationId: String): Mutex =
        conversationLocks.getOrPut(conversationId) { Mutex() }

    suspend fun bootstrapAndConnect() = withContext(Dispatchers.IO) {
        bootstrapRelay()
        connectRelay()
    }

    suspend fun bootstrapRelay() = withContext(Dispatchers.IO) { relay.bootstrap() }

    suspend fun warmupRelay() = withContext(Dispatchers.IO) { relay.warmup() }

    suspend fun connectRelay() = withContext(Dispatchers.IO) {
        withTimeout(180_000L) { relay.connect() }
        retryPendingSendEffects()
        store.pendingWelcomes()
            .filter { it.expiresAt >= System.currentTimeMillis() }
            .forEach { relay.send(it.recipientInstallationId, String(it.payload, Charsets.UTF_8)) }
    }

    suspend fun loadProfile() = relay.profile().also { profile ->
        profile.nickname?.takeIf { it.isNotBlank() }?.let { ownNickname = it }
    }

    suspend fun updateNickname(nickname: String) = relay.updateNickname(nickname).also {
        ownNickname = nickname
    }

    fun reportBootstrapRuntime() {
        runLocalRuntimeCommand(RuntimeContract.BOOTSTRAP_RUNTIME)
    }

    fun reportTorStatus(
        phase: String,
        label: String,
        detail: String = label,
        progress: Int? = null,
        latencyMs: Long? = null,
        retryAttempt: Int = 0,
    ) {
        val status = JSONObject()
            .put("phase", phase)
            .put("label", label)
            .put("detail", detail)
            .put("progress", progress)
            .put("latencyMs", latencyMs)
            .put("retryAttempt", retryAttempt)
        runLocalRuntimeCommand(
            method = RuntimeContract.REPORT_TOR_STATUS,
            params = JSONObject().put("status", status),
        )
    }

    fun reportTorStatus(status: JSONObject) {
        runLocalRuntimeCommand(
            method = RuntimeContract.REPORT_TOR_STATUS,
            params = JSONObject().put("status", status),
        )
    }

    fun applyRemoteProfile(profile: ProfileResponse) {
        runLocalRuntimeCommand(
            method = RuntimeContract.APPLY_REMOTE_PROFILE,
            params = JSONObject().put(
                "profile",
                JSONObject()
                    .put("installationId", profile.installationId)
                    .put("nickname", profile.nickname.orEmpty())
                    .put("publicKey", profile.publicKey)
                    .put("fingerprint", profile.fingerprint),
            ),
        )
    }

    fun reportRuntimeError(message: String) {
        runLocalRuntimeCommand(
            method = RuntimeContract.REPORT_RUNTIME_ERROR,
            params = JSONObject().put("message", message),
        )
    }

    fun localIdentity() = runLocalRuntimeCommand(RuntimeContract.IDENTITY)
        .response
        .getJSONObject("result")
        .toRuntimeMap()

    fun localProfile() = runLocalRuntimeCommand(RuntimeContract.PROFILE)
        .response
        .getJSONObject("result")
        .toRuntimeMap()

    fun updateLocalNickname(nickname: String): Map<String, Any?> {
        val result = runLocalRuntimeCommand(
            method = RuntimeContract.SET_NICKNAME,
            params = JSONObject().put("nickname", nickname),
        )
        val profile = result.response.getJSONObject("result")
        ownNickname = profile.getString("nickname")
        return profile.toRuntimeMap()
    }

    suspend fun refreshPairingCode() = withContext(Dispatchers.IO) {
        val code = relay.refreshPairingCode()
        pairingLog("refreshPairingCode nickname=$ownNickname")
        runtimeSession.importState(
            store.runtimeStateSnapshot(
                identity = RuntimeStateIdentity(
                    installationId = identity.installationId(),
                    publicKey = identity.publicKey(),
                    fingerprint = identity.fingerprint(),
                ),
                nickname = ownNickname,
                pairingCode = code,
            ),
        )
        store.applyRuntimeState(runtimeSession.exportState())
        code
    }

    suspend fun submitPairingCode(code: String): PairingRequestCreated = withContext(Dispatchers.IO) {
        pairingLog("submitPairingCode length=${code.length}")
        val prepared = runLocalRuntimeCommand(
            method = RuntimeContract.PREPARE_SUBMIT_PAIRING_CODE,
            params = JSONObject().put("code", code),
        ).response.getString("result")
        relay.createPairingRequest(prepared).also { created ->
            pairingLog("submitPairingCode created pairingId=${created.pairingId}")
            runLocalRuntimeCommand(
                method = RuntimeContract.MERGE_PAIRING_OUTBOX,
                params = JSONObject().put("items", JSONArray().put(created.toRuntimePairingItemJson())),
            )
        }
    }

    fun pairingOutbox(): List<Map<String, Any?>> {
        val items = runLocalRuntimeCommand(RuntimeContract.PAIRING_OUTBOX).resultItemsAsMaps()
        pairingLog("pairingOutbox items=${items.size}")
        return items
    }

    suspend fun startConversation(contactId: String) = withContext(Dispatchers.IO) {
        val contact = store.contact(contactId) ?: error("kontakt nie istnieje lokalnie")
        if (contact.devFixture != null) {
            startDevConversation(contact)
        } else {
            startConversation(contact)
        }
    }

    suspend fun syncPairingInbox() = withContext(Dispatchers.IO) {
        val remote = relay.pairingInbox()
        pairingLog("syncPairingInbox remote=${remote.size}")
        val items = JSONArray().also { array ->
            remote.forEach { array.put(it.toRuntimePairingItemJson()) }
        }
        val result = runLocalRuntimeCommand(
            method = RuntimeContract.MERGE_PAIRING_INBOX,
            params = JSONObject().put("items", items),
        )
        val receivedIds = result.events
            .asSequence()
            .filter { it["type"] == "invite_received" }
            .mapNotNull { it["pairingId"] as? String }
            .toSet()
        pairingLog("syncPairingInbox merged=${receivedIds.size} ackCandidates=${remote.count { it.pairingId in receivedIds }}")
        buildList {
            remote.forEach { item ->
                if (item.pairingId in receivedIds) {
                    relay.acknowledgePairing(item.pairingId)
                    pairingLog("syncPairingInbox ack pairingId=${item.pairingId}")
                    add(item)
                }
            }
        }
    }

    suspend fun pairingInbox() = withContext(Dispatchers.IO) {
        syncPairingInbox()
        val items = runLocalRuntimeCommand(RuntimeContract.PAIRING_INBOX).resultItemsAsMaps()
        pairingLog("pairingInbox items=${items.size}")
        items
    }

    suspend fun prepareAcceptPairing(pairingId: String): Any? = withContext(Dispatchers.IO) {
        pairingLog("prepareAcceptPairing pairingId=$pairingId")
        val pairing = store.pairingInboxItem(pairingId) ?: error("zaproszenie parowania nie istnieje")
        runLocalRuntimeCommand(
            method = RuntimeContract.PREPARE_ACCEPT_PAIRING,
            params = JSONObject().put("pairingId", pairingId),
        )
    }

    suspend fun acceptPairing(pairingId: String): Unit = withContext(Dispatchers.IO) {
        prepareAcceptPairing(pairingId)
        commitAcceptPairing(pairingId)
    }

    suspend fun commitAcceptPairing(pairingId: String) = withContext(Dispatchers.IO) {
        pairingLog("commitAcceptPairing start pairingId=$pairingId")
        val pairing = store.pairingInboxItem(pairingId) ?: error("zaproszenie parowania nie istnieje")
        val invite = identity.contactInvitePayload(ownNickname, pairing.senderInstallationId)
        val parsed = NativeIdentity.parseContactInvite(invite)
        val payload = RelayPayloads.pairingOffer(pairing.pairingId, pairing.capability, invite)
        val effect = runLocalRuntimeCommand(
            method = RuntimeContract.COMMIT_ACCEPT_PAIRING,
            params = JSONObject()
                .put("pairingId", pairingId)
                .put("offerInviteId", parsed.inviteId)
                .put("offerPayload", payload),
        )
            .response
            .getJSONObject("result")
        pairingLog(
            "commitAcceptPairing effect pairingId=$pairingId recipient=${pairing.senderInstallationId.take(12)} inviteId=${parsed.inviteId}",
        )
        dispatchRuntimeSendEffect(RuntimeSendEffect.fromJson(effect))
        pairingLog("commitAcceptPairing dispatched pairingId=$pairingId")
    }

    suspend fun prepareRejectPairing(pairingId: String): Any? = withContext(Dispatchers.IO) {
        pairingLog("prepareRejectPairing pairingId=$pairingId")
        val pairing = store.pairingInboxItem(pairingId) ?: error("zaproszenie parowania nie istnieje")
        runLocalRuntimeCommand(
            method = RuntimeContract.PREPARE_REJECT_PAIRING,
            params = JSONObject().put("pairingId", pairingId),
        )
    }

    suspend fun rejectPairing(pairingId: String): Unit = withContext(Dispatchers.IO) {
        prepareRejectPairing(pairingId)
        commitRejectPairing(pairingId)
    }

    suspend fun commitRejectPairing(pairingId: String) = withContext(Dispatchers.IO) {
        pairingLog("commitRejectPairing start pairingId=$pairingId")
        val effect = runLocalRuntimeCommand(
            method = RuntimeContract.COMMIT_REJECT_PAIRING,
            params = JSONObject().put("pairingId", pairingId),
        )
            .response
            .getJSONObject("result")
        dispatchRuntimeSendEffect(RuntimeSendEffect.fromJson(effect))
        pairingLog("commitRejectPairing dispatched pairingId=$pairingId")
    }

    fun archivePairing(pairingId: String) {
        runLocalRuntimeCommand(
            method = RuntimeContract.ARCHIVE_PAIRING,
            params = JSONObject().put("pairingId", pairingId),
        )
    }

    suspend fun prepareCancelPairing(pairingId: String): Any? = withContext(Dispatchers.IO) {
        runLocalRuntimeCommand(
            method = RuntimeContract.PREPARE_CANCEL_PAIRING,
            params = JSONObject().put("pairingId", pairingId),
        )
        relay.cancelPairing(pairingId)
    }

    suspend fun cancelPairing(pairingId: String): Unit = withContext(Dispatchers.IO) {
        prepareCancelPairing(pairingId)
        confirmPairingCancelled(pairingId)
    }

    suspend fun confirmPairingCancelled(pairingId: String): Any? = withContext(Dispatchers.IO) {
        runLocalRuntimeCommand(
            method = RuntimeContract.CONFIRM_PAIRING_CANCELLED,
            params = JSONObject().put("pairingId", pairingId),
        )
    }

    fun localContacts() = runLocalRuntimeCommand(RuntimeContract.CONTACTS).resultArrayAsMaps()

    fun localConversations() = runLocalRuntimeCommand(RuntimeContract.CONVERSATIONS).resultArrayAsMaps()

    fun messages(conversationId: String) = runLocalRuntimeCommand(
        method = RuntimeContract.MESSAGES,
        params = JSONObject().put("id", conversationId),
    ).resultArrayAsMaps()

    fun addContact(contact: LocalContact) {
        runLocalRuntimeCommand(
            method = RuntimeContract.BOOTSTRAP_CONTACT,
            params = JSONObject()
                .put("contact", contact.toRuntimeContactJson())
                .put("openConversation", false),
        )
    }

    suspend fun startDevConversation(contact: LocalContact) = withContext(Dispatchers.IO) {
        val fixture = contact.devFixture?.let(devFixtures::get)
            ?: error("brak debugowego fixture dla kontaktu")
        val chat = conversations.getOrPut(contact.installationId) { identity.restoreConversation(fixture) }
        activeConversationId = contact.installationId
        runLocalRuntimeCommand(
            method = RuntimeContract.START_CONVERSATION,
            params = JSONObject().put("contactId", contact.installationId),
        )
        runLocalRuntimeCommand(
            method = RuntimeContract.OPEN_CONVERSATION,
            params = JSONObject().put("id", contact.installationId),
        )
        store.conversationState(contact.installationId)
            ?.let { store.putConversation(it.copy(state = runCatching { chat.snapshot() }.getOrNull())) }
    }

    suspend fun startConversation(contact: LocalContact) = withContext(Dispatchers.IO) {
        if (contact.devFixture != null) {
            startDevConversation(contact)
            return@withContext
        }
        val keyPackage = contact.keyPackage
            ?: error("Ten kontakt nie ma jeszcze pakietu MLS. Rozpocznij rozmowę przez QR.")
        if (conversations.containsKey(contact.installationId)) {
            openConversation(contact.installationId)
            return@withContext
        }
        val chat = identity.createConversation()
        conversations[contact.installationId] = chat
        activeConversationId = contact.installationId
        runLocalRuntimeCommand(
            method = RuntimeContract.START_CONVERSATION,
            params = JSONObject().put("contactId", contact.installationId),
        )
        runLocalRuntimeCommand(
            method = RuntimeContract.OPEN_CONVERSATION,
            params = JSONObject().put("id", contact.installationId),
        )
        store.conversationState(contact.installationId)
            ?.let { store.putConversation(it.copy(state = runCatching { chat.snapshot() }.getOrNull())) }
        val welcome = chat.invite(keyPackage)
        relay.send(
            contact.installationId,
            RelayPayloads.welcome(
                identity,
                ownNickname,
                contact.installationId,
                UUID.randomUUID().toString(),
                welcome[0],
                welcome[1],
            ),
        )
    }

    fun openConversation(conversationId: String) {
        activeConversationId = conversationId
        runLocalRuntimeCommand(
            method = RuntimeContract.OPEN_CONVERSATION,
            params = JSONObject().put("id", conversationId),
        )
    }

    fun closeConversation() {
        activeConversationId = null
        runLocalRuntimeCommand(RuntimeContract.CLOSE_CONVERSATION)
    }

    fun activeConversationId(): String? = activeConversationId

    fun drainLocalRuntimeEvents(): List<Map<String, Any?>> = buildList {
        while (true) {
            add(localRuntimeEvents.poll() ?: break)
        }
    }

    fun dispatchLocalRuntime(method: String, params: JSONObject = JSONObject()): Any? {
        val result = runLocalRuntimeCommand(method, params)
        return result.response.opt("result")?.let { value ->
            when (value) {
                JSONObject.NULL -> null
                is JSONObject -> value.toRuntimeMap()
                is JSONArray -> value.toRuntimeList()
                else -> value
            }
        }
    }

    suspend fun startConversationFromInvite(invitePayload: String) = withContext(Dispatchers.IO) {
        val invite = NativeIdentity.parseContactInvite(invitePayload)
        check(!store.isInviteConsumed(invite.inviteId)) { "zaproszenie zostało już użyte" }
        conversations[invite.installationId]?.let {
            activeConversationId = invite.installationId
            runLocalRuntimeCommand(
                method = RuntimeContract.OPEN_CONVERSATION,
                params = JSONObject().put("id", invite.installationId),
            )
            return@withContext
        }
        val chat = identity.createConversation()
        conversations[invite.installationId] = chat
        activeConversationId = invite.installationId
        runLocalRuntimeCommand(
            method = RuntimeContract.BOOTSTRAP_CONTACT,
            params = JSONObject()
                .put("contact", invite.toRuntimeContactJson())
                .put("openConversation", true),
        )
        store.conversationState(invite.installationId)
            ?.let { store.putConversation(it.copy(state = runCatching { chat.snapshot() }.getOrNull())) }
        val welcome = chat.invite(invite.keyPackage)
        val welcomePayload = RelayPayloads.welcome(
            identity,
            ownNickname,
            invite.installationId,
            invite.inviteId,
            welcome[0],
            welcome[1],
        )
        store.putPendingWelcome(
            LocalPendingWelcome(
                invite.inviteId,
                invite.installationId,
                welcomePayload.toByteArray(Charsets.UTF_8),
                System.currentTimeMillis() + 10 * 60 * 1000,
            )
        )
        if (!relay.send(invite.installationId, welcomePayload)) {
            error("nie udało się wysłać zaproszenia przez Tor")
        }
        check(store.consumeInvite(invite.inviteId)) { "zaproszenie zostało już użyte" }
    }

    suspend fun receive(sender: String, messageId: String, encoded: String): String? = withContext(Dispatchers.IO) {
        when (val payload = RelayPayloads.decode(encoded)) {
          is DecodedRelayPayload.PairingOffer -> handlePairingOffer(payload)
          is DecodedRelayPayload.PairingRejected -> handlePairingRejected(payload)
          is DecodedRelayPayload.Welcome -> handleWelcome(sender, payload)
          is DecodedRelayPayload.Application -> handleApplication(sender, messageId, payload)
        }
    }

    suspend fun receiveLoop(
        onText: (String) -> Unit,
        onWelcome: suspend () -> Unit = {},
        onStateChanged: suspend () -> Unit = {},
    ) {
        try {
            while (true) {
                val frame = JSONObject(relay.nextFrame())
                when (frame.optString("type")) {
                    "envelope" -> {
                        val sender = frame.getString("sender")
                        runCatching {
                            val text = receive(sender, frame.getString("message_id"), frame.getString("ciphertext"))
                            pairingLog("receiveLoop envelope sender=${sender.take(12)} text=${text != null}")
                            if (text != null) onText(text) else onWelcome()
                            retryDueReceipts()
                        }.onFailure { error ->
                            Log.w("TorChat-Relay", "Ignoring invalid inbound envelope without reconnecting", error)
                        }
                    }
                    "delivery_receipt" -> {
                        pairingLog("receiveLoop deliveryReceipt messageId=${frame.getString("message_id")}")
                        applyMessageTransportOutcomeIfKnown(
                            frame.getString("message_id"),
                            RuntimeTransportFact.DELIVERED,
                        )
                        onStateChanged()
                    }
                    "forwarded" -> {
                        pairingLog("receiveLoop forwarded messageId=${frame.getString("message_id")}")
                        applyMessageTransportOutcomeIfKnown(
                            frame.getString("message_id"),
                            RuntimeTransportFact.FORWARDED,
                        )
                        onStateChanged()
                    }
                    "recipient_offline" -> {
                        pairingLog("receiveLoop recipientOffline messageId=${frame.getString("message_id")}")
                        applyMessageTransportOutcomeIfKnown(
                            frame.getString("message_id"),
                            RuntimeTransportFact.RECIPIENT_OFFLINE,
                        )
                        onStateChanged()
                    }
                    "error" -> {
                        val code = frame.optString("code")
                        val detail = frame.optString("detail", code)
                        if (code == "transport_disconnected") error("relay disconnected: $detail")
                        Log.w("TorChat-Relay", "Relay rejected frame code=$code detail=$detail")
                    }
                }
            }
        } finally {
            store.requeueSendingAfterDisconnect(System.currentTimeMillis())
        }
    }

    suspend fun send(text: String) = send(activeConversationId ?: error("no conversation selected"), text)

    suspend fun send(conversationId: String, text: String) = withContext(Dispatchers.IO) {
        pairingLog("send conversationId=$conversationId textLength=${text.trim().length}")
        val effect = runLocalRuntimeCommand(
            method = RuntimeContract.SEND_MESSAGE,
            params = JSONObject()
                .put("id", conversationId)
                .put("text", text),
        )
            .response
            .getJSONObject("result")
        dispatchRuntimeSendEffect(RuntimeSendEffect.fromJson(effect))
    }

    suspend fun retryPendingSendEffects() = withContext(Dispatchers.IO) {
        val effects = runLocalRuntimeCommand(RuntimeContract.PREPARE_PENDING_SEND_EFFECTS)
            .response
            .getJSONArray("result")
        pairingLog("retryPendingSendEffects effects=${effects.length()}")
        for (index in 0 until effects.length()) {
            dispatchRuntimeSendEffect(RuntimeSendEffect.fromJson(effects.getJSONObject(index)))
        }
    }

    suspend fun retryDueMessages() = withContext(Dispatchers.IO) {
        val pending = store.pending()
        pairingLog("retryDueMessages messages=${pending.size}")
        for (message in pending) {
            val nowMs = System.currentTimeMillis()
            val nextAttemptAt = nowMs + retryDelayMs(
                message.attemptCount + 1,
                stableRetrySeed(message.id.toString(), message.attemptCount + 1),
            )
            if (!store.claimMessageRetry(
                    message.id,
                    nowMs,
                    nextAttemptAt,
                    nowMs + 30_000L,
                )
            ) {
                continue
            }
            dispatchMessageSendEffect(
                RuntimeSendEffect.Message(
                    messageId = message.id.toString(),
                    conversationId = message.conversationId,
                    recipientInstallationId = message.conversationId,
                    body = message.body.orEmpty(),
                )
            )
        }
    }

    suspend fun retryDueReceipts() = withContext(Dispatchers.IO) {
        val pending = store.pendingDeliveryReceipts(System.currentTimeMillis())
        pairingLog("retryDueReceipts receipts=${pending.size}")
        for (receipt in pending) {
            val nowMs = System.currentTimeMillis()
            val nextAttemptAt = nowMs + retryDelayMs(
                receipt.attemptCount + 1,
                stableRetrySeed(receipt.messageId, receipt.attemptCount + 1),
            )
            if (!store.claimDeliveryReceiptRetry(receipt.messageId, nowMs, nextAttemptAt)) {
                continue
            }
            val sent = conversationMutex(receipt.originalSender).withLock {
                val chat = conversations[receipt.originalSender] ?: return@withLock false
                val payload = ApplicationPayload.encode(
                    ApplicationPayload.DeliveryReceipt(
                        version = 1,
                        messageId = UUID.fromString(receipt.messageId),
                        receivedAt = nowMs,
                    )
                ).toByteArray(Charsets.UTF_8)
                val encrypted = chat.encrypt(payload)
                store.conversationState(receipt.originalSender)?.let { conversation ->
                    store.putConversation(
                        conversation.copy(state = runCatching { chat.snapshot() }.getOrNull()),
                    )
                }
                relay.sendWithId(
                    UUID.randomUUID().toString(),
                    receipt.originalSender,
                    RelayPayloads.application(encrypted),
                ) != null
            }
            if (sent) {
                pairingLog("retryDueReceipts sent encrypted receipt messageId=${receipt.messageId.take(8)}")
            }
        }
    }

    private fun retryDelayMs(attempt: Int, jitterSeed: Long): Long {
        val baseMs = 2_000L
        val maxMs = 5L * 60L * 1_000L
        val exponent = min(attempt, 8)
        val capped = min(baseMs * (1L shl exponent), maxMs)
        val jitterPercent = Math.floorMod(jitterSeed, 41L) - 20L
        return capped + capped * jitterPercent / 100L
    }

    private fun stableRetrySeed(messageId: String, attempt: Int): Long {
        var hash = 1125899906842597L
        for (character in "$messageId:$attempt") {
            hash = 31L * hash + character.code
        }
        return hash
    }

    suspend fun resendPendingWelcomes() = withContext(Dispatchers.IO) {
        store.pendingWelcomes()
            .filter { it.expiresAt >= System.currentTimeMillis() }
            .forEach { relay.send(it.recipientInstallationId, String(it.payload, Charsets.UTF_8)) }
    }

    private suspend fun handlePairingOffer(payload: DecodedRelayPayload.PairingOffer): String? {
        val invite = NativeIdentity.parseContactInvite(payload.invite)
        if (!store.isInviteConsumed(invite.inviteId)) {
            startConversationFromInvite(payload.invite)
        } else {
            store.pendingWelcomes()
                .firstOrNull { it.inviteId == invite.inviteId && it.expiresAt >= System.currentTimeMillis() }
                ?.let { relay.send(it.recipientInstallationId, String(it.payload, Charsets.UTF_8)) }
        }
        runLocalRuntimeCommand(
            method = RuntimeContract.APPLY_PAIRING_PEER_OUTCOME,
            params = JSONObject()
                .put("pairingId", payload.pairingId)
                .put("outcome", RuntimeContract.PAIRING_OUTCOME_OFFER_RECEIVED),
        )
        runLocalRuntimeCommand(
            method = RuntimeContract.APPLY_PAIRING_PEER_OUTCOME,
            params = JSONObject()
                .put("pairingId", payload.pairingId)
                .put("outcome", RuntimeContract.PAIRING_OUTCOME_WELCOME_PREPARED),
        )
        return null
    }

    private suspend fun handlePairingRejected(payload: DecodedRelayPayload.PairingRejected): String? {
        runLocalRuntimeCommand(
            method = RuntimeContract.APPLY_PAIRING_PEER_OUTCOME,
            params = JSONObject()
                .put("pairingId", payload.pairingId)
                .put("outcome", RuntimeContract.PAIRING_OUTCOME_REJECTION_RECEIVED),
        )
        return null
    }

    private suspend fun handleWelcome(
        sender: String,
        payload: DecodedRelayPayload.Welcome,
    ): String? {
        RelayPayloads.verifyWelcome(identity, payload.value, sender)
        val chat = identity.acceptConversation(
            payload.value.welcome,
            payload.value.ratchetTree,
        )
        store.putMlsInbox(identity.mlsSnapshot())
        conversations[sender] = chat
        activeConversationId = sender
        val welcomeResult = runLocalRuntimeCommand(
            method = RuntimeContract.WELCOME_ACCEPTED,
            params = JSONObject()
                .put("contact", payload.value.toRuntimeContactJson())
                .put("openConversation", true)
                .put("inviteId", payload.value.inviteId),
        )
            .response
            .getJSONObject("result")
        store.conversationState(sender)
            ?.let { store.putConversation(it.copy(state = runCatching { chat.snapshot() }.getOrNull())) }
        welcomeResult.optJSONObject("confirmContact")?.let { confirm ->
            relay.confirmContact(confirm.getString("capability"), confirm.getString("peerInstallationId"))
        }
        return null
    }

    private fun org.torchat.transport.WelcomePayload.toRuntimeContactJson() = JSONObject()
        .put("installationId", senderInstallationId)
        .put("nickname", senderNickname.ifBlank { senderInstallationId })
        .put("publicKey", senderPublicKey)
        .put("fingerprint", senderFingerprint)
        .put("verification", ContactVerification.UNVERIFIED.name)

    private fun org.torchat.core.NativeContactInvite.toRuntimeContactJson() = JSONObject()
        .put("installationId", installationId)
        .put("nickname", nickname?.takeIf { it.isNotBlank() } ?: installationId)
        .put("publicKey", publicKey)
        .put("fingerprint", fingerprint)
        .put("verification", ContactVerification.UNVERIFIED.name)

    private fun LocalContact.toRuntimeContactJson() = JSONObject()
        .put("installationId", installationId)
        .put("nickname", nickname.ifBlank { installationId })
        .put("publicKey", publicKey)
        .put("fingerprint", fingerprint)
        .put("verification", verification.name)
        .apply {
            devFixture?.let { put("dev", it) }
        }

    private suspend fun handleApplication(
        sender: String,
        messageId: String,
        payload: DecodedRelayPayload.Application,
    ): String? {
        val chat = conversations[sender] ?: error("received message before MLS Welcome")
        return conversationMutex(sender).withLock {
            val ciphertextHash = MessageDigest.getInstance("SHA-256").digest(payload.ciphertext)
            val existing = store.receivedEnvelope(sender, messageId)
            if (existing != null) {
                require(existing.ciphertextHash.contentEquals(ciphertextHash)) { "duplicate envelope has different ciphertext" }
                return@withLock null
            }
            val plaintext = chat.decrypt(payload.ciphertext)
            val application = ApplicationPayload.decode(String(plaintext, Charsets.UTF_8))
            val (text, sentAt) = when (application) {
                is ApplicationPayload.Message -> {
                    require(application.messageId.toString() == messageId) { "application messageId mismatch" }
                    application.body to application.sentAt
                }
                is ApplicationPayload.DeliveryReceipt -> {
                    applyMessageTransportOutcomeIfKnown(
                        application.messageId.toString(),
                        RuntimeTransportFact.DELIVERED,
                    )
                    return@withLock null
                }
            }
            runLocalRuntimeCommand(
                method = RuntimeContract.RECEIVE_MESSAGE,
                params = JSONObject()
                    .put("id", sender)
                    .put("text", text)
                    .put("messageId", messageId),
            )
            store.message(UUID.fromString(messageId))
                ?.let { store.put(it.copy(ciphertext = payload.ciphertext)) }
            store.putReceivedEnvelope(
                org.torchat.data.ReceivedEnvelope(
                    senderInstallationId = sender,
                    messageId = messageId,
                    ciphertextHash = ciphertextHash,
                    receivedAt = sentAt,
                    receiptState = "SENT",
                )
            )
            store.putDeliveryReceipt(
                DeliveryReceiptRecord(
                    messageId = messageId,
                    originalSender = sender,
                    state = "PENDING",
                    createdAt = System.currentTimeMillis(),
                )
            )
            store.conversationState(sender)
                ?.let { store.putConversation(it.copy(state = runCatching { chat.snapshot() }.getOrNull())) }
            text
        }
    }

    fun verifyContact(installationId: String) {
        runLocalRuntimeCommand(
            method = RuntimeContract.VERIFY_CONTACT,
            params = JSONObject().put("installationId", installationId),
        )
    }

    private suspend fun dispatchRuntimeSendEffect(effect: RuntimeSendEffect) {
        when (effect) {
            is RuntimeSendEffect.Message -> dispatchMessageSendEffect(effect)
            is RuntimeSendEffect.Pairing -> dispatchPairingSendEffect(effect)
        }
    }

    private suspend fun dispatchMessageSendEffect(effect: RuntimeSendEffect.Message) {
        val messageId = effect.messageId
        val conversationId = effect.conversationId
        val recipient = effect.recipientInstallationId
        val body = effect.body
        conversationMutex(conversationId).withLock {
            pairingLog("dispatchMessageSendEffect messageId=${messageId.take(8)} conversationId=${conversationId.take(12)} recipient=${recipient.take(12)}")
            val chat = conversations[recipient] ?: error("MLS conversation is not established")
            val messageUuid = UUID.fromString(messageId)
            val storedMessage = store.conversation(conversationId)
                .firstOrNull { it.id == messageUuid }
                ?: error("runtime message is missing from storage")
            val encrypted = if (storedMessage.ciphertext.isNotEmpty()) {
                storedMessage.ciphertext
            } else {
                val payload = ApplicationPayload.encode(
                    ApplicationPayload.Message(
                        version = 1,
                        messageId = messageUuid,
                        sentAt = storedMessage.createdAt,
                        body = body,
                    ),
                ).toByteArray(Charsets.UTF_8)
                chat.encrypt(payload).also { ciphertext ->
                    store.put(storedMessage.copy(ciphertext = ciphertext))
                    store.conversationState(conversationId)?.let { conversation -> 
                        store.putConversation(
                            conversation.copy(state = runCatching { chat.snapshot() }.getOrNull()),
                        )
                    }
                }
            }
            val accepted = relay.sendWithId(messageId, recipient, RelayPayloads.application(encrypted)) != null
            if (!accepted) {
                pairingLog("dispatchMessageSendEffect retryableFailure messageId=${messageId.take(8)}")
                applyTransportFact(messageId, RuntimeTransportFact.RETRYABLE_FAILURE)
            }
        }
    }

    private suspend fun dispatchPairingSendEffect(effect: RuntimeSendEffect.Pairing) {
        val pairingId = effect.pairingId
        val recipient = effect.recipientInstallationId
        val payload = when (effect.kind) {
            RuntimeSendEffect.PairingKind.OFFER -> effect.payload ?: error("runtime pairing offer payload is missing")
            RuntimeSendEffect.PairingKind.REJECTION -> RelayPayloads.pairingRejected(pairingId)
        }
        check(relay.send(recipient, payload)) { "relay actor stopped" }
    }

    private fun applyTransportFact(messageId: String, outcome: RuntimeTransportFact) {
        runLocalRuntimeCommand(
            method = RuntimeContract.APPLY_MESSAGE_TRANSPORT_OUTCOME,
            params = JSONObject()
                .put("messageId", messageId)
                .put("outcome", outcome.wireValue),
        )
    }

    private fun applyMessageTransportOutcomeIfKnown(messageId: String, outcome: RuntimeTransportFact) {
        val id = runCatching { UUID.fromString(messageId) }.getOrNull()
        if (id == null || store.message(id) == null) {
            pairingLog("Ignoring transport outcome for non-message envelope messageId=$messageId outcome=$outcome")
            return
        }
        runCatching { applyTransportFact(messageId, outcome) }
            .onFailure { error ->
                Log.w(
                    "TorChat-Relay",
                    "Ignoring stale message transport outcome messageId=$messageId outcome=$outcome",
                    error,
                )
            }
    }

    private fun runLocalRuntimeCommand(
        method: String,
        params: JSONObject = JSONObject(),
    ): RuntimeCommandResult {
        val dispatched = runtimeSession.dispatch(method, params)
        check(dispatched.response.optBoolean("ok")) {
            dispatched.response.optString("error").ifBlank { "runtime command failed: $method" }
        }
        store.applyRuntimeState(dispatched.exportedState)
        localRuntimeEvents.addAll(dispatched.events.map { it.toRuntimeMap() })
        return RuntimeCommandResult(dispatched.response, dispatched.events.map { it.toRuntimeMap() })
    }

    override fun close() {
        try {
            store.applyRuntimeState(runtimeSession.exportState())
        } finally {
            runtimeSession.close()
            conversations.clear()
            localRuntimeEvents.clear()
            activeConversationId = null
            store.close()
        }
    }

}
