/* sub-files.js — the FILES table of a subscription detail page
   (docs/details/subscriptions/<slug>.html; 2026-09-29, user request — it
   replaced the "Latest 1000 files" Features row and its docs/latest/ page).
   ------------------------------------------------------------------------
   Every File of the subscription, newest first, 25 per page with Previous /
   Next, built HERE from the All files search data (bin/analyses/
   publish-all-files.sh). The page bakes only the empty table:
     table[data-subfiles="<slug>"][data-v="<build id>"]
   and this engine loads
     search/all/s/<slug>.js   AXWAY_AFS(slug, `day \t Files \t shard cksum \t
                              local indices`) — the subscription's days,
                              NEWEST FIRST; ?v= the build id (the list is
                              written after the page, so it has no cksum here)
     search/all/d-<day>.js    AXWAY_AFD(day, `rows`, `names`) — a day shard,
                              ?v= its cksum (all-files-search.js documents
                              the row format); only the shards the shown
                              page's rows live in, PAR at a time, and a
                              loaded day stays cached for the next page.
   The rows follow the All files search: State OK / Error / Waiting / Expired,
   tinted by the File colour (_files.tsv col 25: green OK, orange OK after a
   retry or resubmit and Waiting, red Error and Expired), and a File with its
   own page (an UPPERCASE flag) links it from every cell. */
