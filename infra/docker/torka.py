#!/usr/bin/env python3
"""Development-only autonomous TorChat client used to exercise onion P2P."""

import json
import os
import queue
import subprocess
import sys
import threading
import time
import uuid


def log(message):
    print(f"[torka] {message}", flush=True)


class Engine:
    def __init__(self):
        data = "/var/lib/torchat"
        server = os.environ.get("TORCHAT_ONION_URL", "").strip()
        if not server:
            raise RuntimeError("TORCHAT_ONION_URL is required")
        args = [
            "/usr/local/bin/torchat-desktop", "--stdio-engine",
            "--server-url", server,
            "--tor-binary", "/usr/bin/tor",
            "--tor-data-dir", f"{data}/tor",
            "--identity-file", f"{data}/identity.key",
        ]
        self.process = subprocess.Popen(
            args, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            text=True, bufsize=1,
        )
        self.responses = {}
        self.lines = queue.Queue()
        threading.Thread(target=self._read, daemon=True).start()

    def _read(self):
        for raw in self.process.stdout:
            line = raw.strip()
            if not line:
                continue
            try:
                event = json.loads(line)
            except json.JSONDecodeError:
                log(f"sidecar: {line}")
                continue
            if event.get("type") == "response":
                self.responses[event.get("requestId")] = event.get("result", {})
            elif event.get("type") == "log":
                log(event.get("log", {}).get("message", "engine log"))
            elif event.get("type") == "fatal":
                log(f"fatal: {event.get('error', {})}")
            elif event.get("type") == "runtime":
                runtime = event.get("event", {})
                log(f"runtime {runtime.get('type', 'unknown')}")
            self.lines.put(event)

    def command(self, command, timeout=30):
        request_id = str(uuid.uuid4())
        payload = {"requestId": request_id, "command": command}
        self.process.stdin.write(json.dumps(payload) + "\n")
        self.process.stdin.flush()
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            result = self.responses.pop(request_id, None)
            if result is not None:
                if result.get("status") != "ok":
                    raise RuntimeError(result.get("message") or result.get("code") or "engine request failed")
                payload = result.get("payload", {})
                return payload.get("value") if payload.get("type") == "json" else None
            if self.process.poll() is not None:
                raise RuntimeError(f"desktop engine exited with {self.process.returncode}")
            time.sleep(0.05)
        raise TimeoutError(f"engine command timed out: {command.get('type')}")

    def received_events(self):
        while True:
            try:
                event = self.lines.get_nowait()
            except queue.Empty:
                return
            runtime = event.get("event") if event.get("type") == "runtime" else None
            if isinstance(runtime, dict) and runtime.get("type") == "message_received":
                yield runtime


def pending_pairing_ids(value):
    items = value.get("items", []) if isinstance(value, dict) else []
    return [
        item.get("pairingId") for item in items
        if item.get("received") is True and item.get("state") == "PENDING"
        and "ACCEPT" in item.get("availableActions", []) and item.get("pairingId")
    ]


def response_for(text):
    command = text.strip()
    normalized = command.casefold()
    if normalized == "ping":
        return "pong"
    if normalized in {"help", "/help"}:
        return "Torka test commands: ping, status, echo <text>, help"
    if normalized in {"status", "/status"}:
        return "Torka is online. This reply used the normal Tor onion P2P delivery path."
    if normalized.startswith("echo ") or normalized.startswith("/echo "):
        return command.split(" ", 1)[1]
    return None


def conversation_for_message(engine, message_id):
    conversations = engine.command({"type": "list_conversations"}, timeout=15)
    for conversation in conversations if isinstance(conversations, list) else []:
        conversation_id = conversation.get("id")
        if not conversation_id:
            continue
        messages = engine.command(
            {"type": "list_messages", "conversation_id": conversation_id}, timeout=15,
        )
        for message in messages if isinstance(messages, list) else []:
            if message.get("id") == message_id and message.get("outgoing") is False:
                return conversation_id
    return None


def verified_messaging_ready(engine):
    contacts = engine.command({"type": "list_contacts"}, timeout=15)
    if not any(
        contact.get("verified") is True
        for contact in contacts if isinstance(contact, dict)
    ):
        return False
    conversations = engine.command({"type": "list_conversations"}, timeout=15)
    return any(
        conversation.get("id")
        for conversation in conversations if isinstance(conversation, dict)
    )


