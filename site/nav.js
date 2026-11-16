// The top bar of every page (nav.top, site/style.css): its menus open on a
// click as well as on hover, and close on Escape or a click elsewhere; on a
// phone the links fold into a menu behind a button, where a menu of links
// (Languages) opens in place. Without this script the bar still works: the
// menus open on hover and focus, and on a phone the links scroll sideways.
"use strict";
(function () {
  const bar = document.querySelector("nav.top");
  if (!bar) return;
  const links = bar.querySelector(".links");
  bar.classList.add("js");

  const menus = [...bar.querySelectorAll(".menu")];
  function close(except) {
    for (const m of menus) if (m !== except) setOpen(m, false);
  }
  function setOpen(m, open) {
    m.classList.toggle("open", open);
    m.querySelector(".menu-btn").setAttribute("aria-expanded", open ? "true" : "false");
  }
  for (const m of menus) {
    const btn = m.querySelector(".menu-btn");
    btn.setAttribute("role", "button");
    btn.setAttribute("aria-expanded", "false");
    btn.addEventListener("click", (e) => {
      e.preventDefault();
      const open = !m.classList.contains("open");
      close(m);
      setOpen(m, open);
    });
    btn.addEventListener("keydown", (e) => {
      if (e.key === "Enter" || e.key === " " || e.key === "ArrowDown") {
        e.preventDefault();
        close(m);
        setOpen(m, true);
        m.querySelector(".drop a")?.focus();
      }
    });
    m.querySelector(".drop").addEventListener("keydown", (e) => {
      const items = [...m.querySelectorAll(".drop a")], i = items.indexOf(document.activeElement);
      if (e.key === "ArrowDown") { e.preventDefault(); items[(i + 1) % items.length].focus(); }
      if (e.key === "ArrowUp") { e.preventDefault(); items[(i - 1 + items.length) % items.length].focus(); }
    });
  }

  // the phone's menu button
  const burger = document.createElement("button");
  burger.className = "burger";
  burger.type = "button";
  burger.setAttribute("aria-label", "Menu");
  burger.setAttribute("aria-expanded", "false");
  burger.innerHTML = "<span></span><span></span><span></span>";
  bar.insertBefore(burger, links);
  function setBar(open) {
    bar.classList.toggle("open", open);
    burger.setAttribute("aria-expanded", open ? "true" : "false");
    if (!open) close();
  }
  burger.addEventListener("click", () => setBar(!bar.classList.contains("open")));
  // the menu that holds the current page starts open in the phone's panel
  for (const m of menus) if (m.classList.contains("current")) m.dataset.cur = "1";
  burger.addEventListener("click", () => {
    if (bar.classList.contains("open")) for (const m of menus) if (m.dataset.cur) setOpen(m, true);
  });

  document.addEventListener("click", (e) => {
    if (!bar.contains(e.target)) { close(); setBar(false); }
  });
  document.addEventListener("keydown", (e) => {
    if (e.key !== "Escape") return;
    const inMenu = menus.find((m) => m.contains(document.activeElement));
    close();
    setBar(false);
    if (inMenu) inMenu.querySelector(".menu-btn").focus();
  });
  // following an in-page link closes the panel
  links.addEventListener("click", (e) => { if (e.target.closest("a")) setBar(false); });
})();
