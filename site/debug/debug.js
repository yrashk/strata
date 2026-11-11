// The web debugger: a front-end of strata-emu's debug engine (emu/debug.c),
// over its JSON-lines protocol (doc/debug-protocol.md). The engine runs
// either in a Web Worker in this page (dbg-worker.js: the play page's
// WebAssembly module) or in strata-emu --debug PORT on the desktop, reached
// over a WebSocket (the page detects that the engine served it: GET
// /dbg-info; or ?ws=host:port).
//
// What the page shows comes from requests: per core `disasm`, `regs`,
// `caps`; `tags` (the Local Store map), `log` (the transfer timeline),
// `provgraph` / `prov` (provenance), `breakpoints`, `status` (the recorded
// run, for the time slider). Events: `console`, `stopped`, `done`.
//
// URL parameters: ?ex=NAME (a program to load), &cores=N, &do=A,B,...
// (commands run after loading, for demos and screenshots: break:LOC,
// continue, stepi:N, round:N, rstepi:N, rcontinue, goto:TICK, core:N,
// watch:LOC:LEN, wait:MS), ?ws=host:port (a desktop engine).
"use strict";
const $ = (id) => document.getElementById(id);
const Q = new URLSearchParams(location.search);
const BUILD = "__BUILD__";       // (tools/web-stamp.sh: the commit, so that no cached file of another deploy is used)
const V = "?v=" + BUILD;
const ASSETS = "../play/debug/";
const RUNS = new Set(["continue", "stepi", "next", "finish", "step-round", "until"]);

// ---------------------------------------------------------------- transports
class Conn {
  constructor() { this.pending = new Map(); this.nid = 1; this.onEvent = () => {}; }
  request(cmd, args) {
    const id = this.nid++;
    const line = JSON.stringify(Object.assign({ id, cmd }, args || {}));
    return new Promise((res) => { this.pending.set(id, res); this.send(line); });
  }
  line(l) {
    let m;
    try { m = JSON.parse(l); } catch (e) { return; }
    if (m.ev) { this.onEvent(m); return; }
    const r = this.pending.get(m.id);
    if (r) { this.pending.delete(m.id); r(m); }
  }
}

class WorkerConn extends Conn {
  start(files, image, args) {
    this.w = new Worker("dbg-worker.js" + V);
    return new Promise((res, rej) => {
      this.w.onmessage = (e) => {
        const m = e.data;
        if (m.t === "started") res();
        else if (m.t === "error") rej(new Error(m.msg));
        else if (m.t === "resp") this.line(m.line);
        else if (m.t === "ev") for (const l of m.lines) this.line(l);
        else if (m.t === "emu") emuMessage(m.text);
      };
      this.w.onerror = (e) => rej(new Error(e.message || "the worker failed"));
      this.w.postMessage({ t: "start", files, image, args }, files.map((f) => f.data));
    });
  }
  send(line) { this.w.postMessage({ t: "req", line }); }
  close() { if (this.w) this.w.terminate(); }
}

class WsConn extends Conn {
  open(url) {
    this.url = url;
    return new Promise((res, rej) => {
      this.ws = new WebSocket(url);
      this.ws.onopen = () => res();
      this.ws.onerror = () => rej(new Error("cannot connect to " + url));
      this.ws.onmessage = (e) => this.line(e.data);
      this.ws.onclose = () => setStatus("the connection to the engine has closed", true);
    });
  }
  send(line) { this.ws.send(line); }
  close() { if (this.ws) this.ws.close(); }
}

// ---------------------------------------------------------------- state
let conn = null, hello = null, ncores = 0, cur = 0;
let running = false, done = false, busy = false;
let stopEv = null;            // the last stopped / done event
let prevX = [], lastX = [];   // registers at the previous and the last stop
let evs = [], evNext = 0;     // the event log as far as fetched
let hist = null;              // status.history
let pos = { tick: 0, round: 0 };
let poller = 0, provAll = false;

const hex = (v) => (typeof v === "string" ? BigInt(v) : BigInt(v || 0));
const h = (v) => "0x" + hex(v).toString(16);
const esc = (s) => String(s).replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c]);
const base = (f) => (f || "").split("/").pop();

function setStatus(text, stopped) {
  const s = $("status");
  s.textContent = text;
  s.classList.toggle("stopped", !!stopped);
}

function emuMessage(text) { conPut(text + "\n", true); }

// ---------------------------------------------------------------- console
let conText = "";
function conPut(s, emu) {
  const pre = $("con");
  const atEnd = pre.scrollTop + pre.clientHeight >= pre.scrollHeight - 4;
  if (emu) {
    const span = document.createElement("span");
    span.className = "emu";
    span.textContent = s;
    pre.appendChild(span);
  } else pre.appendChild(document.createTextNode(s));
  conText += s;
  while (pre.childNodes.length > 4000) pre.removeChild(pre.firstChild);
  if (atEnd) pre.scrollTop = pre.scrollHeight;
}

// ---------------------------------------------------------------- events
function onEvent(m) {
  if (m.ev === "console") { conPut(m.data); return; }
  if (m.ev === "stopped" || m.ev === "done") {
    stopEv = m;
    running = false;
    done = m.ev === "done";
    pos = { tick: m.tick, round: m.round };
    if (m.ev === "stopped" && m.core >= 0 && m.core < ncores) cur = m.core;
    clearInterval(poller);
    poller = 0;
    showStop();
    refreshAll();
  }
}

