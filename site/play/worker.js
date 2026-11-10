// The play page's emulator worker: owns one instance of strata-emu
// (web/web.c, built with `make wasm`) and runs it continuously, off the
// page's thread. The page (play.js) only paints and handles input; the two
// talk with postMessage (no SharedArrayBuffer: GitHub Pages cannot send
// the COOP/COEP headers it needs).
//
//   page -> worker
//     {t:"start", wasm: WebAssembly.Module, files: [{name, data}], args: [...]}
//     {t:"input", data: Uint8Array}     console bytes (terminal, canvas keys, pasted demos)
//     {t:"break"}                       Ctrl-C
//   worker -> page
//     {t:"started"} | {t:"exit", code} | {t:"error", msg}
//     {t:"out", data: Uint8Array}       console output (stderr lines wrapped in amber), transferred
//     {t:"paint", y0, rows, w, h, data: Uint8ClampedArray}   changed framebuffer rows as RGBA, transferred
//     {t:"status", steps, cores, live, now, jit}             twice a second while running
//     {t:"stopped", state, faulted, steps, cores, live, now, jit}
// Reset and picking another preset terminate the worker and start a new one.
//
// The loop: web_run(SLICE) runs machine rounds for a few milliseconds and
// says what next: 0 = call again at once (after the worker's pending
// messages, which a MessageChannel hop lets in: unlike setTimeout it is
// not clamped to 4 ms); > 0 = every core waits on a device, sleep that
// many milliseconds (or until input arrives); < 0 = the machine stopped.
"use strict";
importScripts("strata-emu.js");

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
           jit: !!M._web_stat(8) };
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
  if (wait >= 1 && !(inPending.length && M._web_stat(6) < HOST_INQ)) {
    // asleep until the deadline; the status line stays alive meanwhile
    timer = setTimeout(pump, Math.min(Math.floor(wait), STATUS_MS));
  } else hop();
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
  instance = await createStrata(cfg);
  for (const f of msg.files) instance.FS.writeFile("/" + f.name, new Uint8Array(f.data));
  inBuf = instance._malloc(4096);
  M = instance;
  const rc = M.callMain([...msg.args]);
  flushOut();
  if (rc) { postMessage({ t: "exit", code: rc }); return; }
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
  }
};
