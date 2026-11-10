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
        o += m[1] + sp(cat ? "k-" + cat : "d", m[2]);
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
        if (F_DEF.has(w)) { o += sp("f-def", t); if (w === ":") want = "name"; continue; }
        if (t === "{") { o += sp("f-loc", t); want = "locals"; continue; }
        if (F_DW.has(w)) {
          o += sp("f-dw", t);
          if (F_NAMED.has(w)) want = "name";
          else if (w === "[char]" || w === "char") want = "char";
          continue;
        }
        if (F_CTL.has(w)) o += sp("f-ctl", t);
        else if (F_ST.has(w)) o += sp("f-st", t);
        else if (RE_FNUM.test(t)) o += sp("n", t);
        else o += esc(t);
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

  window.StrataHL = { init, asmLines, forthLines, sessionLines, highlightAll, colour };
  if (window.STRATA_SYNTAX) init(window.STRATA_SYNTAX);
  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", () => highlightAll());
  else highlightAll();
})();
