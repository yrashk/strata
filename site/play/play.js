// The play page: runs strata-emu (web/web.c, built with `make wasm`) in the
// browser. The emulator lives in a Web Worker (worker.js), where it runs
// continuously; this file only moves bytes: console output to the
// terminal, keys to the worker, framebuffer rows to the canvas. Each run is
// a fresh worker with a fresh instance of the WebAssembly module (Reset =
// a new worker), given the images fetched from images/ and the desktop
// flags. The page compiles the module once and hands it to every worker.
"use strict";

// The build id (tools/web-stamp.sh puts the commit here): every asset URL
// carries it, so a browser never mixes files of two deploys.
const BUILD = "__BUILD__";

// Safari on iPhone and iPad keeps compiled WebAssembly in a small pool and
// kills the page when the JIT fills it: there the JIT keeps at most 256
// regions alive (all cores) and translates only code run 200 times. Shared
// with the Forth playground (site/forth/forth.js).
const IOS = /iPhone|iPad|iPod/.test(navigator.userAgent) ||
            (navigator.platform === "MacIntel" && navigator.maxTouchPoints > 1);
const JIT_LIMITS = IOS ? { jitBudget: 256, jitHot: 200 } : {};
const V = "?v=" + BUILD;

const PRESETS = {
  os: {
    files: ["bootrom.stx", "disk.img"],
    args: ["-c", "12", "-d", "disk.img", "bootrom.stx"],
    fitScreen: true,
    about: "The boot ROM finds the disk, loads the kernel into every core's Local Stores, and StrataOS starts its servers and the shell on 12 cores. Try help, ls, ps, -n 3 mandel, or ws for the window server (click the screen; Alt+P launches programs, Alt+Enter opens a terminal, Alt+? lists the keys).",
  },
  osws: {
    files: ["bootrom.stx", "disk-ws.img"],
    args: ["-c", "12", "-d", "disk-ws.img", "bootrom.stx"],
    fitScreen: true,
    screenKeys: true,
    about: "StrataOS on 12 cores with the window server started at boot (its rc runs ws): the real ws, its terminals running the real shell. A key help comes up after the splash; any key or click dismisses it. Alt+Enter opens a terminal, Alt+P the launch palette, a click focuses a tile, the wheel scrolls a terminal back, Alt+? shows the help again.",
  },
  ws: {
    files: ["wsdemo.stx"],
    args: ["-c", "1", "wsdemo.stx"],
    fitScreen: true,
    screenKeys: true,
    about: "The StrataOS window server's drawing code, running bare metal with a simulated OS behind it: the splash, tiled windows, the core lattice pulsing on context switches, the launch palette. Click the screen, then try Alt+P or Alt+Space (palette), Alt+1..4 or Alt+arrows (focus), Alt+Enter (new terminal), Alt+Q (close).",
  },
  gfx: {
    files: ["gfx.stx"],
    args: ["-c", "8", "gfx.stx"],
    about: "examples/gfx.s: eight cores each own one band of the 1280x800 framebuffer through a capability and render a Mandelbrot set into it. The screen scans out memory live, like the desktop window.",
  },
  forth: {
    files: ["forth.stx"],
    args: ["-c", "8", "-r", "640x400", "forth.stx"],
    demos: true,
    about: "Strata Forth on bare metal (8 cores, a 640x400 screen). Words compile to native Strata code. Type 7 dup * . or paste a demo; the gfx demo draws on the screen.",
  },
  hello: {
    files: ["hello.stx"],
    args: ["-c", "8", "hello.stx"],
    about: "examples/hello.s: Local Stores, output as a transfer, a token passed down a chain of cores.",
  },
  mandel: {
    files: ["mandel.stx"],
    args: ["-c", "8", "mandel.stx"],
    about: "examples/mandel.s: every core renders a band of one text frame it exclusively owns; the bands are collected in order.",
  },
};

const $ = (id) => document.getElementById(id);
const statusEl = $("status"), aboutEl = $("about"), canvas = $("screen"), screenPanel = $("screen-panel");
const ctx = canvas.getContext("2d");
const enc = new TextEncoder();

// ---------------------------------------------------------------- terminal
const term = new Terminal({
  convertEol: true,
  cursorBlink: true,
  macOptionIsMeta: true,
  scrollback: 5000,
  fontFamily: '"JetBrains Mono", ui-monospace, Menlo, monospace',
  fontSize: 13.5,
  theme: {
    background: "#05080f", foreground: "#cfe8ff", cursor: "#ffb347", cursorAccent: "#05080f",
    selectionBackground: "rgba(77, 225, 255, 0.3)",
    black: "#0b1120", red: "#ff6b6b", green: "#5be3a1", yellow: "#ffb347", blue: "#4d8dff",
    magenta: "#c38bff", cyan: "#4de1ff", white: "#cfe8ff",
    brightBlack: "#5b7088", brightRed: "#ff8f8f", brightGreen: "#8af0bf", brightYellow: "#ffd08a",
    brightBlue: "#7fb0ff", brightMagenta: "#dab4ff", brightCyan: "#9bf0ff", brightWhite: "#ffffff",
  },
});
const fit = new FitAddon.FitAddon();
term.loadAddon(fit);
term.open($("term"));
// Rows fill exactly the visible box: fit now, again once the web font has
// loaded (its cell size differs from the fallback's; re-setting the font
// makes xterm measure it again), and whenever the box changes size.
function refit() {
  try { fit.fit(); } catch (e) { /* not laid out yet */ }
  term.scrollToBottom();
}
refit();
document.fonts.load('13.5px "JetBrains Mono"').then(() => document.fonts.ready).then(() => {
  const f = term.options.fontFamily;
  term.options.fontFamily = "monospace";
  term.options.fontFamily = f;
  refit();
});
new ResizeObserver(refit).observe($("term"));
addEventListener("resize", refit);
term.writeln("\x1b[36mStrata\x1b[0m emulator in WebAssembly. Pick something to run above.");

