/* latest-search.js — the engine of docs/latest/search.html, the LATEST FILES
   SEARCH (2026-09-27, user request).
   ------------------------------------------------------------------------
   The page loads EVERY subscription's Latest files payload
   (docs/latest/<slug>.js, written by bin/transfer/publish-details.sh
   render_latest_page), each of which registers itself:

     (window.AXWAY_LATEST = window.AXWAY_LATEST || []).push({
       s: "<slug>",               the page docs/latest/<slug>.html
       n: "<SUBSCRIPTION>",       the subscription name
       h: "Start\tEnd\t…",        the HEAD labels — Pickup and Recovered
                                  come and go per subscription
       r: `<tr data-res=…><td>…</td>…</tr>\n…`   the rows exactly as
                                  render_rpt wrote them, newest first })

   The same payload feeds the subscription's own page (report.js
   latestRows). Here the engine reads the cells it shows BY LABEL and renders
   ONLY the matches (DOM-built, auto-escaped), at most 500, newest Start
   first. report.js still runs for the chrome but keeps its hands off the
   table (restint + nosort + nosearch + nofilter, and the table ships
   empty — each rendered row carries data-res, the restint tint).

   Behaviour:
   - two fields: SUBSCRIPTION (the subscription name) and FILE NAME OR
     COREID; a filled field must match, an empty one does not constrain;
     both empty = nothing shown, the count line says what is searchable;
   - matching is case-insensitive; `*` = any run, `?` = one character,
     several space-separated words must ALL match (a File-field word
     matches on the file name OR the CoreId);
   - the results follow each keystroke (after a short pause);
   - the Subscription cell opens that subscription's Latest files page
     (a whole-cell link, class cl);
   - the From/To selectors (report.js, the shared transfer-area range; the
     table is a `rangehook` table) narrow the Files BEFORE the 500 cap: a
     File counts when its Start..End span overlaps the range — the row rule
     of the Latest files pages. report.js hands the range over through
     window.latestSearchSetRange, the window._slotRange stash covering an
     engine that initialises after the load-time apply;
   - the URL carries ?s=…&f=… (history.replaceState), so a reload or a
     bookmark repeats the search. */
