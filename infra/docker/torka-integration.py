#!/usr/bin/env python3
"""Finite two-engine Tor integration probe for the 0.1 release gate.

The normal ``torka`` container is intentionally long-lived.  This companion
process owns a separate identity and Tor data directory, pairs with Torka via
the development-reserved code, requires an authenticated peer connection and
then verifies the ordinary encrypted message path with ``ping`` -> ``pong``.
It never runs as part of the default Compose project.
"""

import os
import sys
import time

from torka_client import Engine, log


def timeout_seconds():
    try:
        return max(60, int(os.environ.get("TORCHAT_INTEGRATION_TIMEOUT_SECONDS", "240")))
    except ValueError:
        return 240


def list_value(engine, command):
    value = engine.command(command, timeout=30)
    return value if isinstance(value, list) else []


def verified_contact(engine):
    for contact in list_value(engine, {"type": "list_contacts"}):
        if isinstance(contact, dict) and contact_is_verified(contact):
            return contact
    return None


def contact_is_verified(contact):
    return str(
        contact.get("verification")
        or contact.get("verificationState")
        or ""
    ).upper() == "VERIFIED"


def any_contact(engine):
    for contact in list_value(engine, {"type": "list_contacts"}):
        if isinstance(contact, dict) and (
            contact.get("installationId") or contact.get("installation_id")
        ):
            return contact
    return None


def direct_peer_ready(contact):
    # Contract values have changed spelling during development.  Keep the
    # acceptance probe strict about a positive state while remaining resilient
    # to the generated Dart/Kotlin casing used by an older debug image.
    value = str(
        contact.get("peerConnectionStatus")
        or contact.get("peer_connection_status")
        or ""
    ).upper()
    return value in {"ONLINE", "CONNECTED", "READY"}


def conversation_for(engine, installation_id):
    for conversation in list_value(engine, {"type": "list_conversations"}):
        if not isinstance(conversation, dict):
            continue
        peer = conversation.get("contactId") or conversation.get("contact_id")
        if peer == installation_id and conversation.get("id"):
            return conversation["id"]
    return None


def contains_pong(engine, conversation_id):
    messages = list_value(
        engine, {"type": "list_messages", "conversation_id": conversation_id}
    )
    return any(
        isinstance(message, dict)
        and message.get("outgoing") is False
        and message.get("body") == "pong"
        for message in messages
    )


def command_until(engine, command, deadline, label):
    """Retry a control-plane command across normal onion warmup/backoff."""
    last_error = None
    while time.monotonic() < deadline:
        try:
            return engine.command(command, timeout=30)
        except Exception as error:
            last_error = error
            if engine.process.poll() is not None:
                raise RuntimeError(f"engine stopped while waiting for {label}: {error}")
            log(f"integration {label} deferred: {error}")
            time.sleep(3)
    raise RuntimeError(f"timed out waiting for {label}: {last_error}")


def main():
    engine = Engine()
    deadline = time.monotonic() + timeout_seconds()
    try:
        engine.command({"type": "bootstrap"}, timeout=30)
        engine.command({"type": "connect"}, timeout=30)
        engine.wait_for_relay()
        command_until(
            engine,
            {"type": "set_nickname", "nickname": "IntegrationPeer"},
            deadline,
            "relay profile update",
        )

        code = os.environ.get("TORCHAT_TORKA_PAIRING_CODE", "42424242").strip()
        if not code:
            raise RuntimeError("TORCHAT_TORKA_PAIRING_CODE is required")
        # A previous successful smoke can leave the integration identity
        # paired with Torka. Reuse that verified contact so repeated runs do
        # not create a second pending invitation or mutate the shared dev
        # client. A clean identity still follows the normal pairing path.
        contact = verified_contact(engine)
        if contact is not None:
            log("integration reusing existing verified Torka contact")
        # A just-recreated relay may accept Torka's health marker slightly
        # before its reserved-code registration becomes visible. Retrying this
        # one idempotent intent is safe: a conflict means the first request
        # already reached the control plane and we can move on to local state.
        if contact is None:
            submitted = False
            while time.monotonic() < deadline:
                try:
                    command_until(
                        engine,
                        {"type": "submit_pairing_code", "code": code},
                        min(deadline, time.monotonic() + 35),
                        "pairing submission",
                    )
                    submitted = True
                    break
                except Exception as error:
                    if "pending invitation" in str(error).lower():
                        submitted = True
                        break
                    log(f"integration pairing submission deferred: {error}")
                    time.sleep(3)
            if not submitted:
                raise RuntimeError("could not submit the Torka pairing request")
            log("integration pairing request submitted")

        while contact is None and time.monotonic() < deadline:
            # The engine's relay writer applies the incoming offer. The local
            # contact read is intentionally side-effect-free: it proves that
            # UI projection is driven by committed engine events, not by a
            # polling command with its own remote side effect.
            contact = any_contact(engine)
            if contact is not None:
                break
            time.sleep(2)
        if contact is None:
            raise RuntimeError("pairing did not produce a Torka contact")

        installation_id = contact.get("installationId") or contact.get("installation_id")
        if not installation_id:
            raise RuntimeError("verified contact did not have an installation id")
        if not contact_is_verified(contact):
            engine.command(
                {"type": "verify_contact", "installation_id": installation_id}, timeout=30
            )
            while time.monotonic() < deadline:
                candidate = verified_contact(engine)
                if candidate is not None:
                    contact = candidate
                    break
                time.sleep(1)
            if not contact_is_verified(contact):
                raise RuntimeError("local Torka contact did not become verified")
        conversation_id = conversation_for(engine, installation_id)
        if conversation_id is None:
            engine.command(
                {"type": "start_conversation", "contact_id": installation_id}, timeout=30
            )
            # ConversationSummary.id is intentionally the contact installation
            # id. The command returns a boolean indicating creation/activation,
            # not the summary object.
            conversation_id = installation_id
        if not conversation_id:
            raise RuntimeError("pairing did not create a conversation")

        # A direct onion probe can take a few descriptor/circuit attempts.
        while time.monotonic() < deadline:
            if direct_peer_ready(verified_contact(engine) or {}):
                break
            engine.command(
                {"type": "retry_peer_connection", "installation_id": installation_id},
                timeout=30,
            )
            time.sleep(3)
        if not direct_peer_ready(verified_contact(engine) or {}):
            raise RuntimeError("authenticated direct peer session never became ready")

        engine.command(
            {"type": "send_message", "conversation_id": conversation_id, "body": "ping"},
            timeout=30,
        )
        log("integration ping queued over authenticated direct peer session")
        while time.monotonic() < deadline:
            if contains_pong(engine, conversation_id):
                log("TORCHAT_TWO_ENGINE_P2P_OK ping=pong")
                return 0
            time.sleep(2)
        raise RuntimeError("Torka did not return pong through the direct peer conversation")
    finally:
        if engine.process.poll() is None:
            try:
                engine.command({"type": "shutdown"}, timeout=5)
            except Exception:
                engine.process.terminate()


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as error:
        log(f"TORCHAT_TWO_ENGINE_P2P_FAILED: {error}")
        sys.exit(1)