function showStop() {
  if (!stopEv) return;
  const at = `tick ${stopEv.tick} · round ${stopEv.round}`;
  if (stopEv.ev === "done") setStatus(`the machine has stopped: ${stopEv.why}${stopEv.faulted ? " (a core faulted)" : ""} · ${at}`, true);
  else setStatus(`stopped: ${stopEv.reason} · ${at}`, true);
  updateButtons();
}

function updateButtons() {
  const tt = hello && hello.timetravel;
  for (const b of document.querySelectorAll("[data-do]")) {
    const d = b.dataset.do;
    b.disabled = !conn || (running ? d !== "pause" : d === "pause") || (!running && done && !d.startsWith("reverse"));
    if (b.classList.contains("tt") && !tt) b.disabled = true;
  }
}

// ---------------------------------------------------------------- commands
async function doCmd(cmd, extra) {
  if (!conn || busy) return;
  const args = Object.assign({}, extra || {});
  if (["stepi", "next", "finish", "reverse-stepi", "reverse-tag"].includes(cmd) && args.core === undefined) args.core = cur;
  if (cmd !== "pause" && running) return;
  busy = cmd !== "pause";
  const r = await conn.request(cmd, args);
  busy = false;
  if (!r.ok) { setStatus(`${cmd}: ${r.error}`, true); return r; }
  if (RUNS.has(cmd) || (cmd === "goto" && running)) {
    running = true;
    setStatus("running…");
    updateButtons();
    if (!poller) poller = setInterval(poll, 250);
  }
  return r;
}

async function poll() {
  if (!running) return;
  await fetchLog();
  const s = await conn.request("status");
  if (s.ok) { pos = { tick: s.tick, round: s.round }; hist = s.history || hist; updateTime(); }
  drawTimeline();
  if (running) setStatus(`running… tick ${pos.tick} · round ${pos.round} · ${s.steps || 0} steps`);
}

// ---------------------------------------------------------------- refresh
let refreshing = false, again = false;
async function refreshAll() {
  if (refreshing) { again = true; return; }
  refreshing = true;
  try {
    do {
      again = false;
      await refreshCores();
      await fetchLog();
      const s = await conn.request("status");
      if (s.ok) { pos = { tick: s.tick, round: s.round }; hist = s.history || null; }
      updateTime();
      drawTimeline();
      await refreshLs();
      await refreshBps();
      await refreshProv();
    } while (again);
  } finally { refreshing = false; }
}

function coreOf(c) { return stopEv && stopEv.cores ? stopEv.cores.find((k) => k.core === c) : null; }

async function refreshCores() {
  const box = $("cores");
  const cols = [];
  for (let c = 0; c < ncores; c++) {
    const [d, r, k] = await Promise.all([
      conn.request("disasm", { core: c, before: 5, n: 15 }),
      conn.request("regs", { core: c }),
      conn.request("caps", { core: c }),
    ]);
    cols.push({ c, d, r, k });
  }
  prevX = lastX;
  lastX = cols.map((o) => (o.r.ok ? o.r.x : []));
  box.innerHTML = "";
  for (const { c, d, r, k } of cols) {
    const sum = coreOf(c) || {};
    const el = document.createElement("div");
    el.className = "core" + (c === cur ? " cur" : "");
    const who = sum.proc ? ` pid ${sum.pid} ${esc(sum.proc)}` : sum.pid ? ` pid ${sum.pid}` : "";
    let html = `<h4 data-core="${c}">core ${c} <em>${esc(sum.mode || "")}${who} · ${sum.instret || 0} retired</em>${sum.halted ? ' <span class="halt">halted</span>' : ""}</h4>`;
    if (sum.stall) html += `<p class="stall">stalled since round ${sum.stall.since}: ${esc(sum.stall.why)}</p>`;
    html += '<div class="dis">';
    for (const l of d.ok ? d.lines : []) {
      if (l.label) html += `<div class="lab">${esc(l.label)}:</div>`;
      const src = l.file ? `${base(l.file).replace(/\.s$/, "")}:${l.line}` : "";
      html += `<div class="${l.pc ? "pc " : ""}${l.bp ? "bp" : "nb"}" data-addr="${l.addr}" data-bp="${l.bp || ""}" title="${esc(src)}">` +
        `${hex(l.addr).toString(16).padStart(4, "0")}  ${esc(l.text.padEnd(28))} <span class="src">${esc(src)}</span></div>`;
    }
    html += "</div>";
    if (r.ok) {
      html += '<div class="regs">';
      const pv = prevX[c] || [];
      for (let i = 1; i < 32; i++) {
        const v = r.x[i], chg = pv[i] !== undefined && pv[i] !== v;
        html += `<div${chg ? ' class="chg"' : ""}><b>${XR[i]}</b>${hex(v).toString(16).padStart(16, "0")}</div>`;
      }
      html += `<div><b>pc</b>${hex(r.pc).toString(16).padStart(16, "0")}</div></div>`;
    }
    html += '<div class="sub">CAPABILITIES</div><div class="caps">';
    if (k.ok) k.caps.forEach((cap, i) => {
      if (!cap.valid) return;
      html += `<div data-core="${c}" data-reg="${i}" class="${cap.live ? "" : "dead"}" title="its history"><b>c${String(i).padEnd(2)}</b> ${capText(cap)}</div>`;
    });
    html += "</div>";
    el.innerHTML = html;
    box.appendChild(el);
  }
  const curEl = box.querySelector(".core.cur");
  if (curEl && (curEl.offsetLeft < box.scrollLeft || curEl.offsetLeft + curEl.offsetWidth > box.scrollLeft + box.clientWidth))
    box.scrollLeft = curEl.offsetLeft - 20;
}
const XR = ["zero", "ra", "sp", "gp", "tp", "t0", "t1", "t2", "s0", "s1", "a0", "a1", "a2", "a3", "a4", "a5",
  "a6", "a7", "s2", "s3", "s4", "s5", "s6", "s7", "s8", "s9", "s10", "s11", "t3", "t4", "t5", "t6"];