// ---------------------------------------------------------------- state
let W = null;          // the worker running the machine
let current = null;    // its preset key
let stopped = true;    // the machine has stopped (halted, deadlock, exit) or none is running
let stat = null;       // the worker's latest status message
let last = { t: 0, steps: 0 }, mips = 0, runStart = 0;

// ?jit=0 starts with the JIT off, ?jit=1 on; the checkbox restarts the
// current preset. On iPhone and iPad the JIT starts off: Safari there kills
// the page once compiled WebAssembly fills its pool, even with the JIT's
// budget (JIT_LIMITS, used if it is turned on).
const params = new URLSearchParams(location.search);
const jitBox = $("jit");
jitBox.checked = params.get("jit") === "1" || (params.get("jit") !== "0" && !IOS);

// The machine: the emulator (strata-emu.wasm) or the RTL simulator
// (strata-rtl.wasm: the SystemVerilog itself, turned into C++ by Verilator
// and compiled to WebAssembly; `make wasm-rtl`). ?machine=rtl picks the RTL.
// It is some thousand times slower than the emulator's JIT (a few hundred
// thousand clock cycles a second for 8 cores), has no JIT, no network far end,
// and its timer counts clock cycles (-T virtual: a 100 MHz machine), so
// machine time runs far behind the wall clock. The choice is hidden when the
// site was built without it.
const machineSel = $("machine");
const RTL_CORES = 8; // WEB_RTL_CORES in the Makefile: the RTL's core count is fixed when it is built
if (params.get("machine") === "rtl") machineSel.value = "rtl";
fetch("strata-rtl.wasm" + V, { method: "HEAD" }).then((r) => {
  if (!r.ok) throw new Error("no RTL build");
}).catch(() => {
  machineSel.value = "emu";
  $("machine-wrap").hidden = true;
});
function machine() { return machineSel.value === "rtl" ? "rtl" : "emu"; }

const wasmModules = {};
async function compileWasm(which) {
  if (wasmModules[which]) return wasmModules[which];
  const file = (which === "rtl" ? "strata-rtl.wasm" : "strata-emu.wasm") + V;
  try {
    wasmModules[which] = await WebAssembly.compileStreaming(fetch(file));
  } catch (e) { // a server without application/wasm
    wasmModules[which] = await WebAssembly.compile(await (await fetch(file)).arrayBuffer());
  }
  return wasmModules[which];
}

// The emulator's flags for a preset, as strata-rtl takes them: no -c (the
// core count is the build's), and a small screen where the preset would
// draw a large one (every pixel costs clock cycles here).
function rtlArgs(p) {
  const out = [];
  for (let i = 0; i < p.args.length; i++) {
    if (p.args[i] === "-c") { i++; continue; }
    out.push(p.args[i]);
  }
  if (!out.includes("-r")) out.unshift("-r", "640x400");
  return ["-T", "virtual", ...out];
}

const files = new Map();
function fetchFile(name) {
  if (!files.has(name))
    files.set(name, fetch("images/" + name + V).then((r) => {
      if (!r.ok) throw new Error(`images/${name}: ${r.status}`);
      return r.arrayBuffer();
    }));
  return files.get(name);
}

// ---------------------------------------------------------------- input
// Bytes for the console, as the desktop keyboard sends them (spec 1.4).
// The worker queues them and feeds the guest as its input queue drains.
function sendText(s) {
  if (!W || stopped) return;
  let bytes = [];
  const flush = () => { if (bytes.length) { W.postMessage({ t: "input", data: new Uint8Array(bytes) }); bytes = []; } };
  for (const ch of s) {
    if (ch === "\x03") { flush(); W.postMessage({ t: "break" }); continue; } // Ctrl-C is the break key
    for (const b of enc.encode(ch === "\r" ? "\n" : ch)) bytes.push(b);        // Enter is LF
  }
  flush();
}
function sendBreak() { if (W && !stopped) W.postMessage({ t: "break" }); }

term.onData((d) => { term.scrollToBottom(); sendText(d); });