(function () {
  "use strict";

  var PER = 25;   // rows per page
  var PAR = 4;    // day shards loading at once

  function init() {
    var table = document.querySelector("table[data-subfiles]");
    if (!table || !table.rows.length) return;
    // the byte format, the File State words / row colours and the cell
    // builder: report.js's ONE copy (window.AXWAY_UTIL, 2026-09-30 — this
    // file carried its own until then); report.js runs before this file
    var U = window.AXWAY_UTIL;
    if (!U) return;
    var humanBytes = U.humanBytes, STATE = U.fileState, TINT = U.fileTint, cell = U.fileCell;
    var slug = table.getAttribute("data-subfiles"), ver = table.getAttribute("data-v") || "";
    var tb = document.querySelector("div.topbar");
    var root = (tb && tb.getAttribute("data-b")) || "../../";   // back to the docs root
    var base = root + "search/all/";
    var ncols = table.rows[0].cells.length;
    var body = table.tBodies[0] || table;
    var shown = [];                                             // the rows this engine added

    // ---- the pager: the site's tfoot pager row (report.js setupPager) ----
    var prev = document.createElement("span"); prev.textContent = "‹ Previous";
    var info = document.createElement("span"); info.className = "pagerinfo";
    var next = document.createElement("span"); next.textContent = "Next ›";
    // keyboard: a tab stop + the button role (report.js ran its keyboard pass
    // before this engine built them; its delegated Enter / Space handler
    // clicks any span with role=button)
    prev.setAttribute("tabindex", "0"); prev.setAttribute("role", "button");
    next.setAttribute("tabindex", "0"); next.setAttribute("role", "button");
    var bar = document.createElement("div"); bar.className = "pagerbar";
    bar.appendChild(prev); bar.appendChild(info); bar.appendChild(next);
    var ptd = document.createElement("td"); ptd.colSpan = ncols; ptd.appendChild(bar);
    var prow = document.createElement("tr"); prow.className = "pagerrow"; prow.appendChild(ptd);
    var tf = document.createElement("tfoot"); tf.appendChild(prow);
    table.appendChild(tf);
    prow.style.display = "none";

    var DAYS = [], BYDAY = {}, TOTAL = 0, page = 1, gen = 0, WAIT = {};

    function clear() {
      for (var i = 0; i < shown.length; i++) if (shown[i].parentNode) shown[i].parentNode.removeChild(shown[i]);
      shown = [];
    }
    function add(tr) { shown.push(tr); return tr; }
    function message(text) {
      clear();
      var tr = document.createElement("tr"), td = document.createElement("td");
      td.colSpan = ncols; td.className = "empty-state"; td.textContent = text;
      tr.appendChild(td); body.appendChild(add(tr));
    }
    function pages() { return Math.max(1, Math.ceil(TOTAL / PER)); }
    function nav(loading) {
      var n = pages();
      prow.style.display = TOTAL > PER ? "" : "none";
      info.textContent = loading ? "Loading page " + page + " of " + n + "…" : "Page " + page + " of " + n;
      prev.className = "tab" + (page <= 1 ? " disabled" : "");
      next.className = "tab" + (page >= n ? " disabled" : "");
    }

    // ---- one File -> a <tr> ----------------------------------------------
    function whenOf(day, r) { return day + " " + r.tm.substr(0, 2) + ":" + r.tm.substr(2, 2) + ":" + r.tm.substr(4, 2); }
    function row(day, r) {
      var tr = document.createElement("tr");
      var fk = r.fl.toLowerCase(), st = STATE[fk] || "OK";
      var when = whenOf(day, r);
      var h = (r.fl !== "" && r.fl !== r.fl.toLowerCase()) ? root + "files/" + r.cid + ".html" : "";
      tr.setAttribute("data-res", TINT[fk] || "green");
      if (h) tr.setAttribute("data-href", h);
      cell(tr, "", when, h); cell(tr, "", st, h); cell(tr, "num", humanBytes(r.by), h);
      // the CoreId never takes the File-page link (2026-10-02, user request:
      // the file name links /files/, the CoreId the File Tracking URL —
      // report.js addCoreIdLinks turns the plain id into it, no ↗)
      cell(tr, "file", r.nm, h, true); cell(tr, "mono", r.cid, "", true);
      return tr;
    }
    function totalRow() {
      var tr = document.createElement("tr"), i, td;
      tr.className = "total";
      for (i = 0; i < ncols; i++) {
        td = document.createElement("td");
        if (i === 0) td.textContent = "Total (" + TOTAL + " File" + (TOTAL === 1 ? "" : "s") + ")";
        else if (i === 2) td.className = "num";
        tr.appendChild(td);
      }
      return tr;
    }

    // ---- the day shards ----------------------------------------------------
    window.AXWAY_AFD = function (d, rows, subs) {
      var D = BYDAY[d];
      if (!D || D.rows) return;
      var R = [], rl = (typeof rows === "string" && rows !== "") ? rows.split("\n") : [], j, g;
      for (j = 0; j < rl.length; j++) {
        g = rl[j].split("\t");
        if (D.si[+g[2]] !== 1) continue;                        // another subscription's File
        R.push({ nm: g[0], tm: g[1], by: g[3],
                 cid: g[4].substr(0, 8) + "-" + g[4].substr(8, 4) + "-" + g[4].substr(12, 4) + "-" + g[4].substr(16, 4) + "-" + g[4].substr(20),
                 fl: g[5] || "" });
      }
      D.rows = R;
      var cbs = WAIT[d] || []; delete WAIT[d];
      for (j = 0; j < cbs.length; j++) cbs[j](true);
    };
    // cb(ok) — a shard that fails (or loads without calling AXWAY_AFD) is not
    // cached, so the next page turn asks for it again
    function load(D, cb) {
      if (WAIT[D.d]) { WAIT[D.d].push(cb); return; }
      WAIT[D.d] = [cb];
      var s = document.createElement("script");
      s.src = base + "d-" + D.d + ".js?v=" + D.v;
      s.onerror = function () {
        if (s.parentNode) s.parentNode.removeChild(s);
        var cbs = WAIT[D.d] || []; delete WAIT[D.d];
        for (var j = 0; j < cbs.length; j++) cbs[j](false);
      };
      s.onload = function () { if (!D.rows && WAIT[D.d]) s.onerror(); };
      document.head.appendChild(s);
    }

    // ---- one page ----------------------------------------------------------
    function show(p) {
      var my = ++gen;
      page = Math.min(Math.max(1, p), pages());
      var lo = (page - 1) * PER, hi = Math.min(lo + PER, TOTAL), need = [], k;
      for (k = 0; k < DAYS.length; k++) if (DAYS[k].lo < hi && DAYS[k].lo + DAYS[k].n > lo) need.push(DAYS[k]);
      var left = need.length, nxt = 0, inflight = 0, failed = 0, fin = false;
      nav(true);
      function done1(ok) { inflight--; left--; if (!ok) failed++; pump(); }
      function pump() {
        if (my !== gen || fin) return;
        while (inflight < PAR && nxt < need.length) {
          var D = need[nxt++];
          if (D.rows) { left--; continue; }
          inflight++; load(D, done1);
        }
        if (left > 0) return;
        fin = true;
        if (failed) { message(failed + " day(s) of Files could not be loaded — turn the page or reload to retry"); nav(false); return; }
        clear();
        var frag = document.createDocumentFragment(), i, a, b, R;
        for (i = 0; i < need.length; i++) {
          R = need[i].rows; a = Math.max(0, lo - need[i].lo); b = Math.min(R.length, hi - need[i].lo);
          for (; a < b; a++) frag.appendChild(add(row(need[i].d, R[a])));
        }
        frag.appendChild(add(totalRow()));
        body.appendChild(frag);
        nav(false);
      }
      pump();
    }
    // ---- the CSV export: EVERY File, not the 25 on screen -----------------
    // report.js downloadCsv asks table._csvAll(cb) first: every day shard of
    // the subscription is loaded (PAR at a time, cached for the pager too) and
    // cb gets all rows, newest first, as the cell texts the table shows
    // (Start, State, Size, File, CoreId — built column order); cb(null, why)
    // when the list or a shard could not be loaded — report.js then saves
    // NOTHING (2026-09-29 audit F13: it exported the page on screen as if it
    // were every File) and the next click retries the failed days
    table._csvAll = function (cb) {
      if (!got) { cb(null, "the Files list did not load"); return; }
      var k = 0, inflight = 0, left = DAYS.length, failed = 0, fin = false;
      function finish() {
        if (fin) return;
        fin = true;
        if (failed) { cb(null, failed + " of " + DAYS.length + " day(s) could not be loaded"); return; }
        var out = [], i, j, R, r, fk;
        for (i = 0; i < DAYS.length; i++) {
          R = DAYS[i].rows || [];
          for (j = 0; j < R.length; j++) {
            r = R[j]; fk = r.fl.toLowerCase();
            out.push([whenOf(DAYS[i].d, r), STATE[fk] || "OK", humanBytes(r.by), r.nm, r.cid]);
          }
        }
        cb(out);
      }
      function done1(ok) { inflight--; left--; if (!ok) failed++; pump(); }
      function pump() {
        while (inflight < PAR && k < DAYS.length) {
          var D = DAYS[k++];
          if (D.rows) { left--; continue; }
          inflight++; load(D, done1);
        }
        if (left <= 0) finish();
      }
      pump();
    };
    prev.addEventListener("click", function () { if (page > 1) show(page - 1); });
    next.addEventListener("click", function () { if (page < pages()) show(page + 1); });
    // a File-page row opens its page from anywhere in the row
    table.addEventListener("click", function (e) {
      var el = e.target;
      while (el && el !== table) { if (el.tagName === "A") return; if (el.tagName === "TR") break; el = el.parentNode; }
      var h = el && el !== table ? el.getAttribute("data-href") : null;
      if (h) location.href = h;
    });

    // ---- the subscription's day list -------------------------------------
    var got = false;
    window.AXWAY_AFS = function (s, txt) {
      if (s !== slug || got) return;
      got = true;
      var ls = (typeof txt === "string" && txt !== "") ? txt.split("\n") : [], i, j, g, D, ix;
      for (i = 0; i < ls.length; i++) {
        g = ls[i].split("\t");
        if (g.length < 4) continue;
        D = { d: g[0], n: +g[1], v: g[2], si: {}, lo: TOTAL, rows: null };
        ix = g[3].split(",");
        for (j = 0; j < ix.length; j++) D.si[+ix[j]] = 1;
        TOTAL += D.n; DAYS.push(D); BYDAY[D.d] = D;
      }
    };
    message("Loading the Files…");
    var ls = document.createElement("script");
    ls.src = base + "s/" + encodeURIComponent(slug) + ".js" + (ver ? "?v=" + encodeURIComponent(ver) : "");
    ls.onerror = function () { message("The Files could not be loaded — reload the page"); };
    ls.onload = function () {
      if (!got) { ls.onerror(); return; }
      if (!TOTAL) { message("No Files"); return; }
      show(1);
    };
    document.head.appendChild(ls);
  }

  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", init);
  else init();
}());