function capText(c) {
  let s = `${c.space} ${h(c.base)}+${h(c.len)} ${c.perms}`;
  if (c.rv) s += ` rv g${c.gen}`;
  if (!c.live) s += " DEAD";
  if (c.port) s += ` (${c.port})`;
  if (c.id) s += ` #${c.id}`;
  return esc(s);
}

$("cores").addEventListener("click", async (e) => {
  const hd = e.target.closest("h4[data-core]");
  if (hd) { cur = +hd.dataset.core; markCur(); refreshProv(); return; }
  const cap = e.target.closest(".caps div[data-reg]");
  if (cap) { showChain({ core: +cap.dataset.core, reg: +cap.dataset.reg }, `core ${cap.dataset.core} c${cap.dataset.reg}`); return; }
  const line = e.target.closest(".dis div[data-addr]");
  if (!line || running) return;
  if (line.dataset.bp) await conn.request("delete", { bp: +line.dataset.bp });
  else await conn.request("break", { addr: line.dataset.addr });
  await refreshCores();
  await refreshBps();
});
function markCur() {
  for (const el of document.querySelectorAll(".core")) el.classList.toggle("cur", el.querySelector("h4").dataset.core == cur);
}

// ---------------------------------------------------------------- the event log
async function fetchLog() {
  for (let guard = 0; guard < 50; guard++) {
    const r = await conn.request("log", { since: evNext, limit: 4000 });
    if (!r.ok) return;
    if (r.last < evNext) { // time travel: the engine dropped the events after the new present
      evs = evs.filter((e) => e.seq < r.last);
      evNext = r.last;
      continue;
    }
    for (const e of r.events) evs.push(e);
    evNext = r.next;
    if (evs.length > 200000) evs = evs.slice(evs.length - 150000);
    if (r.next >= r.last) return;
  }
}

// ---------------------------------------------------------------- the timeline
const TL = { v0: 0, v1: 100, follow: true, items: [], rowH: 30, axis: 22, drag: null };
const COL = { tget: "#4de1ff", tput: "#ffb347", tgetx: "#c792ea", gift: "#7fdb8a", trap: "#ff5370", stall: "#ffb347", now: "#ffffff" };

function dataRange() {
  let hi = Math.max(pos.round || 0, 1);
  for (const e of evs.length > 5000 ? evs.slice(-5000) : evs) hi = Math.max(hi, e.round, e.to || 0);
  let lo = evs.length ? evs[0].round : 0;
  return [Math.min(lo, hi - 1), hi];
}

function fitTimeline() {
  const [lo, hi] = dataRange();
  const pad = Math.max(2, (hi - lo) * 0.03);
  TL.v0 = Math.max(0, lo - pad);
  TL.v1 = hi + pad;
}

