// The web debugger's worker: one instance of strata-emu (web/web.c, the
// play page's module) under its debug engine (emu/debug.c), driven over the
// engine's protocol (doc/debug-protocol.md). The page (debug.js) sends
// requests and gets answers and events; this worker runs the machine
// between them while the engine says it is running.
//
//   page -> worker
//     {t:"start", files: [{path, data}], image, args: [...]}
//                                 files go into the module's file system at
//                                 their paths (the image, its map, the sources
//                                 the map names); then main(--debug wasm args image)
//     {t:"req", line}             one request (a JSON line, with its "id")
//   worker -> page
//     {t:"started"} | {t:"error", msg}
//     {t:"resp", line}            the answer to a request
//     {t:"ev", lines: [...]}      events: console output, stopped, done
//     {t:"emu", text}             the emulator's own messages (halts, faults)
//     {t:"paint", y0, rows, w, h, data}  changed framebuffer rows as RGBA (as the
//                                 play page's worker): while it runs, at most
//                                 every PAINT_MS; all of it after time travel
//
// The loop: web_dbg_run(SLICE) runs the machine for a few milliseconds and
// says what next: 0 = again (after the messages already queued: a
// MessageChannel hop, so that a "pause" gets in), > 0 = idle (every core
// waits for input or time: sleep that long), < 0 = not running.
"use strict";
importScripts("../play/strata-emu.js" + self.location.search); // (the build id: see debug.js)

const SLICE = 15, PAINT_MS = 33;
let M = null, hopQueued = false, timer = 0, lastPaint = 0;
let travelled = false; // (a snapshot's pages came back without marking the framebuffer: send all of it once stopped)
const chan = new MessageChannel();
chan.port1.onmessage = () => { hopQueued = false; pump(); };
function hop() { if (!hopQueued) { hopQueued = true; chan.port2.postMessage(0); } }

let errLine = "";
function errput(b) {
  if (b === null || b === undefined) return;
  if (b === 10) { postMessage({ t: "emu", text: errLine }); errLine = ""; }
  else errLine += String.fromCharCode(b & 255);
}

function events() {
  const s = M.UTF8ToString(M._web_dbg_events());
  if (s) postMessage({ t: "ev", lines: s.split("\n").filter(Boolean) });
}

function paint(force) {
  const now = performance.now();
  if (!force && now - lastPaint < PAINT_MS) return;
  lastPaint = now;
  M._web_paint();
}

function pump() {
  if (timer) { clearTimeout(timer); timer = 0; }
  if (!M) return;
  const w = M._web_dbg_run(SLICE);
  if (w < 0 && travelled) { travelled = false; M._web_dbg_repaint(); }
  paint(w < 0);
  events();
  if (w < 0) return;
  if (w === 0) hop();
  else timer = setTimeout(pump, Math.min(Math.ceil(w), 100));
}

// requests that move the machine to another point of its run
const TRAVEL = /"cmd":"(goto|reverse-[a-z-]+|set-mem)"/;

function request(line) {
  const p = M.stringToNewUTF8(line);
  const r = M.UTF8ToString(M._web_dbg(p));
  M._free(p);
  if (TRAVEL.test(line)) travelled = true;
  if (travelled) M._web_dbg_repaint();
  paint(true);
  postMessage({ t: "resp", line: r });
  events();
  hop(); // (runs the machine if the request started it; returns at once if not)
}

async function start(msg) {
  const cfg = {
    noInitialRun: true,
    locateFile: (f) => "../play/" + f + self.location.search,
    preRun: [(mod) => (mod || cfg).FS.init(() => null, () => {}, errput)],
    webPaint(ptr, y0, rows, w, h) {
      const data = new Uint8ClampedArray(inst.HEAPU8.buffer, ptr, w * rows * 4).slice(); // a copy to give away
      postMessage({ t: "paint", y0, rows, w, h, data }, [data.buffer]);
    },
    print: () => {},
    printErr: (s) => postMessage({ t: "emu", text: s }),
  };
  const inst = await createStrata(cfg);
  for (const f of msg.files) {
    const dir = f.path.slice(0, f.path.lastIndexOf("/"));
    if (dir) inst.FS.mkdirTree(dir);
    inst.FS.writeFile(f.path, new Uint8Array(f.data));
  }
  const rc = inst.callMain(["--debug", "wasm", ...msg.args, msg.image]);
  if (rc) { postMessage({ t: "error", msg: "the emulator would not start (exit " + rc + ")" }); return; }
  M = inst;
  postMessage({ t: "started" });
}

onmessage = (e) => {
  const m = e.data;
  if (m.t === "start") start(m).catch((err) => postMessage({ t: "error", msg: String(err && err.message ? err.message : err) }));
  else if (m.t === "req" && M) request(m.line);
};
