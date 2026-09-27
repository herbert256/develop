/* all-files-search.js — the engine of search/all-files.html, the ALL FILES
   SEARCH ("Implementation 3, all files", 2026-09-27, user request).
   ------------------------------------------------------------------------
   The data (bin/analyses/publish-all-files.sh):
     search/all/index.js       window.AXWAY_AFX = { v, subs, days } — the
                               manifest, loaded with the page:
         subs  "NAME \t detail-slug" per line (the global dictionary)
         days  one line per data day, NEWEST FIRST:
               date \t files \t subscription indices (",") \t m \t bits \t cksum
               (bits = the day's bloom filter, 6 bits per base64 character)
     search/all/d-<date>.js    AXWAY_AFD(date, `NAME per line`, `rows`) — one
                               day's Files newest first, loaded ON DEMAND:
         name \t HHMMSS \t local subscription index \t bytes \t CoreId (32 hex)
         \t flag ("" delivered, e errored, w waiting, x expired; UPPERCASE =
         the CoreId has a File page, and "D" a delivered one with a page)

   The search: two fields (File name or CoreId, Subscription), the results
   following each keystroke after a short pause, Enter at once. A day is
   loaded only when it can hold a match: inside the shared From/To range
   (report.js hands it over — the table is a rangehook table), one of its
   subscriptions matches the Subscription field, and its bloom filter holds
   every trigram and CoreId token the File field needs — the filter can say
   "maybe" when the day holds nothing, never "no" when it holds a match.
   Candidate days load newest first, PAR at a time, and are scanned in date
   order; the search stops once the newest SHOW matches are in. Loaded days
   stay cached for the next query.

   KEEP THE FILTER IN STEP with publish-all-files.sh: the text is lowercased
   with every run of non-ASCII characters -> "?"; an all-[0-9a-f-] trigram is
   never tested (a CoreId can hold any of them); tokens are "#" + the 8 hex of
   each /[0-9a-f]{8}-/ occurrence; three hashes h = (h * B + code) mod
   2147483647 with B = 131, 257 and 521, bit = h mod m (m >= 8 bits/item). */
