// The manual on the web (isa/, arch/, forth/): the filter of the entries
// (instructions, Forth words), the index that follows the reading position,
// and the index drawer on phones.
// Everything works without it; it only adds the filter and the highlighting.
"use strict";
(function () {
  const $ = (id) => document.getElementById(id);
  const ix = $("ix"), toc = document.querySelector(".doc-toc");
  const narrow = () => innerWidth <= 820;

  // ------------------------------------------------------------ index drawer
  if (ix) {
    if (narrow()) {
      ix.open = false;
      // closing the index moved the page up under a deep link: go to the target again
      const t = location.hash && document.getElementById(decodeURIComponent(location.hash.slice(1)));
      if (t) t.scrollIntoView({ behavior: "instant" });
    }
    let wasNarrow = narrow();
    addEventListener("resize", () => {
      if (wasNarrow && !narrow()) ix.open = true;
      wasNarrow = narrow();
    });
    toc.addEventListener("click", (e) => { if (e.target.closest("a") && narrow()) ix.open = false; });
  }

  // ------------------------------------------------------------ the filter (isa/, forth/)
  // The input says what it filters (data-items, the entries' id prefix and a
  // noun for the count); the instruction set's are the defaults. Entries
  // carry their search text in data-k, and may carry their name in
  // data-name; [data-unfiltered] blocks are hidden while a filter is on.
  const filter = $("filter");
  const items = (filter && filter.dataset.items) || "article.insn";
  const prefix = (filter && filter.dataset.prefix) || "insn-";
  const noun = (filter && filter.dataset.noun) || "instructions";
  const insns = [...document.querySelectorAll(items)];
  const unfiltered = [...document.querySelectorAll("[data-unfiltered]")];
  const linked = [...document.querySelectorAll("[data-for]")];
  const chaps = [...document.querySelectorAll("section.chap[data-ch]")];
  const opcodes = $("opcodes");
  let shown = insns;

  function apply() {
    const words = filter.value.trim().toLowerCase().split(/\s+/).filter(Boolean);
    const on = new Set();
    for (const a of insns) {
      const hay = a.dataset.k;
      const ok = words.every((w) => hay.includes(w));
      a.hidden = !ok;
      if (ok) on.add(a.id);
    }
    for (const el of linked) el.hidden = !on.has(el.dataset.for);
    for (const c of chaps) c.hidden = !c.querySelector(items + ":not([hidden])");
    for (const el of unfiltered) el.hidden = words.length > 0;
    for (const g of document.querySelectorAll(".ix-group[data-ch]")) g.hidden = !g.querySelector(".ix:not([hidden])");
    if (opcodes) opcodes.hidden = words.length > 0;
    const og = $("ix-opcodes");
    if (og) og.hidden = words.length > 0;
    shown = insns.filter((a) => !a.hidden);
    $("count").textContent = words.length ? `${shown.length} of ${insns.length} ${noun}` : "";
    if (words.length && narrow()) ix.open = true;
  }

  function best() {
    const q = filter.value.trim().toLowerCase();
    const name = (a) => a.dataset.name || a.id.slice(prefix.length);
    return shown.find((a) => name(a) === q) || shown.find((a) => name(a).startsWith(q)) || shown[0];
  }

  if (filter) {
    filter.addEventListener("input", apply);
    filter.addEventListener("keydown", (e) => {
      if (e.key === "Enter") {
        const a = best();
        if (a) { e.preventDefault(); location.hash = a.id; if (narrow()) ix.open = false; }
      } else if (e.key === "Escape") {
        if (filter.value) { filter.value = ""; apply(); } else filter.blur();
      }
    });
    // a link to an entry the filter hides clears the filter
    addEventListener("hashchange", () => {
      const t = document.getElementById(decodeURIComponent(location.hash.slice(1)));
      if (t && t.closest("[hidden]")) { filter.value = ""; apply(); t.scrollIntoView(); }
    });
    document.addEventListener("keydown", (e) => {
      if (e.metaKey || e.ctrlKey || e.altKey) return;
      if (/^(INPUT|TEXTAREA|SELECT)$/.test(document.activeElement.tagName)) return;
      if (e.key === "/") { e.preventDefault(); filter.focus(); filter.select(); }
    });
  }

  // ------------------------------------------------------------ where am I
  if (toc && "IntersectionObserver" in window) {
    const links = new Map();
    for (const a of toc.querySelectorAll("a.ix")) links.set(decodeURIComponent(a.hash.slice(1)), a);
    const targets = [...links.keys()].map((id) => document.getElementById(id)).filter(Boolean);
    let cur = null;
    const visible = new Set();
    const mark = () => {
      // the topmost target that is on screen, else the last one above it
      let best = null;
      for (const t of targets) {
        if (visible.has(t)) { best = t; break; }
      }
      if (!best) {
        for (const t of targets) if (t.getBoundingClientRect().top < 120) best = t;
      }
      const a = best && links.get(best.id);
      if (a === cur) return;
      if (cur) cur.classList.remove("on");
      cur = a;
      if (!a) return;
      a.classList.add("on");
      const top = a.offsetTop - ix.offsetTop;    // keep it in view inside the index, not the page
      if (!narrow() && (top < ix.scrollTop || top > ix.scrollTop + ix.clientHeight - 30))
        ix.scrollTop = top - ix.clientHeight / 3;
    };
    const io = new IntersectionObserver((es) => {
      for (const e of es) (e.isIntersecting ? visible.add(e.target) : visible.delete(e.target));
      mark();
    }, { rootMargin: "-60px 0px -55% 0px" });
    for (const t of targets) io.observe(t);
  }
})();
