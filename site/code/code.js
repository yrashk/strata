// The source browser. manifest.json (written by tools/web-code.py) lists
// every Strata assembly and Forth file, grouped by area, with the keyword
// lists of the real assembler (asm/sasm.c) and of Strata Forth; the files
// themselves are under src/<path>. The highlighters are the site's shared
// line-at-a-time scanners (../hl.js), so a 6000-line file colours in a few
// milliseconds.
//
// URLs: #path/to/file.s, #path/to/file.s:42, #path/to/file.s:42-50.
"use strict";
if ("scrollRestoration" in history) history.scrollRestoration = "manual";

const $ = (id) => document.getElementById(id);
const REPO = "https://github.com/yrashk/strata";
let M = null;               // the manifest
let order = [];             // every file, in tree order
const byPath = new Map();
const texts = new Map();    // path -> Promise<string>
let cur = null;             // the file shown
let sel = null;             // [from, to] highlighted lines

const esc = (s) => s.replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c]);

// ---------------------------------------------------------------- highlighting
// The scanners are shared with the rest of the site: ../hl.js (StrataHL).
const { asmLines, forthLines } = window.StrataHL;

// ---------------------------------------------------------------- the tree
function buildTree() {
  const tree = $("tree");
  let html = "";
  for (const g of M.groups) {
    html += `<details class="src-group" open><summary><span>${esc(g.name)}</span><em>${g.files.length}</em></summary>`;
    let dir = null;
    const dirs = new Set(g.files.map((f) => f.path.replace(/[^/]*$/, "")));
    for (const f of g.files) {
      const d = f.path.replace(/[^/]*$/, "");
      if (dirs.size > 1 && d !== dir) { html += `<div class="src-dir">${esc(d)}</div>`; dir = d; }
      const name = dirs.size > 1 ? f.path.slice(d.length) : f.path;
      html += `<a class="src-file" href="#${esc(f.path)}" data-path="${esc(f.path)}" title="${esc(f.title || f.path)}">` +
              `<span>${esc(name)}</span><em>${f.lines}</em></a>`;
    }
    html += `</details>`;
  }
  html += `<p class="src-none" hidden>No file matches.</p>`;
  tree.innerHTML = html;
}

function visibleFiles() {
  return [...document.querySelectorAll(".src-file")].filter((a) => !a.hidden && a.closest("details").open);
}

function applyFilter() {
  const q = $("filter").value.trim().toLowerCase().split(/\s+/).filter(Boolean);
  let any = false;
  for (const det of document.querySelectorAll(".src-group")) {
    let n = 0, dirEl = null, dirN = 0;
    for (const el of det.children) {
      if (el.classList.contains("src-dir")) {
        if (dirEl) dirEl.hidden = !dirN;
        dirEl = el; dirN = 0;
      } else if (el.classList.contains("src-file")) {
        const f = byPath.get(el.dataset.path);
        const hay = (f.path + " " + f.title + " " + f.desc).toLowerCase();
        const ok = q.every((w) => hay.includes(w));
        el.hidden = !ok;
        if (ok) { n++; dirN++; }
      }
    }
    if (dirEl) dirEl.hidden = !dirN;
    det.hidden = !n;
    if (q.length && n) det.open = true;
    any = any || n > 0;
  }
  document.querySelector(".src-none").hidden = any;
}

