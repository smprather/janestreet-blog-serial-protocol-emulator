/**
 * Hermes Live Canvas — Dashboard Plugin
 *
 * A pane that renders diagram files (HTML / SVG) live. The backend watches the
 * configured directories and pushes revisions over a WebSocket; this component
 * keeps a slide list, renders the newest slide by default, and re-reads a slide
 * in place whenever its file changes on disk.
 *
 * Plain IIFE, no build step. React + UI primitives come from
 * window.__HERMES_PLUGIN_SDK__; auth (loopback token / gated ticket) is handled
 * by SDK.fetchJSON and SDK.buildWsUrl so this file never reads a credential.
 */
(function () {
  "use strict";

  var SDK = window.__HERMES_PLUGIN_SDK__;
  if (!SDK) return;

  var React = SDK.React;
  var h = React.createElement;
  var hooks = SDK.hooks || {};
  var useState = hooks.useState || React.useState;
  var useEffect = hooks.useEffect || React.useEffect;
  var useCallback = hooks.useCallback || React.useCallback;
  var useMemo = hooks.useMemo || React.useMemo;
  var useRef = hooks.useRef || React.useRef;

  var API = "/api/plugins/live-canvas";

  // ---------------------------------------------------------------------
  // helpers
  // ---------------------------------------------------------------------

  function fmtBytes(n) {
    if (typeof n !== "number") return "";
    if (n < 1024) return n + " B";
    if (n < 1024 * 1024) return (n / 1024).toFixed(1) + " KB";
    return (n / (1024 * 1024)).toFixed(1) + " MB";
  }

  function relTime(ts) {
    try {
      if (SDK.utils && SDK.utils.timeAgo) return SDK.utils.timeAgo(ts * 1000);
    } catch (_e) {}
    return new Date(ts * 1000).toLocaleTimeString();
  }

  /** Wrap a slide body in a minimal document for the sandboxed iframe. */
  function frameDoc(slide, body) {
    if (slide.kind === "render" && slide.ext === "svg") {
      // Fit the WIDTH, scroll the height. Fitting both dimensions shrinks a tall
      // chart until its labels are unreadable; flowcharts read top-down, so a
      // vertical scroll is the natural gesture and text stays legible.
      return (
        "<!doctype html><html><head><meta charset=\"utf-8\">" +
        "<style>html,body{margin:0;padding:0;background:#fff;height:100%}" +
        "body{overflow-y:auto;overflow-x:hidden;display:block}" +
        "svg{width:100%;height:auto;display:block}</style>" +
        "</head><body>" + body + "</body></html>"
      );
    }
    return body;
  }

  var PANE_CSS = [
    ".lc-root{display:flex;flex-direction:column;height:calc(100vh - 140px);min-height:420px}",
    ".lc-bar{display:flex;align-items:center;gap:10px;padding:8px 4px;flex-wrap:wrap}",
    ".lc-dot{width:8px;height:8px;border-radius:50%;display:inline-block}",
    ".lc-body{display:flex;flex:1;min-height:0;gap:12px}",
    ".lc-list{width:230px;flex:0 0 auto;overflow:auto;border:1px solid var(--color-border,rgba(128,128,128,.3));border-radius:8px;padding:6px}",
    ".lc-item{padding:6px 8px;border-radius:6px;cursor:pointer;font-size:12px;line-height:1.35;word-break:break-all}",
    ".lc-item:hover{background:color-mix(in oklab, currentColor 8%, transparent)}",
    ".lc-item.lc-active{background:color-mix(in oklab, currentColor 14%, transparent);font-weight:600}",
    ".lc-item .lc-meta{opacity:.65;font-size:11px;display:block}",
    ".lc-stage{flex:1;min-width:0;border:1px solid var(--color-border,rgba(128,128,128,.3));border-radius:8px;overflow:hidden;background:#fff;position:relative}",
    ".lc-stage iframe{width:100%;height:100%;border:0;display:block;background:#fff}",
    // Text slides sit on the same paper-white stage as rendered ones, so their
    // colours must be set explicitly: inheriting the dashboard's dark-theme
    // foreground gives light-grey-on-white (unreadable).
    ".lc-stage pre{width:100%;height:100%;margin:0;overflow:auto;padding:14px 16px;background:#fff;color:#1f2328;font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;font-size:12.5px;line-height:1.55;white-space:pre-wrap;overflow-wrap:anywhere}",
    ".lc-empty{display:flex;height:100%;align-items:center;justify-content:center;flex-direction:column;gap:10px;color:#57606a;background:#fff;font-size:13px;text-align:center;padding:20px}",
    ".lc-warn{color:#9a6700;font-size:12px}",
  ].join("");

  // ---------------------------------------------------------------------
  // component
  // ---------------------------------------------------------------------

  function LiveCanvasPage() {
    var state = useState({ rev: 0, slides: [], roots: [], changed: null, last_error: "" });
    var snap = state[0];
    var setSnap = state[1];

    var sel = useState(null);
    var selectedKey = sel[0];
    var setSelectedKey = sel[1];

    var fol = useState(true);
    var follow = fol[0];
    var setFollow = fol[1];

    var docState = useState({ key: null, slide: null, body: "", error: "" });
    var doc = docState[0];
    var setDoc = docState[1];

    var link = useState("connecting");
    var wsState = link[0];
    var setWsState = link[1];

    var wsRef = useRef(null);
    var wsClosedRef = useRef(false);
    var backoffRef = useRef(1000);
    var selectedKeyRef = useRef(null);
    var followRef = useRef(true);

    selectedKeyRef.current = selectedKey;
    followRef.current = follow;

    var applyState = useCallback(function (frame) {
      if (!frame || typeof frame !== "object") return;
      setSnap(function (prev) {
        // Rev-guard: WS frames and HTTP polls can race; never go backwards.
        if (typeof frame.rev === "number" && frame.rev < prev.rev) return prev;
        return {
          rev: frame.rev != null ? frame.rev : prev.rev,
          slides: Array.isArray(frame.slides) ? frame.slides : prev.slides,
          roots: Array.isArray(frame.roots) ? frame.roots : prev.roots,
          changed: frame.changed !== undefined ? frame.changed : prev.changed,
          last_error: frame.last_error !== undefined ? frame.last_error : prev.last_error,
        };
      });
    }, []);

    // --- initial state -------------------------------------------------
    useEffect(function () {
      var cancelled = false;
      SDK.fetchJSON(API + "/state")
        .then(function (frame) {
          if (!cancelled) applyState(frame);
        })
        .catch(function (err) {
          if (!cancelled) setWsState("error: " + (err && err.message ? err.message : String(err)));
        });
      return function () {
        cancelled = true;
      };
    }, [applyState]);

    // --- WebSocket -----------------------------------------------------
    useEffect(function () {
      wsClosedRef.current = false;
      function openWs() {
        if (wsClosedRef.current) return;
        var params = { since: String((snap.rev || 0) > 0 ? snap.rev - 1 : 0) };
        SDK.buildWsUrl(API + "/events", params)
          .then(function (url) {
            if (wsClosedRef.current) return;
            var ws;
            try {
              ws = new WebSocket(url);
            } catch (_e) {
              return;
            }
            wsRef.current = ws;
            ws.onopen = function () {
              backoffRef.current = 1000;
              setWsState("live");
            };
            ws.onmessage = function (ev) {
              try {
                var msg = JSON.parse(ev.data);
                if (msg && msg.type === "state") applyState(msg);
              } catch (_e) {}
            };
            ws.onclose = function (ev) {
              if (wsClosedRef.current) return;
              if (ev && ev.code === 1008) {
                setWsState("auth failed — reload the page");
                return;
              }
              setWsState("reconnecting");
              var delay = Math.min(backoffRef.current, 30000);
              backoffRef.current = Math.min(backoffRef.current * 2, 30000);
              setTimeout(openWs, delay);
            };
          })
          .catch(function () {
            if (wsClosedRef.current) return;
            setWsState("reconnecting");
            var d = Math.min(backoffRef.current, 30000);
            backoffRef.current = Math.min(backoffRef.current * 2, 30000);
            setTimeout(openWs, d);
          });
      }
      openWs();
      return function () {
        wsClosedRef.current = true;
        try {
          if (wsRef.current) wsRef.current.close();
        } catch (_e) {}
      };
      // eslint-disable-next-line react-hooks/exhaustive-deps
    }, [applyState]);

    // --- follow the newest slide ---------------------------------------
    useEffect(function () {
      if (!follow || !snap.slides.length) return;
      var newest = snap.slides[0];
      if (newest && newest.key !== selectedKeyRef.current) setSelectedKey(newest.key);
    }, [snap.slides, snap.rev, follow, setSelectedKey]);

    // --- fetch the selected slide, and re-fetch it when it changes ------
    var changedKeys = useMemo(function () {
      var c = snap.changed;
      return c && Array.isArray(c.keys) ? c.keys.join("\u0000") : "";
    }, [snap.changed]);

    useEffect(function () {
      if (!selectedKey) {
        setDoc({ key: null, slide: null, body: "", error: "" });
        return;
      }
      var cancelled = false;
      var slide = null;
      for (var i = 0; i < snap.slides.length; i++) {
        if (snap.slides[i].key === selectedKey) {
          slide = snap.slides[i];
          break;
        }
      }
      SDK.fetchJSON(API + "/slide?key=" + encodeURIComponent(selectedKey))
        .then(function (payload) {
          if (cancelled) return;
          setDoc({ key: selectedKey, slide: slide, body: payload.body || "", error: "" });
        })
        .catch(function (err) {
          if (cancelled) return;
          setDoc({ key: selectedKey, slide: slide, body: "", error: err && err.message ? err.message : String(err) });
        });
      return function () {
        cancelled = true;
      };
    }, [selectedKey, changedKeys, snap.slides, setDoc]);

    // --- render ---------------------------------------------------------
    var slides = snap.slides || [];
    var activeSlide = doc.slide;
    var bodyForFrame = doc.body || "";
    var isRender = activeSlide && activeSlide.kind === "render" && doc.key === selectedKey;

    var stage = null;
    if (!slides.length) {
      stage = h(
        "div",
        { className: "lc-empty" },
        h("div", null, "No diagrams yet."),
        h(
          "div",
          null,
          "Write an .html or .svg file into a watched directory and it appears here.",
        ),
        h(
          "div",
          { className: "lc-warn" },
          (snap.roots || []).length ? "Watching: " + snap.roots.join("  ·  ") : "No roots configured.",
        ),
      );
    } else if (doc.error) {
      stage = h("div", { className: "lc-empty" }, h("div", null, "Could not read slide"), h("div", { className: "lc-warn" }, doc.error));
    } else if (!selectedKey) {
      stage = h("div", { className: "lc-empty" }, h("div", null, "Select a slide"));
    } else if (isRender) {
      stage = h("iframe", {
        title: activeSlide.name,
        // No allow-same-origin: the diagram runs in an opaque origin and cannot
        // touch the dashboard's DOM, storage or session token.
        sandbox: "allow-scripts",
        srcDoc: frameDoc(activeSlide, bodyForFrame),
      });
    } else {
      stage = h("pre", null, bodyForFrame);
    }

    return h(
      "div",
      { className: "lc-root" },
      h("style", null, PANE_CSS),

      h(
        "div",
        { className: "lc-bar" },
        h(
          "span",
          { className: "lc-dot", style: { background: wsState === "live" ? "#2f9e44" : wsState === "connecting" ? "#b8860b" : "#c92a2a" } },
        ),
        h("strong", null, "Live Canvas"),
        h("span", { style: { fontSize: 12, opacity: 0.7 } }, wsState + " · rev " + snap.rev + " · " + slides.length + " slide" + (slides.length === 1 ? "" : "s")),
        h(
          "button",
          {
            onClick: function () {
              setFollow(true);
            },
            style: { marginLeft: "auto", fontSize: 12, opacity: follow ? 1 : 0.6 },
            title: "Auto-select the newest slide",
          },
          follow ? "Following latest ✓" : "Follow latest",
        ),
        h(
          "button",
          {
            onClick: function () {
              SDK.fetchJSON(API + "/rescan", { method: "POST" }).catch(function () {});
            },
            style: { fontSize: 12 },
            title: "Force a rescan of the watched directories",
          },
          "Rescan",
        ),
      ),

      h(
        "div",
        { className: "lc-body" },
        h(
          "div",
          { className: "lc-list" },
          slides.map(function (s) {
            return h(
              "div",
              {
                key: s.key,
                className: "lc-item" + (s.key === selectedKey ? " lc-active" : ""),
                onClick: function () {
                  setFollow(false);
                  setSelectedKey(s.key);
                },
                title: s.path,
              },
              s.name,
              h("span", { className: "lc-meta" }, s.ext.toUpperCase() + " · " + fmtBytes(s.bytes) + " · " + relTime(s.mtime)),
            );
          }),
        ),
        h("div", { className: "lc-stage" }, stage),
      ),
    );
  }

  if (window.__HERMES_PLUGINS__ && typeof window.__HERMES_PLUGINS__.register === "function") {
    window.__HERMES_PLUGINS__.register("live-canvas", LiveCanvasPage);
  }
})();
