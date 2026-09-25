"""Tests for tools/host_gui/transport.py — newline-JSON USB CDC transport.

Contract source: wiki/plans/host-controller-gui.md "Host-to-board transport"
and Task 6 Step 2. Requests are newline-delimited JSON objects with a protocol
version, a monotonic integer id, an operation and an argument object; responses
echo the id; asynchronous event objects are queued. A timeout must never be
reported as a successful result.
"""

from __future__ import annotations

import json
import sys
import threading
import time
import unittest
from collections import deque

from tools.host_gui import transport as T
from tools.host_gui.tests.fakes import FakeClock, FaultyPort, ScriptedPort, json_lines


def resp(
    request_id: int, result: dict | None = None, ok: bool = True, error: str | None = None
) -> str:
    return json.dumps(
        {
            "v": T.PROTOCOL_VERSION,
            "id": request_id,
            "ok": ok,
            "result": result,
            "error": error,
        }
    )


def event(name: str, data: dict | None = None) -> str:
    return json.dumps({"v": T.PROTOCOL_VERSION, "event": name, "data": data or {}})


class EchoPort:
    """Answer each request with its own id, yielding the GIL in write().

    The yield is deliberate: it is the window fuzz_server used to show two
    requests reading each other's replies ('response id 7 does not match
    request id 10') and a concurrent poller stealing a reply.
    """

    def __init__(self) -> None:
        self.incoming: deque[bytes] = deque()
        self.closed = False

    def readline(self) -> bytes:
        return self.incoming.popleft() if self.incoming else b""

    def write(self, data: bytes, /) -> int:
        message = json.loads(data.decode("utf-8"))
        reply = (
            json.dumps(
                {
                    "v": T.PROTOCOL_VERSION,
                    "id": message["id"],
                    "ok": True,
                    "result": {"id": message["id"]},
                    "error": None,
                }
            ).encode()
            + b"\n"
        )
        self.incoming.append(reply)
        time.sleep(0)
        return len(data)

    def flush(self) -> None:
        pass

    def close(self) -> None:
        self.closed = True


class TestRequestForm(unittest.TestCase):
    def test_request_assigns_monotonic_ids_and_version(self):
        port = ScriptedPort([resp(1, {"n": 1}), resp(2, {"n": 2})])
        transport = T.SerialTransport(port)
        self.assertEqual(transport.request("ping"), {"n": 1})
        self.assertEqual(transport.request("status"), {"n": 2})
        requests = json_lines(port)
        self.assertEqual([r["id"] for r in requests], [1, 2])
        self.assertEqual([r["op"] for r in requests], ["ping", "status"])
        self.assertEqual(requests[0]["v"], T.PROTOCOL_VERSION)
        self.assertEqual(requests[0]["args"], {})
        self.assertEqual(set(requests[0]), {"v", "id", "op", "args"})

    def test_request_passes_arguments_and_trailing_newline(self):
        port = ScriptedPort([resp(1, {})])
        T.SerialTransport(port).request("load", {"words": [1, 2]})
        self.assertEqual(json_lines(port)[0]["args"], {"words": [1, 2]})
        self.assertTrue(port.writes[0].endswith(b"\n"))

    def test_error_response_raises_bridge_command_error(self):
        port = ScriptedPort([resp(1, None, ok=False, error="bad args")])
        with self.assertRaises(T.BridgeCommandError) as ctx:
            T.SerialTransport(port).request("load", {})
        self.assertEqual(ctx.exception.op, "load")
        self.assertEqual(ctx.exception.error, "bad args")


class TestTimeouts(unittest.TestCase):
    def setUp(self):
        self.clock = FakeClock()

    def _transport(self, port, **kw):
        return T.SerialTransport(
            port, clock=self.clock, sleep=self.clock.sleep, timeout_s=1.0, **kw
        )

    def test_timeout_raises_and_does_not_synthesize_result(self):
        port = ScriptedPort([])
        with self.assertRaises(T.TransportTimeout):
            self._transport(port).request("status")
        self.assertEqual(len(port.writes), 1)  # the request was sent

    def test_late_response_after_timeout_is_ignored(self):
        port = ScriptedPort([])
        transport = self._transport(port)
        with self.assertRaises(T.TransportTimeout):
            transport.request("first")
        port.incoming.append(resp(1, {"stale": True}).encode())
        port.incoming.append(resp(2, {"fresh": True}).encode())
        self.assertEqual(transport.request("second"), {"fresh": True})

    def test_unexpected_response_id_raises_protocol_error(self):
        port = ScriptedPort([resp(99, {"x": 1})])
        with self.assertRaises(T.TransportProtocolError):
            self._transport(port).request("ping")

    def test_wrong_protocol_version_raises_protocol_error(self):
        port = ScriptedPort(
            [json.dumps({"v": 99, "id": 1, "ok": True, "result": {}, "error": None})]
        )
        with self.assertRaises(T.TransportProtocolError):
            self._transport(port).request("ping")

    def test_malformed_json_raises_protocol_error(self):
        port = ScriptedPort(["{not json"])
        with self.assertRaises(T.TransportProtocolError):
            self._transport(port).request("ping")

    def test_non_object_json_raises_protocol_error(self):
        port = ScriptedPort(["[1, 2, 3]"])
        with self.assertRaises(T.TransportProtocolError):
            self._transport(port).request("ping")

    def test_oversized_line_is_rejected(self):
        port = ScriptedPort(["x" * 100])
        with self.assertRaises(T.TransportProtocolError):
            self._transport(port, max_line=32).request("ping")