// ---------------------------------------------------------------- views
function inline(s) {
  return esc(s).replace(/`([^`]+)`/g, "<code>$1</code>").replace(/\*([^*\s][^*]*)\*/g, "<em>$1</em>");
}
const cap = (s) => (s ? s[0].toUpperCase() + s.slice(1) : s);
const kib = (n) => (n < 1024 ? `${n} bytes` : `${(n / 1024).toFixed(1)} KiB`);

function overview() {
  cur = null; sel = null;
  document.title = "Strata source";
  markActive();
  $("crumb").textContent = "Source";
  $("title").textContent = "Every program, in Strata assembly and Forth";
  $("meta").innerHTML = `<span>${M.files} files</span><span>${M.lines.toLocaleString("en")} lines</span><span>straight from the repository</span>`;
  $("desc").innerHTML = "The examples, the StrataOS kernel and its servers, the assembler written in its own " +
    "assembly, the firmware, Strata Forth and the conformance suite — coloured with the real assembler's " +
    "instruction and register tables. Pick a file; click a line number to link to it.";
  $("actions").innerHTML = `<a class="btn" href="../play/">Run Strata in your browser</a>` +
    `<a class="btn ghost" href="${REPO}">Repository on GitHub</a>`;
  let h = `<div class="src-groups">`;
  for (const g of M.groups) {
    const lines = g.files.reduce((a, f) => a + f.lines, 0);
    const names = g.files.slice(0, 6).map((f) => f.path.split("/").pop()).join(" · ") + (g.files.length > 6 ? " …" : "");
    h += `<a href="#${esc(g.files[0].path)}"><article class="card"><h3>${esc(g.name)}</h3><p>${esc(names)}</p>` +
         `<em>${g.files.length} file${g.files.length > 1 ? "s" : ""} · ${lines.toLocaleString("en")} lines</em></article></a>`;
  }
  $("body").innerHTML = h + `</div>`;
}

function fetchText(path) {
  if (!texts.has(path))
    texts.set(path, fetch("src/" + encodeURI(path)).then((r) => {
      if (!r.ok) throw new Error(`${path}: ${r.status}`);
      return r.text();
    }));
  return texts.get(path);
}

function header(f) {
  const parts = f.path.split("/");
  document.title = `${parts[parts.length - 1]} · Strata source`;
  $("crumb").innerHTML = `<a href="#">Source</a> / ` + parts.map(esc).join(" / ");
  $("title").textContent = parts[parts.length - 1];
  $("meta").innerHTML = `<span>${f.lines.toLocaleString("en")} lines</span><span>${kib(f.bytes)}</span>` +
    `<span>${f.lang === "forth" ? "Forth" : "Strata assembly"}</span><span>${esc(groupOf(f))}</span>`;
  $("desc").innerHTML = (f.title ? `<b>${inline(cap(f.title))}.</b> ` : "") + inline(f.desc || "");
  let a = `<a class="btn ghost" id="gh" href="${ghLink(f)}">View on GitHub</a>`;
  if (f.run) a = `<a class="btn" href="../play/${f.run}">Run in browser</a>` + a;
  a += `<a class="btn ghost" href="src/${encodeURI(f.path)}">Raw</a>`;
  $("actions").innerHTML = a;
}
const groupOf = (f) => M.groups.find((g) => g.files.includes(f)).name;
const ghLink = (f) => `${REPO}/blob/${M.branch}/${encodeURI(f.path)}` +
  (sel ? `#L${sel[0]}` + (sel[1] > sel[0] ? `-L${sel[1]}` : "") : "");

async function show(f, range, scroll) {
  if (cur !== f) {
    cur = f; sel = null;
    header(f);
    markActive();
    $("body").innerHTML = `<div class="src-loading">loading ${esc(f.path)}…</div>`;
    let text;
    try { text = await fetchText(f.path); }
    catch (e) { $("body").innerHTML = `<div class="src-loading">could not load ${esc(f.path)}: ${esc(e.message)}</div>`; return; }
    if (cur !== f) return;
    const t0 = performance.now();
    const lines = text.split("\n");
    if (lines.length > 1 && lines[lines.length - 1] === "") lines.pop();
    const html = f.lang === "forth" ? forthLines(lines) : asmLines(lines);
    const out = new Array(html.length);
    for (let i = 0; i < html.length; i++) out[i] = `<div class="L"><i>${i + 1}</i><b>${html[i] || " "}</b></div>`;
    $("body").innerHTML = `<div class="src-code hl"><div class="src-lines" id="lines">${out.join("")}</div></div>`;
    document.body.dataset.renderMs = (performance.now() - t0).toFixed(1);
    if (!range) window.scrollTo({ top: 0, behavior: "instant" });
  }
  highlight(range, scroll);
}

function highlight(range, scroll) {
  const box = $("lines");
  if (!box) return;
  if (sel) for (let i = sel[0]; i <= sel[1]; i++) box.children[i - 1]?.classList.remove("hl");
  sel = null;
  if (range) {
    const n = box.children.length;
    const a = Math.min(Math.max(range[0], 1), n), b = Math.min(Math.max(range[1], a), n);
    sel = [a, b];
    for (let i = a; i <= b; i++) box.children[i - 1].classList.add("hl");
    if (scroll) {
      const el = box.children[a - 1];
      const y = el.getBoundingClientRect().top + window.scrollY - Math.max(80, innerHeight / 3);
      window.scrollTo({ top: y, behavior: "instant" });
    }
  }
  const gh = $("gh");
  if (gh && cur) gh.href = ghLink(cur);
}

function markActive() {
  for (const a of document.querySelectorAll(".src-file.on")) a.classList.remove("on");
  if (!cur) return;
  const a = document.querySelector(`.src-file[data-path="${CSS.escape(cur.path)}"]`);
  if (a) {
    a.classList.add("on");
    a.closest("details").open = true;
    const tree = $("tree"), top = a.offsetTop - tree.offsetTop;   // not scrollIntoView: that scrolls the page too
    if (top < tree.scrollTop || top > tree.scrollTop + tree.clientHeight - 30) tree.scrollTop = top - tree.clientHeight / 3;
  }
}

