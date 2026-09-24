"""Test doubles for the host GUI phase 1b tests (transport/session/server).

Kept out of the production modules on purpose: the transport accepts any
``LinePort`` (readline/write/flush/close) so tests never need pyserial, and the
session accepts a transport factory so reconnect logic can swap transports.
"""

from __future__ import annotations

import json
from collections import deque


class FakeClock:
    """Deterministic clock+sleep pair so timeout tests run instantly."""

    def __init__(self) -> None:
        self.now = 0.0

    def __call__(self) -> float:
        return self.now

    def sleep(self, seconds: float) -> None:
        self.now += seconds


class ScriptedPort:
    """LinePort driven by pre-loaded incoming lines; records writes."""

    def __init__(self, lines=()) -> None:
        self.incoming = deque(
            line.encode() if isinstance(line, str) else line for line in lines)
        self.writes: list[bytes] = []
        self.closed = False

    def readline(self) -> bytes:
        return self.incoming.popleft() if self.incoming else b""

    def write(self, data: bytes) -> int:
        self.writes.append(data)
        return len(data)

    def flush(self) -> None:
        pass

    def close(self) -> None:
        self.closed = True


class FaultyPort(ScriptedPort):
    """LinePort whose read raises, to simulate a USB disconnect."""

    def __init__(self, error: OSError) -> None:
        super().__init__([])
        self.error = error

    def readline(self) -> bytes:
        raise self.error


class LoopbackPort:
    """LinePort wired to a FakeBridge: writes are handled, replies queued."""

    def __init__(self, bridge) -> None:
        self.bridge = bridge
        self.incoming: deque[bytes] = deque()
        self.writes: list[bytes] = []
        self.closed = False

    def readline(self) -> bytes:
        return self.incoming.popleft() if self.incoming else b""

    def write(self, data: bytes) -> int:
        self.writes.append(data)
        for line in self.bridge.handle_line(data.decode("utf-8").strip()):
            self.incoming.append(line.encode())
        return len(data)

    def flush(self) -> None:
        pass

    def close(self) -> None:
        self.closed = True


class StubTransport:
    """Session-facing transport double: scripted results and queued events."""

    def __init__(self, responses=(), events=()) -> None:
        self.responses = deque(responses)
        self.queue = deque(events)
        self.requests: list[tuple[str, dict]] = []
        self.closed = False

    def request(self, op, args=None, *, timeout_s=None):
        self.requests.append((op, dict(args or {})))
        if not self.responses:
            raise AssertionError(f"StubTransport: no response queued for {op!r}")
        item = self.responses.popleft()
        if isinstance(item, Exception):
            raise item
        return item

    def poll_events(self):
        out = list(self.queue)
        self.queue.clear()
        return out

    def close(self) -> None:
        self.closed = True


def json_lines(port) -> list[dict]:
    """Parse every line a port recorded from the transport."""
    return [json.loads(w.decode("utf-8").strip()) for w in port.writes]
