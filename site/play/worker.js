// The play page's emulator worker: owns one instance of strata-emu
// (web/web.c, built with `make wasm`) and runs it continuously, off the
// page's thread. With machine: "rtl" it owns the RTL simulator instead
// (strata-rtl: web/web_rtl.cpp, built with `make wasm-rtl`), which answers
// the same calls: no JIT, no network far end, and web_stat(0) counts clock
// cycles. The page (play.js) only paints and handles input; the two
// talk with postMessage (no SharedArrayBuffer: GitHub Pages cannot send
// the COOP/COEP headers it needs).
//
//   page -> worker
//     {t:"start", machine: "emu" | "rtl", wasm: WebAssembly.Module, files: [{name, data}], args: [...],
//      net: {mode: "peer" | "tab" | "relay", url},   (net.js: the network's far end)
//      jitBudget?, jitHot?}            (the JIT's limits: see JIT_LIMITS in play.js)
//     {t:"input", data: Uint8Array}     console bytes (terminal, canvas keys, pasted demos)
//     {t:"break"}                       Ctrl-C
//     {t:"ptr", op, a, b}               the canvas's mouse (web/web.c web_pointer)
//     {t:"http", id, port, request: Uint8Array}   one HTTP exchange with the guest's server
//                                       (sw.js: the guest's web server in the page)
//     {t:"ports", ports: [80, 8000]}    which of these the guest listens on
//   worker -> page
//     {t:"started"} | {t:"exit", code} | {t:"error", msg}
//     {t:"out", data: Uint8Array}       console output (stderr lines wrapped in amber), transferred
//     {t:"paint", y0, rows, w, h, data: Uint8ClampedArray}   changed framebuffer rows as RGBA, transferred
//     {t:"status", steps, cores, live, now, jit, ptr}        twice a second while running
//                                       (ptr: the guest reads the pointer: hide the page's cursor)
//     {t:"stopped", state, faulted, steps, cores, live, now, jit}
//     {t:"net", text}                   a note about the network (this tab's address, the relay)
//     {t:"http", id, response: Uint8Array} | {t:"http", id, error: 503 | 504}
//     {t:"ports", listening: {port: 1 | 0 | -1}}
// Reset and picking another preset terminate the worker and start a new one.
//
// The loop: web_run(SLICE) runs machine rounds for a few milliseconds and
// says what next: 0 = call again at once (after the worker's pending
// messages, which a MessageChannel hop lets in: unlike setTimeout it is
// not clamped to 4 ms); > 0 = every core waits on a device, sleep that
// many milliseconds (or until input arrives); < 0 = the machine stopped.
"use strict";
// (the machine's module, strata-emu.js or strata-rtl.js, is loaded by start())
importScripts("net.js" + self.location.search);         // the network's far end (StrataNet)

const SLICE = 12;        // ms of emulation between looks at the message queue
const PAINT_MS = 15;     // at most one canvas update per display frame
const STATUS_MS = 500;
const HOST_INQ = 4096;   // common/display.h: the guest's console input queue

let M = null, inBuf = 0, running = false;
let out = [];            // console output bytes not yet posted
let errLine = [];        // stderr, posted a line at a time in amber
let inPending = [];      // input bytes waiting for room in the guest's queue
let lastPaint = 0, lastStatus = 0, timer = 0, hopQueued = false;
const enc = new TextEncoder();

function flushOut() {
  if (!out.length) return;
  const data = new Uint8Array(out);
  out = [];
  postMessage({ t: "out", data }, [data.buffer]);
}
function errput(b) {
  if (b === null || b === undefined) return;
  if (b === 10) {
    out.push(27, 91, 51, 51, 109, ...errLine, 27, 91, 48, 109, 10); // ESC[33m line ESC[0m
    errLine = [];
  } else errLine.push(b & 255);
}
function text(s) { for (const b of enc.encode(s)) out.push(b); }

