// The play page's network (common/net.h's browser modes), shared by the
// worker (worker.js: importScripts) and the node tests (tools/wasm-run.js:
// require). Nothing here talks to a server the user did not choose, except
// the two public DNS-over-HTTPS services that answer the guest's DNS queries
// in "peer" mode.
//
//   StrataNet.dohAnswer(query, fetchFn) -> Promise<Uint8Array | null>
//     query: a DNS query message (what the guest sent to port 53). Asks
//     Cloudflare's JSON API (https://cloudflare-dns.com/dns-query), then
//     Google's (https://dns.google/resolve) if that fails, and builds the DNS
//     answer message from the JSON: A and CNAME records, the response code.
//     null if neither answered (the guest's resolver then times out).
//   StrataNet.link(M, hop, post, opts) -> {stop()}
//     the "tab" and "relay" modes: packets the guest sends (Module.webNetTx)
//     go to a BroadcastChannel shared by the page's tabs, or to a WebSocket;
//     what arrives goes to the guest (web_net_rx). In "tab" mode the tabs
//     agree on host numbers first: 10.0.0.1, 10.0.0.2, ... (web_net_hint).
"use strict";
(function (root) {
  const DOH = [
    (name) => `https://cloudflare-dns.com/dns-query?name=${encodeURIComponent(name)}&type=A`,
    (name) => `https://dns.google/resolve?name=${encodeURIComponent(name)}&type=A`,
  ];

  // the question's name and type, and where the question ends
  function question(q) {
    if (q.length < 17) return null;
    let o = 12, parts = [];
    while (o < q.length && q[o]) {
      const l = q[o++];
      if (l > 63 || o + l > q.length) return null;
      parts.push(String.fromCharCode(...q.subarray(o, o + l)));
      o += l;
    }
    if (o + 5 > q.length) return null;
    return { name: parts.join("."), type: (q[o + 1] << 8) | q[o + 2], end: o + 5 };
  }

  function encName(name) {
    const out = [];
    for (const label of name.replace(/\.$/, "").split(".")) {
      if (!label) continue;
      const b = Array.from(label, (c) => c.charCodeAt(0) & 255).slice(0, 63);
      out.push(b.length, ...b);
    }
    out.push(0);
    return out;
  }

  // the DNS answer to query q from the JSON reply j
  function build(q, qi, j) {
    const out = Array.from(q.subarray(0, qi.end));
    out[2] = 0x80 | (q[2] & 1);                          // a response, RD as asked
    out[3] = 0x80 | ((j.Status | 0) & 15);               // RA, the response code
    out[6] = out[7] = out[8] = out[9] = out[10] = out[11] = 0;
    let an = 0;
    for (const a of j.Answer || []) {
      const ttl = Math.max(0, Math.min(a.TTL | 0, 0x7fffffff));
      let rd;
      if (a.type === 1) {
        const p = String(a.data).split(".").map((x) => x | 0);
        if (p.length !== 4) continue;
        rd = p;
      } else if (a.type === 5) rd = encName(String(a.data));
      else continue;
      out.push(...encName(String(a.name)), 0, a.type, 0, 1, ttl >>> 24, (ttl >> 16) & 255, (ttl >> 8) & 255, ttl & 255,
               rd.length >> 8, rd.length & 255, ...rd);
      an++;
    }
    out[6] = an >> 8;
    out[7] = an & 255;
    return new Uint8Array(out);
  }

  async function dohAnswer(query, fetchFn) {
    const q = new Uint8Array(query);
    const qi = question(q);
    if (!qi) return null;
    for (const url of DOH) {
      try {
        const r = await fetchFn(url(qi.name), { headers: { accept: "application/dns-json" } });
        if (!r.ok) continue;
        return build(q, qi, await r.json());
      } catch (e) { /* the next one */ }
    }
    return null;
  }

  // The guest's DNS queries in "peer" mode: answered over HTTPS.
  function peer(M, hop, fetchFn) {
    const buf = M._malloc(1500);
    M.webDns = (ptr, n) => {
      const q = M.HEAPU8.slice(ptr, ptr + n);
      dohAnswer(q, fetchFn).then((r) => {
        if (!r || r.length > 1472) return;
        M.HEAPU8.set(r, buf);
        M._web_net_dns(buf, r.length);
        hop();
      });
    };
  }

  // "tab": BroadcastChannel("strata-net"); "relay": a WebSocket to opts.url.
  // post(text): a note for the page (the address this tab took, the relay's state).
  function link(M, hop, post, opts) {
    const buf = M._malloc(1500);
    const rx = (data) => {
      const p = new Uint8Array(data);
      if (!p.length || p.length > 1500) return;
      M.HEAPU8.set(p, buf);
      M._web_net_rx(buf, p.length);
      hop();
    };
    if (opts.mode === "relay") {
      let ws;
      try { ws = new WebSocket(opts.url); } catch (e) { post(`relay: ${e.message || e}`); return { stop() {} }; }
      ws.binaryType = "arraybuffer";
      ws.onopen = () => post(`relay: connected to ${opts.url}; every packet of this machine goes through it`);
      ws.onclose = () => post(`relay: ${opts.url} closed the connection`);
      ws.onerror = () => post(`relay: cannot reach ${opts.url}`);
      ws.onmessage = (e) => rx(e.data);
      M.webNetTx = (ptr, n) => { if (ws.readyState === 1) ws.send(M.HEAPU8.slice(ptr, ptr + n)); };
      return { stop() { try { ws.close(); } catch (e) { /* gone */ } } };
    }
    const id = Math.random().toString(36).slice(2);
    const bc = new BroadcastChannel("strata-net");
    const taken = new Set();
    let me = 0;
    bc.onmessage = (e) => {
      const m = e.data;
      if (!m || m.id === id) return;
      if (m.t === "who" && me) bc.postMessage({ t: "me", id, n: me });
      else if (m.t === "me") taken.add(m.n);
      else if (m.t === "pkt" && me) rx(m.data);
    };
    bc.postMessage({ t: "who", id });
    setTimeout(() => {                                     // the lowest number no other tab has
      me = 1;
      while (taken.has(me)) me++;
      M._web_net_hint(me);
      bc.postMessage({ t: "me", id, n: me });
      post(`tab link: this machine is 10.0.0.${me} (other tabs of this page are 10.0.0.x on the same link)`);
    }, 300);
    M.webNetTx = (ptr, n) => { if (me) bc.postMessage({ t: "pkt", id, data: M.HEAPU8.slice(ptr, ptr + n) }); };
    return { stop() { bc.close(); } };
  }

  const api = { dohAnswer, peer, link, question, build };
  if (typeof module !== "undefined" && module.exports) module.exports = api;
  else root.StrataNet = api;
})(typeof self !== "undefined" ? self : this);