function drawTimeline() {
  const cv = $("tl"), box = $("tlbox");
  const dpr = window.devicePixelRatio || 1;
  const W = box.clientWidth, H = TL.axis + Math.max(1, ncores) * TL.rowH + 6;
  if (cv.width !== Math.round(W * dpr) || cv.height !== Math.round(H * dpr)) {
    cv.width = Math.round(W * dpr);
    cv.height = Math.round(H * dpr);
    cv.style.height = H + "px";
  }
  const g = cv.getContext("2d");
  g.setTransform(dpr, 0, 0, dpr, 0, 0);
  g.clearRect(0, 0, W, H);
  if (TL.follow) fitTimeline(); /* (zooming or dragging turns it off) */
  const L = 64, R = W - 8, span = Math.max(1e-9, TL.v1 - TL.v0);
  const X = (r) => L + ((r - TL.v0) / span) * (R - L);
  const rowY = (c) => TL.axis + c * TL.rowH;
  // rows and axis
  g.font = "11px JetBrains Mono, monospace";
  for (let c = 0; c < ncores; c++) {
    g.fillStyle = c === cur ? "rgba(77,225,255,0.06)" : c % 2 ? "rgba(255,255,255,0.015)" : "transparent";
    g.fillRect(0, rowY(c), W, TL.rowH);
    g.fillStyle = c === cur ? "#4de1ff" : "#5b7088";
    g.fillText("core " + c, 8, rowY(c) + TL.rowH / 2 + 4);
  }
  g.strokeStyle = "rgba(31,111,139,0.5)";
  g.beginPath(); g.moveTo(L, TL.axis - 0.5); g.lineTo(R, TL.axis - 0.5); g.stroke();
  const step = niceStep(span / Math.max(1, (R - L) / 90));
  g.fillStyle = "#5b7088";
  for (let t = Math.ceil(TL.v0 / step) * step; t <= TL.v1; t += step) {
    const x = X(t);
    g.fillRect(x, TL.axis - 5, 1, 5);
    g.fillText(fmtRound(t), x + 3, 13);
    g.fillStyle = "rgba(31,111,139,0.15)"; g.fillRect(x, TL.axis, 1, H - TL.axis); g.fillStyle = "#5b7088";
  }
  g.save();
  g.beginPath(); g.rect(L, 0, R - L, H); g.clip();
  const items = [];
  const vis = (a, b) => b >= TL.v0 && a <= TL.v1;
  // pending reads: issue -> completion
  const open = new Map();
  const nowR = pos.round;
  for (const e of evs) {
    if (e.core < 0 || e.core >= ncores) continue;
    if (e.kind === "xfer" && e.pending) open.set(e.core + ":" + e.tag, e);
    else if (e.kind === "xdone") {
      const k = e.core + ":" + e.tag, s = open.get(k);
      if (s) { open.delete(k); addSpan(s, e.round); }
    }
  }
  for (const s of open.values()) addSpan(s, nowR, true);
  function addSpan(s, end, still) {
    if (!vis(s.round, end)) return;
    const x0 = X(s.round), x1 = Math.max(X(end), x0 + 2), y = rowY(s.core) + 5;
    g.fillStyle = "rgba(77,225,255,0.22)"; g.fillRect(x0, y, x1 - x0, 11);
    g.strokeStyle = "#4de1ff"; g.strokeRect(x0 + 0.5, y + 0.5, x1 - x0 - 1, 10);
    items.push({ x0, x1, y0: y, y1: y + 11, e: s, text: `core ${s.core} tg${s.tag} ${s.op} ${s.port || s.space} into D-LS ${s.ls}+${hex(s.len)}\nissued round ${s.round}, ${still ? "still in flight" : "completed round " + end}\npc ${s.pc}` });
  }
  // stalls (and the stalls in progress now)
  const stalls = evs.filter((e) => e.kind === "stall");
  if (stopEv && stopEv.cores) for (const k of stopEv.cores) if (k.stall) stalls.push({ core: k.core, from: k.stall.since, to: nowR, reason: k.stall.reason, why: k.stall.why, open: true });
  for (const s of stalls) {
    if (s.core < 0 || s.core >= ncores || !vis(s.from, s.to)) continue;
    const x0 = X(s.from), x1 = Math.max(X(s.to), x0 + 1), y = rowY(s.core) + TL.rowH - 9;
    hatch(g, x0, y, x1 - x0, 6);
    items.push({ x0, x1, y0: y - 1, y1: y + 7, text: `core ${s.core} stalled, rounds ${s.from}..${s.to}${s.open ? " (still)" : ""}: ${s.why || s.reason}` });
  }
  // instants (transfers last, so that a gift in the same round does not hide one)
  const inst = evs.filter((e) => !(e.kind === "xfer" && !e.pending)).concat(evs.filter((e) => e.kind === "xfer" && !e.pending));
  for (const e of inst) {
    if (e.core < 0 || e.core >= ncores || e.round < TL.v0 - span * 0.01 || e.round > TL.v1) continue;
    const x = X(e.round), y = rowY(e.core);
    if (e.kind === "xfer" && !e.pending) {
      g.fillStyle = COL[e.op] || "#fff";
      g.fillRect(x - 1, y + 4, 2, TL.rowH - 14);
      items.push({ e, x0: x - 3, x1: x + 3, y0: y + 3, y1: y + TL.rowH - 9, text: `core ${e.core} tg${e.tag} ${e.op} ${e.space} ${e.port ? e.port : e.far}  ${e.op === "tput" ? "from" : "into"} ${e.op === "tgetx" ? "I-LS" : "D-LS"} ${e.ls}+${hex(e.len)}\nround ${e.round} (issued and completed), pc ${e.pc}${e.cap ? ", capability #" + e.cap : ""}` });
    } else if (e.kind === "give" || e.kind === "send") {
      g.fillStyle = COL.gift;
      diamond(g, x, y + TL.rowH / 2, 5);
      if (e.to >= 0 && e.to < ncores) {
        g.strokeStyle = "rgba(127,219,138,0.7)";
        g.beginPath(); g.moveTo(x, y + TL.rowH / 2); g.lineTo(x + 3, rowY(e.to) + TL.rowH / 2); g.stroke();
      }
      items.push({ e, x0: x - 6, x1: x + 6, y0: y + 8, y1: y + TL.rowH - 8, text: `core ${e.core} ${e.kind === "give" ? "cgive" : "csend"} to node ${e.to}: ${e.space} ${e.base}+${e.len} ${e.perms}${e.cap ? " #" + e.cap : ""}${e.msgop !== undefined ? "\nStrataOS message, op " + e.msgop : ""}\nround ${e.round}` });
    } else if (e.kind === "take" || e.kind === "recv") {
      g.strokeStyle = COL.gift;
      g.beginPath(); g.arc(x, y + TL.rowH / 2, 4, 0, 7); g.stroke();
      items.push({ e, x0: x - 5, x1: x + 5, y0: y + 9, y1: y + TL.rowH - 9, text: `core ${e.core} ${e.kind === "take" ? "ctake" : "crecv"} from node ${e.from}: ${e.space} ${e.base}+${e.len} ${e.perms}${e.cap ? " #" + e.cap : ""}\nround ${e.round}` });
    } else if (e.kind === "trap") {
      g.fillStyle = COL.trap;
      g.beginPath(); g.moveTo(x, y + 3); g.lineTo(x + 5, y + 11); g.lineTo(x - 5, y + 11); g.fill();
      items.push({ e, x0: x - 6, x1: x + 6, y0: y + 2, y1: y + 12, text: `core ${e.core} trap ${e.cause}, tval ${e.tval}, at ${e.pc}${e.user ? " (user mode)" : ""}\nround ${e.round}` });
    } else if (e.kind === "halt") {
      g.fillStyle = "#fff"; g.fillRect(x - 3, y + TL.rowH / 2 - 3, 6, 6);
      items.push({ x0: x - 4, x1: x + 4, y0: y + 8, y1: y + 22, text: `core ${e.core} halted, a0 ${e.a0}${e.faulted ? " (fault)" : ""}\nround ${e.round}` });
    } else if (e.kind === "eret") {
      g.fillStyle = "#5b7088"; g.fillRect(x, y + TL.rowH - 4, 1, 4);
    } else if (e.kind === "dom" || e.kind === "revoke" || e.kind === "undom") {
      g.fillStyle = COL.trap; g.fillRect(x - 1, y + 1, 3, 3);
      items.push({ x0: x - 3, x1: x + 3, y0: y, y1: y + 6, text: `core ${e.core} ${e.kind} ${e.space} ${e.base}+${e.len}, generation ${e.gen}\nround ${e.round}` });
    }
  }
  // now
  const xn = X(nowR);
  g.fillStyle = COL.now; g.fillRect(xn, TL.axis, 1, H - TL.axis);
  g.restore();
  TL.items = items;
  TL.X = X; TL.L = L; TL.R = R;
  $("tlinfo").textContent = `${evs.length} events · rounds ${fmtRound(TL.v0)}..${fmtRound(TL.v1)}`;
}
function niceStep(x) {
  const p = Math.pow(10, Math.floor(Math.log10(Math.max(x, 1e-9))));
  for (const m of [1, 2, 5, 10]) if (m * p >= x) return Math.max(1, m * p);
  return 10 * p;
}
function fmtRound(r) {
  r = Math.round(r);
  return r >= 1e9 ? (r / 1e9).toFixed(2) + "G" : r >= 1e6 ? (r / 1e6).toFixed(2) + "M" : r >= 1e4 ? (r / 1e3).toFixed(1) + "k" : String(r);
}
function diamond(g, x, y, s) { g.beginPath(); g.moveTo(x, y - s); g.lineTo(x + s, y); g.lineTo(x, y + s); g.lineTo(x - s, y); g.fill(); }
function hatch(g, x, y, w, hh) {
  g.save();
  g.beginPath(); g.rect(x, y, w, hh); g.clip();
  g.fillStyle = "rgba(255,179,71,0.15)"; g.fillRect(x, y, w, hh);
  g.strokeStyle = COL.stall; g.lineWidth = 1.2;
  g.beginPath();
  for (let k = x - hh; k < x + w; k += 4) { g.moveTo(k, y + hh); g.lineTo(k + hh, y); }
  g.stroke();
  g.restore();
}

