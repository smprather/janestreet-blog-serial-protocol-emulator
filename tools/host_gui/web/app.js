/* PE Host Controller — dependency-free operator workspace.
 *
 * Controls map to the plan's rail: connect -> load -> start -> stop -> dump.
 * Load progress is shown while the load request is in flight and finalised
 * from the response's words_written / manifest word_count. Async bridge events
 * arrive over /api/events with a /api/status polling fallback.
 */

"use strict";

const $ = (id) => document.getElementById(id);

async function api(path, options = {}) {
  const response = await fetch(path, {
    headers: { "Content-Type": "application/json" },
    ...options,
  });
  const body = await response.json().catch(() => ({}));
  if (!response.ok) {
    throw new Error(body.detail || `${response.status} ${response.statusText}`);
  }
  return body;
}

function setMessage(text, isError = false) {
  const el = $("message");
  el.textContent = text || "";
  el.classList.toggle("error", Boolean(isError));
}

// Which states each action is offered in. These are the session's rules, not
// the page's: `tests/test_gui_capabilities.py` asks the real ControllerSession
// what it accepts in each state and fails if the two disagree, so a policy
// change on either side has to be made on both.
const LOADABLE = ["PREPARED", "LOADED", "STOPPED"];
// FAULTED is in DUMPABLE deliberately: the sticky fault word IS a header field,
// so a faulted core is exactly the core whose header an operator needs to read.
// A latched fault does not close the read path - it is the session that
// refuses run-control, not reads (see STEPPABLE below).
const DUMPABLE = ["PREPARED", "LOADED", "STOPPED", "DEBUG_HOLD", "FAULTED"];

// The debug panel's four buttons. A single step needs a program to step and a
// core that is not mid-error; the session refuses both cases (nothing loaded is
// nothing to step, and a latched fault means the last frame was rejected), so
// the button offers the SAME rule rather than a hand-copied list of state
// names. The other three need only a chip that implements R3: arming is legal
// while running AND while held (a held core cannot RUN into an armed address -
// the free-running hit is gated on the hold being clear - but a step onto it
// still latches the hit, which is the stop-before flow; the session warns
// about exactly that), and clear/release is the only way off a held core.
const DEBUG_BUTTONS = ["debug-step", "bp-set", "bp-clr", "debug-resume"];
const STEPPABLE = ["LOADED", "STOPPED", "DEBUG_HOLD", "BP_HIT"];

// The event stream's scheme follows the PAGE's scheme. A hard-coded ws:// is
// unavailable in exactly the deployment where the event stream matters most -
// the page served over TLS - and it fails silently: the socket simply never
// opens and the page falls back to polling without saying why.
//
// A lint rule asks for wss unconditionally and reads the `ws:` below as a
// finding. Suppressed deliberately, with the reason: a page served over plain
// HTTP (the local dev server) cannot open wss:// at all, so an unconditional
// wss:// would break the only environment this page is developed in. The
// property that actually matters - "the socket is secure exactly when the page
// is" - is pinned by tests/test_gui_capabilities.py, which drives this
// function with both page schemes.
function eventSocketUrl() {
  const secure = location.protocol === "https:";
  const scheme = secure ? "wss:" : "ws:";
  // nosemgrep: javascript.lang.security.detect-insecure-websocket
  return `${scheme}//${location.host}/api/events`;
}

function applyDebugAvailability(state, available = true) {
  // `available` is the chip's R3 support, which the page discovers by asking:
  // /api/debug answers UNSUPPORTED on a chip without it, and a button that
  // invites an error the chip can only answer with UNSUPPORTED is worse than a
  // greyed one.
  $(DEBUG_BUTTONS[0]).disabled = !available || !STEPPABLE.includes(state);
  for (const id of DEBUG_BUTTONS.slice(1)) {
    $(id).disabled = !available || state === "DISCONNECTED";
  }
}