def queued_command_messages(engine, handled_message_ids):
    seen = set()

    for event in engine.received_events():
        message_id = event.get("messageId")
        text = event.get("text")
        conversation_id = event.get("conversationId")
        if not message_id or not isinstance(text, str):
            continue
        seen.add(message_id)
        if message_id in handled_message_ids:
            continue
        yield {
            "message_id": message_id,
            "text": text,
            "conversation_id": conversation_id,
        }

    conversations = engine.command({"type": "list_conversations"}, timeout=15)
    pending = []
    for conversation in conversations if isinstance(conversations, list) else []:
        conversation_id = conversation.get("id")
        if not conversation_id:
            continue
        messages = engine.command(
            {"type": "list_messages", "conversation_id": conversation_id},
            timeout=15,
        )
        for message in messages if isinstance(messages, list) else []:
            message_id = message.get("id")
            if (
                not message_id
                or message_id in handled_message_ids
                or message_id in seen
                or message.get("outgoing") is not False
                or not isinstance(message.get("body"), str)
            ):
                continue
            pending.append(
                {
                    "message_id": message_id,
                    "text": message["body"],
                    "conversation_id": conversation_id,
                    "created_at": message.get("createdAt") or 0,
                }
            )

    pending.sort(key=lambda item: (item["created_at"], item["message_id"]))
    for message in pending:
        yield message


def respond_to_commands(engine, handled_message_ids):
    for command_message in queued_command_messages(engine, handled_message_ids):
        message_id = command_message["message_id"]
        text = command_message["text"]
        handled_message_ids.add(message_id)
        reply = response_for(text)
        if reply is None:
            continue
        conversation_id = command_message.get("conversation_id") or conversation_for_message(
            engine, message_id
        )
        if conversation_id is None:
            log(f"command ignored; conversation not found message={message_id}")
            continue
        engine.command(
            {"type": "send_message", "conversation_id": conversation_id, "body": reply},
            timeout=30,
        )
        log(f"command={text!r} reply={reply!r} message={message_id}")


def env_interval(name, default, minimum=1):
    try:
        return max(minimum, float(os.environ.get(name, str(default))))
    except ValueError:
        return float(default)


def main():
    engine = Engine()
    try:
        engine.command({"type": "bootstrap"})
        engine.command({"type": "connect"})
        profile = engine.command({"type": "set_nickname", "nickname": os.environ.get("TORCHAT_NICKNAME", "Torka")})
        log(f"identity ready installation={profile.get('installationId', 'unknown')}")
        reserved_code = os.environ.get("TORCHAT_TORKA_PAIRING_CODE", "").strip()
        if reserved_code:
            log(f"reserved pairing code: {reserved_code}")

        pairing_interval = env_interval("TORCHAT_TORKA_PAIRING_POLL_SECONDS", 20, 5)
        message_interval = env_interval("TORCHAT_TORKA_MESSAGE_POLL_SECONDS", 10, 5)
        idle_sleep = env_interval("TORCHAT_TORKA_IDLE_SLEEP_SECONDS", 1, 0.25)
        next_pairing_poll = 0.0
        next_message_poll = 0.0
        next_code_refresh = 0.0
        message_wait_logged = False
        handled_message_ids = set()

        while True:
            now = time.monotonic()
            if now >= next_pairing_poll:
                next_pairing_poll = now + pairing_interval
                try:
                    inbox = engine.command({"type": "pairing_inbox"}, timeout=15)
                    for pairing_id in pending_pairing_ids(inbox):
                        log(f"accepting pairing request {pairing_id}")
                        engine.command({"type": "accept_pairing", "pairing_id": pairing_id}, timeout=30)
                except Exception as error:
                    log(f"pairing inbox deferred: {error}")

            if now >= next_code_refresh:
                try:
                    invite = engine.command({"type": "refresh_pairing_code"}, timeout=15)
                    code = invite.get("code") if isinstance(invite, dict) else None
                    if code:
                        log(f"pairing code (valid until rotation): {code}")
                    next_code_refresh = now + 10 * 60
                except Exception as error:
                    next_code_refresh = now + 60
                    log(f"pairing code refresh deferred: {error}")

            if now >= next_message_poll:
                next_message_poll = now + message_interval
                try:
                    if verified_messaging_ready(engine):
                        message_wait_logged = False
                        respond_to_commands(engine, handled_message_ids)
                    elif not message_wait_logged:
                        message_wait_logged = True
                        log("message polling paused until a verified contact and MLS conversation exist")
                except Exception as error:
                    log(f"message poll deferred: {error}")

            time.sleep(idle_sleep)
    finally:
        if engine.process.poll() is None:
            try:
                engine.command({"type": "shutdown"}, timeout=5)
            except Exception:
                engine.process.terminate()


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        log(f"stopped: {error}")
        sys.exit(1)