(function () {
  "use strict";

  var SHOW = 500;    // matches rendered at most; the count line says the truth
  var PAUSE = 150;   // ms after the last keystroke before the search runs
  var COLS = ["Start", "End", "State", "Direction", "Size", "Duration", "File", "CoreId"];

  function decode(s) {                          // render_rpt's esc(), undone
    return s.replace(/&(lt|gt|quot|#39|amp);/g, function (m, e) {
      return e === "lt" ? "<" : e === "gt" ? ">" : e === "quot" ? "\"" : e === "#39" ? "'" : "&";
    });
  }

  var CELL = /<td[^>]*>([\s\S]*?)<\/td>/g;
  function cellsOf(row) {                       // the TEXT of each <td>
    var out = [], m;
    CELL.lastIndex = 0;
    while ((m = CELL.exec(row)) !== null)
      out.push(decode(m[1].replace(/<[^>]*>/g, "")).replace(/^\s+|\s+$/g, ""));
    return out;
  }

  // one term -> a matcher (substring, or a glob when * / ? appear)
  function matcher(term) {
    if (!/[*?]/.test(term)) return function (k) { return k.indexOf(term) !== -1; };
    var re = new RegExp(term.replace(/[.+^${}()|[\]\\]/g, "\\$&")
                            .replace(/\*/g, "[\\s\\S]*").replace(/\?/g, "[\\s\\S]"));
    return function (k) { return re.test(k); };
  }
  function matchers(q) {
    q = q.replace(/^\s+|\s+$/g, "").toLowerCase();
    if (q === "") return null;
    var t = q.split(/\s+/), ms = [], i;
    for (i = 0; i < t.length; i++) ms.push(matcher(t[i]));
    return ms;
  }

  function param(name) {
    var m = new RegExp("[?&]" + name + "=([^&]*)").exec(location.search);
    if (!m) return "";
    try { return decodeURIComponent(m[1].replace(/\+/g, " ")); } catch (e) { return m[1]; }
  }

  function init() {
    var L = window.AXWAY_LATEST;
    var page = location.pathname.split("/").pop();
    if (page !== "search.html") return;
    var table = document.querySelector(".tablewrap table");
    if (!table || !table.rows.length) return;
    if (!L) L = [];

    // ---- the index: one record per File, the shown cells by label -------
    var subs = [], subKey = [];                 // per payload: [slug, name], lower-cased name
    var rec = [];                               // per File: [payload, res, Start … CoreId]
    var fkey = [], ckey = [];                   // per File: lower-cased file name, CoreId
    var p, i, j;
    for (p = 0; p < L.length; p++) {
      var P = L[p];
      if (!P || typeof P.r !== "string") continue;
      var si = subs.length;
      subs.push([P.s || "", P.n || ""]);
      subKey.push((P.n || "").toLowerCase());
      var h = String(P.h || "").split("\t"), at = [];
      for (j = 0; j < COLS.length; j++) at.push(h.indexOf(COLS[j]));
      var rows = P.r.split("\n");
      for (i = 0; i < rows.length; i++) {
        var row = rows[i];
        if (row.indexOf("<tr") !== 0) continue;
        var c = cellsOf(row), res = /^<tr[^>]*\bdata-res="([^"]*)"/.exec(row);
        var r = [si, res ? res[1] : ""];
        for (j = 0; j < COLS.length; j++) r.push(at[j] >= 0 && at[j] < c.length ? c[at[j]] : "");
        rec.push(r);
        fkey.push(r[2 + 6].toLowerCase());      // File
        ckey.push(r[2 + 7].toLowerCase());      // CoreId
      }
    }

    // ---- the controls row, above the table wrap -------------------------
    var wrap = table.closest ? table.closest(".tablewrap") : table.parentNode;
    var bar = document.createElement("div");
    bar.className = "controls";
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
    var sbox = field("Subscription", "Subscription name…", "");
    var fbox = field("File", "File name or CoreId…", "sep");
    var count = document.createElement("span");
    count.className = "searchhint";

    // ---- the From/To range (report.js hands it over; null = full period) -
    var range = null;                           // { f: "yyyy-mm-dd", t: "yyyy-mm-dd" }
    function inRange(r) {
      if (!range) return true;
      var s = r[2].slice(0, 10), e = (r[3] || r[2]).slice(0, 10);
      if (e < s) { var x = s; s = e; e = x; }
      return s <= range.t && e >= range.f;       // the span overlaps the range
    }
    var idle = "";
    function setIdle() {
      var n = rec.length, ss = subs.length, k, seen;
      if (range) {
        n = 0; seen = {}; ss = 0;
        for (k = 0; k < rec.length; k++)
          if (inRange(rec[k])) { n++; if (!seen[rec[k][0]]) { seen[rec[k][0]] = 1; ss++; } }
      }
      idle = n + " files of " + ss + " subscriptions searchable" + (range ? " in the selected period" : "")
           + " — type a subscription name, a file name or a CoreId";
    }
    setIdle();
    count.textContent = idle;
    bar.appendChild(count);
    wrap.parentNode.insertBefore(bar, wrap);

    function showData(on) { wrap.style.display = on ? "" : "none"; }
    showData(false);

    // ---- one record -> a <tr> -------------------------------------------
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
    function render(r) {
      var tr = document.createElement("tr"), sb = subs[r[0]];
      if (r[1]) tr.setAttribute("data-res", r[1]);   // the restint tint
      cell(tr, sb[0] ? "cl" : "", sb[1], sb[0] ? sb[0] + ".html" : "");
      cell(tr, "", r[2]);                  // Start
      cell(tr, "", r[3]);                  // End
      cell(tr, "", r[4]);                  // State
      cell(tr, "", r[5]);                  // Direction
      cell(tr, "num", r[6]);               // Size
      cell(tr, "num", r[7]);               // Duration
      cell(tr, "", r[8], "", true);        // File
      cell(tr, "", r[9], "", true);        // CoreId
      return tr;
    }

    function sync(sq, fq) {
      // keep every parameter that is not ours (?axway_date=… is report.js's,
      // read AFTER this engine's first run)
      var qs = [], rest = location.search.replace(/^\?/, "").split("&"), i;
      for (i = 0; i < rest.length; i++)
        if (rest[i] !== "" && !/^[sf]=/.test(rest[i])) qs.push(rest[i]);
      if (sq !== "") qs.push("s=" + encodeURIComponent(sq));
      if (fq !== "") qs.push("f=" + encodeURIComponent(fq));
      try { history.replaceState(null, "", location.pathname + (qs.length ? "?" + qs.join("&") : "")); } catch (e) {}
    }

    function run() {
      var sq = sbox.value.replace(/^\s+|\s+$/g, ""), fq = fbox.value.replace(/^\s+|\s+$/g, "");
      sync(sq, fq);
      while (table.rows.length > 1) table.deleteRow(1);   // keep the header row
      var sm = matchers(sq), fm = matchers(fq);
      if (!sm && !fm) { count.textContent = idle; showData(false); return; }
      // the subscription field narrows the payloads once, not per File
      var subOk = [], s, t, ok;
      for (s = 0; s < subs.length; s++) {
        ok = true;
        if (sm) for (t = 0; t < sm.length && ok; t++) ok = sm[t](subKey[s]);
        subOk.push(ok);
      }
      var hit = [], inSubs = {}, nSubs = 0, k;
      for (k = 0; k < rec.length; k++) {
        if (!subOk[rec[k][0]] || !inRange(rec[k])) continue;
        ok = true;
        if (fm) for (t = 0; t < fm.length && ok; t++) ok = fm[t](fkey[k]) || fm[t](ckey[k]);
        if (!ok) continue;
        hit.push(k);
        if (!inSubs[rec[k][0]]) { inSubs[rec[k][0]] = 1; nSubs++; }
      }
      // newest Start first across the subscriptions ("yyyy-mm-dd hh:mm:ss.mmm"
      // sorts as text); a tie keeps the payload order
      hit.sort(function (a, b) {
        var x = rec[a][2], y = rec[b][2];
        return x < y ? 1 : x > y ? -1 : a - b;
      });
      var frag = document.createDocumentFragment(), shown = Math.min(hit.length, SHOW);
      for (k = 0; k < shown; k++) frag.appendChild(render(rec[hit[k]]));
      (table.tBodies[0] || table).appendChild(frag);
      showData(shown > 0);
      var where = " in " + nSubs + (nSubs === 1 ? " subscription" : " subscriptions");
      count.textContent = hit.length === 0 ? "no matches"
        : hit.length > shown ? hit.length + " matches" + where + " — showing the newest " + shown
        : hit.length + (hit.length === 1 ? " match" : " matches") + where;
    }

    var timer = null;
    function later() {
      if (timer) clearTimeout(timer);
      timer = setTimeout(function () { timer = null; run(); }, PAUSE);
    }
    sbox.addEventListener("input", later);
    fbox.addEventListener("input", later);
    function now(e) { if (e.key === "Enter") { if (timer) { clearTimeout(timer); timer = null; } run(); } }
    sbox.addEventListener("keydown", now);
    fbox.addEventListener("keydown", now);

    // the range hook report.js's date filter calls on every change (and at
    // load when a stored range is restored); the stash covers a range applied
    // before this engine was ready
    function takeRange(f, t, narrowed) {
      range = (narrowed && f && t) ? { f: f < t ? f : t, t: f < t ? t : f } : null;
      setIdle();
      run();
    }
    window.latestSearchSetRange = takeRange;
    var sr = window._slotRange;
    if (sr && sr.narrowed && sr.from && sr.to) { range = { f: sr.from < sr.to ? sr.from : sr.to, t: sr.from < sr.to ? sr.to : sr.from }; setIdle(); count.textContent = idle; }

    // ?s=…&f=… (a reload or a bookmark): fill and search now
    var s0 = param("s"), f0 = param("f");
    if (s0 !== "" || f0 !== "") { sbox.value = s0; fbox.value = f0; run(); }
    (s0 !== "" && f0 === "" ? fbox : sbox).focus();
  }

  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", init);
  else init();
}());