// ---------------------------------------------------------------- routing
let quietHash = false;       // a hash change made by a line-number click
function route(first) {
  const h = decodeURIComponent(location.hash.slice(1));
  const m = /^(.*?)(?::(\d+)(?:-(\d+))?)?$/.exec(h);
  const f = m && byPath.get(m[1]);
  if (!f) { overview(); return; }
  const range = m[2] ? [+m[2], +(m[3] || m[2])] : null;
  const shown = show(f, range, !quietHash);
  quietHash = false;
  // a deep link opened cold: the page can still grow (web fonts) and the
  // browser restore its scroll position at "load"; scroll again after it
  if (first === true && range)
    shown.then(() => {
      if (document.readyState !== "complete") addEventListener("load", () => highlight(sel, true), { once: true });
    });
  closeDrawer();
}

$("body").addEventListener("click", (e) => {
  const i = e.target.closest(".L > i");
  if (!i || !cur) return;
  const n = +i.textContent;
  let a = n, b = n;
  if (e.shiftKey && sel) { a = Math.min(sel[0], n); b = Math.max(sel[1], n); }
  if (!e.shiftKey && sel && sel[0] === n && sel[1] === n) {          // a second click clears
    history.replaceState(null, "", "#" + cur.path); highlight(null); return;
  }
  quietHash = true;
  location.hash = cur.path + ":" + a + (b > a ? "-" + b : "");
});

// ---------------------------------------------------------------- drawer, keys
const side = $("side"), scrim = $("scrim"), filesBtn = $("files-btn");
function openDrawer() { side.classList.add("open"); scrim.hidden = false; filesBtn.setAttribute("aria-expanded", "true"); $("filter").focus(); }
function closeDrawer() { side.classList.remove("open"); scrim.hidden = true; filesBtn.setAttribute("aria-expanded", "false"); }
filesBtn.addEventListener("click", () => (side.classList.contains("open") ? closeDrawer() : openDrawer()));
scrim.addEventListener("click", closeDrawer);

$("filter").addEventListener("input", applyFilter);
$("filter").addEventListener("keydown", (e) => {
  const v = visibleFiles();
  if (e.key === "ArrowDown" && v.length) { e.preventDefault(); v[0].focus(); }
  else if (e.key === "Enter" && v.length) { e.preventDefault(); location.hash = v[0].dataset.path; }
  else if (e.key === "Escape") {
    if ($("filter").value) { $("filter").value = ""; applyFilter(); } else { $("filter").blur(); closeDrawer(); }
  }
});
$("tree").addEventListener("keydown", (e) => {
  if (e.key !== "ArrowDown" && e.key !== "ArrowUp") return;
  const v = visibleFiles(), i = v.indexOf(document.activeElement);
  if (i < 0) return;
  e.preventDefault();
  if (e.key === "ArrowUp" && i === 0) $("filter").focus();
  else v[Math.min(v.length - 1, Math.max(0, i + (e.key === "ArrowDown" ? 1 : -1)))].focus();
});
document.addEventListener("keydown", (e) => {
  if (e.metaKey || e.ctrlKey || e.altKey) return;
  const typing = /^(INPUT|TEXTAREA|SELECT)$/.test(document.activeElement.tagName);
  if (e.key === "Escape") closeDrawer();
  if (typing) return;
  if (e.key === "/") { e.preventDefault(); if (innerWidth <= 820) openDrawer(); else $("filter").focus(); }
  else if ((e.key === "[" || e.key === "]") && order.length) {
    const v = visibleFiles().map((a) => byPath.get(a.dataset.path));
    const list = v.length ? v : order;
    let i = list.indexOf(cur);
    i = i < 0 ? 0 : (i + (e.key === "]" ? 1 : -1) + list.length) % list.length;
    location.hash = list[i].path;
  }
});

// ---------------------------------------------------------------- start
fetch("manifest.json").then((r) => {
  if (!r.ok) throw new Error("manifest.json: " + r.status);
  return r.json();
}).then((m) => {
  M = m;
  StrataHL.init(m.syntax);
  for (const g of m.groups) for (const f of g.files) { order.push(f); byPath.set(f.path, f); }
  buildTree();
  addEventListener("hashchange", route);
  route(true);
}).catch((e) => {
  $("desc").textContent = "Could not load the file list (" + e.message + "). It is built by `make web-site`.";
});