(function timelineInput() {
  const cv = $("tl"), tip = $("tip");
  const zoom = (f, cx) => {
    const x = cx === undefined ? (TL.L + TL.R) / 2 : cx;
    const r = TL.v0 + ((x - TL.L) / (TL.R - TL.L)) * (TL.v1 - TL.v0);
    TL.v0 = r - (r - TL.v0) * f;
    TL.v1 = r + (TL.v1 - r) * f;
    if (TL.v1 - TL.v0 < 4) { TL.v1 = r + 2; TL.v0 = r - 2; }
    setFollow(false);
    drawTimeline();
  };
  const at = (e) => { const r = cv.getBoundingClientRect(); return [e.clientX - r.left, e.clientY - r.top]; };
  const hitAt = (x, y) => { let hit = null; for (const it of TL.items) if (x >= it.x0 - 1 && x <= it.x1 + 1 && y >= it.y0 && y <= it.y1) hit = it; return hit; };
  cv.addEventListener("wheel", (e) => { e.preventDefault(); zoom(e.deltaY > 0 ? 1.25 : 0.8, at(e)[0]); }, { passive: false });
  cv.addEventListener("pointerdown", (e) => { TL.drag = { x: e.clientX, v0: TL.v0, v1: TL.v1, moved: false }; cv.setPointerCapture(e.pointerId); });
  cv.addEventListener("pointermove", (e) => {
    if (TL.drag) {
      const dx = e.clientX - TL.drag.x;
      if (Math.abs(dx) > 2) TL.drag.moved = true;
      const d = (dx / (TL.R - TL.L)) * (TL.drag.v1 - TL.drag.v0);
      TL.v0 = TL.drag.v0 - d;
      TL.v1 = TL.drag.v1 - d;
      if (TL.drag.moved) { setFollow(false); drawTimeline(); }
      return;
    }
    const [x, y] = at(e);
    const hit = hitAt(x, y);
    if (!hit || !hit.text) { tip.hidden = true; return; }
    tip.textContent = hit.text;
    tip.hidden = false;
    const bw = $("tlbox").clientWidth;
    tip.style.left = Math.min(x + 14, bw - tip.offsetWidth - 6) + "px";
    tip.style.top = (y + 16) + "px";
  });
  cv.addEventListener("pointerleave", () => { tip.hidden = true; });
  cv.addEventListener("pointerup", (e) => {
    const d = TL.drag;
    TL.drag = null;
    if (d && !d.moved && hello && hello.timetravel && !running) {
      // a click on a transfer: go to the tick it happened at
      const hit = hitAt(...at(e));
      const ev = hit && hit.e ? hit.e : null;
      if (ev) doCmd("goto", { tick: ev.tick });
    }
  });
  $("tl-fit").onclick = () => { fitTimeline(); setFollow(false); drawTimeline(); };
  $("tl-in").onclick = () => zoom(0.6);
  $("tl-out").onclick = () => zoom(1.6);
  $("tl-follow").onclick = () => { setFollow(!TL.follow); drawTimeline(); };
  addEventListener("resize", () => drawTimeline());
})();
function setFollow(on) { TL.follow = on; $("tl-follow").classList.toggle("on", on); }

