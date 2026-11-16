// Whether a page starts the emulator with its JIT on, shared by the play
// page (play.js) and the Forth playground (../forth/forth.js), which load
// this file first.
//
// Safari on iPhone and iPad keeps compiled WebAssembly in a limited pool and
// kills the page when the JIT fills it. There the JIT keeps at most 256
// regions alive (all cores) and translates only code run 200 times (LIMITS,
// read by worker.js). With that, an iPad runs StrataOS and its games; an
// iPhone, with less memory, still loses the page, so the JIT starts on on
// iPads and off on iPhones. iPadOS Safari usually says it is a Mac: a Mac
// user agent with touch points is an iPad.
//
// Any device can still lose the page to the JIT, so a page marks in
// localStorage that a machine with the JIT is running (arm) and clears the
// mark once it has run for RUN_OK ms, stops, or the page is closed (disarm).
// A page that finds the mark set was killed while the JIT ran: from then on
// it starts with the JIT off on this browser (OFF, remembered), and says so
// (note); turning the JIT on by hand forgets that (forget). ?jit=0 and
// ?jit=1 override all of it.
"use strict";
var StrataJIT = (function () {
  const ua = navigator.userAgent;
  const IPHONE = /iPhone|iPod/.test(ua);
  const IPAD = !IPHONE && (/iPad/.test(ua) || (/Macintosh|MacIntel/.test(ua + navigator.platform) && navigator.maxTouchPoints > 1));
  const LIMITS = IPHONE || IPAD ? { jitBudget: 256, jitHot: 200 } : {};
  const MARK = "strata-jit-running", OFF = "strata-jit-off";
  const RUN_OK = 20000;

  // storage can be missing or refused (private windows, blocked site data)
  function get(k) { try { return localStorage.getItem(k); } catch (e) { return null; } }
  function set(k, v) { try { localStorage.setItem(k, v); } catch (e) {} }
  function del(k) { try { localStorage.removeItem(k); } catch (e) {} }

  if (get(MARK) !== null) { set(OFF, "1"); del(MARK); }

  // on: the JIT at start; params: the page's URLSearchParams
  function choose(params) {
    const q = params.get("jit");
    if (q === "1" || q === "0") return { on: q === "1", note: null };
    if (get(OFF) !== null)
      return { on: false, note: "The JIT is off: this page was closed while it ran last time, " +
                                "likely by the browser running out of memory." };
    return { on: !IPHONE, note: null };
  }

  let timer = 0, armed = false;
  function arm() {
    clearTimeout(timer);
    armed = true;
    set(MARK, String(Date.now()));
    timer = setTimeout(disarm, RUN_OK);
  }
  function disarm() {
    clearTimeout(timer);
    armed = false;
    del(MARK);
  }
  function forget() { del(OFF); }
  // closing or leaving the page is not a crash; a page restored from the
  // back/forward cache with the machine still young marks it again
  let rearm = false;
  addEventListener("pagehide", () => { rearm = armed; if (armed) { clearTimeout(timer); del(MARK); } });
  addEventListener("pageshow", (e) => { if (e.persisted && rearm) arm(); rearm = false; });

  return { IPHONE, IPAD, LIMITS, choose, arm, disarm, forget };
})();