function stats() {
  return { steps: M._web_stat(0), cores: M._web_stat(2), live: M._web_stat(3), now: M._web_stat(4),
           jit: !!M._web_stat(8), rtl: !!M._web_stat(9), ptr: !!M._web_pointer_used() };
}

// Moves pending input into the guest's queue as far as it has room.
function feed() {
  if (!inPending.length) return;
  const n = Math.min(HOST_INQ - M._web_stat(6), inPending.length, 4096);
  if (n <= 0) return;
  M.HEAPU8.set(inPending.slice(0, n), inBuf);
  M._web_input(inBuf, n);
  inPending = inPending.slice(n);
}

function paint(now) {
  if (M._web_paint()) lastPaint = now;
}

// One slice of emulation, then whatever the page should see.
function pump() {
  hopQueued = false;
  if (timer) { clearTimeout(timer); timer = 0; }
  if (!running) return;
  feed();
  const wait = M._web_run(SLICE);
  const now = performance.now();
  flushOut();
  if (wait < 0) {
    running = false;
    paint(now);
    postMessage(Object.assign({ t: "stopped", state: M._web_stat(5), faulted: !!M._web_stat(7) }, stats()));
    return;
  }
  // an idle machine has finished what it was drawing: show it now
  if (wait > 0 || now - lastPaint >= PAINT_MS) paint(now);
  if (now - lastStatus >= STATUS_MS) {
    lastStatus = now;
    postMessage(Object.assign({ t: "status" }, stats()));
  }
  if (httpOpen.size) httpPump(now);
  if (wait >= 1 && !(inPending.length && M._web_stat(6) < HOST_INQ)) {
    // asleep until the deadline; the status line stays alive meanwhile
    // (an HTTP exchange in progress: back soon, to move its bytes)
    timer = setTimeout(pump, Math.min(Math.floor(wait), httpOpen.size ? 5 : STATUS_MS));
  } else hop();
}

// ---- the guest's servers, for the page (sw.js) -------------------------------------------
// One exchange: open a connection to the guest's port (web_http_open), send
// the request, gather the response until the guest closes or Content-Length
// is complete; then close (web_http_close). An empty answer: nothing listens.
const httpOpen = new Map();  // id -> {cid, chunks, len, until}
let httpBuf = 0;
const HTTP_MAX = 65536;
function httpStart(msg) {
  if (!httpBuf) httpBuf = M._malloc(HTTP_MAX);
  const cid = M._web_http_open(msg.port);
  if (cid < 0) { postMessage({ t: "http", id: msg.id, error: 503 }); return; }
  const rq = new Uint8Array(msg.request);
  for (let o = 0; o < rq.length; o += HTTP_MAX) {
    const part = rq.subarray(o, o + HTTP_MAX);
    M.HEAPU8.set(part, httpBuf);
    M._web_http_send(cid, httpBuf, part.length);
  }
  httpOpen.set(msg.id, { cid, chunks: [], len: 0, until: performance.now() + 30000 });
}
function httpDone(id, h, error) {
  M._web_http_close(h.cid);
  httpOpen.delete(id);
  if (error || !h.len) { postMessage({ t: "http", id, error: error || 503 }); return; }
  const response = new Uint8Array(h.len);
  let o = 0;
  for (const c of h.chunks) { response.set(c, o); o += c.length; }
  postMessage({ t: "http", id, response }, [response.buffer]);
}
// complete once the header is there and Content-Length bytes follow it
function httpComplete(h) {
  const all = new Uint8Array(h.len);
  let o = 0;
  for (const c of h.chunks) { all.set(c, o); o += c.length; }
  const text = new TextDecoder("latin1").decode(all.subarray(0, Math.min(all.length, 8192)));
  const end = text.indexOf("\r\n\r\n");
  if (end < 0) return false;
  const m = /\r\ncontent-length:\s*(\d+)/i.exec(text.slice(0, end));
  return m ? all.length >= end + 4 + +m[1] : false;
}
function httpPump(now) {
  for (const [id, h] of httpOpen) {
    for (;;) {
      const n = M._web_http_recv(h.cid, httpBuf, HTTP_MAX);
      if (n > 0) { h.chunks.push(M.HEAPU8.slice(httpBuf, httpBuf + n)); h.len += n; continue; }
      if (n === 0) { httpDone(id, h); break; }
      if (h.len && httpComplete(h)) { httpDone(id, h); break; }
      if (now > h.until) httpDone(id, h, h.len ? 0 : 504);
      break;
    }
  }
}


