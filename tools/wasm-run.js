#!/usr/bin/env node
// Runs the WebAssembly build of strata-emu (make wasm: web/web.c, the same
// module the play page's worker runs) under node, with the desktop
// emulator's flags:
//
//   node tools/wasm-run.js build/web/strata-emu.js [strata-emu flags] image.stx
//
// Files named on the command line (the image, -d disk, -i input) are
// copied into the module's in-memory file system; -F frame.ppm and
// -t trace.txt are copied back out at the end. Console output goes to
// stdout, the emulator's messages to stderr, and the exit status is the
// desktop emulator's (1 after a fault, a deadlock or a timeout). There is
// no terminal input: without -i the console reads nothing (as with
// </dev/null). -J runs the WebAssembly JIT, -j the interpreter.
// Environment: STRATA_JIT_HOT=n (see below), STRATA_JIT_STAT=1 (print the
// number of translated regions at exit).
"use strict";
const fs = require("fs");
const path = require("path");

const [modPath, ...argv] = process.argv.slice(2);
if (!modPath || !argv.length) {
  console.error("usage: node tools/wasm-run.js strata-emu.js [flags] image.stx");
  process.exit(2);
}
const WITH_ARG = new Set(["-c", "-t", "-m", "-d", "-i", "-b", "-T", "-g", "-F", "-z", "-r"]);
const inputs = [], outputs = [], args = [];
let haveInput = false;
for (let i = 0; i < argv.length; i++) {
  const a = argv[i];
  if (WITH_ARG.has(a) && i + 1 < argv.length) {
    const v = argv[++i];
    if (a === "-i" || a === "-d") { inputs.push([`/in${i}`, v]); args.push(a, `/in${i}`); haveInput |= a === "-i"; }
    else if (a === "-F" || a === "-t") { outputs.push([`/out${i}`, v]); args.push(a, `/out${i}`); }
    else args.push(a, v);
  } else if (!a.startsWith("-")) { inputs.push([`/in${i}`, v_of(a)]); args.push(`/in${i}`); }
  else args.push(a);
}
function v_of(a) { return a; }
if (!haveInput) { inputs.push(["/empty", null]); args.unshift("-i", "/empty"); }

function write(fd, bytes) { if (bytes.length) fs.writeSync(fd, Buffer.from(bytes)); }

(async () => {
  let out = [], err = [];
  const cfg = {
    noInitialRun: true,
    locateFile: (f) => path.join(path.dirname(path.resolve(modPath)), f),
    preRun: [(mod) => (mod || cfg).FS.init(() => null,
      (b) => { if (b !== null && b !== undefined) out.push(b & 255); },
      (b) => { if (b !== null && b !== undefined) err.push(b & 255); })],
    print: (s) => fs.writeSync(1, s + "\n"),
    printErr: (s) => fs.writeSync(2, s + "\n"),
  };
  const M = await require(path.resolve(modPath))(cfg);
  for (const [name, host] of inputs) M.FS.writeFile(name, host === null ? new Uint8Array(0) : fs.readFileSync(host));
  const flush = () => { write(1, out); write(2, err); out = []; err = []; };
  let rc = M.callMain(args);
  // STRATA_JIT_HOT=n: translate a pc after n visits (default 24; 1 = everything; 0 = also no tail calls)
  if (process.env.STRATA_JIT_HOT !== undefined) M._jit_wasm_set_hot(+process.env.STRATA_JIT_HOT);
  if (process.env.STRATA_JIT_STAT) process.on("exit", () => fs.writeSync(2, `jit: ${M._jit_wasm_stat(0)} regions, tail calls ${M._jit_wasm_stat(1) ? "on" : "off"}\n`));
  flush();
  if (rc) process.exit(rc);
  while (M._web_run(1000) >= 0) flush(); // (an interactive wait cannot end here: there is no input)
  M._web_finish();
  flush();
  for (const [name, host] of outputs) {
    try { fs.writeFileSync(host, M.FS.readFile(name)); } catch (e) { /* not written (no frame presented) */ }
  }
  const state = M._web_stat(5); // 1 halted, 2 deadlock, 4 timeout
  process.exit(state === 1 ? (M._web_stat(7) ? 1 : 0) : 1);
})().catch((e) => { console.error(e); process.exit(2); });
