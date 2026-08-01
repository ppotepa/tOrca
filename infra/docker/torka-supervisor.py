#!/usr/bin/env python3
"""Restart the development Torka client after transient engine failures."""

import os
import signal
import subprocess
import sys
import time


STOPPING = False
CHILD = None


def log(message):
    print(f"[torka-supervisor] {message}", flush=True)


def stop(signum, _frame):
    global STOPPING
    STOPPING = True
    child = CHILD
    if child is not None and child.poll() is None:
        child.send_signal(signum)


def main():
    global CHILD
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)

    minimum_backoff = max(1, int(os.environ.get("TORCHAT_TORKA_RESTART_MIN_SECONDS", "2")))
    maximum_backoff = max(
        minimum_backoff,
        int(os.environ.get("TORCHAT_TORKA_RESTART_MAX_SECONDS", "60")),
    )
    backoff = minimum_backoff

    while not STOPPING:
        started_at = time.monotonic()
        log("TORCHAT_TORKA_START")
        CHILD = subprocess.Popen(["/usr/local/bin/torka-client"])
        exit_code = CHILD.wait()
        CHILD = None
        if STOPPING:
            return 0

        lived_for = time.monotonic() - started_at
        if lived_for >= 120:
            backoff = minimum_backoff
        log(
            f"TORCHAT_TORKA_EXIT code={exit_code}; restarting in {backoff}s "
            f"after {lived_for:.1f}s"
        )
        time.sleep(backoff)
        backoff = min(maximum_backoff, backoff * 2)

    return 0


if __name__ == "__main__":
    sys.exit(main())
