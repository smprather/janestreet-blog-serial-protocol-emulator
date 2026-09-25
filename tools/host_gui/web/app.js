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
const DUMPABLE = ["PREPARED", "LOADED", "STOPPED", "DEBUG_HOLD"];

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
        debugReady("DISCONNECTED");
      }
    }
    debugReady(health.state);
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
  const debugButtons = ["debug-step", "bp-set", "bp-clr", "debug-resume"];

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
    $("debug-run").textContent = debug.run ? "high" : "low";
  }

  function debugReady(state) {
    // Step is only legal when the core is held or stopped; a free-running core
    // answers NOT_READY, so the button is disabled instead of inviting an
    // error. Setting a breakpoint IS legal while running.
    const held = state === "DEBUG_HOLD" || state === "BP_HIT" ||
                 state === "STOPPED" || state === "LOADED";
    $(debugButtons[0]).disabled = !held;
    for (const id of debugButtons.slice(1)) $(id).disabled = state === "DISCONNECTED";
  }

  async function debugCall(path, body) {
    try {
      const result = await api(path, { method: "POST", body: JSON.stringify(body) });
      const payload = result.debug || result.step || result.breakpoint;
      if (payload) renderDebug({ ...payload, state_name: result.state_name ||
        payload.state_name, armed: result.armed ?? Boolean(payload.bp_flags & 1),
        hit: result.hit ?? Boolean(payload.bp_flags & 2), run: payload.run ?? 0 });
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

  try {
    // The socket scheme follows the page's scheme: a page served over TLS
    // cannot open a plaintext WebSocket, and a hard-coded ws:// would make
    // the event stream silently unavailable in exactly the deployment where
    // it must not be.
    const socketScheme = location.protocol === "https:" ? "wss:" : "ws:";
    const socket = new WebSocket(`${socketScheme}//${location.host}/api/events`);
    socket.addEventListener("message", (message) => pushEvent(JSON.parse(message.data)));
  } catch (error) {
    setInterval(async () => {
      for (const event of (await api("/api/health")).events ?? []) pushEvent(event);
    }, 2000);
  }

  await refresh();
}

main();