(function () {
  "use strict";

  var SHOW = 500;   // matches rendered at most
  var PAUSE = 250;  // ms after the last keystroke before the search runs
  var PAR = 4;      // day shards loading at once

  var A64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
  var B64 = {};
  for (var z = 0; z < A64.length; z++) B64[A64.charAt(z)] = z;

  function lines(s) { return (typeof s === "string" && s !== "") ? s.split("\n") : []; }

  function humanBytes(b) {                      // the site's humanbytes format
    b = +b;
    if (b < 1024) return b + " B";
    if (b < 1048576) return (b / 1024).toFixed(2) + " KB";
    if (b < 1073741824) return (b / 1048576).toFixed(2) + " MB";
    return (b / 1073741824).toFixed(2) + " GB";
  }

  // ---- the filter (publish-all-files.sh twin) -----------------------------
  function norm(s) { return s.replace(/[^\x00-\x7f]+/g, "?").toLowerCase(); }
  function hsh(s, b) {
    var h = 0;
    for (var i = 0; i < s.length; i++) h = (h * b + s.charCodeAt(i)) % 2147483647;
    return h;
  }
  function bit(day, h) {
    var i = h % day.m;
    return (B64[day.bits.charAt(Math.floor(i / 6))] >> (i % 6)) & 1;
  }
  function has(day, item) { return bit(day, hsh(item, 131)) && bit(day, hsh(item, 257)) && bit(day, hsh(item, 521)); }
  // the items one File-field word needs: its wildcard-free segments'
  // trigrams (all-hex ones excepted) and CoreId tokens
  function needs(word) {
    var out = [], segs = word.split(/[*?]/), i, j, s, g, re, m;
    for (i = 0; i < segs.length; i++) {
      s = norm(segs[i]);
      for (j = 0; j + 3 <= s.length; j++) { g = s.substr(j, 3); if (/[^0-9a-f-]/.test(g)) out.push(g); }
      re = /[0-9a-f]{8}-/g;
      while ((m = re.exec(s)) !== null) out.push("#" + m[0].substr(0, 8));
    }
    return out;
  }

  // ---- the matcher (file-search.js rules) ---------------------------------
  function matcher(term) {
    if (!/[*?]/.test(term)) return function (k) { return k.indexOf(term) !== -1; };
    var re = new RegExp(term.replace(/[.+^${}()|[\]\\]/g, "\\$&")
                            .replace(/\*/g, "[\\s\\S]*").replace(/\?/g, "[\\s\\S]"));
    return function (k) { return re.test(k); };
  }
  function words(q) {
    q = q.replace(/^\s+|\s+$/g, "").toLowerCase();
    return q === "" ? [] : q.split(/\s+/);
  }

  function param(name) {
    var m = new RegExp("[?&]" + name + "=([^&]*)").exec(location.search);
    if (!m) return "";
    try { return decodeURIComponent(m[1].replace(/\+/g, " ")); } catch (e) { return m[1]; }
  }

  function init() {
    var X = window.AXWAY_AFX;
    if (location.pathname.split("/").pop() !== "all-files.html") return;
    var table = document.querySelector(".tablewrap table");
    if (!table || !table.rows.length) return;
    if (!X) X = { subs: "", days: "" };

    // ---- the manifest ----------------------------------------------------
    var SUBK = [], SLUGOF = {}, i, f;
    var sl = lines(X.subs);
    for (i = 0; i < sl.length; i++) {
      f = sl[i].split("\t");
      SUBK.push(f[0].toLowerCase()); SLUGOF[f[0]] = f[1] || "";
    }
    var DAYS = [], dl = lines(X.days);
    for (i = 0; i < dl.length; i++) {
      f = dl[i].split("\t");
      DAYS.push({ d: f[0], n: +f[1], subs: f[2] === "" ? [] : f[2].split(","), m: +f[3], bits: f[4], v: f[5] });
    }

    // ---- the day cache + the shard loader -------------------------------
    var CACHE = {}, WAIT = {};
    window.AXWAY_AFD = function (d, subs, rows) {
      var names = lines(subs), rl = lines(rows), R = [], j, g;
      for (j = 0; j < rl.length; j++) {
        g = rl[j].split("\t");
        R.push({ nm: g[0], nk: g[0].toLowerCase(), tm: g[1], si: +g[2], by: g[3],
                 cid: g[4].substr(0, 8) + "-" + g[4].substr(8, 4) + "-" + g[4].substr(12, 4) + "-" + g[4].substr(16, 4) + "-" + g[4].substr(20),
                 fl: g[5] || "" });
      }
      var gs = [];
      for (j = 0; j < names.length; j++) gs.push({ name: names[j], key: names[j].toLowerCase() });
      CACHE[d] = { rows: R, subs: gs };
      var cbs = WAIT[d] || []; delete WAIT[d];
      for (j = 0; j < cbs.length; j++) cbs[j]();
    };
    function load(day, cb) {
      if (CACHE[day.d]) { cb(); return; }
      if (WAIT[day.d]) { WAIT[day.d].push(cb); return; }
      WAIT[day.d] = [cb];
      var s = document.createElement("script");
      s.src = "all/d-" + day.d + ".js?v=" + day.v;
      s.onerror = function () { CACHE[day.d] = { rows: [], subs: [] }; var cbs = WAIT[day.d] || []; delete WAIT[day.d]; for (var j = 0; j < cbs.length; j++) cbs[j](); };
      document.head.appendChild(s);
    }

    // ---- the controls row (BELOW report.js's From/To row: underdates) ---
    var wrap = table.closest ? table.closest(".tablewrap") : table.parentNode;
    var bar = document.createElement("div");
    bar.className = "controls underdates";
    function field(label, ph, cls) {
      var l = document.createElement("label");
      if (cls) l.className = cls;
      l.textContent = label;
      var b = document.createElement("input");
      b.type = "text"; b.className = "search"; b.placeholder = ph;
      b.title = "Wildcards: ? = one character, * = any run; several space-separated words must all match";
      bar.appendChild(l); bar.appendChild(b);
      return b;
    }
    var fbox = field("File", "File name or CoreId…", "");
    var sbox = field("Subscription", "Subscription name…", "sep");
    var count = document.createElement("span");
    count.className = "searchhint";
    bar.appendChild(count);
    wrap.parentNode.insertBefore(bar, wrap);
    function showData(on) { wrap.style.display = on ? "" : "none"; }
    showData(false);

    // ---- one match -> a <tr> (the file-search.js shape) -----------------
    function cell(tr, cls, text, href, mono) {
      var c = document.createElement("td"), t;
      if (cls) c.className = cls;
      if (mono) { t = document.createElement("code"); t.textContent = text; }
      if (href) {
        var a = document.createElement("a");
        a.setAttribute("href", href);
        if (mono) a.appendChild(t); else a.textContent = text;
        c.appendChild(a);
      } else if (mono) c.appendChild(t);
      else c.textContent = text;
      tr.appendChild(c);
    }
    var STATE = { "": "Delivered", d: "Delivered", e: "Errored", w: "Waiting", x: "Expired" };
    var TINT = { Delivered: "green", Errored: "red", Expired: "red", Waiting: "orange" };
    function render(day, r) {
      var tr = document.createElement("tr");
      var sn = CACHE[day].subs[r.si] ? CACHE[day].subs[r.si].name : "";
      var slug = Object.prototype.hasOwnProperty.call(SLUGOF, sn) ? SLUGOF[sn] : "";
      var st = STATE[r.fl.toLowerCase()] || "Delivered";
      var when = day + " " + r.tm.substr(0, 2) + ":" + r.tm.substr(2, 2) + ":" + r.tm.substr(4, 2);
      tr.setAttribute("data-res", TINT[st]);
      if (r.fl !== "" && r.fl !== r.fl.toLowerCase()) {   // a File page: the whole row opens it
        var h = "../files/" + r.cid + ".html";
        tr.setAttribute("data-href", h);
        cell(tr, "cl", when, h); cell(tr, "cl", sn, h); cell(tr, "cl", st, h);
        cell(tr, "num cl", humanBytes(r.by), h); cell(tr, "file cl", r.nm, h, true); cell(tr, "mono cl", r.cid, h, true);
      } else {                                              // else the subscription page
        var dh = slug ? "../details/subscriptions/" + slug + ".html" : "";
        cell(tr, "", when, ""); cell(tr, dh ? "cl" : "", sn, dh); cell(tr, "", st, "");
        cell(tr, "num", humanBytes(r.by), ""); cell(tr, "file", r.nm, "", true); cell(tr, "mono", r.cid, "", true);
      }
      return tr;
    }

    // ---- the search ------------------------------------------------------
    var range = null, gen = 0, timer = null;
    function sync(fq, sq) {
      var qs = [], rest = location.search.replace(/^\?/, "").split("&"), k;
      for (k = 0; k < rest.length; k++) if (rest[k] !== "" && !/^[fs]=/.test(rest[k])) qs.push(rest[k]);
      if (fq !== "") qs.push("f=" + encodeURIComponent(fq));
      if (sq !== "") qs.push("s=" + encodeURIComponent(sq));
      try { history.replaceState(null, "", location.pathname + (qs.length ? "?" + qs.join("&") : "")); } catch (e) {}
    }
    function run() {
      var my = ++gen;
      var fq = fbox.value.replace(/^\s+|\s+$/g, ""), sq = sbox.value.replace(/^\s+|\s+$/g, "");
      sync(fq, sq);
      while (table.rows.length > 1) table.deleteRow(1);
      var fw = words(fq), sw = words(sq);
      if (!fw.length && !sw.length) { count.textContent = ""; showData(false); return; }
      var fm = [], sm = [], need = [], k, j;
      for (k = 0; k < fw.length; k++) { fm.push(matcher(fw[k])); need = need.concat(needs(fw[k])); }
      for (k = 0; k < sw.length; k++) sm.push(matcher(sw[k]));
      // which global subscriptions pass the Subscription field
      var subOk = null;
      if (sm.length) { subOk = {}; for (k = 0; k < SUBK.length; k++) { var ok = true; for (j = 0; j < sm.length && ok; j++) ok = sm[j](SUBK[k]); if (ok) subOk[k] = 1; } }
      // the candidate days
      var cand = [], skipped = 0;
      for (k = 0; k < DAYS.length; k++) {
        var D = DAYS[k];
        if (range && (D.d < range.f || D.d > range.t)) continue;
        if (subOk) { var any = false; for (j = 0; j < D.subs.length && !any; j++) any = subOk[D.subs[j]] === 1; if (!any) { skipped++; continue; } }
        var pass = true; for (j = 0; j < need.length && pass; j++) pass = has(D, need[j]);
        if (!pass) { skipped++; continue; }
        cand.push(D);
      }
      var hits = [], nsubs = {}, done = 0, next = 0, inflight = 0, stopped = false, painted = 0;
      function status(final) {
        var nsb = 0; for (var q in nsubs) nsb++;
        var head = hits.length === 0 ? (final ? "no matches" : "searching…")
                 : (stopped ? "the newest " + SHOW + " matches" : hits.length + (hits.length === 1 ? " match" : " matches")) +
                   " in " + nsb + (nsb === 1 ? " subscription" : " subscriptions");
        count.textContent = head + " · " + done + " of " + cand.length + " day(s) searched" +
          (skipped ? ", " + skipped + " skipped by the index" : "") + (final ? "" : "…");
      }
      function paint() {                     // append the matches found since the last paint
        var frag = document.createDocumentFragment();
        for (; painted < hits.length && painted < SHOW; painted++) frag.appendChild(render(hits[painted][0], hits[painted][1]));
        (table.tBodies[0] || table).appendChild(frag);
        showData(hits.length > 0);
      }
      function scan(D) {                     // one day, in date order
        var C = CACHE[D.d], R = C.rows, q, r, ok2, t2;
        for (q = 0; q < R.length && hits.length < SHOW; q++) {
          r = R[q];
          if (sm.length) { var sk = C.subs[r.si] ? C.subs[r.si].key : ""; ok2 = true; for (t2 = 0; t2 < sm.length && ok2; t2++) ok2 = sm[t2](sk); if (!ok2) continue; }
          ok2 = true; for (t2 = 0; t2 < fm.length && ok2; t2++) ok2 = fm[t2](r.nk) || fm[t2](r.cid);
          if (!ok2) continue;
          hits.push([D.d, r]);
        }
        if (hits.length >= SHOW) stopped = true;
      }
      // the subscription count must not double-count one name over days
      function countSubs() { nsubs = {}; for (var p = 0; p < hits.length; p++) { var c = CACHE[hits[p][0]]; nsubs[c.subs[hits[p][1].si].key] = 1; } }
      function pump() {
        if (my !== gen) return;
        // scan every loaded day at the head of the queue, in date order
        while (done < cand.length && !stopped && CACHE[cand[done].d]) { scan(cand[done]); done++; }
        countSubs();
        if (stopped || done >= cand.length) { paint(); status(true); return; }
        paint(); status(false);
        while (inflight < PAR && next < cand.length) {
          var D2 = cand[next++];
          if (CACHE[D2.d]) continue;
          inflight++;
          load(D2, function () { inflight--; pump(); });
        }
      }
      status(false);
      pump();
    }
    function later() { if (timer) clearTimeout(timer); timer = setTimeout(function () { timer = null; run(); }, PAUSE); }
    fbox.addEventListener("input", later);
    sbox.addEventListener("input", later);
    function now(e) { if (e.key === "Enter") { if (timer) { clearTimeout(timer); timer = null; } run(); } }
    fbox.addEventListener("keydown", now);
    sbox.addEventListener("keydown", now);

    // the From/To range (report.js rangehook; null = every day)
    (window.AXWAY_RANGEHOOKS = window.AXWAY_RANGEHOOKS || []).push(function (fr, to, narrowed) {
      range = (narrowed && fr && to) ? { f: fr < to ? fr : to, t: fr < to ? to : fr } : null;
      if (fbox.value.replace(/\s/g, "") !== "" || sbox.value.replace(/\s/g, "") !== "") run();
    });
    var sr = window._slotRange;
    if (sr && sr.narrowed && sr.from && sr.to) range = { f: sr.from < sr.to ? sr.from : sr.to, t: sr.from < sr.to ? sr.to : sr.from };

    // whole-row links: a File-page row carries data-href; any other row
    // follows its first link (the subscription cell) — delegated, rows come later
    table.addEventListener("click", function (e) {
      var el = e.target, tr = null;
      while (el && el !== table) { if (el.tagName === "A") return; if (el.tagName === "TR") { tr = el; break; } el = el.parentNode; }
      if (!tr) return;
      var h = tr.getAttribute("data-href");
      if (!h) { var a0 = tr.getElementsByTagName("a")[0]; if (a0) h = a0.getAttribute("href"); }
      if (h) location.href = h;
    });

    var f0 = param("f"), s0 = param("s");
    if (f0 !== "" || s0 !== "") { fbox.value = f0; sbox.value = s0; run(); }
    (f0 !== "" && s0 === "" ? sbox : fbox).focus();
  }

  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", init);
  else init();
}());
