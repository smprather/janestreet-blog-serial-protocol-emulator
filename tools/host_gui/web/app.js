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

function renderHealth(health) {
  $("connection-state").textContent = health.state;
  $("session-id").textContent = health.session_id || "—";
  $("sclk-cap").textContent = health.sclk_hz
    ? `${(health.sclk_hz / 1e6).toFixed(1)} MHz`
    : "—";
  const connected = health.state !== "DISCONNECTED";
  $("connect").disabled = connected;
  $("load").disabled = !["PREPARED", "LOADED", "STOPPED"].includes(health.state);
  $("start").disabled = !["LOADED", "STOPPED"].includes(health.state);
  $("stop").disabled = health.state !== "RUNNING";
  $("dump").disabled = !["PREPARED", "LOADED", "STOPPED"].includes(health.state);
  setCpuPolling(health.state === "RUNNING");
}

function renderStatus(status) {
  if (!status) return;
  $("chip-state").textContent = status.state === 1 ? "RUNNING" : "STOPPED";
  $("run-state").textContent = status.run ? "on" : "off";
  $("words-written").textContent = status.words_written;
  $("faults").textContent = status.faults
    ? `0x${status.faults.toString(16).padStart(4, "0")}`
    : "none";
}

// The live CPU header comes from READ_CPU, the one non-halting read, so it
// refreshes while the core runs (R2; not chip-confirmed until the RTL lands).
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
      try { renderCpu((await api("/api/read_cpu")).cpu); } catch (error) { /* running read */ }
    }, 1000);
  } else if (!on && cpuPoll) {
    clearInterval(cpuPoll);
    cpuPoll = null;
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
      if (health.state === "RUNNING") {
        renderCpu((await api("/api/read_cpu")).cpu);
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

  try {
    const socket = new WebSocket(`ws://${location.host}/api/events`);
    socket.addEventListener("message", (message) => pushEvent(JSON.parse(message.data)));
  } catch (error) {
    setInterval(async () => {
      for (const event of (await api("/api/health")).events ?? []) pushEvent(event);
    }, 2000);
  }

  await refresh();
}

main();
