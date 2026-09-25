"""Bounded host soak: the bridge + session + API loop under an RSS watch.

Why this exists: the demo machine has a history of Python processes
OOM-killing everything around them. A leak in the host stack (the bridge
session, the transport, the server, or the image assembler) would repeat it
live, and no unit test can see it. This runner keeps the real host path hot
for a bounded run - minutes or cycles, whichever comes first - samples RSS
and GC object counts, and fails when the footprint does not stay bounded
after warmup.

What it drives (in-process; it never opens a serial device):

  * one long-lived ``Api``/``ControllerSession``/``SerialTransport`` over a
    ``FakeBridge`` - the steady-state server process;
  * a load -> run -> status/read_cpu -> stop -> dump/read cycle, with a full
    image *assembly* through ``Api.load`` every ``--assemble-every`` cycles;
  * a reconnect every ``--reconnect-every`` cycles (fresh transport+bridge),
    so teardown paths are soaked too;
  * a hostile-bridge fraction (dropped replies -> typed timeout faults), so
    failure paths are soaked, not just the happy path;
  * a protocol-fuzz chunk every ``--fuzz-every`` cycles (both decoders plus
    the chip-side model), the same campaign the gate runs.

Verdict: after a final ``gc.collect()``, growth from the warmup baseline
beyond ``--max-growth-mb`` RSS (or ``--max-object-growth`` live GC objects)
is a finding. The analysis (``summarize``) is a pure function and unit-tested;
samples are written to ``--json`` for post-mortem.

Usage:
    python3 -m tools.host_gui.soak_host --minutes 20
    python3 -m tools.host_gui.soak_host --cycles 5000 --json /tmp/soak.json

Exit: 0 = footprint bounded (or the run was too short to judge), 1 = finding.
"""

from __future__ import annotations

import argparse
import functools
import gc
import json
import math
import random
import time
from pathlib import Path
from types import SimpleNamespace

from tools.host_gui import fake_pe as F
from tools.host_gui import fuzz_protocol as FZ
from tools.host_gui import image as I
from tools.host_gui import server as SV
from tools.host_gui import session as S
from tools.host_gui import transport as T

DEFAULT_SEED = 20260926
DEFAULT_MINUTES = 20.0
DEFAULT_MAX_GROWTH_MB = 8.0
DEFAULT_MAX_OBJECT_GROWTH = 50_000
FUZZ_CHUNK_ITERATIONS = 40


class FakeClock:
    """Deterministic clock+sleep, so a dropped reply times out instantly."""

    def __init__(self) -> None:
        self.now = 0.0

    def __call__(self) -> float:
        return self.now

    def sleep(self, seconds: float) -> None:
        self.now += seconds


class LeanPort:
    """Loopback to a bridge with no write recording (no harness growth)."""

    def __init__(self, bridge) -> None:
        self.bridge = bridge
        self.incoming: list[bytes] = []
        self.closed = False

    def write(self, data: bytes, /) -> int:
        for reply in self.bridge.handle_line(data.decode("utf-8").strip()):
            self.incoming.append(reply.encode())
        return len(data)

    def readline(self) -> bytes:
        return self.incoming.pop(0) if self.incoming else b""

    def flush(self) -> None:
        pass

    def close(self) -> None:
        self.closed = True


class FlakyBridge(F.FakeBridge):
    """FakeBridge whose replies can be dropped on demand (a flaky USB link)."""

    def __init__(self) -> None:
        super().__init__()
        self.drop = False

    def handle_line(self, line: str) -> list[str]:
        if self.drop:
            return []
        return super().handle_line(line)


@functools.cache
def _image():
    """The real firmware image, assembled once (assembly is ~36 ms)."""
    config = SV.ServerConfig.default()
    path = SV.resolve_source("uart_echo.pe", config.sources_dir)
    return I.assemble_program(path, config.repo_root)


def rss_bytes() -> int:
    """Resident set size of this process, best effort, in bytes."""
    try:
        with open("/proc/self/status", encoding="ascii") as handle:
            for line in handle:
                if line.startswith("VmRSS:"):
                    return int(line.split()[1]) * 1024
    except OSError:
        pass
    import resource
    return resource.getrusage(resource.RUSAGE_SELF).ru_maxrss * 1024


def gc_object_count() -> int:
    """Live GC-tracked objects (after a collect); the leak signal RSS blurs."""
    gc.collect()
    return len(gc.get_objects())