// ---------------------------------------------------------------- time
function updateTime() {
  const sl = $("slider"), tt = hello && hello.timetravel && hist && hist.on;
  sl.disabled = !tt || running;
  if (tt) {
    sl.min = hist.from;
    sl.max = Math.max(hist.to, pos.tick);
    if (!sl.matches(":active")) sl.value = pos.tick;
    $("timeinfo").textContent = `ticks ${hist.from}..${hist.to} recorded · ${hist.snapshots} snapshot(s) every ${hist.every} ticks · ${(hist.bytes / 1048576).toFixed(1)} MiB`;
  } else $("timeinfo").textContent = hello && !hello.timetravel ? "no time travel in this run (it needs -T virtual, no JIT, no network)" : "the recorded run";
  $("slidepos").textContent = `tick ${sl.value}`;
}
$("slider").addEventListener("input", () => { $("slidepos").textContent = `tick ${$("slider").value}`; });
$("slider").addEventListener("change", () => doCmd("goto", { tick: +$("slider").value }));

// ---------------------------------------------------------------- the Local Store map
async function refreshLs() {
  const r = await conn.request("tags");
  const box = $("lsmap");
  let html = '<div class="lsscale"><span></span><div><span>0</span><span>16K</span><span>32K</span><span>48K</span><span>64K</span></div></div>';
  for (let c = 0; c < ncores; c++) {
    const recent = [];
    for (let i = evs.length - 1; i >= 0 && recent.length < 40; i--) {
      const e = evs[i];
      if (e.core === c && e.kind === "xfer") recent.push(e);
    }
    const busyTags = r.ok ? (r.cores.find((k) => k.core === c) || { tags: [] }).tags.filter((t) => t.busy && t.op) : [];
    const bar = (ils) => {
      let s = "";
      for (const e of recent) {
        if ((e.op === "tgetx") !== ils) continue;
        s += lsRange(e.ls, e.len, e.op, `tg${e.tag} ${e.op} ${e.port || e.space + " " + e.far} round ${e.round}`, false);
      }
      if (!ils) for (const t of busyTags) s += lsRange(t.ls, t.len, t.op, `tg${t.tag} ${t.op} ${t.port || t.space} IN FLIGHT since round ${t.issued}`, true);
      return s;
    };
    html += `<div class="lsrow"><span>core ${c}</span><div><div class="lsbar" title="D-LS">${bar(false)}</div><div class="lsbar ils" title="I-LS">${bar(true)}</div></div></div>`;
  }
  box.innerHTML = html;
}
function lsRange(ls, len, op, title, busy) {
  const a = Number(hex(ls)), n = Math.max(Number(hex(len)), 1);
  const cls = op === "tput" ? "put" : op === "tgetx" ? "getx" : "get";
  return `<i class="${cls}${busy ? " busy" : ""}" style="left:${(a / 65536) * 100}%;width:${(n / 65536) * 100}%" title="${esc(title)} · ${h(ls)}+${n}"></i>`;
}

// ---------------------------------------------------------------- provenance
async function refreshProv() {
  const r = await conn.request("provgraph", provAll ? {} : { core: cur });
  const box = $("prov");
  if (!r.ok) { box.textContent = r.error; return; }
  const nodes = new Map();
  for (const n of r.nodes) nodes.set(n.id, Object.assign({ kids: [], who: [] }, n));
  for (const k of r.held) {
    const n = nodes.get(k.id);
    if (n) { n.who.push(`core ${k.core} ${k.reg !== undefined ? "c" + k.reg : "slot " + k.slot}`); n.live = k.live; n.held = true; }
  }
  const roots = [];
  for (const n of nodes.values()) {
    const p = nodes.get(n.parent);
    if (p) p.kids.push(n); else roots.push(n);
  }
  let row = 0, maxD = 0;
  const place = (n, d) => {
    n.d = d;
    maxD = Math.max(maxD, d);
    if (!n.kids.length) n.row = row++;
    else {
      n.kids.sort((a, b) => a.id - b.id);
      for (const k of n.kids) place(k, d + 1);
      n.row = (n.kids[0].row + n.kids[n.kids.length - 1].row) / 2;
    }
  };
  roots.sort((a, b) => a.id - b.id);
  for (const n of roots) place(n, 0);
  const BW = 176, BH = 40, GX = 34, GY = 8;
  const W = (maxD + 1) * (BW + GX) + 10, H = row * (BH + GY) + 10;
  const px = (n) => 6 + n.d * (BW + GX), py = (n) => 6 + n.row * (BH + GY);
  let svg = `<svg width="${W}" height="${H}" viewBox="0 0 ${W} ${H}">`;
  for (const n of nodes.values()) {
    for (const pid of [n.parent, n.parent2]) {
      const p = nodes.get(pid);
      if (!p) continue;
      const x0 = px(p) + BW, y0 = py(p) + BH / 2, x1 = px(n), y1 = py(n) + BH / 2;
      svg += `<path class="edge${n.op === "give" ? " give" : ""}" d="M${x0} ${y0} C${x0 + GX / 2} ${y0} ${x1 - GX / 2} ${y1} ${x1} ${y1}"/>`;
    }
  }
  for (const n of nodes.values()) {
    const x = px(n), y = py(n);
    const range = `${n.space} ${h(n.base)}+${h(n.len)} ${n.perms}`;
    const opText = n.op === "give" ? `give from ${n.from}` : n.op;
    svg += `<g class="node${n.held ? " held" : ""}${n.held && n.live === false ? " dead" : ""}" data-id="${n.id}"><title>#${n.id} ${esc(opText)} by core ${n.core}, round ${n.round}\n${esc(range)}${n.who.length ? "\nheld: " + esc(n.who.join(", ")) : ""}</title>` +
      `<rect x="${x}" y="${y}" width="${BW}" height="${BH}"/>` +
      `<text x="${x + 6}" y="${y + 15}"><tspan class="op">#${n.id} ${esc(opText)}</tspan>${n.who.length ? ` <tspan class="who">${esc(n.who[0])}${n.who.length > 1 ? " …" : ""}</tspan>` : ""}</text>` +
      `<text x="${x + 6}" y="${y + 31}">${esc(range.length > 26 ? range.slice(0, 25) + "…" : range)}</text></g>`;
  }
  svg += "</svg>";
  box.innerHTML = nodes.size ? svg : '<p class="sub" style="padding:0 10px">no capabilities</p>';
  $("provinfo").textContent = `${nodes.size} capabilities, ${r.held.length} held ${provAll ? "by all cores" : "by core " + cur}`;
}
$("prov").addEventListener("click", (e) => {
  const g = e.target.closest(".node");
  if (g) showChain({ id: +g.dataset.id }, "#" + g.dataset.id);
});
$("prov-cur").onclick = () => { provAll = false; $("prov-cur").classList.add("on"); $("prov-all").classList.remove("on"); refreshProv(); };
$("prov-all").onclick = () => { provAll = true; $("prov-all").classList.add("on"); $("prov-cur").classList.remove("on"); refreshProv(); };

