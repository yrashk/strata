// The play page: runs strata-emu (web/web.c, built with `make wasm`) in the
// browser. The emulator lives in a Web Worker (worker.js), where it runs
// continuously; this file only moves bytes: console output to the
// terminal, keys to the worker, framebuffer rows to the canvas. Each run is
// a fresh worker with a fresh instance of the WebAssembly module (Reset =
// a new worker), given the images fetched from images/ and the desktop
// flags. The page compiles the module once and hands it to every worker.
"use strict";

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

// ?jit=0 starts with the JIT off; the checkbox restarts the current preset
const params = new URLSearchParams(location.search);
const jitBox = $("jit");
jitBox.checked = params.get("jit") !== "0";

let wasmModule = null;
async function compileWasm() {
  if (wasmModule) return wasmModule;
  const resp = fetch("strata-emu.wasm");
  try {
    wasmModule = await WebAssembly.compileStreaming(resp);
  } catch (e) { // a server without application/wasm
    wasmModule = await WebAssembly.compile(await (await fetch("strata-emu.wasm")).arrayBuffer());
  }
  return wasmModule;
}

const files = new Map();
function fetchFile(name) {
  if (!files.has(name))
    files.set(name, fetch("images/" + name).then((r) => {
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
  else if (!s && !e.ctrlKey && e.key.length === 1) s = e.key;
  if (!s) return;
  e.preventDefault();
  sendText(e.altKey && s !== "\x03" ? "\x1b" + s : s);
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
  const { steps, cores, live, now, jit } = stat;
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
               : m.state === 2 ? "deadlock: every live core is blocked" : "stopped";
    const secs = (performance.now() - runStart) / 1000;
    stat = m;
    mips = m.steps / secs / 1e6; // the average over the run
    setStopped(`${what} after ${secs.toFixed(1)} s · ${statusLine()} · Reset to run again`);
    break;
  }
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
  aboutEl.textContent = p.about;
  screenPanel.classList.add("collapsed");
  $("geom").textContent = "no framebuffer output yet";
  ctx.fillStyle = "#000";
  ctx.fillRect(0, 0, canvas.width, canvas.height);
  const args = [jitBox.checked ? "-J" : "-j", ...(p.fitScreen ? ["-r", screenGeometry()] : []), ...p.args];
  term.write("\x1bc"); // reset, in order with the writes still queued
  outText(`\x1b[2m$ strata-emu ${args.join(" ")}\x1b[0m\n`);

  try {
    const [wasm, ...bufs] = await Promise.all([compileWasm(), ...p.files.map(fetchFile)]);
    if (current !== key || W) return; // another preset was picked meanwhile
    const w = new Worker("worker.js");
    W = w;
    stopped = false;
    w.onmessage = (e) => onWorker(w, e.data);
    w.onerror = (e) => { if (w === W) setStopped("error: " + (e.message || "the worker failed")); };
    // the module and the images are copied (structured clone), so Reset can reuse them
    w.postMessage({ t: "start", wasm, files: p.files.map((name, i) => ({ name, data: bufs[i] })), args });
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

fetch("demos/index.txt").then((r) => (r.ok ? r.text() : "")).then((txt) => {
  for (const name of txt.split(/\s+/).filter(Boolean)) {
    const o = document.createElement("option");
    o.value = name;
    o.textContent = name + ".fs";
    $("demos").appendChild(o);
  }
});
async function pasteDemo(name) {
  if (!name || current !== "forth" || !W) return;
  const text = await (await fetch(`demos/${name}.fs`)).text();
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