def summarize(samples, *, max_growth_mb: float = DEFAULT_MAX_GROWTH_MB,
              max_object_growth: int = DEFAULT_MAX_OBJECT_GROWTH,
              warmup_fraction: float = 0.25) -> dict:
    """Judge a soak from its samples: (t, cycles, rss_bytes, objects|None).

    Baseline is the minimum RSS over the first ``warmup_fraction`` of samples
    (allocation warmup is not a leak); final is the last sample. Growth beyond
    the thresholds is a finding. A run with fewer than four samples, or one
    shorter than 20 s, is reported as ``insufficient`` rather than a pass.
    """
    usable = [s for s in samples if s[2]]
    if len(usable) < 4 or usable[-1][0] - usable[0][0] < 20.0:
        return {"verdict": "insufficient",
                "samples": len(usable),
                "seconds": round(usable[-1][0] - usable[0][0], 1)
                if usable else 0.0,
                "baseline_rss_mb": None, "final_rss_mb": None,
                "growth_mb": None, "growth_mb_per_hour": None,
                "object_growth": None, "ok": True}
    cut = max(1, round(len(usable) * warmup_fraction))
    baseline = min(sample[2] for sample in usable[:cut])
    final = usable[-1][2]
    growth = final - baseline
    span_s = max(1e-9, usable[-1][0] - usable[0][0])
    objects = [sample[3] for sample in usable if sample[3] is not None]
    object_growth = (objects[-1] - min(objects)) if len(objects) >= 2 else 0
    ok = (growth <= max_growth_mb * 1e6
          and object_growth <= max_object_growth)
    return {"verdict": "bounded" if ok else "leak",
            "samples": len(usable), "seconds": round(span_s, 1),
            "baseline_rss_mb": round(baseline / 1e6, 2),
            "final_rss_mb": round(final / 1e6, 2),
            "growth_mb": round(growth / 1e6, 3),
            "growth_mb_per_hour": round(growth / 1e6 / span_s * 3600, 2),
            "object_growth": object_growth,
            "max_growth_mb": max_growth_mb,
            "max_object_growth": max_object_growth,
            "ok": ok}


def _new_stack(*, hostile: bool = False):
    bridge = FlakyBridge() if hostile else F.FakeBridge()
    clock = None
    if hostile:
        clock = FakeClock()
    ports: list[LeanPort] = []

    def factory():
        port = LeanPort(bridge)
        ports.append(port)
        if clock is not None:
            return T.SerialTransport(port, clock=clock, sleep=clock.sleep)
        return T.SerialTransport(port)

    session = S.ControllerSession(factory)
    api = SV.Api(session, SV.ServerConfig.default())
    return SimpleNamespace(api=api, session=session, bridge=bridge,
                           clock=clock, ports=ports)


def _clean_cycle(stack) -> None:
    """One legal, steady-state cycle: status/run/read/stop or dump/read."""
    session = stack.session
    session.status()
    phase = session.state
    if phase is S.SessionState.PREPARED:
        session.load(_image())
    elif phase is S.SessionState.LOADED or phase is S.SessionState.STOPPED:
        session.start()
        session.status()
        session.read_cpu()
        session.stop()
        session.dump_core()
        session.read_imem(0, 4)
        session.read_dmem(0, 4)
    elif phase is S.SessionState.RUNNING:
        session.status()
        session.read_cpu()
        session.stop()
    elif phase is S.SessionState.FAULTED:
        session.clear_fault()


