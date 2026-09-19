/**
 * Hermes Live Canvas — Dashboard Plugin
 *
 * A pane that renders diagram files (HTML / SVG) live. The backend watches the
 * configured directories and pushes revisions over a WebSocket; this component
 * keeps a slide list, renders the newest slide by default, and re-reads a slide
 * in place whenever its file changes on disk.
 *
 * Zoom: wide diagrams are unreadable squeezed into the pane, so rendered slides
 * get a real viewer — fit-width, percentage zoom (100% = the SVG's intrinsic
 * size), Ctrl/Cmd+wheel, and drag-to-pan. Because the iframe is sandboxed with
 * an opaque origin, the viewer script inside it talks to this component only
 * through postMessage; nothing about the sandbox is relaxed for it.
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

  // Zoom steps, and the range. 1.0 == the SVG's own width in CSS px.
  var ZOOM_STEPS = [0.25, 0.33, 0.5, 0.67, 0.8, 1, 1.25, 1.5, 2, 2.5, 3, 4, 6, 8];
  var ZOOM_MIN = ZOOM_STEPS[0];
  var ZOOM_MAX = ZOOM_STEPS[ZOOM_STEPS.length - 1];

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

  function nextStep(current, dir) {
    var i;
    if (dir > 0) {
      for (i = 0; i < ZOOM_STEPS.length; i++) {
        if (ZOOM_STEPS[i] > current + 1e-6) return ZOOM_STEPS[i];
      }
      return ZOOM_MAX;
    }
    for (i = ZOOM_STEPS.length - 1; i >= 0; i--) {
      if (ZOOM_STEPS[i] < current - 1e-6) return ZOOM_STEPS[i];
    }
    return ZOOM_MIN;
  }

  /**
   * The viewer script injected into a rendered slide.
   *
   * Runs in an opaque origin and owns the scrolling element, so it alone can
   * implement pan. It takes zoom as a message from the parent and reports back
   * the fit scale (so the parent's "+" can start from wherever fit landed
   * rather than jumping) and Ctrl+wheel gestures.
   */
  var FRAME_SCRIPT = [
    "(function(){",
    "  var VIEW = __LC_VIEW__;",
    "  var wrap = document.getElementById('lc-wrap');",
    "  var svg = document.querySelector('svg');",
    "  if(!svg) return;",
    "  function num(v){ var n = parseFloat(v); return (n && isFinite(n)) ? n : 0; }",
    "  // Intrinsic size from the attributes; fall back to the viewBox, then to a",
    "  // sane default. Both dimensions are needed: an SVG with width+height+viewBox",
    "  // and preserveAspectRatio (the default) scales its CONTENT to fit the box it",
    "  // is given, so setting only width leaves the height pinned and the drawing",
    "  // stays at its original size, centred.",
    "  var iw = num(svg.getAttribute('width'));",
    "  var ih = num(svg.getAttribute('height'));",
    "  var vb = (svg.getAttribute('viewBox')||'').split(/[\\s,]+/);",
    "  if((!iw || !ih) && vb.length === 4){ iw = iw || num(vb[2]); ih = ih || num(vb[3]); }",
    "  if(!iw) iw = 900;",
    "  if(!ih) ih = 600;",
    "  // Take the SVG out of layout scaling entirely: a viewBox with no width/height",
    "  // attributes makes the element size itself from its container, which fights",
    "  // any explicit size. Setting all three keeps behaviour identical everywhere.",
    "  svg.setAttribute('viewBox', svg.getAttribute('viewBox') || ('0 0 ' + iw + ' ' + ih));",
    "  svg.setAttribute('preserveAspectRatio', 'xMinYMin meet');",
    "  function paneW(){ return wrap.clientWidth || 1; }",
    "  function apply(){",
    "    // Belt and braces: the stylesheet rule, then the inline style, then the",
    "    // attributes. Some renderers honour the attributes over inline CSS in",
    "    // replaced-element sizing, so they must agree.",
    "    svg.style.maxWidth = 'none';",
    "    svg.style.maxHeight = 'none';",
    "    var w, h;",
    "    if(VIEW.mode === 'fit'){ w = paneW(); h = ih * (w / iw); }",
    "    else { w = iw * VIEW.scale; h = ih * VIEW.scale; }",
    "    svg.style.width = w + 'px';",
    "    svg.style.height = h + 'px';",
    "    svg.setAttribute('width', String(Math.round(w)));",
    "    svg.setAttribute('height', String(Math.round(h)));",
    "    wrap.style.cursor = VIEW.mode === 'fit' ? 'default' : 'grab';",
    "  }",
    "  function reportFit(){",
    "    try { parent.postMessage({type:'lc-fit', value: paneW() / iw}, '*'); } catch(e){}",
    "  }",
    "  apply(); reportFit();",
    "  window.addEventListener('resize', function(){ apply(); reportFit(); });",
    "  window.addEventListener('message', function(e){",
    "    var d = e && e.data;",
    "    if(!d || d.type !== 'lc-view') return;",
    "    VIEW = { mode: d.mode, scale: d.scale };",
    "    apply(); reportFit();",
    "  });",
    "  wrap.addEventListener('wheel', function(e){",
    "    if(e.ctrlKey || e.metaKey){",
    "      e.preventDefault();",
    "      try { parent.postMessage({type:'lc-wheel', dir: e.deltaY < 0 ? 1 : -1}, '*'); } catch(err){}",
    "    }",
    "  }, {passive:false});",
    "  var dragging = false, sx = 0, sy = 0, sl = 0, st = 0;",
    "  wrap.addEventListener('mousedown', function(e){",
    "    if(VIEW.mode === 'fit' || e.button !== 0) return;",
    "    dragging = true; sx = e.clientX; sy = e.clientY;",
    "    sl = wrap.scrollLeft; st = wrap.scrollTop;",
    "    wrap.style.cursor = 'grabbing'; e.preventDefault();",
    "  });",
    "  window.addEventListener('mousemove', function(e){",
    "    if(!dragging) return;",
    "    wrap.scrollLeft = sl - (e.clientX - sx);",
    "    wrap.scrollTop  = st - (e.clientY - sy);",
    "  });",
    "  window.addEventListener('mouseup', function(){",
    "    if(!dragging) return;",
    "    dragging = false;",
    "    wrap.style.cursor = VIEW.mode === 'fit' ? 'default' : 'grab';",
    "  });",
    "})();",
  ].join("\n");

  /** Wrap an SVG slide in a viewer document, with the current zoom baked in. */
  function svgFrameDoc(body, view) {
    return (
      "<!doctype html><html><head><meta charset=\"utf-8\">" +
      "<style>" +
      "html,body{margin:0;padding:0;background:#fff;height:100%;overflow:hidden}" +
      "#lc-wrap{width:100%;height:100%;overflow:auto;background:#fff}" +
      "svg{display:block;background:#fff}" +
      "</style></head><body>" +
      "<div id=\"lc-wrap\">" + body + "</div>" +
      "<script>" + FRAME_SCRIPT.replace("__LC_VIEW__", JSON.stringify(view)) + "</" + "script>" +
      "</body></html>"
    );
  }

  /** HTML slides are the author's document — never inject a viewer into them. */
  function htmlFrameDoc(body) {
    return body;
  }

  var PANE_CSS = [
    ".lc-root{display:flex;flex-direction:column;height:calc(100vh - 140px);min-height:420px}",
    ".lc-bar{display:flex;align-items:center;gap:8px;padding:8px 4px;flex-wrap:wrap}",
    ".lc-dot{width:8px;height:8px;border-radius:50%;display:inline-block}",
    ".lc-sep{width:1px;height:18px;background:var(--color-border,rgba(128,128,128,.35));margin:0 2px}",
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
    ".lc-stage pre{width:100%;height:100%;margin:0;overflow:auto;padding:14px 16px;background:#fff;color:#1f2328;font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;line-height:1.55;white-space:pre-wrap;overflow-wrap:anywhere}",
    ".lc-empty{display:flex;height:100%;align-items:center;justify-content:center;flex-direction:column;gap:10px;color:#57606a;background:#fff;font-size:13px;text-align:center;padding:20px}",
    ".lc-warn{color:#9a6700;font-size:12px}",
    ".lc-zoom{display:flex;align-items:center;gap:3px}",
    ".lc-zoom button{min-width:26px;padding:2px 6px;font-size:13px;line-height:1.2}",
    ".lc-zoom .lc-pct{font-size:12px;min-width:52px;text-align:center;opacity:.85;font-variant-numeric:tabular-nums}",
    ".lc-hint{font-size:11px;opacity:.55}",
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

    // Viewer state. mode 'fit' tracks the pane; 'manual' holds an explicit scale
    // where 1.0 is the SVG's intrinsic width.
    var zs = useState({ mode: "fit", scale: 1 });
    var view = zs[0];
    var setView = zs[1];
    var fitRef = useRef(1);

    var iframeRef = useRef(null);
    var wsRef = useRef(null);
    var wsClosedRef = useRef(false);
    var backoffRef = useRef(1000);
    var selectedKeyRef = useRef(null);
    var followRef = useRef(true);
    var viewRef = useRef(view);

    selectedKeyRef.current = selectedKey;
    followRef.current = follow;
    viewRef.current = view;

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

    // --- zoom controls --------------------------------------------------
    var zoomBy = useCallback(
      function (dir) {
        setView(function (prev) {
          // Coming out of fit, step from wherever fit actually landed — jumping
          // straight to 100% from a 40% fit would be a lurch.
          var base = prev.mode === "fit" ? fitRef.current : prev.scale;
          return { mode: "manual", scale: nextStep(base, dir) };
        });
      },
      [setView],
    );

    var zoomTo = useCallback(
      function (scale) {
        setView({ mode: "manual", scale: Math.min(ZOOM_MAX, Math.max(ZOOM_MIN, scale)) });
      },
      [setView],
    );

    var fit = useCallback(function () {
      setView({ mode: "fit", scale: 1 });
    }, [setView]);

    // --- messages from the viewer iframe --------------------------------
    useEffect(function () {
      function onMessage(e) {
        var fr = iframeRef.current;
        // Only the pane's own iframe may move this component's state.
        if (!fr || e.source !== fr.contentWindow) return;
        var d = e.data;
        if (!d || typeof d !== "object") return;
        if (d.type === "lc-fit" && typeof d.value === "number" && isFinite(d.value) && d.value > 0) {
          fitRef.current = d.value;
        } else if (d.type === "lc-wheel") {
          zoomBy(d.dir > 0 ? 1 : -1);
        }
      }
      window.addEventListener("message", onMessage);
      return function () {
        window.removeEventListener("message", onMessage);
      };
    }, [zoomBy]);

    // --- push zoom into the viewer when it changes ----------------------
    useEffect(function () {
      var fr = iframeRef.current;
      if (!fr || !fr.contentWindow) return;
      try {
        fr.contentWindow.postMessage({ type: "lc-view", mode: view.mode, scale: view.scale }, "*");
      } catch (_e) {}
    }, [view, doc.key]);

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
    var isSvg = isRender && activeSlide.ext === "svg";
    var isHtml = isRender && !isSvg;

    // The frame document must depend ONLY on the slide, never on the zoom.
    // Rebuilding it on zoom would make React re-set `srcdoc` — which reloads the
    // iframe, blanking the stage and discarding the scroll position. The view is
    // baked in once at load (from the ref, so this memo stays stable) and every
    // later change arrives over postMessage.
    var frameDocHtml = useMemo(
      function () {
        if (!isSvg) return "";
        return svgFrameDoc(bodyForFrame, viewRef.current);
      },
      // eslint-disable-next-line react-hooks/exhaustive-deps
      [isSvg, doc.key, bodyForFrame],
    );

    var stage = null;
    if (!slides.length) {
      stage = h(
        "div",
        { className: "lc-empty" },
        h("div", null, "No diagrams yet."),
        h("div", null, "Write an .html or .svg file into a watched directory and it appears here."),
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
    } else if (isSvg) {
      // One iframe per SLIDE. Zoom changes flow through postMessage rather than
      // a remount: a key that changed with the zoom tore the frame down and
      // rebuilt it on every click, which blanked the stage and threw away the
      // scroll position. The viewer applies the baked-in view on load and
      // updates live from the message effect above.
      stage = h("iframe", {
        ref: iframeRef,
        title: activeSlide.name,
        // No allow-same-origin: the diagram runs in an opaque origin and cannot
        // touch the dashboard's DOM, storage or session token. The viewer script
        // therefore talks to this component only via postMessage.
        sandbox: "allow-scripts",
        key: "svg:" + doc.key,
        srcDoc: frameDocHtml,
      });
    } else if (isHtml) {
      stage = h("iframe", {
        ref: iframeRef,
        title: activeSlide.name,
        sandbox: "allow-scripts",
        key: doc.key,
        srcDoc: htmlFrameDoc(bodyForFrame),
      });
    } else {
      // Text slides zoom by font size — they reflow, so scaling the type is the
      // right gesture (and the browser's own text zoom stays available).
      var textScale = view.mode === "fit" ? 1 : view.scale;
      stage = h("pre", { style: { fontSize: (12.5 * textScale).toFixed(1) + "px" } }, bodyForFrame);
    }

    var pct = view.mode === "fit" ? "Fit" : Math.round(view.scale * 100) + "%";

    return h(
      "div",
      { className: "lc-root" },
      h("style", null, PANE_CSS),

      h(
        "div",
        { className: "lc-bar" },
        h("span", {
          className: "lc-dot",
          style: { background: wsState === "live" ? "#2f9e44" : wsState === "connecting" ? "#b8860b" : "#c92a2a" },
        }),
        h("strong", null, "Live Canvas"),
        h("span", { style: { fontSize: 12, opacity: 0.7 } }, wsState + " · rev " + snap.rev + " · " + slides.length + " slide" + (slides.length === 1 ? "" : "s")),

        h("span", { className: "lc-sep" }),
        h(
          "span",
          { className: "lc-zoom" },
          h("button", { onClick: function () { zoomBy(-1); }, title: "Zoom out (Ctrl or Cmd + scroll down)" }, "\u2212"),
          h("span", { className: "lc-pct" }, pct),
          h("button", { onClick: function () { zoomBy(1); }, title: "Zoom in (Ctrl or Cmd + scroll up)" }, "+"),
          h("button", { onClick: function () { zoomTo(1); }, title: "Actual size — 100%, the diagram's own pixel width" }, "100%"),
          h("button", { onClick: fit, title: "Fit the pane width" }, "Fit"),
        ),

        h("span", { className: "lc-sep" }),
        h(
          "button",
          {
            onClick: function () { setFollow(true); },
            style: { fontSize: 12, opacity: follow ? 1 : 0.6 },
            title: "Auto-select the newest slide",
          },
          follow ? "Following ✓" : "Follow latest",
        ),
        h(
          "button",
          {
            onClick: function () { SDK.fetchJSON(API + "/rescan", { method: "POST" }).catch(function () {}); },
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