// Runs pump() after the messages already queued for the worker.
const chan = new MessageChannel();
chan.port1.onmessage = pump;
function hop() {
  if (!hopQueued) { hopQueued = true; chan.port2.postMessage(0); }
}

async function start(msg) {
  let instance;
  const cfg = {
    noInitialRun: true,
    instantiateWasm(imports, done) {
      WebAssembly.instantiate(msg.wasm, imports).then((i) => done(i, msg.wasm));
      return {};
    },
    preRun: [(mod) => (mod || cfg).FS.init(() => null, (b) => { if (b !== null && b !== undefined) out.push(b & 255); }, errput)],
    webPaint(ptr, y0, rows, w, h) {
      const data = new Uint8ClampedArray(instance.HEAPU8.buffer, ptr, w * rows * 4).slice(); // a copy to give away
      postMessage({ t: "paint", y0, rows, w, h, data }, [data.buffer]);
    },
    print: (s) => text(s + "\n"),
    printErr: (s) => text("\x1b[33m" + s + "\x1b[0m\n"),
  };
  const rtl = msg.machine === "rtl";
  importScripts((rtl ? "strata-rtl.js" : "strata-emu.js") + self.location.search); // (the build id: see play.js)
  instance = await (rtl ? createStrataRtl : createStrata)(cfg);
  for (const f of msg.files) instance.FS.writeFile("/" + f.name, new Uint8Array(f.data));
  inBuf = instance._malloc(4096);
  M = instance;
  // a phone's browser has little room for compiled code: fewer, hotter regions
  if (msg.jitBudget && M._jit_wasm_set_budget) M._jit_wasm_set_budget(msg.jitBudget);
  if (msg.jitHot && M._jit_wasm_set_hot) M._jit_wasm_set_hot(msg.jitHot);
  const rc = M.callMain([...msg.args]);
  flushOut();
  if (rc) { postMessage({ t: "exit", code: rc }); return; }
  const net = msg.net || { mode: "peer" };
  const note = (text) => postMessage({ t: "net", text });
  if (rtl) { /* the RTL's network interface has no cable in the browser */ }
  else if (net.mode === "peer") StrataNet.peer(M, hop, self.fetch.bind(self));
  else StrataNet.link(M, hop, note, net);
  running = true;
  lastStatus = performance.now();
  postMessage({ t: "started" });
  hop();
}

onmessage = (e) => {
  const msg = e.data;
  if (msg.t === "start") {
    start(msg).catch((err) => { flushOut(); postMessage({ t: "error", msg: String(err && err.message ? err.message : err) }); });
  } else if (msg.t === "input") {
    for (const b of msg.data) inPending.push(b);
    if (running) hop();
  } else if (msg.t === "break") {
    if (!running) return;
    feed();          // what was typed before it goes first, as far as it fits
    M._web_break();
    hop();
  } else if (msg.t === "http") {
    if (!running || !M._web_http_open) { postMessage({ t: "http", id: msg.id, error: 502 }); return; }
    httpStart(msg);
    hop();
  } else if (msg.t === "ports") {
    if (!running || !M._web_port_listening) return;
    const listening = {};
    for (const p of msg.ports) listening[p] = M._web_port_listening(p);
    postMessage({ t: "ports", listening });
    hop();
  } else if (msg.t === "ptr") {
    if (!running) return;
    M._web_pointer(msg.op, msg.a, msg.b);
    hop();
  }
};