async function showChain(args, what) {
  const r = await conn.request("prov", args);
  const box = $("chain");
  if (!r.ok) { box.textContent = r.error; return; }
  box.innerHTML = `<div class="sub">${esc(what)}: newest first</div>` + r.chain.map((p, i) =>
    `<div>${"  ".repeat(i)}#${p.id} <span class="op">${esc(p.op)}${p.from !== undefined ? " from node " + p.from : ""}</span> ${esc(p.space)} ${h(p.base)}+${h(p.len)} ${esc(p.perms)} · core ${p.core} round ${p.round}${p.sym ? " · " + esc(p.sym) : ""}${p.file ? " (" + esc(base(p.file)) + ":" + p.line + ")" : ""}</div>`).join("");
}

// ---------------------------------------------------------------- breakpoints
async function refreshBps() {
  const r = await conn.request("breakpoints");
  const ul = $("bplist");
  ul.innerHTML = "";
  if (!r.ok) return;
  for (const b of r.bps) {
    const li = document.createElement("li");
    li.className = b.on ? "" : "off";
    li.innerHTML = `<span>${b.id}</span><span class="d">${esc(b.desc)} · ${b.hits} hit(s)</span>` +
      `<button data-t="${b.on ? "disable" : "enable"}" data-id="${b.id}">${b.on ? "off" : "on"}</button><button data-t="delete" data-id="${b.id}">×</button>`;
    ul.appendChild(li);
  }
  const sel = $("bpcore"), keep = sel.value;
  sel.innerHTML = '<option value="">any core</option>' + Array.from({ length: ncores }, (_, i) => `<option value="${i}">core ${i}</option>`).join("");
  sel.value = keep;
}
$("bplist").addEventListener("click", async (e) => {
  const b = e.target.closest("button[data-t]");
  if (!b) return;
  await conn.request(b.dataset.t, { bp: +b.dataset.id });
  await refreshBps();
  await refreshCores();
});
$("bpform").addEventListener("submit", async (e) => {
  e.preventDefault();
  const loc = $("bploc").value.trim();
  if (!loc || !conn) return;
  const a = { loc };
  if ($("bpcore").value !== "") a.core = +$("bpcore").value;
  const r = await conn.request("break", a);
  if (!r.ok) setStatus("break: " + r.error, true); else $("bploc").value = "";
  await refreshBps();
  await refreshCores();
});
$("wform").addEventListener("submit", async (e) => {
  e.preventDefault();
  const loc = $("wloc").value.trim(), mem = $("wmem").value;
  if (!loc || !conn) return;
  const a = { access: $("wacc").value, len: $("wlen").value.trim().replace(/^len\s*/, "") || "8" };
  if (mem === "dls" || mem === "ils") { a.kind = "ls"; a.mem = mem; } else { a.kind = "far"; a.space = mem; }
  if (/^(0x)?[0-9a-f]+$/i.test(loc)) a.addr = loc; else a.loc = loc;
  const r = await conn.request("watch", a);
  if (!r.ok) setStatus("watch: " + r.error, true); else $("wloc").value = "";
  await refreshBps();
});
$("bkadd").onclick = async () => {
  if (!conn) return;
  const k = $("bkind").value;
  const r = await conn.request("break", { kind: k });
  if (!r.ok) setStatus("break: " + r.error, true);
  await refreshBps();
};

// ---------------------------------------------------------------- console input
$("conform").addEventListener("submit", async (e) => {
  e.preventDefault();
  if (!conn) return;
  const r = await conn.request("input", { data: $("conin").value + "\n" });
  if (!r.ok) setStatus("input: " + r.error, true);
  $("conin").value = "";
});

// ---------------------------------------------------------------- buttons and keys
for (const b of document.querySelectorAll("[data-do]")) b.addEventListener("click", () => doCmd(b.dataset.do));
addEventListener("keydown", (e) => {
  if (e.target.closest("input, select, textarea") || e.metaKey || e.ctrlKey || e.altKey) return;
  const k = e.key;
  const map = { c: "continue", s: "stepi", n: "next", f: "finish", r: "step-round", S: "reverse-stepi", R: "reverse-step-round", C: "reverse-continue", Escape: "pause" };
  if (map[k]) { e.preventDefault(); doCmd(map[k]); }
  else if (k === "[" || k === "]") { cur = (cur + (k === "]" ? 1 : ncores - 1)) % Math.max(1, ncores); markCur(); refreshProv(); drawTimeline(); }
});