// Alt+key as the desktop window sends it (spec 1.4): the xterm modified-key
// forms, which cannot be typed by hand, so the window server tells Alt+P from
// Esc and then p by the bytes, not by time. A character is ESC [ 27 ; 3 ;
// code ~ (Enter: 13), an arrow, Home or End ESC [ 1 ; 3 X, Delete, Page Up
// or Down ESC [ n ; 3 ~.
function altSeq(s) {
  let m = /^\x1b\[([A-DHF])$/.exec(s);
  if (m) return "\x1b[1;3" + m[1];
  if ((m = /^\x1b\[(\d+)~$/.exec(s))) return `\x1b[${m[1]};3~`;
  if ([...s].length === 1) return `\x1b[27;3;${s === "\n" ? 13 : s.codePointAt(0)}~`;
  return s;
}
// The canvas keyboard: the same mapping as the desktop window.
const KEYS = {
  Enter: "\n", Backspace: "\x7f", Tab: "\t", Escape: "\x1b",
  ArrowUp: "\x1b[A", ArrowDown: "\x1b[B", ArrowRight: "\x1b[C", ArrowLeft: "\x1b[D",
  Home: "\x1b[H", End: "\x1b[F", Delete: "\x1b[3~", PageUp: "\x1b[5~", PageDown: "\x1b[6~",
};
canvas.addEventListener("keydown", (e) => {
  if (e.metaKey) return; // Cmd belongs to the host
  let s = KEYS[e.key];
  const letter = /^Key([A-Z])$/.exec(e.code);
  if (!s && e.ctrlKey && letter) s = String.fromCharCode(letter[1].charCodeAt(0) - 64); // Ctrl-C = 0x03 = break
  else if (!s && e.altKey && letter) s = e.shiftKey ? letter[1] : letter[1].toLowerCase();
  else if (!s && e.altKey && /^Digit\d$/.test(e.code) && !e.shiftKey) s = e.code[5];
  else if (!s && e.altKey && e.code === "Space") s = " "; // (Option+Space, Option+? are other characters on a Mac)
  else if (!s && e.altKey && e.code === "Slash") s = e.shiftKey ? "?" : "/";
  else if (!s && !e.ctrlKey && e.key.length === 1) s = e.key;
  if (!s) return;
  e.preventDefault();
  sendText(e.altKey && s !== "\x03" ? altSeq(s) : s);
});
canvas.addEventListener("click", () => canvas.focus());

// The canvas's mouse: the pointer device (web/web.c web_pointer; op = the
// PTR_* kinds of common/platform.h). Positions are framebuffer pixels.
function sendPtr(op, a, b) { if (W && !stopped) W.postMessage({ t: "ptr", op, a, b }); }
function ptrAt(e) {
  const r = canvas.getBoundingClientRect();
  return [Math.floor((e.clientX - r.left) * canvas.width / r.width), Math.floor((e.clientY - r.top) * canvas.height / r.height)];
}
const BUTTON = [0, 2, 1]; // DOM left, middle, right -> device bit 0 left, 1 right, 2 middle
canvas.addEventListener("pointermove", (e) => sendPtr(1, ...ptrAt(e)));
canvas.addEventListener("pointerdown", (e) => {
  if (e.button > 2) return;
  canvas.setPointerCapture(e.pointerId);
  sendPtr(1, ...ptrAt(e));
  sendPtr(2, BUTTON[e.button], 1);
});
canvas.addEventListener("pointerup", (e) => { if (e.button <= 2) sendPtr(2, BUTTON[e.button], 0); });
canvas.addEventListener("pointerenter", (e) => { sendPtr(4, 0, 0); sendPtr(1, ...ptrAt(e)); });
canvas.addEventListener("pointerleave", () => sendPtr(5, 0, 0));
canvas.addEventListener("contextmenu", (e) => e.preventDefault());
let wheelY = 0, wheelX = 0; // pixel deltas, one notch per 100 px (one line = one notch)
canvas.addEventListener("wheel", (e) => {
  e.preventDefault();
  const k = e.deltaMode === 0 ? 1 : 100;
  wheelY += e.deltaY * k; wheelX += e.deltaX * k;
  const ny = Math.trunc(wheelY / 100), nx = Math.trunc(wheelX / 100);
  if (!ny && !nx) return;
  wheelY -= ny * 100; wheelX -= nx * 100;
  sendPtr(3, -ny, nx); // > 0: away from the user (DOM deltaY < 0)
}, { passive: false });

// ---------------------------------------------------------------- screen
// Changed rows from the worker, already RGBA.
function paint(m) {
  let resized = false;
  if (canvas.width !== m.w || canvas.height !== m.h) { canvas.width = m.w; canvas.height = m.h; resized = true; }
  if (screenPanel.classList.contains("collapsed")) {
    screenPanel.classList.remove("collapsed");
    resized = true;
  }
  if (resized) fitScreen();
  ctx.putImageData(new ImageData(m.data, m.w, m.rows), 0, m.y0);
}

// ---------------------------------------------------------------- screen size
// The framebuffer is drawn with 1-pixel bitmap fonts: they stay legible only
// when every framebuffer pixel becomes a whole number of device pixels, drawn
// nearest-neighbour (play.css). The canvas's width/height attributes stay the
// framebuffer size (paint()); only its CSS size is set here.
//   auto  the largest whole number of device pixels per framebuffer pixel
//         that fits the panel (and the window's height), as long as that is
//         at least 3/4 of a CSS pixel; else a fractional fit
//   fill  fit the panel at any scale (uneven pixels; averaged below 1)
//   1, 2  U or 2U device pixels per framebuffer pixel, where U is
//         devicePixelRatio rounded (one CSS pixel, kept whole); the box scrolls
// ws and StrataOS (presets with fitScreen) get a framebuffer size chosen at
// start to show whole at 1x: see screenGeometry().
const screenBox = $("screen-box"), fullBtn = $("full");
const SCALES = ["auto", "fill", "1", "2"], SCALE_KEY = "strata-play-scale";
let scaleMode = "auto";
try { const v = localStorage.getItem(SCALE_KEY); if (SCALES.includes(v)) scaleMode = v; } catch (e) { /* no storage */ }

const dpr = () => window.devicePixelRatio || 1;
const unitPx = () => Math.max(1, Math.round(dpr())); // device pixels per framebuffer pixel at 1x
const fsElement = () => document.fullscreenElement || document.webkitFullscreenElement || null;
const READABLE = 0.75; // CSS pixels per framebuffer pixel below which the fonts are too small

// The room for the screen, in CSS pixels: the whole display in full screen;
// else the panel's width and the window's height under the site's sticky
// nav and the panel's tag.
function screenRoom() {
  if (fsElement() === screenBox) return { w: screenBox.clientWidth, h: screenBox.clientHeight, full: true };
  const nav = document.querySelector("nav.top"), tag = screenPanel.querySelector(".tag");
  const above = (nav ? nav.offsetHeight : 0) + tag.offsetHeight + 8;
  return { w: screenPanel.clientWidth, h: Math.max(240, innerHeight - above), full: false };
}

// CSS pixels per framebuffer pixel for the current mode and room.
function screenScale(fw, fh, room) {
  const d = dpr();
  if (scaleMode === "1" || scaleMode === "2") return unitPx() * Number(scaleMode) / d;
  const fitCss = Math.min(room.w / fw, room.h / fh);
  if (scaleMode === "fill") return fitCss;
  const both = Math.floor(fitCss * d + 1e-6);              // whole device pixels, fits both ways
  if (both >= 1 && both / d >= READABLE) return both / d;
  const wide = Math.floor(room.w / fw * d + 1e-6);         // fits the width only: the page scrolls
  if (!room.full && wide >= 1 && wide / d >= READABLE) return wide / d;
  return fitCss;
}

function fitScreen() {
  if (screenPanel.classList.contains("collapsed")) return;
  const fw = canvas.width, fh = canvas.height, d = dpr(), room = screenRoom();
  const css = screenScale(fw, fh, room), w = fw * css, h = fh * css;
  canvas.style.width = w + "px";
  canvas.style.height = h + "px";
  canvas.classList.toggle("smooth", css * d < 1 - 1e-6);
  // centred, with its corner on a whole device pixel (else even a whole
  // scale samples between pixels)
  const box = screenBox.getBoundingClientRect();
  const snap = (start, free) => Math.max(0, Math.round((start + Math.max(0, free) / 2) * d) / d - start);
  canvas.style.marginLeft = snap(box.left, box.width - w) + "px";
  canvas.style.marginTop = snap(box.top, room.full ? box.height - h : 0) + "px";
  const n = css * d, whole = Math.abs(n - Math.round(n)) < 1e-6;
  $("geom").textContent = `${fw}x${fh} XRGB8888 · live scanout · ${Math.round(css * 100)}%` +
    (whole ? "" : n < 1 ? " (averaged)" : " (uneven)") + " · click to type here";
}

// A framebuffer size (the emulator's -r WxH) for programs that adapt to it:
// the largest that shows whole at 1x (U device pixels per pixel; a smaller
// U only while that stays readable), at most the 1280x800 ws is designed
// at, at least the 1152 columns ws's status strip needs (narrower, its
// labels overlap) and 560 rows. When even that does not fit, Auto scales
// the display down instead.
function screenGeometry(minW = 640, minH = 400, maxW = 1280, maxH = 800) {
  const d = dpr(), room = screenRoom();
  for (let k = unitPx(); k >= 1 && k / d >= READABLE; k--) {
    const w = Math.min(maxW, Math.floor(room.w * d / k / 8) * 8);
    if (w < minW) continue;
    const h = Math.min(maxH, Math.floor(room.h * d / k / 2) * 2, Math.floor(w * 10 / 16 / 2) * 2);
    return `${w}x${Math.max(minH, h)}`;
  }
  return `${minW}x${Math.max(minH, Math.min(720, Math.floor(minW * room.h / room.w / 2) * 2))}`;
}

function setScale(mode) {
  scaleMode = mode;
  try { localStorage.setItem(SCALE_KEY, mode); } catch (e) { /* no storage */ }
  for (const b of document.querySelectorAll(".seg[data-scale]")) b.classList.toggle("on", b.dataset.scale === mode);
  fitScreen();
}
for (const b of document.querySelectorAll(".seg[data-scale]"))
  b.addEventListener("click", () => { setScale(b.dataset.scale); canvas.focus({ preventScroll: true }); });
setScale(scaleMode);
new ResizeObserver(() => fitScreen()).observe(screenPanel);
addEventListener("resize", () => fitScreen()); // also a zoom (devicePixelRatio) change
screenBox.addEventListener("click", () => canvas.focus({ preventScroll: true }));

// Full screen: the box (the canvas centred on black) at the same scaling;
// keys keep going to the canvas; Esc leaves (the browser does that). The
// button is hidden where the API is missing or refused (iPhone Safari).
const fsAvailable = !!(document.fullscreenEnabled || document.webkitFullscreenEnabled) &&
  !!(screenBox.requestFullscreen || screenBox.webkitRequestFullscreen);
fullBtn.hidden = !fsAvailable;
fullBtn.addEventListener("click", () => {
  canvas.focus({ preventScroll: true });
  if (fsElement()) return;
  try {
    const p = screenBox.requestFullscreen ? screenBox.requestFullscreen({ navigationUI: "hide" })
                                          : screenBox.webkitRequestFullscreen();
    if (p && p.catch) p.catch(() => {});
  } catch (e) { /* refused */ }
});
for (const ev of ["fullscreenchange", "webkitfullscreenchange"])
  document.addEventListener(ev, () => { fitScreen(); canvas.focus({ preventScroll: true }); });

// ---------------------------------------------------------------- running
function outText(s) { term.write(s, () => term.scrollToBottom()); }

function stopCurrent() {
  if (W) W.terminate();
  W = null;
  stopped = true;
}

function setStopped(msg) {
  stopped = true;
  $("brk").disabled = true;
  statusEl.classList.add("stopped");
  statusEl.textContent = msg;
}

function fmtTime(us) {
  const s = us / 1e6;
  return s < 60 ? s.toFixed(2) + " s" : `${Math.floor(s / 60)} min ${(s % 60).toFixed(0)} s`;
}
function statusLine() {
  if (!stat) return "";
  const { steps, cores, live, now, jit, rtl } = stat;
  if (rtl) // steps are clock cycles
    return `${(mips * 1000).toFixed(0)} kHz simulated clock (RTL, Verilator) · ${live}/${cores} cores live · ` +
           `machine time ${fmtTime(now)} · ` +
           (steps < 1e6 ? `${steps} cycles` : `${(steps / 1e6).toFixed(1)}M cycles`);
  return `${mips.toFixed(1)} MIPS (${jit ? "JIT" : "interpreter"}) · ${live}/${cores} cores live · ` +
         `machine time ${fmtTime(now)} · ` +
         (steps < 1e6 ? `${steps} instructions` : `${(steps / 1e6).toFixed(1)}M instructions`);
}

function onWorker(w, m) {
  if (w !== W) return; // a worker already replaced
  switch (m.t) {
  case "out": term.write(m.data, () => term.scrollToBottom()); break;
  case "paint": paint(m); break;
  case "started":
    last = { t: performance.now(), steps: 0 };
    runStart = last.t;
    statusEl.textContent = "running";
    break;
  case "status": {
    const t = performance.now();
    stat = m;
    canvas.style.cursor = m.ptr ? "none" : ""; // the guest draws its own
    mips = (m.steps - last.steps) / ((t - last.t) * 1000);
    last = { t, steps: m.steps };
    statusEl.textContent = "running · " + statusLine();
    break;
  }
  case "stopped": {
    const what = m.state === 1 ? (m.faulted ? "halted (a core faulted)" : "every core halted")
               : m.state === 2 ? "deadlock: every live core is blocked" : m.state === 4 ? "timeout" : "stopped";
    const secs = (performance.now() - runStart) / 1000;
    stat = m;
    mips = m.steps / secs / 1e6; // the average over the run
    setStopped(`${what} after ${secs.toFixed(1)} s · ${statusLine()} · Reset to run again`);
    break;
  }
  case "net": $("netnote").textContent = m.text; break;
  case "http": vmAnswer(m); break;
  case "ports": vmPorts(m.listening); break;
  case "exit": setStopped(`exited (${m.code})`); break;
  case "error": setStopped("error: " + m.msg); break;
  }
}

async function run(key) {
  const p = PRESETS[key];
  stopCurrent();
  current = key;
  stat = null;
  mips = 0;
  for (const b of document.querySelectorAll(".preset")) b.classList.toggle("on", b.dataset.preset === key);
  $("demos-wrap").hidden = !p.demos;
  $("reset").disabled = false;
  $("brk").disabled = false;
  statusEl.classList.remove("stopped");
  statusEl.textContent = "loading…";
  const rtl = machine() === "rtl";
  jitBox.disabled = rtl;
  aboutEl.textContent = rtl
    ? `On the RTL: the SystemVerilog implementation, simulated cycle by cycle (${RTL_CORES} cores, a 640x400 screen unless the program asks otherwise, no network). It is slow: expect seconds where the emulator takes milliseconds` +
      (key === "os" || key === "osws" ? ", and about half a minute for StrataOS to reach its prompt (every command after that takes its time too)" : "") + ". " + p.about
    : p.about;
  screenPanel.classList.add("collapsed");
  $("geom").textContent = "no framebuffer output yet";
  ctx.fillStyle = "#000";
  ctx.fillRect(0, 0, canvas.width, canvas.height);
  const net = netChoice();
  const netArgs = ["-N", net.mode === "peer" ? "peer" : net.mode === "relay" ? "web,nat" : "web"];
  const args = rtl ? rtlArgs(p)
             : [jitBox.checked ? "-J" : "-j", ...(p.fitScreen ? ["-r", screenGeometry()] : []), ...netArgs, ...p.args];
  term.write("\x1bc"); // reset, in order with the writes still queued
  outText(`\x1b[2m$ ${rtl ? "strata-rtl" : "strata-emu"} ${args.join(" ")}\x1b[0m\n`);

  try {
    const [wasm, ...bufs] = await Promise.all([compileWasm(rtl ? "rtl" : "emu"), ...p.files.map(fetchFile)]);
    if (current !== key || W) return; // another preset was picked meanwhile
    const w = new Worker("worker.js" + V);
    W = w;
    stopped = false;
    w.onmessage = (e) => onWorker(w, e.data);
    w.onerror = (e) => { if (w === W) setStopped("error: " + (e.message || "the worker failed")); };
    // the module and the images are copied (structured clone), so Reset can reuse them
    w.postMessage(Object.assign({ t: "start", machine: rtl ? "rtl" : "emu", wasm, files: p.files.map((name, i) => ({ name, data: bufs[i] })), args, net }, JIT_LIMITS));
    if (p.screenKeys) canvas.focus(); else term.focus();
  } catch (e) {
    setStopped("error: " + (e && e.message ? e.message : e));
  }
}

// ---------------------------------------------------------------- controls
for (const b of document.querySelectorAll(".preset")) b.addEventListener("click", () => run(b.dataset.preset));
$("reset").addEventListener("click", () => current && run(current));
$("brk").addEventListener("click", () => { sendBreak(); term.focus(); });
jitBox.addEventListener("change", () => current && run(current));
machineSel.addEventListener("change", () => { jitBox.disabled = machine() === "rtl"; if (current) run(current); });

// ---------------------------------------------------------------- the network (net.js)
// peer: the built-in test peer, and DNS answered over HTTPS by Cloudflare or
// Google; tab: one link with this page's other tabs (BroadcastChannel); relay:
// a WebSocket to a tools/netrelay the user runs (the real network, through it).
function netChoice() {
  const mode = $("net").value;
  return mode === "relay" ? { mode, url: $("relay").value.trim() } : { mode };
}
function netNote() {
  const c = netChoice();
  $("relay-wrap").hidden = c.mode !== "relay";
  $("netnote").textContent =
    c.mode === "peer" ? "Network: the built-in test peer (ping 10.0.0.2, peer.test); other names are looked up with DNS over HTTPS (Cloudflare, else Google)." :
    c.mode === "tab" ? "Network: a link between this page's tabs; open another tab, pick the same, and the two machines get 10.0.0.1 and 10.0.0.2." :
    c.url ? `Network: every packet goes through the relay at ${c.url} (it is the NAT: 10.0.2.15, DNS 10.0.2.3).` :
    "Network: enter the WebSocket URL of a relay you run (tools/netrelay, e.g. ws://localhost:8765), then Enter.";
}
$("net").addEventListener("change", () => { netNote(); if (current && $("net").value !== "relay") run(current); });
$("relay").addEventListener("keydown", (e) => { if (e.key === "Enter" && current) { netNote(); run(current); } });
netNote();

// ---------------------------------------------------------------- the guest's web server
// sw.js (scope vm/) turns a fetch of vm/PORT/PATH into a raw HTTP request and
// asks this page; the emulator worker has the guest answer it (web_http_*).
// While StrataOS runs, the worker is asked every 3 s which of the web ports
// listen; one that starts listening opens a panel with the page in it.
const VM_PORTS = [80, 8000];
const vmWait = new Map();   // request id -> the Service Worker's MessagePort
let vmSeq = 0;
const vmSeen = {};          // port -> listening (1 / 0 / -1), and whether its panel was shown
if ("serviceWorker" in navigator) {
  navigator.serviceWorker.register("sw.js" + V, { scope: "vm/" }).catch(() => { /* (no panel then) */ });
  navigator.serviceWorker.addEventListener("message", (e) => {
    const m = e.data, port = e.ports[0];
    if (!m || m.t !== "vmhttp" || !port) return;
    if (!W || stopped) { port.postMessage({ error: 502 }); return; }
    const id = ++vmSeq;
    vmWait.set(id, port);
    W.postMessage({ t: "http", id, port: m.port, request: m.request });
  });
}
function vmAnswer(m) {
  const port = vmWait.get(m.id);
  if (!port) return;
  vmWait.delete(m.id);
  if (m.response) port.postMessage({ response: m.response }, [m.response.buffer]);
  else port.postMessage({ error: m.error || 502 });
}
setInterval(() => {
  if (W && !stopped && (current === "os" || current === "osws")) W.postMessage({ t: "ports", ports: VM_PORTS });
}, 3000);
function vmPorts(listening) {
  for (const p of VM_PORTS) {
    const was = vmSeen[p] && vmSeen[p].on;
    const on = listening[p] === 1;
    vmSeen[p] = Object.assign(vmSeen[p] || {}, { on });
    if (on && !was) vmShow(p, !vmSeen[p].shown);
  }
  vmChips();
}

// The windows: one small browser per guest web server (port), all shown
// together, each floating, moved by its title bar and resized by its edges
// and corner (a bottom sheet on a phone, one at a time there), with back /
// forward over its own history (the iframe's history.back() could take the
// play page itself back), an address field, reload, open-in-a-tab and close
// (a chip stays). A click brings a window to the front. They never take the
// focus from the terminal or the screen; each one's place and size are
// remembered.
const vmWins = {};          // port -> { el, port, hist, at, nav }
let vmTop = 50;             // the front window's z-index
let vmChipBox = null;
const VM_GEOM = "strata-play-vm-";
const vmPhone = () => matchMedia("(max-width: 700px)").matches;
function vmUrl(p, path = "/") { return new URL(`vm/${p}${path}`, location.href).href; }
function vmPathOf(href) { // the guest path of a vm/PORT/... URL
  const m = /\/vm\/(\d+)(\/.*)?$/.exec(new URL(href, location.href).pathname);
  return m ? (m[2] || "/") : null;
}
function vmGo(w, path, push = true) {
  w.nav = !push;
  w.el.querySelector("iframe").src = vmUrl(w.port, path.startsWith("/") ? path : "/" + path);
}
function vmButtons(w) {
  w.el.querySelector(".vmback").disabled = w.at <= 0;
  w.el.querySelector(".vmfwd").disabled = w.at >= w.hist.length - 1;
}
function vmFront(w) { w.el.style.zIndex = ++vmTop; }
function vmSaveGeom(w) {
  if (vmPhone()) return;
  const r = w.el.getBoundingClientRect();
  try { localStorage.setItem(VM_GEOM + w.port, JSON.stringify({ l: r.left, t: r.top, w: r.width, h: r.height })); } catch (e) { /* no storage */ }
}
// The guest's page keeps its scrolling: at its ends (or when it cannot
// scroll at all) the wheel would otherwise go on to the play page under the
// panel. Same origin (the Service Worker serves it), so the panel can say so.
function vmContain(frame) {
  let d;
  try { d = frame.contentDocument; } catch (e) { return; }
  if (!d || !d.documentElement) return;
  d.documentElement.style.overscrollBehavior = "contain";
  if (d.body) d.body.style.overscrollBehavior = "contain";
  d.addEventListener("wheel", (e) => {
    // the innermost element under the pointer that can still scroll that way takes it
    for (let n = e.target; n && n.nodeType === 1; n = n.parentElement) {
      const cs = d.defaultView.getComputedStyle(n);
      const canY = /(auto|scroll)/.test(cs.overflowY) || n === d.scrollingElement;
      const canX = /(auto|scroll)/.test(cs.overflowX) || n === d.scrollingElement;
      if (canY && e.deltaY < 0 && n.scrollTop > 0) return;
      if (canY && e.deltaY > 0 && n.scrollTop + n.clientHeight < n.scrollHeight - 1) return;
      if (canX && e.deltaX < 0 && n.scrollLeft > 0) return;
      if (canX && e.deltaX > 0 && n.scrollLeft + n.clientWidth < n.scrollWidth - 1) return;
    }
    e.preventDefault(); // nothing left to scroll here: and not the page below either
  }, { passive: false });
}
function vmBuild(p) {
  const el = document.createElement("section");
  el.className = "vmpanel";
  el.hidden = true;
  el.innerHTML = `<div class="vmbar"><span class="vmtitle"></span>` +
    `<span class="vmbtns"><button class="small vmback" title="Back">←</button>` +
    `<button class="small vmfwd" title="Forward">→</button>` +
    `<button class="small vmreload" title="Reload">↻</button></span>` +
    `<input class="vmaddr" spellcheck="false" autocomplete="off" aria-label="Path on the guest's server">` +
    `<span class="vmbtns"><button class="small vmopen" title="Open in a new tab">↗</button>` +
    `<button class="small vmclose" title="Close (a chip stays)">✕</button></span></div>` +
    `<iframe class="vmframe" title="The guest's web server on port ${p}" tabindex="-1"></iframe>` +
    `<div class="vmgrip" data-e="e"></div><div class="vmgrip" data-e="s"></div><div class="vmgrip" data-e="w"></div>` +
    `<div class="vmgrip" data-e="se"></div><div class="vmgrip" data-e="sw"></div>`;
  document.body.appendChild(el);
  const w = { el, port: p, hist: [], at: -1, nav: false };
  vmWins[p] = w;
  el.querySelector(".vmtitle").textContent = `:${p}`;
  el.querySelector(".vmtitle").title = `The guest's web server on port ${p}: ${vmUrl(p)}`;
  const frame = el.querySelector("iframe"), addr = el.querySelector(".vmaddr");
  // the window's own history: every page the iframe shows, back / forward move in it
  frame.addEventListener("load", () => {
    let path = null;
    try { path = vmPathOf(frame.contentWindow.location.href); } catch (e) { /* not ours */ }
    if (path === null) return;
    vmContain(frame);
    try { frame.contentDocument.addEventListener("pointerdown", () => vmFront(w)); } catch (e) { /* not ours */ }
    if (w.nav) w.nav = false;
    else if (w.hist[w.at] !== path) { w.hist.splice(w.at + 1); w.hist.push(path); w.at = w.hist.length - 1; }
    addr.value = path;
    vmButtons(w);
  });
  el.querySelector(".vmback").addEventListener("click", () => { if (w.at > 0) vmGo(w, w.hist[--w.at], false); vmButtons(w); });
  el.querySelector(".vmfwd").addEventListener("click", () => { if (w.at < w.hist.length - 1) vmGo(w, w.hist[++w.at], false); vmButtons(w); });
  el.querySelector(".vmreload").addEventListener("click", () => { if (w.at >= 0) vmGo(w, w.hist[w.at], false); else vmGo(w, "/"); });
  el.querySelector(".vmopen").addEventListener("click", () => window.open(vmUrl(p, w.hist[w.at] || "/"), "_blank", "noopener"));
  el.querySelector(".vmclose").addEventListener("click", () => { el.hidden = true; vmChips(); });
  addr.addEventListener("keydown", (e) => {
    if (e.key === "Enter") { e.preventDefault(); vmGo(w, addr.value.trim() || "/"); addr.blur(); }
    else if (e.key === "Escape") { addr.value = w.hist[w.at] || "/"; addr.blur(); }
  });
  for (const b of el.querySelectorAll("button")) b.addEventListener("mousedown", (e) => e.preventDefault()); // (no focus)
  el.addEventListener("wheel", (e) => e.preventDefault(), { passive: false }); // the bar and the edges: no page scrolling
  el.addEventListener("pointerdown", () => vmFront(w));
  // moving (by the bar) and resizing (by the grips): the pointer is captured,
  // and the iframes ignore it meanwhile so they cannot swallow the moves
  const track = (e, onMove) => {
    e.preventDefault();
    const t = e.currentTarget;
    t.setPointerCapture(e.pointerId);
    for (const f of document.querySelectorAll(".vmframe")) f.style.pointerEvents = "none";
    const r0 = el.getBoundingClientRect(), x0 = e.clientX, y0 = e.clientY;
    const mv = (ev) => onMove(r0, ev.clientX - x0, ev.clientY - y0);
    const up = () => {
      t.removeEventListener("pointermove", mv);
      t.removeEventListener("pointerup", up);
      t.removeEventListener("pointercancel", up);
      for (const f of document.querySelectorAll(".vmframe")) f.style.pointerEvents = "";
      vmSaveGeom(w);
    };
    t.addEventListener("pointermove", mv);
    t.addEventListener("pointerup", up);
    t.addEventListener("pointercancel", up);
  };
  const place = (l, t, wd, h) => {
    wd = Math.max(280, Math.min(wd, innerWidth));
    h = Math.max(180, Math.min(h, innerHeight));
    l = Math.max(0, Math.min(l, innerWidth - 80));
    t = Math.max(0, Math.min(t, innerHeight - 40));
    Object.assign(el.style, { left: l + "px", top: t + "px", width: wd + "px", height: h + "px", right: "auto", bottom: "auto" });
  };
  w.place = place;
  el.querySelector(".vmbar").addEventListener("pointerdown", (e) => {
    if (e.target.closest("button, a, input") || vmPhone()) return;
    track(e, (r, dx, dy) => place(r.left + dx, r.top + dy, r.width, r.height));
  });
  for (const g of el.querySelectorAll(".vmgrip")) g.addEventListener("pointerdown", (e) => {
    if (vmPhone()) return;
    const edge = g.dataset.e;
    track(e, (r, dx, dy) => {
      let l = r.left, wd = r.width, h = r.height;
      if (edge.includes("e")) wd = r.width + dx;
      if (edge.includes("w")) { wd = r.width - dx; l = r.left + dx; if (wd < 280) l -= 280 - wd; }
      if (edge.includes("s")) h = r.height + dy;
      place(l, r.top, wd, h);
    });
  });
  // where it was last time, else cascaded from the bottom right after the other windows
  let g = null;
  try { g = JSON.parse(localStorage.getItem(VM_GEOM + p) || "null"); } catch (e) { /* no storage */ }
  if (!vmPhone()) {
    if (g) place(g.l, g.t, g.w, g.h);
    else {
      const k = Object.keys(vmWins).length - 1, wd = Math.min(720, innerWidth * 0.92), h = Math.min(500, innerHeight * 0.7);
      place(innerWidth - wd - 24 - 40 * k, innerHeight - h - 24 - 40 * k, wd, h);
    }
  }
  addEventListener("resize", () => { if (!el.hidden && el.style.left) { const r = el.getBoundingClientRect(); place(r.left, r.top, r.width, r.height); } });
  return w;
}
function vmShow(p, open) {
  vmSeen[p].shown = true;
  const w = vmWins[p] || vmBuild(p);
  if (open) {
    if (vmPhone()) for (const q in vmWins) if (+q !== p) vmWins[q].el.hidden = true; // a phone: one sheet at a time
    w.el.hidden = false;
    vmFront(w);
    if (w.at < 0) vmGo(w, "/");
  }
  vmChips();
}
function vmChips() {
  if (!vmChipBox) {
    vmChipBox = document.createElement("div");
    vmChipBox.className = "vmchips";
    document.body.appendChild(vmChipBox);
  }
  vmChipBox.textContent = "";
  for (const p of VM_PORTS) {
    if (!vmSeen[p] || !vmSeen[p].on || (vmWins[p] && !vmWins[p].el.hidden)) continue;
    const c = document.createElement("button");
    c.className = "small vmchip";
    c.textContent = `◉ web :${p}`;
    c.title = `The guest's web server on port ${p}`;
    c.addEventListener("mousedown", (e) => e.preventDefault());
    c.addEventListener("click", () => vmShow(p, true));
    vmChipBox.appendChild(c);
  }
}

fetch("demos/index.txt" + V).then((r) => (r.ok ? r.text() : "")).then((txt) => {
  for (const name of txt.split(/\s+/).filter(Boolean)) {
    const o = document.createElement("option");
    o.value = name;
    o.textContent = name + ".fs";
    $("demos").appendChild(o);
  }
});
async function pasteDemo(name) {
  if (!name || current !== "forth" || !W) return;
  const text = await (await fetch(`demos/${name}.fs` + V)).text();
  sendText(text.replace(/\r\n?/g, "\n"));
  term.focus();
}
$("demos").addEventListener("change", (e) => {
  const name = e.target.value;
  e.target.value = "";
  pasteDemo(name);
});

// ?run=os|ws|gfx|forth|hello|mandel starts one at once; with run=forth,
// &demo=NAME then pastes demos/NAME.fs (the source browser links these)
const want = params.get("run"), demo = params.get("demo");
if (want && PRESETS[want])
  run(want).then(() => { if (want === "forth" && demo && /^[\w-]+$/.test(demo)) pasteDemo(demo); });

// ---------------------------------------------------------------- touch keys
// A phone or tablet has no hardware keyboard: the soft keyboard types only
// into text fields, and it has no Alt, Ctrl or Esc. So on a touch screen a
// key bar under the screen sends those, and its Keyboard button focuses a
// hidden field whose input goes to the machine as the canvas keyboard would
// (Ctrl and Alt are sticky for the next key).
(() => {
  const bar = $("touchkeys"), field = $("tkin");
  if (!bar || !matchMedia("(pointer: coarse)").matches) return;
  const unesc = (s) => s.replace(/\\x([0-9a-f]{2})/gi, (_, h) => String.fromCharCode(parseInt(h, 16)))
                        .replace(/\\n/g, "\n").replace(/\\t/g, "\t");
  let ctrl = false, alt = false;
  const mods = () => { for (const b of bar.querySelectorAll(".tk-mod")) b.classList.toggle("on", b.dataset.tk === "ctrl" ? ctrl : alt); };
  const send = (s) => {
    if (ctrl && s.length === 1 && /[a-z@\[\\\]^_ ]/i.test(s)) s = String.fromCharCode(s.toUpperCase().charCodeAt(0) & 31);
    if (alt && s !== "\x03") s = altSeq(s);
    ctrl = alt = false;
    mods();
    sendText(s);
  };
  // show the bar while the screen is shown (StrataOS, ws, gfx, Forth with a screen)
  new MutationObserver(() => { bar.hidden = screenPanel.classList.contains("collapsed"); })
    .observe(screenPanel, { attributes: true, attributeFilter: ["class"] });
  bar.hidden = screenPanel.classList.contains("collapsed");
  let typing = false; // the soft keyboard is up (the field has focus)
  field.addEventListener("focus", () => { typing = true; });
  field.addEventListener("blur", () => { typing = false; });
  const refocus = (was) => { if (was) field.focus({ preventScroll: true }); };
  for (const b of bar.querySelectorAll("button")) {
    b.addEventListener("mousedown", (e) => e.preventDefault()); // (a mouse: keep the field's focus)
    b.addEventListener("click", () => {
      const was = typing; // a tap on a button may take the focus: give it back (the keyboard stays up)
      const tk = b.dataset.tk;
      if (tk === "kbd") { field.focus({ preventScroll: true }); return; }
      if (tk === "ctrl") ctrl = !ctrl, mods();
      else if (tk === "alt") alt = !alt, mods();
      else if (b.dataset.alt) ctrl = false, alt = true, send(unesc(b.dataset.alt)); // an Alt binding
      else send(unesc(b.dataset.send));
      refocus(was);
    });
  }
  field.addEventListener("beforeinput", (e) => {
    e.preventDefault(); // nothing collects in the field; every key goes out at once
    if (e.inputType === "deleteContentBackward") send("\x7f");
    else if (e.inputType === "insertLineBreak" || e.inputType === "insertParagraph") send("\n");
    else if (e.data) for (const ch of e.data) send(ch);
  });
  field.addEventListener("keydown", (e) => { // keys the soft keyboard reports only as keydown
    if (e.key === "Enter") { e.preventDefault(); send("\n"); }
    else if (e.key === "Backspace" && !field.value) { e.preventDefault(); send("\x7f"); }
  });
})();