class TestEvents(unittest.TestCase):
    def setUp(self):
        self.clock = FakeClock()

    def _transport(self, port, **kw):
        return T.SerialTransport(
            port, clock=self.clock, sleep=self.clock.sleep, timeout_s=1.0, **kw
        )

    def test_events_are_queued_while_waiting_for_response(self):
        port = ScriptedPort(
            [event("chip.irq", {"faults": 0x4}), resp(1, {"state": "RUNNING"})]
        )
        transport = self._transport(port)
        self.assertEqual(transport.request("status"), {"state": "RUNNING"})
        events = list(transport.events())
        self.assertEqual(len(events), 1)
        self.assertEqual(events[0]["event"], "chip.irq")
        self.assertEqual(events[0]["data"], {"faults": 0x4})

    def test_poll_events_drains_the_queue(self):
        port = ScriptedPort(
            [event("board.reset"), event("chip.status", {"run": 1}), resp(1, {})]
        )
        transport = self._transport(port)
        transport.request("ping")
        self.assertEqual(len(transport.poll_events()), 2)
        self.assertEqual(transport.poll_events(), [])

    def test_event_queue_is_bounded(self):
        port = ScriptedPort([event("e1"), event("e2"), event("e3"), resp(1, {})])
        transport = self._transport(port, max_events=2)
        transport.request("ping")
        names = [e["event"] for e in transport.poll_events()]
        self.assertEqual(names, ["e2", "e3"])  # oldest dropped

    def test_usb_disconnect_raises_and_queues_event(self):
        port = FaultyPort(OSError("device unplugged"))
        transport = self._transport(port)
        with self.assertRaises(T.TransportClosed):
            transport.request("ping")
        events = transport.poll_events()
        self.assertEqual([e["event"] for e in events], ["usb.disconnect"])

    def test_close_closes_the_port_and_is_idempotent(self):
        port = ScriptedPort([])
        transport = self._transport(port)
        transport.close()
        transport.close()
        self.assertTrue(port.closed)


class TestWireSerialization(unittest.TestCase):
    """fuzz_server (seed 20260926) found concurrent requests crossing on the
    wire and a websocket-style poller stealing replies. One request owns the
    wire at a time, so neither can happen."""

    def test_concurrent_requests_never_read_each_others_replies(self):
        transport = T.SerialTransport(EchoPort(), timeout_s=1.0)
        threads, rounds = 8, 60
        previous = sys.getswitchinterval()
        sys.setswitchinterval(1e-6)  # force the interleave, do not hope
        try:
            for _ in range(rounds):
                results: list[object] = [None] * threads
                barrier = threading.Barrier(threads + 1)

                def worker(
                    index: int,
                    results: list = results,
                    barrier: threading.Barrier = barrier,
                ) -> None:
                    barrier.wait()
                    try:
                        results[index] = transport.request("ping")["id"]
                    except BaseException as exc:  # noqa: BLE001
                        results[index] = exc

                pool = [
                    threading.Thread(target=worker, args=(i,)) for i in range(threads)
                ]
                for thread in pool:
                    thread.start()
                barrier.wait()
                for thread in pool:
                    thread.join()
                for outcome in results:
                    if isinstance(outcome, BaseException):
                        self.fail(
                            "concurrent request corrupted the wire: "
                            f"{type(outcome).__name__}: {outcome}"
                        )
        finally:
            sys.setswitchinterval(previous)

    def test_concurrent_poll_events_does_not_steal_a_response(self):
        transport = T.SerialTransport(EchoPort(), timeout_s=0.2)
        stop = threading.Event()

        def poll() -> None:
            while not stop.is_set():
                transport.poll_events()

        poller = threading.Thread(target=poll, daemon=True)
        poller.start()
        try:
            for _ in range(100):
                transport.request("ping")
        finally:
            stop.set()
            poller.join()


class TestDependencies(unittest.TestCase):
    def test_open_serial_without_pyserial_raises_typed_error(self):
        try:
            import serial  # noqa: F401
        except ImportError:
            pass
        else:
            self.skipTest("pyserial is installed; missing-dependency path untestable")
        with self.assertRaises(T.MissingDependencyError):
            T.open_serial("/dev/ttyACM0")

    def test_version_constant(self):
        self.assertEqual(T.PROTOCOL_VERSION, 1)
        self.assertEqual(T.DEFAULT_BAUDRATE, 115200)
        self.assertLessEqual(T.DEFAULT_MAX_LINE, 65536)


if __name__ == "__main__":
    unittest.main(verbosity=2)
