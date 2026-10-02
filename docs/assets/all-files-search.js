/* all-files-search.js — the engine of search/all-files.html, the ALL FILES
   SEARCH (2026-09-27, user request; the site's one file search since 2026-09-29).
   ------------------------------------------------------------------------
   The data (bin/analyses/publish-all-files.sh):
     search/all/index.js       window.AXWAY_AFX = { v, subs, days } — the
                               manifest, loaded with the page:
         subs  "NAME \t detail-slug" per line (the global dictionary)
         days  one line per data day, NEWEST FIRST:
               date \t files \t subscription indices (",") \t m \t bits \t cksum
               (bits = the day's bloom filter, 6 bits per base64 character)
     search/all/d-<date>.js    AXWAY_AFD(date, `rows`, `NAME per line`) — one
                               day's Files newest first, loaded ON DEMAND:
         name \t HHMMSS \t local subscription index \t bytes \t CoreId (32 hex)
         \t flag ("" delivered, o delivered after a retry or resubmit, e
         errored, w waiting, x expired; UPPERCASE = the CoreId has a File
         page, and "D" a delivered one with a page)

   The search: two fields (File name, Subscription — the CoreId is a column,
   not searched since 2026-09-30, user request), the results
   following each keystroke after a short pause, Enter at once. A day is
   loaded only when it can hold a match: inside the shared From/To range
   (report.js hands it over — the table is a rangehook table), one of its
   subscriptions matches the Subscription field, and its bloom filter holds
   every trigram and UUID-run token the File field needs — the filter can say
   "maybe" when the day holds nothing, never "no" when it holds a match.
   Candidate days load newest first, PAR at a time, and are scanned in date
   order; the search stops once the newest SHOW matches are in. Loaded days
   stay cached for the next query. With BOTH fields empty the line beside
   them reads "N files in M subscriptions" for the From/To period (the
   period summary, from the MANIFEST: per day its File count + subscription
   indexes, 2026-10-01); no day file is read for it (the background warm-up
   of every day file went 2026-10-01, user request).

   KEEP THE FILTER IN STEP with publish-all-files.sh: the text is lowercased
   with every run of non-ASCII characters -> "?"; an all-[0-9a-f-] trigram is
   never tested (the generator files none — the digit runs of every timestamp);
   tokens are "#" + the 8 hex of each /[0-9a-f]{8}-/ occurrence (a UUID run in a
   NAME — the CoreId files none since 2026-09-30); three hashes h = (h * B + code) mod
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

  // the glob matcher, the byte format, the File State words / row colours
  // and the cell builder are report.js's ONE copy (window.AXWAY_UTIL,
  // 2026-09-30 — this file carried its own globMatcher, a KEEP-IN-STEP pair,
  // until then). report.js loads AFTER this file on the page (the engine
  // registers its range hook first), so they are read when used — and the
  // initial ?f= / ?s= search waits for them (whenUtil).
  function U() { return window.AXWAY_UTIL; }
  function whenUtil(fn) { if (U()) fn(); else document.addEventListener("DOMContentLoaded", fn); }

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
  // trigrams (all-hex ones excepted) and UUID-run tokens
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

  // ---- the matcher -------------------------------------------------------
  function matcher(term) {
    if (!/[*?]/.test(term)) return function (k) { return k.indexOf(term) !== -1; };
    return U().globMatcher(term);   // the glob test without a RegExp (report.js)
  }
  function words(q, raw) {
    q = q.replace(/^\s+|\s+$/g, "");
    if (!raw) q = q.toLowerCase();
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
    var NOIDX = !X;   // the manifest script did not load: say so, never "no matches"
    if (!X) X = { subs: "", days: "" };

    // ---- the manifest ----------------------------------------------------
    var SUBK = [], SUBN = [], SLUGOF = {}, i, f;
    var sl = lines(X.subs);
    for (i = 0; i < sl.length; i++) {
      f = sl[i].split("\t");
      SUBK.push(f[0].toLowerCase()); SUBN.push(f[0]); SLUGOF[f[0]] = f[1] || "";
    }
    var DAYS = [], dl = lines(X.days);
    for (i = 0; i < dl.length; i++) {
      f = dl[i].split("\t");
      DAYS.push({ d: f[0], n: +f[1], subs: f[2] === "" ? [] : f[2].split(","), m: +f[3], bits: f[4], v: f[5] });
    }

    // ---- the day cache + the shard loader -------------------------------
    // CACHE[d] = a day's parsed rows, kept for the next query once a typed
    // search read the day. The day files load ON DEMAND only: the background
    // warm-up of every day file went 2026-10-01 (user request: "do not cache
    // the day files at page load anymore").
    // SEQ / DONE: one script per day in flight (WAIT dedupes); DONE[d] =
    // the load number AXWAY_AFD answered, so a late onload of an older
    // script can never fail a newer load of the same day.
    var CACHE = {}, WAIT = {}, SEQ = {}, DONE = {};
    window.AXWAY_AFD = function (d, rows, subs) {
      var names = lines(subs), rl = lines(rows), R = [], j, g, gs = [];
      for (j = 0; j < rl.length; j++) {
        g = rl[j].split("\t");
        R.push({ nm: g[0], nk: g[0].toLowerCase(), tm: g[1], si: +g[2], by: g[3],
                 cid: g[4].substr(0, 8) + "-" + g[4].substr(8, 4) + "-" + g[4].substr(12, 4) + "-" + g[4].substr(16, 4) + "-" + g[4].substr(20),
                 fl: g[5] || "" });
      }
      for (j = 0; j < names.length; j++) gs.push({ name: names[j], key: names[j].toLowerCase() });
      CACHE[d] = { rows: R, subs: gs };
      DONE[d] = SEQ[d];
      var cbs = WAIT[d] || []; delete WAIT[d];
      for (j = 0; j < cbs.length; j++) cbs[j](true);
    };
    // load(day, cb): cb(ok), ok = false when the shard could not be read. A
    // FAILED shard is NOT cached (2026-09-28 audit F07): it was stored as an
    // empty day, so the search said "no matches" for a day it never read and
    // never asked for it again; now the status counts it and the next search
    // retries it. A script that loads but never calls AXWAY_AFD fails the
    // same way.
    function load(day, cb) {
      if (CACHE[day.d]) { cb(true); return; }
      if (WAIT[day.d]) { WAIT[day.d].push(cb); return; }
      WAIT[day.d] = [cb];
      var my = SEQ[day.d] = (SEQ[day.d] || 0) + 1;
      var s = document.createElement("script");
      s.src = "all/d-" + day.d + ".js?v=" + day.v;
      s.onerror = function () {
        if (s.parentNode) s.parentNode.removeChild(s);
        if (DONE[day.d] === my) return;      // answered after all (a late error event)
        var cbs = WAIT[day.d] || []; delete WAIT[day.d];
        for (var j = 0; j < cbs.length; j++) cbs[j](false);
      };
      s.onload = function () { if (s.parentNode) s.parentNode.removeChild(s); if (DONE[day.d] !== my) s.onerror(); };
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
      b.title = "Type to search; every word must match";   // (the wildcard wording went 2026-09-30 with the search-syntax hint, audit A6-12)
      bar.appendChild(l); bar.appendChild(b);
      return b;
    }
    var fbox = field("File", "File name…", "");
    var sbox = field("Subscription", "Subscription name…", "sep");
    var count = document.createElement("span");
    count.className = "searchhint";
    bar.appendChild(count);
    wrap.parentNode.insertBefore(bar, wrap);
    function showData(on) { wrap.style.display = on ? "" : "none"; }
    showData(false);

    // ---- one match -> a <tr> -------------------------------------------
    // the site's words: OK / Error / Waiting / Expired; the row COLOUR is the
    // File colour (_files.tsv col 25): green OK, orange OK after a retry or
    // resubmit ("o") and Waiting, red Error and Expired — report.js
    // fileState / fileTint; fileCell makes a linked cell a whole-cell link
    function render(day, r) {
      var u = U(), cell = u.fileCell, hb = u.humanBytes;
      var tr = document.createElement("tr");
      var sn = CACHE[day].subs[r.si] ? CACHE[day].subs[r.si].name : "";
      var slug = Object.prototype.hasOwnProperty.call(SLUGOF, sn) ? SLUGOF[sn] : "";
      var fk = r.fl.toLowerCase(), st = u.fileState[fk] || "OK";
      var when = day + " " + r.tm.substr(0, 2) + ":" + r.tm.substr(2, 2) + ":" + r.tm.substr(4, 2);
      tr.setAttribute("data-res", u.fileTint[fk] || "green");
      if (r.fl !== "" && r.fl !== r.fl.toLowerCase()) {   // a File page: the whole row opens it
        var h = "../files/" + r.cid + ".html";
        tr.setAttribute("data-href", h);
        cell(tr, "", when, h); cell(tr, "", sn, h); cell(tr, "", st, h);
        // the CoreId never takes the File-page link (2026-10-02, user
        // request: the file name links /files/, the CoreId the File Tracking
        // URL — report.js addCoreIdLinks turns the plain id into it, no ↗)
        cell(tr, "num", hb(r.by), h); cell(tr, "file", r.nm, h, true); cell(tr, "mono", r.cid, "", true);
      } else {                                              // else the subscription page
        var dh = slug ? "../details/subscriptions/" + slug + ".html" : "";
        cell(tr, "", when, ""); cell(tr, "", sn, dh); cell(tr, "", st, "");
        cell(tr, "num", hb(r.by), ""); cell(tr, "file", r.nm, "", true); cell(tr, "mono", r.cid, "", true);
      }
      return tr;
    }

    // ---- the search ------------------------------------------------------
    var range = null, gen = 0, timer = null;

    // ---- THE PERIOD SUMMARY (2026-09-30, user request: "When no value in
    // both input boxes give the text "nnnn files in nnn subscriptions" for
    // the selected period"). With both fields empty the line beside them
    // counts the Files of the From/To period and their DISTINCT
    // subscriptions from the MANIFEST (2026-10-01: per day its File count +
    // subscription indexes — exact the moment the page opens, no day file
    // read). The background warm-up that loaded every day file for the
    // browser cache went the same day (user request: "do not cache the day
    // files at page load anymore"). "Unknown" (no subscription found) counts
    // its Files but is no subscription — the site rule every subscription
    // count follows.
    function inRange(D) { return !range || (D.d >= range.f && D.d <= range.t); }
    function plural(n, one, many) { return n + " " + (n === 1 ? one : many); }
    function summary(my) {
      if (NOIDX) { count.textContent = "the search index did not load — reload the page"; return; }
      if (my !== gen) return;
      var nf = 0, ns = 0, seen = {}, k, q, D, nm;
      for (k = 0; k < DAYS.length; k++) {
        D = DAYS[k]; if (!inRange(D)) continue;
        nf += D.n;
        for (q = 0; q < D.subs.length; q++) {
          nm = SUBN[+D.subs[q]];
          if (nm && nm !== "Unknown" && seen["k" + nm] !== 1) { seen["k" + nm] = 1; ns++; }   // "Unknown" is no subscription (its Files count)
        }
      }
      count.textContent = plural(nf, "file", "files") + " in " + plural(ns, "subscription", "subscriptions");
    }
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
      if (!fw.length && !sw.length) { showData(false); summary(my); return; }   // both fields empty: the period summary
      if (NOIDX) { count.textContent = "the search index did not load — reload the page; nothing was searched"; showData(false); return; }
      // the filter items come from the RAW words: norm() is the generator's
      // C-locale fold (non-ASCII runs -> "?", then ASCII lowercase), and a
      // Unicode lowercase first can turn a non-ASCII letter ASCII ("İ" ->
      // "i" + U+0307), asking for a trigram no shard holds — the day of a
      // real match was skipped (2026-09-28 fix)
      var fr = words(fq, true);
      var fm = [], sm = [], need = [], k, j;
      for (k = 0; k < fw.length; k++) { fm.push(matcher(fw[k])); need = need.concat(needs(fr[k] || "")); }
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
      var bad = {}, nbad = 0;                // this search's days whose shard failed to load
      function status(final) {
        var nsb = 0; for (var q in nsubs) nsb++;
        var head = hits.length === 0 ? (final ? (nbad ? "no matches in the days that loaded" : "no matches") : "searching…")
                 : (stopped ? "the newest " + SHOW + " matches" : hits.length + (hits.length === 1 ? " match" : " matches")) +
                   " in " + nsb + (nsb === 1 ? " subscription" : " subscriptions");
        count.textContent = head + " · " + (done - nbad) + " of " + cand.length + " day(s) searched" +
          (nbad ? ", " + nbad + " could not be loaded (press Enter to retry)" : "") +
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
          ok2 = true; for (t2 = 0; t2 < fm.length && ok2; t2++) ok2 = fm[t2](r.nk);   // the file NAME only — no CoreId search since 2026-09-30 (user request)
          if (!ok2) continue;
          hits.push([D.d, r]);
        }
        if (hits.length >= SHOW) stopped = true;
      }
      // the subscription count must not double-count one name over days
      function countSubs() { nsubs = {}; for (var p = 0; p < hits.length; p++) { var c = CACHE[hits[p][0]]; nsubs[c.subs[hits[p][1].si].key] = 1; } }
      function pump() {
        if (my !== gen) return;
        // scan every settled day at the head of the queue, in date order (a
        // day whose shard failed is counted, not scanned)
        while (done < cand.length && !stopped) {
          var cd = cand[done].d;
          if (CACHE[cd]) scan(cand[done]);
          else if (bad[cd]) nbad++;
          else break;
          done++;
        }
        countSubs();
        if (stopped || done >= cand.length) { paint(); status(true); return; }
        paint(); status(false);
        while (inflight < PAR && next < cand.length) {
          var D2 = cand[next++];
          if (CACHE[D2.d]) continue;
          inflight++;
          load(D2, loaded(D2.d));
        }
      }
      function loaded(d) { return function (ok) { inflight--; if (!ok) bad[d] = 1; pump(); }; }
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
      run();   // a search re-runs, an empty pair recounts the period
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
    if (f0 !== "" || s0 !== "") { fbox.value = f0; sbox.value = s0; whenUtil(run); }
    else run();   // both fields empty: the period summary at once
    (f0 !== "" && s0 === "" ? sbox : fbox).focus();
  }

  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", init);
  else init();
}());