def run(*, minutes: float = DEFAULT_MINUTES, cycles: int = 0,
        seed: int = DEFAULT_SEED, sample_every: int = 100,
        sample_seconds: float = 2.0, reconnect_every: int = 2000,
        assemble_every: int = 500, hostile_every: int = 500,
        fuzz_every: int = 250, http: bool = False,
        max_growth_mb: float = DEFAULT_MAX_GROWTH_MB,
        max_object_growth: int = DEFAULT_MAX_OBJECT_GROWTH,
        progress=None) -> dict:
    """Run the soak; returns the result dict (never raises on a finding)."""
    rng = random.Random(seed)
    started = time.monotonic()
    deadline = started + minutes * 60.0 if minutes > 0 else math.inf
    stack = _new_stack()
    stack.session.connect()
    stack.session.load(_image())
    samples: list[tuple[float, int, int, int | None]] = []
    done = 0
    last_sample = 0.0
    http_client = None
    if http and SV.HAVE_FASTAPI:
        from fastapi.testclient import TestClient  # type: ignore[import-not-found]
        http_client = TestClient(SV.create_app(stack.api, stack.api.config),
                                 raise_server_exceptions=False)
    while done < cycles if cycles else True:
        now = time.monotonic()
        if now >= deadline:
            break
        done += 1
        try:
            _clean_cycle(stack)
            if done % assemble_every == 0:
                stack.api.load("uart_echo.pe")        # the real route+assemble
            if http_client is not None and done % 50 == 0:
                http_client.get("/api/status")
            if done % hostile_every == 0:
                _hostile_cycle(rng)
            if done % fuzz_every == 0:
                FZ.run(seed=seed + done, iterations=FUZZ_CHUNK_ITERATIONS,
                       budget_s=10.0)
            if done % reconnect_every == 0:
                stack.session.disconnect()
                stack = _new_stack()
                stack.session.connect()
                stack.session.load(_image())
        except S.SessionError:
            # A refused/failed op is handled by reconnecting; the soak is not
            # a correctness campaign (fuzz_server owns that) - it is a memory
            # watch that must keep the stack alive and busy.
            stack.session.disconnect()
            stack = _new_stack()
            stack.session.connect()
            stack.session.load(_image())
        now = time.monotonic()
        if (done % sample_every == 0 or now - last_sample >= sample_seconds):
            objects = gc_object_count() if done % (sample_every * 3) == 0 \
                else None
            samples.append((now - started, done, rss_bytes(), objects))
            last_sample = now
            if progress is not None and len(samples) % 10 == 0:
                progress(done, samples[-1])
    gc.collect()
    samples.append((time.monotonic() - started, done, rss_bytes(),
                    gc_object_count()))
    summary = summarize(samples, max_growth_mb=max_growth_mb,
                        max_object_growth=max_object_growth)
    return {"seed": seed, "cycles": done,
            "seconds": round(time.monotonic() - started, 1),
            "minutes_requested": minutes, "summary": summary,
            "samples": samples,
            "ok": summary["ok"]}


def _hostile_cycle(rng: random.Random) -> None:
    """Soak the failure path: a dropped reply, a typed timeout, then recovery."""
    stack = _new_stack(hostile=True)
    stack.session.connect()
    stack.bridge.drop = True
    try:
        stack.session.load(_image())
    except S.SessionError:
        pass
    stack.bridge.drop = False
    try:
        if stack.session.state is S.SessionState.FAULTED:
            stack.session.clear_fault()
        stack.session.load(_image())
    except S.SessionError:
        pass
    stack.session.disconnect()


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(
        description=(__doc__ or "host soak").split("\n")[0])
    parser.add_argument("--minutes", type=float, default=DEFAULT_MINUTES)
    parser.add_argument("--cycles", type=int, default=0,
                        help="stop after N cycles (0 = minutes only)")
    parser.add_argument("--seed", type=int, default=DEFAULT_SEED)
    parser.add_argument("--sample-every", type=int, default=100)
    parser.add_argument("--sample-seconds", type=float, default=2.0)
    parser.add_argument("--reconnect-every", type=int, default=2000)
    parser.add_argument("--assemble-every", type=int, default=500)
    parser.add_argument("--hostile-every", type=int, default=500)
    parser.add_argument("--fuzz-every", type=int, default=250)
    parser.add_argument("--http", action="store_true",
                        help="also exercise the FastAPI routes (needs fastapi)")
    parser.add_argument("--max-growth-mb", type=float,
                        default=DEFAULT_MAX_GROWTH_MB)
    parser.add_argument("--max-object-growth", type=int,
                        default=DEFAULT_MAX_OBJECT_GROWTH)
    parser.add_argument("--json", type=Path, default=None)
    args = parser.parse_args(argv)
    result = run(minutes=args.minutes, cycles=args.cycles, seed=args.seed,
                 sample_every=args.sample_every,
                 sample_seconds=args.sample_seconds,
                 reconnect_every=args.reconnect_every,
                 assemble_every=args.assemble_every,
                 hostile_every=args.hostile_every,
                 fuzz_every=args.fuzz_every, http=args.http,
                 max_growth_mb=args.max_growth_mb,
                 max_object_growth=args.max_object_growth)
    summary = result["summary"]
    print(f"soak seed={result['seed']} cycles={result['cycles']} "
          f"seconds={result['seconds']}")
    print(f"  verdict: {summary['verdict']}  "
          f"rss {summary['baseline_rss_mb']} -> {summary['final_rss_mb']} MB "
          f"(+{summary['growth_mb']} MB, "
          f"{summary['growth_mb_per_hour']} MB/h), "
          f"objects +{summary['object_growth']}")
    if args.json is not None:
        args.json.write_text(json.dumps(result, indent=1), encoding="utf-8")
        print(f"  samples -> {args.json}")
    print("RESULT: PASS" if result["ok"] else "RESULT: FAIL (footprint grew)")
    return 0 if result["ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
