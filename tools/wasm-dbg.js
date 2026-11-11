#!/usr/bin/env node
// Drives the debug engine of the WebAssembly build (web/web.c: web_dbg,
// web_dbg_run, web_dbg_events; the same calls the web debugger's worker
// makes) under node, for the tests (tools/test-dbg.sh):
//
//   node tools/wasm-dbg.js build/web/strata-emu.js [strata-emu flags] image.stx < requests
//
// The image and its map (IMAGE.map, if there is one) and the sources the
// map names are copied into the module's file system. Each line of stdin is
// one request; a request that runs the machine (continue, stepi, ...) is
// followed by web_dbg_run() until the machine stops. Answers and events are
// printed one per line, as the engine wrote them.
"use strict";
const fs = require("fs");
const path = require("path");

const [modPath, ...argv] = process.argv.slice(2);
const image = argv[argv.length - 1];
const RUN = new Set(["continue", "stepi", "step-round", "until", "next", "finish", "goto"]);

(async () => {
  const cfg = {
    noInitialRun: true,
    locateFile: (f) => path.join(path.dirname(path.resolve(modPath)), f),
    print: (s) => process.stderr.write(s + "\n"),
    printErr: (s) => process.stderr.write(s + "\n"),
  };
  const create = require(path.resolve(modPath));
  const M = await create(cfg);
  const put = (p, data) => {
    const dir = path.posix.dirname(p);
    if (dir !== "/" && dir !== ".") M.FS.mkdirTree(dir);
    M.FS.writeFile(p, data);
  };
  put("/" + path.basename(image), fs.readFileSync(image));
  const map = image.replace(/\.stx$/, "") + ".map";
  if (fs.existsSync(map)) {
    const text = fs.readFileSync(map, "utf8");
    put("/" + path.basename(map), text);
    for (const m of text.matchAll(/^file \d+ (.*)$/gm)) if (fs.existsSync(m[1])) put("/" + m[1], fs.readFileSync(m[1]));
  }
  const rc = M.callMain(["--debug", "wasm", ...argv.slice(0, -1), "/" + path.basename(image)]);
  if (rc) process.exit(rc);
  const call = (line) => {
    const p = M.stringToNewUTF8(line);
    const r = M.UTF8ToString(M._web_dbg(p));
    M._free(p);
    return r;
  };
  const events = () => M.UTF8ToString(M._web_dbg_events()).split("\n").filter(Boolean);
  const lines = fs.readFileSync(0, "utf8").split("\n").filter((l) => l.trim());
  for (const l of lines) {
    console.log(call(l));
    for (const e of events()) console.log(e);
    if (RUN.has(JSON.parse(l).cmd))
      for (let i = 0; i < 100000; i++) {
        const w = M._web_dbg_run(50);
        for (const e of events()) console.log(e);
        if (w < 0) break;
      }
  }
})();