function renderHealth(health) {
  $("connection-state").textContent = health.state;
  $("session-id").textContent = health.session_id || "—";
  $("sclk-cap").textContent = health.sclk_hz
    ? `${(health.sclk_hz / 1e6).toFixed(1)} MHz`
    : "—";
  const connected = health.state !== "DISCONNECTED";
  $("connect").disabled = connected;
  $("load").disabled = !LOADABLE.includes(health.state);
  // START and STOP are absent from the two HELD states on purpose, not by
  // oversight: while a debug hold is asserted the run strap is MASKED in BOTH
  // directions (`cpu_exec = dbg_step || (run && !dbg_hold)`), so pulling it
  // low neither stops nor starts the core - DEBUG_BP_CLR is the only release,
  // and it also disarms. Offering a Start/Stop that provably does nothing is
  // the same lie as mislabelling the state; see the debug panel's Clear.
  $("start").disabled = !["LOADED", "STOPPED"].includes(health.state);
  $("stop").disabled = health.state !== "RUNNING";
  // DUMP_CORE is gated on the run STRAP, so it answers in every state whose
  // strap is low - which includes a step-pause (DEBUG_HOLD), where the core is
  // held but the strap never went high. It is refused under BP_HIT because a
  // live hit holds the core WITHOUT dropping the strap.
  $("dump").disabled = !DUMPABLE.includes(health.state);
  applyDebugAvailability(health.state);
  // READ_CPU is the ONE non-halting read: the session answers it in every
  // state, including a core parked on a breakpoint, which is exactly when the
  // registers matter. Polling only while RUNNING froze the register view at
  // the pre-hit values while the debug panel showed the post-hit PC.
  setCpuPolling(connected);
  setStatusPolling(connected);
}

// The chip's own state encoding (rtl/pe_ctrl.v:
//   dbg_state = dbg_hold_r ? (bp_hit ? 2'd3 : 2'd2) : (run ? 2'd1 : 2'd0)).
// Four values, not two: R3's debug control made 2 and 3 reachable, and a core
// parked on a breakpoint is 3 WITH the run strap still high. Collapsing that
// to "STOPPED" is a lie the operator acts on - it is how a held core looks
// like an idle one. Same vocabulary and same "(value)" form as the debug
// panel's readout below, so the two rows of this page cannot disagree.
const CHIP_STATE_NAMES = { 0: "STOPPED", 1: "RUNNING", 2: "DEBUG_HOLD",
                           3: "BP_HIT" };

function renderStatus(status) {
  if (!status) return;
  const name = CHIP_STATE_NAMES[status.state];
  // An unrecognised value is shown as itself, never as a definite state: a
  // host talking to a newer chip must not read an unknown word as "STOPPED".
  $("chip-state").textContent =
    `${name || "UNKNOWN"} (${status.state})`;
  $("run-state").textContent = status.run ? "on" : "off";
  $("words-written").textContent = status.words_written;
  $("faults").textContent = status.faults
    ? `0x${status.faults.toString(16).padStart(4, "0")}`
    : "none";
  noteHeartbeat(status.timer, status.run);
}

function renderDebug(debug) {
  // The chip's own state word drives the label; "armed" and "hit" come from
  // bp_flags, never from the address -- a breakpoint at 0 is legal and is
  // only distinguishable by bit0.
  $("debug-state").textContent = `${debug.state_name} (${debug.state})`;
  $("debug-pc").textContent = `0x${debug.pc.toString(16).padStart(3, "0")}`;
  $("debug-bp").textContent = debug.armed
    ? `armed at 0x${debug.bp_addr.toString(16).padStart(3, "0")}` : "disarmed";
  $("debug-bp-flags").textContent =
    `0x${debug.bp_flags.toString(16).padStart(2, "0")}` +
    `${debug.hit ? " (hit latched)" : ""}`;
  // A missing run word means the RESPONSE did not report the strap: the
  // five-word debug prefix (DEBUG_BP_SET, DEBUG_STEP) has no such word. Say so,
  // rather than defaulting to 0 and telling an operator who armed a breakpoint
  // on a RUNNING core that the run strap is low - which is exactly the state
  // where they are about to be stopped by their own breakpoint.
  const run = debug.run;
  let runText = "not reported";
  if (run !== undefined && run !== null) runText = run ? "high" : "low";
  $("debug-run").textContent = runText;
}