// ---------------------------------------------------------------- starting
async function fetchBytes(url) {
  const r = await fetch(url);
  if (!r.ok) throw new Error("cannot fetch " + url);
  return r.arrayBuffer();
}

async function loadExample(name, cores) {
  if (conn) conn.close();
  conn = null;
  reset();
  setStatus(`loading ${name}…`);
  const map = await (await fetch(ASSETS + name + ".map" + V)).text();
  const files = [{ path: "/" + name + ".stx", data: await fetchBytes(ASSETS + name + ".stx" + V) },
    { path: "/" + name + ".map", data: new TextEncoder().encode(map).buffer }];
  for (const m of map.matchAll(/^file \d+ (.*)$/gm)) {
    try { files.push({ path: "/" + m[1], data: await fetchBytes(ASSETS + "src/" + m[1] + V) }); } catch (e) { /* no source: addresses only */ }
  }
  const c = new WorkerConn();
  c.onEvent = onEvent;
  await c.start(files, "/" + name + ".stx", ["-c", String(cores), "-j", "-T", "virtual", "-g", "none"]);
  conn = c;
  $("mode").textContent = "in this page (WebAssembly)";
  await connected();
}

async function connectWs(url) {
  reset();
  setStatus("connecting to " + url + "…");
  const c = new WsConn();
  c.onEvent = onEvent;
  await c.open(url);
  conn = c;
  $("source").querySelectorAll("label, #load").forEach((el) => (el.hidden = true));
  await connected();
  // (the engine runs the image it was started with: name it where the picker was)
  const img = (hello.image || "").split("/").pop();
  $("mode").textContent = (img ? img + " · " : "") + "the engine at " + url.replace(/^ws:\/\//, "").replace(/\/$/, "");
}

function reset() {
  hello = null; ncores = 0; cur = 0; running = false; done = false; stopEv = null;
  evs = []; evNext = 0; hist = null; prevX = []; lastX = [];
  $("con").textContent = ""; $("chain").textContent = ""; $("prov").textContent = "";
  clearInterval(poller); poller = 0;
  setFollow(true);
}

async function connected() {
  hello = await conn.request("hello");
  ncores = hello.ncores;
  const cs = await conn.request("cores");
  stopEv = { ev: hello.state === "done" ? "done" : "stopped", reason: hello.state === "running" ? "running" : "at the start", tick: cs.tick, round: cs.round, cores: cs.cores };
  running = hello.state === "running";
  const con = await conn.request("console");
  if (con.ok && con.data) conPut(con.data);
  if (running) { setStatus("running…"); poller = setInterval(poll, 250); } else showStop();
  updateButtons();
  await refreshAll();
  await runScript(Q.get("do"));
}

// ?do=break:c_loop,continue,stepi:3,...: the page drives itself (demos, screenshots)
async function runScript(s) {
  if (!s) return;
  for (const step of s.split(",")) {
    const [c, ...rest] = step.split(":");
    const a = rest.join(":");
    const waitStop = async () => { for (let i = 0; i < 600 && (running || busy); i++) await new Promise((r) => setTimeout(r, 50)); await new Promise((r) => setTimeout(r, 60)); while (refreshing) await new Promise((r) => setTimeout(r, 30)); };
    if (c === "break") await conn.request("break", { loc: a });
    else if (c === "watch") { const [l, n] = a.split(":"); await conn.request("watch", { kind: "ls", loc: l, len: n || "8" }); }
    else if (c === "core") cur = +a;
    else if (c === "wait") await new Promise((r) => setTimeout(r, +a || 500));
    else if (c === "delete") await conn.request("delete", {});
    else {
      const cmd = { continue: "continue", stepi: "stepi", next: "next", finish: "finish", round: "step-round", rstepi: "reverse-stepi", rcontinue: "reverse-continue", rround: "reverse-step-round", goto: "goto" }[c];
      if (!cmd) continue;
      const args = c === "goto" ? { tick: +a } : a ? { n: +a } : {};
      await doCmd(cmd, args);
    }
    await waitStop();
  }
  await refreshAll();
}

async function main() {
  updateButtons();
  const ws = Q.get("ws");
  if (ws) { try { await connectWs(ws.startsWith("ws") ? ws : "ws://" + ws + "/"); } catch (e) { setStatus(e.message, true); } return; }
  try {
    const ctl = new AbortController();
    setTimeout(() => ctl.abort(), 1500);
    const r = await fetch("/dbg-info", { signal: ctl.signal });
    const j = r.ok ? await r.json() : null;
    if (j && j.engine) { await connectWs("ws://" + location.host + "/"); return; }
  } catch (e) { /* not served by an engine: the in-page one */ }
  let names = ["hello", "pipeline", "stream_sum", "parsum", "overlay", "swcache", "race"];
  try {
    const t = await (await fetch(ASSETS + "index.txt" + V)).text();
    const l = t.split("\n").map((s) => s.trim()).filter(Boolean);
    if (l.length) names = l;
  } catch (e) { /* the default list */ }
  const sel = $("ex");
  sel.innerHTML = names.map((n) => `<option>${esc(n)}</option>`).join("");
  sel.value = Q.get("ex") || "pipeline";
  if (Q.get("cores")) $("ncores").value = Q.get("cores");
  $("load").onclick = () => loadExample(sel.value, +$("ncores").value).catch((e) => setStatus(e.message, true));
  $("mode").textContent = "runs in this page";
  $("load").click();
}
main();
