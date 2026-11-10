// The play page's Service Worker (scope vm/): shows the guest's web server.
// A fetch of vm/PORT/PATH (vm/PATH: port 80) becomes a raw HTTP/1.0 request,
// which goes to the play page that runs the machine (clients.matchAll; the
// page hands it to its emulator worker, which opens a connection to the
// guest's PORT through web/web.c's web_http_* calls) and comes back as the
// guest's raw response, parsed here into a Response. Nothing leaves the
// browser.
//   page <- sw   {t: "vmhttp", port, request: Uint8Array}  (a MessagePort to answer on)
//   page -> sw   {response: Uint8Array} | {error: 502 | 503 | 504, text}
"use strict";
const TIMEOUT = 30000;
const KEEP = ["accept", "accept-language", "content-type", "cache-control", "if-modified-since", "if-none-match", "range"];

self.addEventListener("install", () => self.skipWaiting());
self.addEventListener("activate", (e) => e.waitUntil(self.clients.claim()));

self.addEventListener("fetch", (e) => {
  const url = new URL(e.request.url);
  const at = url.pathname.indexOf("/vm/");
  if (at < 0 || url.origin !== self.location.origin) return;
  let rest = url.pathname.slice(at + 4);
  let port = 80;
  const m = /^(\d{1,5})(\/.*)?$/.exec(rest);
  if (m) { port = +m[1]; rest = m[2] || "/"; } else rest = "/" + rest;
  e.respondWith(relay(e.request, port, rest + url.search));
});

function page(status, title, text) {
  const html = `<!doctype html><meta charset="utf-8"><title>${title}</title>` +
    `<body style="font:15px system-ui;background:#05080f;color:#cfe8ff;padding:2em"><h1 style="font-size:1.2em">${title}</h1><p>${text}</p>`;
  return new Response(html, { status, headers: { "content-type": "text/html; charset=utf-8" } });
}

async function relay(req, port, path) {
  let head = `${req.method} ${path} HTTP/1.0\r\nHost: localhost:${port}\r\n`;
  for (const k of KEEP) { const v = req.headers.get(k); if (v) head += `${k}: ${v}\r\n`; }
  let body = new Uint8Array(0);
  if (req.method !== "GET" && req.method !== "HEAD") body = new Uint8Array(await req.arrayBuffer());
  if (body.length) head += `Content-Length: ${body.length}\r\n`;
  head += "Connection: close\r\n\r\n";
  const h = new TextEncoder().encode(head);
  const request = new Uint8Array(h.length + body.length);
  request.set(h);
  request.set(body, h.length);
  const tabs = (await self.clients.matchAll({ type: "window", includeUncontrolled: true }))
    .filter((c) => !new URL(c.url).pathname.includes("/vm/"));
  let last = null;
  for (const c of tabs) {
    const ans = await ask(c, { t: "vmhttp", port, request });
    if (ans && ans.response) return parse(ans.response);
    if (ans && ans.error && ans.error !== 502) { last = ans; break; }
  }
  if (last && last.error === 503) return page(503, `Nothing listening on port ${port}`, `The Strata machine in the play tab has no server on port ${port} (try <code>httpd &amp;</code> in its shell).`);
  if (last && last.error === 504) return page(504, "No answer", `The guest's server on port ${port} did not answer in time.`);
  return page(502, "No Strata machine", "No play tab is running a Strata machine. Open the play page and boot StrataOS, then start <code>httpd &amp;</code>.");
}

function ask(client, msg) {
  return new Promise((done) => {
    const ch = new MessageChannel();
    const t = setTimeout(() => done(null), TIMEOUT);
    ch.port1.onmessage = (e) => { clearTimeout(t); done(e.data); };
    client.postMessage(msg, [ch.port2]);
  });
}

// "HTTP/1.x CODE reason\r\nheaders\r\n\r\nbody" -> a Response
function parse(raw) {
  const r = new Uint8Array(raw);
  let end = -1, sep = 4;
  for (let i = 0; i + 1 < r.length; i++) {
    if (r[i] === 13 && r[i + 1] === 10 && r[i + 2] === 13 && r[i + 3] === 10) { end = i; break; }
    if (r[i] === 10 && r[i + 1] === 10) { end = i; sep = 2; break; }
  }
  if (end < 0) return page(502, "A broken response", "The guest's server sent no complete HTTP header.");
  const lines = new TextDecoder("latin1").decode(r.subarray(0, end)).split(/\r?\n/);
  const st = /^HTTP\/\d\.\d\s+(\d{3})\s*(.*)$/.exec(lines[0]);
  if (!st) return page(502, "A broken response", "The guest's server sent no HTTP status line.");
  const headers = new Headers();
  for (const l of lines.slice(1)) {
    const c = l.indexOf(":");
    if (c > 0) {
      const k = l.slice(0, c).trim(), v = l.slice(c + 1).trim();
      if (!/^(connection|transfer-encoding|content-length|keep-alive)$/i.test(k)) { try { headers.append(k, v); } catch (e) { /* not allowed */ } }
    }
  }
  const status = +st[1];
  const nobody = status === 204 || status === 304 || (status >= 100 && status < 200);
  return new Response(nobody ? null : r.slice(end + sep), { status, statusText: st[2], headers });
}
