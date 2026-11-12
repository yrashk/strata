// Strata syntax highlighting, shared by every page of the site: the source
// browser (code/), the landing page and the instruction-set and architecture
// pages. Two line-at-a-time scanners, one for Strata assembly and one for
// Forth (which keeps one bit of state across lines: an open paren comment).
//
// The keyword tables are the real assembler's (asm/sasm.c) and Strata
// Forth's, extracted by tools/web-code.py. A page gets them either from
// code/syntax.js (window.STRATA_SYNTAX, loaded before this file) or, like the
// source browser, from its manifest via StrataHL.init(). Without them the
// scanners still colour comments, labels, numbers, strings and c/tg registers.
//
// On load, every <pre><code class="language-strata-asm"> and
// <pre><code class="language-forth"> is coloured. A Forth block with
// data-session is a transcript: a trailing "ok" is the prompt, and indented
// "addr:  insn" lines (the output of see) are coloured as assembly.
//
// Hovering an instruction's mnemonic or a Forth word shows what it is in one
// line, with ↗ to its entry in the instruction or Forth pages (a new tab).
// The scanners mark them (data-mn, data-fw); the text comes from
// isa/insns.json and forth/words.json, written with those pages
// (doc/manual/gen/genweb.py, genforth.py), or from the published site when
// this one has no generated pages (site/ served by the debug engine).
"use strict";
(function () {
  const esc = (s) => s.replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c]);
  const sp = (cls, s) => `<span class="${cls}">${esc(s)}</span>`;

  // -------------------------------------------------------------- Strata assembly
  let MN = new Map(), DIRS = new Set(), CSRS = new Set(), XREGS = new Set(), F_ST = new Set();
  function init(syn) {
    if (!syn) return;
    const k = syn.asm;
    MN = new Map();
    for (const [cat, list] of Object.entries(k.mnemonics)) for (const m of list) MN.set(m, cat);
    DIRS = new Set(k.directives);
    CSRS = new Set(k.csrs);
    XREGS = new Set(k.xregs);
    F_ST = new Set(syn.forth.strata);
  }

  const RE_LABEL = /^(\s*)([A-Za-z_.$][\w.$]*):/;
  const RE_CONST = /^(\s*)([A-Za-z_.$][\w.$]*)(\s*)=(?!=)/;
  const RE_WORD = /^(\s*)([A-Za-z_.][\w.]*)/;
  const RE_OPS = /(;|#|\/\/)|"(?:[^"\\]|\\.)*"?|'(?:\\.|[^'\\])'?|\b(?:0[xX][0-9a-fA-F_]+|0[bB][01_]+|\d+)\b|[A-Za-z_.$][\w.$]*/g;
  const RE_CREG = /^(?:c(?:1[0-5]|[0-9])|tg(?:1[0-5]|[0-9]))$/;
  const RE_CAPS = /^[A-Z][A-Z0-9_]*[A-Z0-9]$/;
  const RE_RULE = /^\s*(?:[;#/\\]+\s*)?(?:-{3,}|={3,})/;

  function asmComment(s) { return `<span class="${RE_RULE.test(s) ? "c h" : "c"}">${esc(s)}</span>`; }

  function asmLine(s) {
    let o = "", p = 0, m, mn = null, rest = s;
    while ((m = RE_LABEL.exec(rest))) {
      o += m[1] + sp("lb", m[2]) + ":";
      p += m[0].length; rest = s.slice(p);
    }
    if ((m = RE_CONST.exec(rest))) {
      o += m[1] + sp("kd", m[2]) + m[3] + "=";
      p += m[0].length;
    } else if ((m = RE_WORD.exec(rest))) {
      const w = m[2].toLowerCase();
      const cat = MN.get(w);
      if (cat || w[0] === ".") {
        mn = w;
        o += m[1] + (cat ? `<span class="k-${cat}" data-mn="${esc(w)}">${esc(m[2])}</span>` : sp("d", m[2]));
        p += m[0].length;
      }
    }
    return o + asmOps(s, p, mn === "csrr" || mn === "csrw");
  }

  function asmOps(s, p, csr) {
    let o = "", last = p, m;
    RE_OPS.lastIndex = p;
    while ((m = RE_OPS.exec(s))) {
      o += esc(s.slice(last, m.index));
      const t = m[0], c = t[0];
      if (m[1]) { o += asmComment(s.slice(m.index)); return o; }
      if (c === '"' || c === "'") o += sp("s", t);
      else if (c >= "0" && c <= "9") o += sp("n", t);
      else if (XREGS.has(t)) o += sp("r", t);
      else if (RE_CREG.test(t)) o += sp("cr", t);
      else if (csr && CSRS.has(t)) o += sp("csr", t);
      else if (RE_CAPS.test(t)) o += sp("kc", t);
      else o += esc(t);
      last = RE_OPS.lastIndex;
    }
    return o + esc(s.slice(last));
  }

  function asmLines(lines) {
    return lines.map((s) => {
      const t = s.trimStart();
      if (t[0] === ";" || t[0] === "#" || t.startsWith("//"))
        return esc(s.slice(0, s.length - t.length)) + asmComment(t);
      return asmLine(s);
    });
  }

  // -------------------------------------------------------------- Forth
  const F_CTL = new Set(("if else then endif do ?do loop +loop leave unloop i j begin until while repeat again " +
    "case of endof endcase exit recurse ahead [if] [else] [then] [defined] [undefined] catch throw abort " +
    "execute ?dup").split(" "));
  const F_DW = new Set(("variable constant create value defer 2variable 2constant buffer: field: +field " +
    "does> immediate is to postpone literal ['] ' [char] char compile, action-of [ ] marker").split(" "));
  const F_NAMED = new Set("variable constant create value defer 2variable 2constant buffer: field: +field marker is to".split(" "));
  const F_DEF = new Set(": :noname ; [: ;]".split(" "));
  const RE_FNUM = /^-?(?:\$-?[0-9a-f]+|#-?\d+|%-?[01]+|\d+\.?|'.')$/i;
  const fw = (cls, t) => `<span class="${cls}" data-fw="${esc(t.toLowerCase())}">${esc(t)}</span>`;

  function forthLines(lines) {
    let inParen = false;
    return lines.map((s) => {
      let o = "", p = 0;
      if (inParen) {
        const e = s.indexOf(")");
        if (e < 0) return sp("c", s);
        o = sp("c", s.slice(0, e + 1)); p = e + 1; inParen = false;
      }
      let want = null;            // "name": the next word is defined; "char"; "locals"
      const re = /\S+/g;
      re.lastIndex = p;
      let m, last = p;
      while ((m = re.exec(s))) {
        o += esc(s.slice(last, m.index));
        const t = m[0], w = t.toLowerCase(), end = m.index + t.length;
        last = end;
        if (want === "locals") {
          o += sp("f-loc", t);
          if (t === "}") want = null;
          continue;
        }
        if (want === "name") { o += sp("f-name", t); want = null; continue; }
        if (want === "char") { o += sp("s", t); want = null; continue; }
        if (t === "\\") { o += sp("c", s.slice(m.index)); last = s.length; break; }
        if (t === "(") {
          const e = s.indexOf(")", end);
          if (e < 0) { o += sp("c", s.slice(m.index)); inParen = true; last = s.length; break; }
          o += sp("c", s.slice(m.index, e + 1)); last = re.lastIndex = e + 1;
          continue;
        }
        if ((t.length > 1 && t.endsWith('"')) || w === ".(") {
          const e = s.indexOf(w === ".(" ? ")" : '"', end + 1);
          const stop = e < 0 ? s.length : e + 1;
          o += sp("s", s.slice(m.index, stop)); last = re.lastIndex = stop;
          continue;
        }
        if (F_DEF.has(w)) { o += fw("f-def", t); if (w === ":") want = "name"; continue; }
        if (t === "{") { o += sp("f-loc", t); want = "locals"; continue; }
        if (F_DW.has(w)) {
          o += fw("f-dw", t);
          if (F_NAMED.has(w)) want = "name";
          else if (w === "[char]" || w === "char") want = "char";
          continue;
        }
        if (F_CTL.has(w)) o += fw("f-ctl", t);
        else if (F_ST.has(w)) o += fw("f-st", t);
        else if (RE_FNUM.test(t)) o += sp("n", t);
        else o += fw("f-w", t);
      }
      return o + esc(s.slice(last));
    });
  }

  // A Forth transcript: input lines answered by "ok", and see's disassembly.
  const RE_DIS = /^(\s+)([0-9a-f]+:)(.*)$/;
  const RE_OK = /^(.*?)(\s+)(ok)(\s*)$/;
  function sessionLines(lines) {
    return lines.map((s) => {
      let m = RE_DIS.exec(s);
      if (m) return m[1] + sp("addr", m[2]) + asmLines([m[3]])[0];
      m = RE_OK.exec(s);
      if (m) return forthLines([m[1]])[0] + m[2] + sp("ok", m[3]) + m[4];
      return forthLines([s])[0];
    });
  }

  // -------------------------------------------------------------- the page
  function colour(el) {
    if (el.dataset.hl === "done") return;
    const text = el.textContent.replace(/\n$/, "");
    const lines = text.split("\n");
    const forth = el.classList.contains("language-forth");
    const out = forth ? ("session" in el.dataset ? sessionLines(lines) : forthLines(lines)) : asmLines(lines);
    el.innerHTML = out.join("\n");
    el.dataset.hl = "done";
    el.classList.add("hl");
  }
  function highlightAll(root) {
    for (const el of (root || document).querySelectorAll("code.language-strata-asm, code.language-forth")) colour(el);
  }

  // -------------------------------------------------------------- hover help
  const ROOT = document.currentScript ? new URL(".", document.currentScript.src).href : "";
  const PUBLISHED = "https://yrashk.com/strata/";
  const docs = { mn: null, fw: null };
  const loading = {};
  function load(kind) {   // the table and the site root its links are relative to
    if (!loading[kind]) {
      const file = kind === "mn" ? "isa/insns.json" : "forth/words.json";
      loading[kind] = (async () => {
        for (const base of [ROOT, PUBLISHED]) {
          try {
            const r = await fetch(base + file);
            if (r.ok) { docs[kind] = { base, t: await r.json() }; return; }
          } catch (e) { /* the next one */ }
        }
        docs[kind] = { base: "", t: {} };
      })();
    }
    return loading[kind];
  }
  let tip = null, hideT = 0;
  function tipEl() {
    if (tip) return tip;
    tip = document.createElement("div");
    tip.className = "hl-tip";
    tip.hidden = true;
    tip.addEventListener("mouseenter", () => clearTimeout(hideT));
    tip.addEventListener("mouseleave", later);
    document.body.appendChild(tip);
    return tip;
  }
  function later() { clearTimeout(hideT); hideT = setTimeout(() => { if (tip) tip.hidden = true; }, 350); }
  async function show(el) {
    const kind = el.dataset.mn !== undefined ? "mn" : "fw", key = el.dataset[kind];
    await load(kind);
    const d = docs[kind], e = d.t[key];
    if (!e) return;
    el.classList.add("hl-doc");
    const url = new URL(e.u, d.base);
    const here = url.origin === location.origin && url.pathname === location.pathname;
    const t = tipEl();
    clearTimeout(hideT);
    t.innerHTML = `<code>${esc(el.textContent)}</code>` + (e.e ? ` <span class="hl-tip-e">${esc(e.e)}</span>` : "") +
      (e.t ? ` ${esc(e.t)}` : "") +
      ` <a href="${esc(here ? url.hash : url.href)}"${here ? "" : ' target="_blank" rel="noopener"'} title="Its entry in the documentation${here ? "" : " (a new tab)"}">↗</a>`;
    t.hidden = false;
    const r = el.getBoundingClientRect();
    t.style.left = Math.max(4, Math.min(r.left, innerWidth - t.offsetWidth - 8)) + "px";
    t.style.top = (r.bottom + t.offsetHeight + 6 > innerHeight ? r.top - t.offsetHeight - 2 : r.bottom + 2) + "px";
  }
  document.addEventListener("mouseover", (ev) => {
    const el = ev.target.closest && ev.target.closest(".hl [data-mn], .hl [data-fw]");
    if (el) show(el);
  });
  document.addEventListener("mouseout", (ev) => {
    if (ev.target.closest && ev.target.closest(".hl [data-mn], .hl [data-fw]")) later();
  });
  addEventListener("scroll", () => { if (tip) tip.hidden = true; }, { passive: true, capture: true });

  window.StrataHL = { init, asmLines, forthLines, sessionLines, highlightAll, colour };
  if (window.STRATA_SYNTAX) init(window.STRATA_SYNTAX);
  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", () => highlightAll());
  else highlightAll();
})();