// Liveness (P3, host half): the chip's heartbeat is the STATUS timer. A
// RUNNING core whose timer stops advancing is exactly the liveness gap P3
// describes, so the indicator is driven by whether the timer MOVES between
// samples, not by run alone:
//   unknown -> no sample yet; idle -> stopped (a still core is fine);
//   alive -> running and the timer advanced; stale -> running but the timer
//   has not moved (the liveness gap). NOT chip-confirmed until a real run.
let lastHeartbeat = null;
function setLiveness(state, label) {
  const el = $("liveness");
  if (!el) return;
  el.dataset.state = state;
  el.textContent = `liveness: ${label}`;
}
function noteHeartbeat(timer, run) {
  if (!Number.isInteger(timer)) { setLiveness("unknown", "unknown"); return; }
  $("heartbeat").textContent = `0x${timer.toString(16).padStart(4, "0")}`;
  if (!run) { lastHeartbeat = null; setLiveness("idle", "idle (core stopped)"); return; }
  if (lastHeartbeat === null) {
    lastHeartbeat = timer;
    setLiveness("alive", "running (heartbeat: starting)");
    return;
  }
  if (timer !== lastHeartbeat) {
    lastHeartbeat = timer;
    setLiveness("alive", "alive & running");
  } else {
    setLiveness("stale", "running but heartbeat stalled");
  }
}

// The live CPU header comes from READ_CPU, the one non-halting read, so it
// refreshes while the core runs (R2; chip-confirmed in simulation, hardware
// acceptance still open).
function renderCpu(cpu) {
  if (!cpu) return;
  for (const [element, key] of [["cpu-pc", "pc"], ["cpu-a", "a"],
                                ["cpu-x", "x"], ["cpu-y", "y"],
                                ["cpu-insn", "insn"]]) {
    const value = cpu[key];
    $(element).textContent = Number.isInteger(value)
      ? `0x${value.toString(16).padStart(4, "0")}`
      : "—";
  }
}

let cpuPoll = null;
function setCpuPolling(on) {
  if (on && !cpuPoll) {
    cpuPoll = setInterval(async () => {
      // READ_CPU is non-halting, so this also keeps the heartbeat moving while
      // the core runs: one read, registers + liveness together.
      try {
        renderCpu((await api("/api/read_cpu")).cpu);
        renderStatus((await api("/api/status")).status);
      } catch { /* running read */ }
    }, 1000);
  } else if (!on && cpuPoll) {
    clearInterval(cpuPoll);
    cpuPoll = null;
  }
}

// The Pico samples IRQ_N only when a host request unblocks its read loop, so
// a session that sends nothing never observes a chip fault. Keep one light
// status read in flight while connected - not just while running - so a fault
// on a stopped/idle board surfaces within a poll. The response is also our
// event tick: the server drains bridge events per request.
let statusPoll = null;
async function pollStatus() {
  const health = await api("/api/health");
  if (health.state === "DISCONNECTED") { setStatusPolling(false); return; }
  renderStatus((await api("/api/status")).status);
}
function setStatusPolling(on) {
  if (on && !statusPoll) {
    statusPoll = setInterval(() => { pollStatus().catch(() => {}); }, 2000);
  } else if (!on && statusPoll) {
    clearInterval(statusPoll);
    statusPoll = null;
  }
}

function renderManifest(manifest) {
  const el = $("manifest");
  el.innerHTML = "";
  if (!manifest) return;
  const rows = [
    ["source", manifest.source],
    ["words", manifest.word_count],
    ["load address", manifest.load_address],
    ["clock", `${(manifest.clock_hz / 1e6).toFixed(0)} MHz`],
    ["sha256", manifest.sha256.slice(0, 16) + "…"],
    ["terminal jump", manifest.terminal_jump ? "yes" : "no"],
  ];
  for (const [key, value] of rows) {
    const dt = document.createElement("dt");
    dt.textContent = key;
    const dd = document.createElement("dd");
    dd.textContent = value;
    el.append(dt, dd);
  }
  for (const warning of manifest.warnings || []) {
    const p = document.createElement("p");
    p.className = "warning";
    p.textContent = warning;
    el.append(p);
  }
}

function pushEvent(event) {
  const item = document.createElement("li");
  const time = new Date().toLocaleTimeString();
  item.textContent = `[${time}] ${event.event} ${JSON.stringify(event.data ?? {})}`;
  $("events").prepend(item);
  if (event.event === "chip.irq") setMessage("chip fault asserted", true);
}

async function refresh() {
  try {
    const health = await api("/api/health");
    renderHealth(health);
    if (health.state !== "DISCONNECTED") {
      renderStatus((await api("/api/status")).status);
      // READ_CPU answers while stopped, held or running (it is the non-halting
      // read), so the register view is fetched whenever the session is up. It
      // used to be fetched only while RUNNING, which froze the registers at
      // their pre-breakpoint values on a core that had just been stopped BY its
      // breakpoint - while the debug panel, read a moment later, showed the
      // post-hit PC. Two views of one register, disagreeing.
      renderCpu((await api("/api/read_cpu")).cpu);
      try {
        renderDebug(await api("/api/debug"));
      } catch {
        // A chip without R3 answers UNSUPPORTED; the panel says so instead of
        // leaving stale values on screen.
        $("debug-state").textContent = "not supported by this chip";
        applyDebugAvailability(health.state, false);
      }
    }
  } catch (error) {
    setMessage(error.message, true);
  }
}

async function withProgress(label, task) {
  const bar = $("load-progress-bar");
  bar.style.width = "10%";
  setMessage(`${label}…`);
  try {
    return await task((progress) => { bar.style.width = `${progress}%`; });
  } finally {
    bar.style.width = "0%";
  }
}

async function main() {
  try {
    const { sources } = await api("/api/sources");
    for (const name of sources) {
      const option = document.createElement("option");
      option.value = name;
      option.textContent = name;
      $("sources").append(option);
    }
  } catch (error) {
    setMessage(error.message, true);
  }

  $("connect").addEventListener("click", async () => {
    try {
      await withProgress("Connecting", () => api("/api/connect", { method: "POST" }));
      await refresh();
    } catch (error) { setMessage(error.message, true); }
  });

  $("load").addEventListener("click", async () => {
    const source = $("sources").value;
    try {
      const result = await withProgress("Loading", () =>
        api("/api/load", { method: "POST", body: JSON.stringify({ source }) }));
      renderManifest(result.manifest);
      $("load-progress-bar").style.width = "100%";
      setMessage(`loaded ${result.load.words_written} words`);
      await refresh();
    } catch (error) {
      setMessage(error.message, true);
      await refresh();
    }
  });

  for (const [id, path] of [["start", "/api/start"], ["stop", "/api/stop"],
                            ["dump", "/api/dump"]]) {
    $(id).addEventListener("click", async () => {
      try {
        const result = await api(path, { method: "POST" });
        if (result.dump) renderStatus(result.dump);
        setMessage(`${id} ok`);
        await refresh();
      } catch (error) { setMessage(error.message, true); }
    });
  }

  // ---- R3 debug panel ----------------------------------------------------

  async function debugCall(path, body) {
    try {
      const result = await api(path, { method: "POST", body: JSON.stringify(body) });
      const payload = result.debug || result.step || result.breakpoint;
      if (payload) renderDebug({ ...payload, state_name: result.state_name ||
        payload.state_name, armed: result.armed ?? Boolean(payload.bp_flags & 1),
        hit: result.hit ?? Boolean(payload.bp_flags & 2),
        // left undefined when the response carries no run word, so the
        // panel can say "not reported" instead of inventing "low"
        run: payload.run });
      setDebugMessage(`${path} ok`);
      await refresh();
    } catch (error) {
      setDebugMessage(error.message, true);
    }
  }

  function setDebugMessage(text, bad) {
    const el = $("debug-message");
    el.textContent = text;
    el.classList.toggle("error", Boolean(bad));
  }

  const bpAddress = () => Number($("bp-address").value);

  $("debug-step").addEventListener("click", () => debugCall("/api/debug/step", {}));
  $("bp-set").addEventListener("click", () => debugCall("/api/debug/bp_set", { address: bpAddress() }));
  $("bp-clr").addEventListener("click", () => debugCall("/api/debug/bp_clr", {}));
  $("debug-resume").addEventListener("click", () => debugCall("/api/debug/resume", { address: bpAddress() }));

  // The event stream, with a polling fallback for when there is no socket.
  let eventPollFallback = null;
  const startEventPolling = () => {
    if (eventPollFallback) return;
    eventPollFallback = setInterval(async () => {
      for (const event of (await api("/api/health")).events ?? []) pushEvent(event);
    }, 2000);
  };
  try {
    const socket = new WebSocket(eventSocketUrl());
    // A WebSocket to an endpoint that is not listening does NOT throw: it
    // fires `error` and closes. A fallback hung only on `catch` therefore
    // never engaged, and the event stream died silently - the same failure
    // `eventSocketUrl` exists to prevent, one layer up. So the fallback hangs
    // off the events, and `catch` is left for the synchronous throw (a bad URL).
    socket.addEventListener("error", startEventPolling);
    socket.addEventListener("close", startEventPolling);
    socket.addEventListener("message", (message) => pushEvent(JSON.parse(message.data)));
  } catch {
    startEventPolling();
  }

  await refresh();
}

main();
