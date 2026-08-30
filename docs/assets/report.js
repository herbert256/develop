/* Cloud log reports — client-side interactivity (loaded by every page).
 * Works off the rendered markup only (no per-page code):
 *   - click a column header to sort (numeric / date / size / duration / text aware);
 *     the tr.total footer stays pinned at the bottom.
 *   - if a table has a "Date" column, a From/To date pulldown pair filters rows.
 * No framework, ES5-compatible. */
(function () {
  "use strict";

  var SIZE = { b: 1, kb: 1024, mb: 1048576, gb: 1073741824, tb: 1099511627776, pb: 1125899906842624 };
  var TIME = { ms: 1, s: 1000, m: 60000, min: 60000, h: 3600000 };

  // "2026-06-28[ HH:MM:SS[.mmm]]" or "06/28/2026[ HH:MM:SS]" -> epoch ms, else null.
  function parseDate(s) {
    var m = /^(\d{4})-(\d{2})-(\d{2})(?:[ T](\d{2}):(\d{2}):(\d{2}))?/.exec(s);
    if (m) return Date.UTC(+m[1], +m[2] - 1, +m[3], +(m[4] || 0), +(m[5] || 0), +(m[6] || 0));
    m = /^(\d{2})\/(\d{2})\/(\d{4})(?:[ T](\d{2}):(\d{2}):(\d{2}))?/.exec(s);
    if (m) return Date.UTC(+m[3], +m[1] - 1, +m[2], +(m[4] || 0), +(m[5] || 0), +(m[6] || 0));
    return null;
  }

  // "1.59 GB" / "574 ms" / "45.1%" / "+14.2%" / "1.33 MB/s" / "12,345" -> comparable number, else null.
  function parseNum(s) {
    var t = s.trim();
    if (t === "" || t === "-") return null;
    // a RANK cell ("#1", "#12" — the Ranking report) sorts by its number;
    // only the exact #<digits> shape qualifies, anything longer stays text
    if (/^#\d+$/.test(t)) return parseFloat(t.slice(1));
    // Dot-grouped integer ("663.706", "1.350.636") — the root analysis tables
    // (index, entities, PDA) group thousands with a DOT (bin/publish.sh). Only
    // a BARE number in 1-2 strict groups of three qualifies: a unit suffix
    // keeps decimal-dot semantics ("1.314 s"), and 3+ groups would match IPv4
    // addresses ("10.249.100.105"), which must stay text.
    if (/^[-+]?\d{1,3}(?:\.\d{3}){1,2}$/.test(t)) return parseFloat(t.replace(/\./g, ""));
    var m = /^([-+]?[\d,]+(?:\.\d+)?)\s*([A-Za-z%\/]*)$/.exec(t);
    if (!m) return null;
    var n = parseFloat(m[1].replace(/,/g, ""));
    if (isNaN(n)) return null;
    var u = m[2].toLowerCase().replace(/\/s$/, "");
    if (SIZE[u] != null) return n * SIZE[u];
    if (TIME[u] != null) return n * TIME[u];
    return n;
  }

  function sortKey(s) {
    var d = parseDate(s); if (d !== null) return d;
    var n = parseNum(s); if (n !== null) return n;
    return null;
  }
  // Numeric sort value of a CELL. A 0-blanked Failed/Processed cell (class "z",
  // rendered empty) is the number 0 — not "no value" — so it sorts AMONG the
  // numbers in both directions instead of clumping at the top on a descending
  // sort. Any other non-numeric cell -> null (sorts last).
  function numKey(cell) {
    if (!cell) return null;
    // An explicit per-cell sort value wins over the text: a collapsed
    // <details> count cell (the coverage Accounts / Endpoints / Whitelisted IPs
    // columns) carries data-sortval="<count>" so the column sorts by its count,
    // not by the concatenated summary+names text (which parseNum can't read).
    if (cell.getAttribute) {
      var sv = cell.getAttribute("data-sortval");
      if (sv !== null) return sortKey(sv);
    }
    var s = cell.textContent.trim();
    if (s === "" && (" " + cell.className + " ").indexOf(" z ") >= 0) return 0;
    return sortKey(s);
  }

  function isTotal(tr) { return (" " + tr.className + " ").indexOf(" total ") >= 0; }

  // Every table is wrapped in a <div class="tablewrap"> (horizontal-scroll box).
  // Layout insertions and show/hide operate on this unit, so a table's title,
  // notes and the search/date controls stay OUTSIDE the scroll box.
  function tunit(t) {
    var p = t.parentNode;
    return (p && (" " + p.className + " ").indexOf(" tablewrap ") >= 0) ? p : t;
  }

  function headerRow(table) {
    // Prefer the FIELD header row: a th row whose cells carry no colspan. A
    // grouped-banner row (GHEAD, e.g. Top view IDs' Files/Transfers/Sessions
    // band) spans columns and must not become the sort header.
    var cand = null;
    for (var i = 0; i < table.rows.length; i++)
      if (table.rows[i].getElementsByTagName("th").length) {
        var r = table.rows[i], spanned = false;
        for (var j = 0; j < r.cells.length; j++)
          if ((r.cells[j].colSpan || 1) > 1) { spanned = true; break; }
        if (!spanned) return r;
        if (!cand) cand = r;
      }
    return cand;
  }
  function dataRows(table) {
    var out = [], r = table.rows, i, c0;
    for (i = 0; i < r.length; i++) {
      c0 = r[i].cells[0];
      if (!r[i].getElementsByTagName("th").length && !isTotal(r[i]) &&
          r[i].className.indexOf("coreid-detail") < 0 &&
          r[i].className.indexOf("pagerrow") < 0 &&
          r[i].className.indexOf("foldrow") < 0 &&
          !(c0 && c0.className.indexOf("bluemsg") >= 0)) out.push(r[i]);   // skip injected drill-down rows, the pager footer, fold summaries, and paired message rows
    }
    return out;
  }
  // 2-row entries (fake-transfers list): a full-width message row (cell class
  // bluemsg) immediately above its data row. Bind each data row to its message
  // row so any re-order (sort/unsort) keeps the pair together; the message row
  // itself is excluded from dataRows so it never sorts on its own.
  function bindPairs(table) {
    var r = table.rows, i, c0;
    for (i = 0; i < r.length; i++) {
      c0 = r[i].cells[0];
      if (c0 && c0.className.indexOf("bluemsg") >= 0 && r[i].nextElementSibling)
        r[i].nextElementSibling._pairmsg = r[i];
    }
  }
  function repositionPairs(table) {
    var dr = dataRows(table), i, body = table.tBodies[0] || table;
    for (i = 0; i < dr.length; i++) if (dr[i]._pairmsg) body.insertBefore(dr[i]._pairmsg, dr[i]);
  }
  function totalRows(table) {
    var out = [], r = table.rows, i;
    for (i = 0; i < r.length; i++) if (isTotal(r[i])) out.push(r[i]);
    return out;
  }

  // Group-column blanking (detail tables tagged class="grouped"): the data files
  // now carry the real value on every row; we blank a repeated leading cell in
  // the browser instead, re-applied after sort/filter so it always reflects the
  // VISIBLE rows (a blanked cell always means "same as the row above it").
  function isGrouped(table) { return (" " + table.className + " ").indexOf(" grouped ") >= 0; }

  // Remember each row's real group value (col 0) once, so we can blank/restore.
  // Stored as innerHTML (not textContent) so a linked cell (<a> to a detail
  // page) survives blanking/restoring; grouping compares the HTML, which is
  // identical for equal values.
  function initGroup(table) {
    if (!isGrouped(table)) return;
    dataRows(table).forEach(function (tr) {
      if (tr.cells[0] && !tr.hasAttribute("data-g")) tr.setAttribute("data-g", tr.cells[0].innerHTML);
    });
  }
  // Put the real value back into col 0 (undo blanking) — used before sorting.
  function ungroup(table) {
    if (!isGrouped(table)) return;
    dataRows(table).forEach(function (tr) {
      var g = tr.getAttribute("data-g");
      if (tr.cells[0] && g !== null) tr.cells[0].innerHTML = g;
    });
  }
  // Blank col 0 when it repeats the previous VISIBLE row's value.
  function applyGroup(table) {
    if (!isGrouped(table)) return;
    var last = null;
    dataRows(table).forEach(function (tr) {
      var c = tr.cells[0]; if (!c) return;
      var g = tr.getAttribute("data-g"); if (g === null) g = c.innerHTML;
      if (tr.style.display === "none") { c.innerHTML = g; return; }  // hidden: keep real (unseen)
      if (g === last) { c.innerHTML = ""; } else { c.innerHTML = g; last = g; }
    });
  }

  // ---- totals that follow the date filter ----
  function humanBytes(b) {
    var u = ["B", "KB", "MB", "GB", "TB", "PB"], i = 0, v = b;
    while (v >= 1024 && i < 5) { v /= 1024; i++; }
    return i === 0 ? Math.round(v) + " B" : v.toFixed(2) + " " + u[i];
  }
  function humanDur(ms) {
    if (ms < 1000) return Math.round(ms) + " ms";
    if (ms < 60000) return (ms / 1000).toFixed(2) + " s";
    if (ms < 3600000) return (ms / 60000).toFixed(1) + " min";
    return (ms / 3600000).toFixed(2) + " h";
  }

  // ---- generic per-date re-aggregation (the date filter) --------------------
  // A row carries data-buckets = "date:m0:m1:...,date:m0:m1:..." (raw per-date
  // base metrics); the table carries data-recalc = one token per column telling
  // how to rebuild that column's cell from the metrics summed over the selected
  // range. Tokens: "-"/"k" keep · sN sum(N) · hN humanBytes(sum N) · %N share
  // (100*sumN/columnTotalN) · pN.M 100*sumN/sumM · aN round(sumN/days) · c
  // in-range day count · dN count of in-range days with metric N > 0 ·
  // qN.M humanDur(sumN/sumM) · xN humanDur(max N) · tN.M
  // humanBytes(sumN*1000/sumM)+"/s" · bN bar of sumN vs column max ·
  // rN position by column N descending (rN.a ascending, rN.z zeros last) —
  // see rankCols.
  function aggBuckets(str, lo, hi) {
    var sum = {}, max = {}, pos = {}, days = 0, i, v;
    if (str) str.split(",").forEach(function (seg) {
      if (!seg) return;
      var pp = seg.split(":"), e = parseDate(pp[0]);
      if (e === null || e < lo || e > hi) return;
      days++;
      for (i = 1; i < pp.length; i++) {
        v = +pp[i] || 0; sum[i - 1] = (sum[i - 1] || 0) + v;
        if (max[i - 1] == null || v > max[i - 1]) max[i - 1] = v;
        if (v > 0) pos[i - 1] = (pos[i - 1] || 0) + 1;
      }
    });
    return { sum: sum, max: max, pos: pos, days: days };
  }
  // ---- top-N re-select tables (data-topsel) ---------------------------------
  // The table's rows are the CANDIDATE set — per qualifying date its own top N,
  // each row carrying data-date + data-val, baked value-descending with rows
  // past the global top N hidden (data-dhide, backed by CSS so no script needs
  // to run at load). On a range change the visible set becomes the N highest
  // values among the in-range candidates; the full range reproduces the baked
  // list exactly. The selection is by VALUE, so an active user sort holds.
  function recalcTopsel(table, lo, hi, narrowed) {
    var N = parseInt(table.getAttribute("data-topsel"), 10) || 0, i;
    var drows = dataRows(table), cands = [];
    for (i = 0; i < drows.length; i++) {
      if (!drows[i].hasAttribute("data-val")) continue;
      var e = parseDate(drows[i].getAttribute("data-date") || "");
      cands.push({ r: drows[i], v: +drows[i].getAttribute("data-val"),
                   ok: !narrowed || (e !== null && e >= lo && e <= hi) });
    }
    cands.sort(function (a, b) { return b.v - a.v; });   // stable: ties keep DOM order
    var shown = 0;
    for (i = 0; i < cands.length; i++) {
      var keep = cands[i].ok && shown < N;
      if (keep) shown++;
      cands[i].r.setAttribute("data-dhide", keep ? "0" : "1");
      applyRowVis(cands[i].r);
    }
    // the custom "Top N of M Files" footer label follows the selection; the
    // baked text restores at the full range
    var trs = totalRows(table);
    if (trs.length && trs[0].cells.length) {
      var lc = trs[0].cells[0];
      if (!lc.hasAttribute("data-tsl0")) lc.setAttribute("data-tsl0", lc.textContent);
      var lbl = narrowed ? ("Top " + shown + " of the selected days") : lc.getAttribute("data-tsl0");
      // data-orig too: recomputeTotals runs after this on the apply() path and
      // rebuilds the label cell from data-orig, which would undo the rewrite
      lc.textContent = lbl; lc.setAttribute("data-orig", lbl);
    }
  }
  // ---- date-aware STAT boxes ------------------------------------------------
  // A .stat carrying data-tok recomputes its value for the selected range from
  // its data-sb per-day payload; the full range restores the baked original
  // (the recalcTable rule). Payload "date:V,date:V" — V per token:
  //   sum     V = count                    -> plain sum
  //   share   V = total:matching           -> 100*sum(matching)/sum(total) "%"
  //   maxdur  V = max ms                   -> humanDur(max)
  //   p50/p90 V = ms.count|ms.count|...    -> nearest-rank percentile of the
  //           merged histogram, humanDur; the writer quantizes each ms to the
  //           humanDur DISPLAY grid, so the shown value equals the exact one.
  //   uniq    V = id|id|...                -> size of the id UNION over the
  //           range (recovered-files: distinct subscriptions/protocols).
  // data-thr retints the box: "le:A:B" green<=A / orange<=B / red on the ms (or
  // %) result; "ge:A:B" the same with >= (a high share is the good end).
  function recalcStats(lo, hi, narrowed) {
    var els = document.querySelectorAll(".stat[data-tok]"), i, j, k;
    for (i = 0; i < els.length; i++) {
      var el = els[i], vEl = el.querySelector(".stat-v");
      if (!vEl) continue;
      if (!el.hasAttribute("data-vorig")) { el.setAttribute("data-vorig", vEl.textContent); el.setAttribute("data-corig", el.className); }
      if (!narrowed) { vEl.textContent = el.getAttribute("data-vorig"); el.className = el.getAttribute("data-corig"); continue; }
      var tok = el.getAttribute("data-tok"), segs = (el.getAttribute("data-sb") || "").split(","), out = "-", num = null;
      var tot = 0, mt = 0, mx = null, map = {}, pp, e, pr;
      for (j = 0; j < segs.length; j++) {
        if (!segs[j]) continue;
        pp = segs[j].split(":"); e = parseDate(pp[0]);
        if (e === null || e < lo || e > hi) continue;
        if (tok === "sum") tot += +pp[1] || 0;
        else if (tok === "share") { tot += +pp[1] || 0; mt += +pp[2] || 0; }
        else if (tok === "maxdur") { if (mx === null || +pp[1] > mx) mx = +pp[1]; }
        else if (tok === "uniq") { var us = pp[1].split("|"); for (k = 0; k < us.length; k++) if (us[k]) map[us[k]] = 1; }
        else if (tok === "p50" || tok === "p90") {
          var prs = pp[1].split("|");
          for (k = 0; k < prs.length; k++) {
            pr = prs[k].split("."); if (pr.length < 2) continue;
            map[pr[0]] = (map[pr[0]] || 0) + (+pr[1]); tot += +pr[1];
          }
        }
      }
      if (tok === "sum") { out = String(tot); num = tot; }
      else if (tok === "uniq") { num = Object.keys(map).length; out = String(num); }
      else if (tok === "share") { num = tot ? 100 * mt / tot : 0; out = num.toFixed(1) + "%"; }
      else if (tok === "maxdur") { if (mx !== null) { out = humanDur(mx); num = mx; } }
      else if (tok === "p50" || tok === "p90") {
        if (tot) {
          var keys = Object.keys(map).map(Number).sort(function (a, b) { return a - b; });
          var rank = Math.max(1, Math.floor(tot * (tok === "p50" ? 0.5 : 0.9))), cum = 0;
          for (k = 0; k < keys.length; k++) { cum += map[keys[k]]; if (cum >= rank) { num = keys[k]; break; } }
          if (num !== null) out = humanDur(num);
        }
      }
      vEl.textContent = out;
      var thr = el.getAttribute("data-thr");
      if (thr && num !== null) {
        var tp = thr.split(":"), good = tp[0] === "ge" ? num >= +tp[1] : num <= +tp[1], mid = tp[0] === "ge" ? num >= +tp[2] : num <= +tp[2];
        el.className = "stat stat-" + (good ? "green" : mid ? "orange" : "red");
      }
    }
  }
  function recalcCell(tok, agg, colSum) {
    var t = tok.charAt(0), rest = tok.slice(1), N, p, den;
    if (t === "s") return String(agg.sum[+rest] || 0);
    if (t === "h") return humanBytes(agg.sum[+rest] || 0);
    if (t === "%") { N = +rest; den = colSum[N] || 0; return (den ? (100 * (agg.sum[N] || 0) / den).toFixed(1) : "0.0") + "%"; }
    if (t === "p") { p = rest.split("."); den = agg.sum[+p[1]] || 0; return (den ? (100 * (agg.sum[+p[0]] || 0) / den).toFixed(1) : "0.0") + "%"; }
    if (t === "a") return agg.days ? String(Math.round((agg.sum[+rest] || 0) / agg.days)) : "0";
    if (t === "c") return String(agg.days || 0);
    if (t === "d") return String((agg.pos && agg.pos[+rest]) || 0);
    if (t === "q") { p = rest.split("."); den = agg.sum[+p[1]] || 0; return den ? humanDur((agg.sum[+p[0]] || 0) / den) : "-"; }
    if (t === "x") { N = +rest; return humanDur(agg.max[N] > 0 ? agg.max[N] : 0); }
    if (t === "t") { p = rest.split("."); den = agg.sum[+p[1]] || 0; return den ? humanBytes((agg.sum[+p[0]] || 0) * 1000 / den) + "/s" : "-"; }
    return null;
  }
  // The NUMBER behind a recalc token — recalcCell without the formatting, so a
  // rank column can order rows on the re-aggregated value itself instead of
  // parsing "3.40 GB" back out of a cell. null = the row has no such value in
  // range (nothing timed), and never takes a position.
  function recalcNum(tok, agg, colSum) {
    var t = tok.charAt(0), rest = tok.slice(1), p, den;
    if (t === "s" || t === "h") return agg.sum[+rest] || 0;
    if (t === "%") { den = colSum[+rest] || 0; return den ? 100 * (agg.sum[+rest] || 0) / den : 0; }
    if (t === "p") { p = rest.split("."); den = agg.sum[+p[1]] || 0; return den ? 100 * (agg.sum[+p[0]] || 0) / den : 0; }
    if (t === "a") return agg.days ? (agg.sum[+rest] || 0) / agg.days : 0;
    if (t === "c") return agg.days || 0;
    if (t === "d") return (agg.pos && agg.pos[+rest]) || 0;
    if (t === "b" || t === "B") return agg.sum[+rest] || 0;
    if (t === "q") { p = rest.split("."); den = agg.sum[+p[1]] || 0; return den ? (agg.sum[+p[0]] || 0) / den : null; }
    if (t === "x") { return agg.max[+rest] > 0 ? agg.max[+rest] : 0; }
    if (t === "t") { p = rest.split("."); den = agg.sum[+p[1]] || 0; return den ? (agg.sum[+p[0]] || 0) * 1000 / den : null; }
    return null;
  }
  // Write one logical column of a row (colspans make cell index != column).
  function setColCell(tr, dcol, txt) {
    var ci, c, span = 0;
    for (ci = 0; ci < tr.cells.length; ci++) {
      c = tr.cells[ci];
      if (span === dcol) { c.textContent = txt; return; }
      span += c.colSpan || 1;
    }
  }
  // Rank columns (the Ranking report). A position is a statement about the
  // whole population, so it cannot survive a date filter unrecomputed: rN
  // renumbers this column from the RE-AGGREGATED value in column N, descending
  // (#1 = the highest); rN.a ascending (#1 = the lowest — the fastest
  // duration); rN.z descending with ZERO taking the last position, the error
  // rule (a flawless entity is not "best at failing", it is out of that race).
  // Competition ranking — equal values share a position and the next ones are
  // skipped — which is how details_lib.sh ranks them, so the full range
  // restores exactly the baked numbers. A row with no value in range (nothing
  // timed) shows "-" and is out of the population, as it is when baked.
  function rankCols(toks, drows, aggs, colSum) {
    var rc, i;
    for (rc = 0; rc < toks.length; rc++) {
      if (toks[rc].charAt(0) !== "r") continue;
      var p = toks[rc].slice(1).split("."), vc = +p[0], mode = p[1] || "", vals = [];
      drows.forEach(function (r, x) {
        if (r.style.display === "none" || !r.hasAttribute("data-buckets")) return;
        vals.push({ r: r, v: recalcNum(toks[vc] || "-", aggs[x], colSum) });
      });
      for (i = 0; i < vals.length; i++) {
        if (vals[i].v === null) { setColCell(vals[i].r, rc, "-"); continue; }
        if (mode === "z" && vals[i].v === 0) { setColCell(vals[i].r, rc, "#" + vals.length); continue; }
        var pos = 1, j;
        for (j = 0; j < vals.length; j++)
          if (vals[j].v !== null && (mode === "a" ? vals[j].v < vals[i].v : vals[j].v > vals[i].v)) pos++;
        setColCell(vals[i].r, rc, "#" + pos);
      }
    }
  }
  // Save each recalc cell's original so a widen-back-to-full-range restores exact
  // text/bar (recomputing bytes/percentages could drift by a rounding step).
  function initRecalc(table) {
    if (!table.getAttribute("data-recalc")) return;
    var rows = table.rows, i, j, tr, c;
    for (i = 0; i < rows.length; i++) {
      tr = rows[i]; if (tr.getElementsByTagName("th").length) continue;
      for (j = 0; j < tr.cells.length; j++) {
        c = tr.cells[j];
        if ((" " + c.className + " ").indexOf(" bar ") >= 0) { if (!c.hasAttribute("data-origc")) c.setAttribute("data-origc", c.className); }
        else {
          if (!c.hasAttribute("data-orig")) c.setAttribute("data-orig", c.textContent);
          // Markup cells (lines -> <br>, entity links -> <a>, mono -> <code>) lose their markup
          // if restored via textContent; remember the HTML so the restore keeps them stacked/linked.
          if (c.innerHTML !== c.textContent && !c.hasAttribute("data-html")) c.setAttribute("data-html", c.innerHTML);
          // Failed/Processed cells also remember their class so the 0->blank toggle can restore it.
          if (/ (failed|processed) /.test(" " + c.className + " ") && !c.hasAttribute("data-origc")) c.setAttribute("data-origc", c.className);
        }
      }
    }
  }
  // Rewrite one row's cells from its aggregated metrics (dcol tracks the logical
  // column across colspans). Bars need the column max; shares need the column sum.
  function writeRecalc(tr, toks, agg, colSum, colMax, colMaxA, isTot) {
    var dcol = 0, ci, c, span, tok, v, N, mx, w, oc, base, av;
    for (ci = 0; ci < tr.cells.length; ci++) {
      c = tr.cells[ci]; span = c.colSpan || 1; tok = toks[dcol] || "-";
      if (tok.charAt(0) === "b" || tok.charAt(0) === "B") {
        if ((" " + c.className + " ").indexOf(" bar ") >= 0 || c.hasAttribute("data-origc")) {
          // b<N> = bar of sum(N) vs the column max; B<N> = bar of the
          // per-day AVERAGE (sum(N)/days) vs the max average (weekday.sh's
          // Load column — day counts differ per weekday, so sums would skew)
          if (tok.charAt(0) === "B") {
            N = +tok.slice(1); mx = (colMaxA && colMaxA[N]) || 0;
            av = agg.days ? (agg.sum[N] || 0) / agg.days : 0;
            w = mx ? Math.round(av * 100 / mx) : 0;
          } else {
          N = +tok.slice(1); mx = colMax[N] || 0; w = mx ? Math.round((agg.sum[N] || 0) * 100 / mx) : 0;
          }
          w = Math.round(w / 5) * 5; if (w > 100) w = 100; c.className = "bar w" + w;
        }
      } else if (tok !== "-" && tok !== "k") {
        if (!(isTot && c.getAttribute("data-orig") === "")) {   // leave blank total cells blank
          v = recalcCell(tok, agg, colSum);
          if (v !== null) {
            oc = c.getAttribute("data-origc");
            if (oc !== null && /failed|processed|errc|okc|warn/.test(oc)) {    // tinted count kinds: a 0 -> blank + no tint (matches render_rpt's z rule; warn untints via td.warn:empty)
              base = oc.replace(/ ?\bz\b/g, "");
              if (v === "0") { c.textContent = ""; c.className = base + " z"; }
              else { c.textContent = v; c.className = base; }
            } else { c.textContent = v; }
          }
        }
      }
      dcol += span;
    }
  }
  function updateTotalLabel(tr, vis) {
    var c = tr.cells[0]; if (!c) return;
    var o = c.getAttribute("data-orig"); if (o === null) o = c.textContent;
    if (/\(\s*[\d,]+/.test(o)) c.textContent = o.replace(/\((\s*)[\d,]+/, "($1" + vis);
  }
  // Re-aggregate a whole data-recalc table for the [lo,hi] range.
  function recalcTable(table, lo, hi, narrowed) {
    var toks = (table.getAttribute("data-recalc") || "").split(/\s+/);
    var all = table.rows, i, j, tr, c;
    if (!narrowed) {                                    // full range -> restore exact originals
      for (i = 0; i < all.length; i++) {
        tr = all[i]; if (tr.getElementsByTagName("th").length) continue;
        tr.setAttribute("data-dhide", "0"); applyRowVis(tr);
        if (tr.hasAttribute("data-seen-orig")) tr.setAttribute("data-seen", tr.getAttribute("data-seen-orig"));   // seenrows tint back to full-period
        for (j = 0; j < tr.cells.length; j++) {
          c = tr.cells[j];
          if (c.hasAttribute("data-origc")) c.className = c.getAttribute("data-origc");
          if (c.hasAttribute("data-html")) c.innerHTML = c.getAttribute("data-html");   // markup cell: keep <br>/<a>/<code>
          else if (c.hasAttribute("data-orig")) c.textContent = c.getAttribute("data-orig");
        }
      }
      return;
    }
    var drows = dataRows(table), aggs = [];
    var zh = table.getAttribute("data-zerohide");
    zh = zh == null || zh === "" ? null : +zh;
    drows.forEach(function (r, x) { aggs[x] = aggBuckets(r.getAttribute("data-buckets"), lo, hi); });
    drows.forEach(function (r, x) {
      // A seenrows row (data-seen INSIDE a data-seenrows table — the detail
      // pages' entity tables) is never hidden by the date filter — its
      // green/red tint tracks the range instead. Rows carrying data-seen as
      // a plain marker (the entities All view, res-tinted) hide normally.
      if (table.getAttribute("data-seenrows") && r.hasAttribute("data-seen")) {
        if (!r.hasAttribute("data-seen-orig")) r.setAttribute("data-seen-orig", r.getAttribute("data-seen") || "0");
        r.setAttribute("data-seen", aggs[x].days > 0 ? "1" : "0");
        r.setAttribute("data-dhide", "0");
      } else {
        var hide = !(aggs[x].days > 0);
        // zerohide=<m>: a row whose metric <m> re-sums to 0 over the range
        // says nothing on this page ("Recovered 0") — hide it like a row the
        // range left without days; the full-range restore brings it back
        if (!hide && zh !== null && !(aggs[x].sum[zh] > 0)) hide = true;
        r.setAttribute("data-dhide", hide ? "1" : "0");
      }
      applyRowVis(r);
    });
    var colSum = {}, colMax = {}, colMaxA = {}, vis = 0;
    drows.forEach(function (r, x) {
      if (r.style.display === "none") return;
      var s = aggs[x].sum, m, d = aggs[x].days || 0, av;
      for (m in s) { colSum[m] = (colSum[m] || 0) + s[m]; if (colMax[m] == null || s[m] > colMax[m]) colMax[m] = s[m];
        av = d ? s[m] / d : 0; if (colMaxA[m] == null || av > colMaxA[m]) colMaxA[m] = av; }
    });
    drows.forEach(function (r, x) {
      if (r.style.display === "none") return;
      vis++;
      if (!r.hasAttribute("data-buckets") && r.hasAttribute("data-seen")) return;   // config-only row: keep its blank cells
      writeRecalc(r, toks, aggs[x], colSum, colMax, colMaxA, false);
    });
    rankCols(toks, drows, aggs, colSum);   // positions renumber over the rows the range left standing
    var totAgg = { sum: colSum, max: {}, days: 0 };
    totalRows(table).forEach(function (r) { writeRecalc(r, toks, totAgg, colSum, colMax, colMaxA, true); updateTotalLabel(r, vis); });
  }
  // ---- Show-Seen coverage tables (configured vs. observed) ------------------
  // Three complementary views of the SAME configured entity set. Every data row
  // carries data-buckets (date:rows:failed:processed) and data-seen (its
  // full-period seen flag, 1/0). "Seen" means ">=1 matching row IN THE SELECTED
  // RANGE", so narrowing the date filter re-counts the numbers AND moves
  // entities between the Seen / Not-Seen views. data-seenmode picks the view:
  //   all     — every entity, with a Seen (yes/no) column and a row tint
  //   seen    — only the entities active in range
  //   notseen — only the entities NOT active in range
  function initSeen(table) {
    dataRows(table).forEach(function (tr) {
      // remember data-seen ONLY where it exists: stamping a default "0" here
      // would make recalcTable's full-range restore INJECT data-seen onto
      // every row, turning the whole table into never-hide seenrows on the
      // next narrow (the date filter would stop hiding rows)
      if (!tr.hasAttribute("data-seen-orig") && tr.hasAttribute("data-seen"))
        tr.setAttribute("data-seen-orig", tr.getAttribute("data-seen"));
      for (var j = 0; j < tr.cells.length; j++) {
        var c = tr.cells[j];
        if (!c.hasAttribute("data-orig")) c.setAttribute("data-orig", c.textContent);
        if (c.innerHTML !== c.textContent && !c.hasAttribute("data-html")) c.setAttribute("data-html", c.innerHTML);   // keep markup on restore
        if (/ (failed|processed) /.test(" " + c.className + " ") && !c.hasAttribute("data-origc")) c.setAttribute("data-origc", c.className);
      }
    });
  }
  // The INTRO ("Seen: X of N …") sits just above the table — a p.range sibling,
  // possibly past the injected From/To + search controls; walk back to find it.
  function seenIntro(table) {
    var e = tunit(table).previousElementSibling;
    while (e) { if (e.tagName === "P" && (" " + e.className + " ").indexOf(" range ") >= 0) return e; e = e.previousElementSibling; }
    return null;
  }
  function recalcSeen(table, lo, hi, narrowed) {
    var mode = table.getAttribute("data-seenmode");
    var drows = dataRows(table), seenN = 0, total = drows.length;
    // The "all" view's Seen (yes/no) column, found by its header label — cell 1
    // on the Show Seen tables, cell 2 on Entity Search (after Type).
    var seenCol = -1, hr = headerRow(table);
    if (mode === "all" && hr) for (var h = 0; h < hr.cells.length; h++)
      if (hr.cells[h].textContent.replace(/[▲▼]/g, "").trim() === "Seen") { seenCol = h; break; }
    drows.forEach(function (tr) {
      var agg = narrowed ? aggBuckets(tr.getAttribute("data-buckets"), lo, hi) : null;
      var active = narrowed ? (agg.sum[0] || 0) > 0 : tr.getAttribute("data-seen-orig") === "1";
      if (active) seenN++;
      tr.setAttribute("data-dhide", (mode === "all" ? false : mode === "seen" ? !active : active) ? "1" : "0");
      applyRowVis(tr);
      if (mode === "all") tr.setAttribute("data-seen", active ? "1" : "0");   // row tint
      for (var j = 0; j < tr.cells.length; j++) {
        var c = tr.cells[j], cl = " " + c.className + " ";
        if (!narrowed) {                                          // full range -> restore exact originals
          if (c.hasAttribute("data-origc")) c.className = c.getAttribute("data-origc");
          if (c.hasAttribute("data-html")) c.innerHTML = c.getAttribute("data-html");   // markup cell: keep <br>/<a>/<code>
          else if (c.hasAttribute("data-orig")) c.textContent = c.getAttribute("data-orig");
          continue;
        }
        if (j === seenCol) { c.textContent = active ? "yes" : "no"; continue; }   // Seen column ("all" view only; -1 otherwise)
        var metric = cl.indexOf(" failed ") >= 0 ? 1 : cl.indexOf(" processed ") >= 0 ? 2 : cl.indexOf(" num ") >= 0 ? 0 : -1;
        if (metric < 0) continue;
        var v = agg.sum[metric] || 0;
        if (metric === 0) { c.textContent = v === 0 ? "" : String(v); continue; }   // the count column: blank when 0
        var base = (c.getAttribute("data-origc") || c.className).replace(/ ?\bz\b/g, "");   // Failed/Processed: 0 -> blank + no tint
        if (v === 0) { c.textContent = ""; c.className = base + " z"; } else { c.textContent = String(v); c.className = base; }
      }
    });
    var p = seenIntro(table), notN = total - seenN;
    // The intro noun: "configured" on the Show Seen tables (the default),
    // "entries" on Entity Search (data-seenword, from the seenword= modifier).
    var word = table.getAttribute("data-seenword") || "configured";
    if (p) p.textContent = mode === "all" ? word.charAt(0).toUpperCase() + word.slice(1) + ": " + total + "  |  Seen: " + seenN + "  |  Not seen: " + notN
      : mode === "seen" ? "Seen in the logs: " + seenN + " of " + total + " " + word
      : "Not seen in the logs: " + notN + " of " + total + " " + word;
  }

  // ---- Hour × weekday heatmap (the one 2-D per-cell table) ------------------
  // Each data cell (weekday columns 1..7 of an hour row) carries its own per-date
  // series in data-h<col-1> (date:count,…). On a date change we re-sum every cell
  // for the range, find the new busiest cell, and re-tint by quartile (heat1..4) —
  // RECALC can't do this because the tint depends on the whole grid's max.
  function initHeat(table) {
    var rows = table.rows, i, j, c;
    for (i = 0; i < rows.length; i++)
      for (j = 0; j < rows[i].cells.length; j++) {
        c = rows[i].cells[j];
        if (!c.hasAttribute("data-orig")) c.setAttribute("data-orig", c.textContent);
        if (!c.hasAttribute("data-origc")) c.setAttribute("data-origc", c.className);
      }
  }
  function recalcHeat(table, lo, hi, narrowed) {
    var drows = dataRows(table), i, w, c;
    if (!narrowed) {                                        // restore exact originals
      var all = table.rows;
      for (i = 0; i < all.length; i++)
        for (w = 0; w < all[i].cells.length; w++) {
          c = all[i].cells[w];
          if (c.hasAttribute("data-origc")) c.className = c.getAttribute("data-origc");
          if (c.hasAttribute("data-orig")) c.textContent = c.getAttribute("data-orig");
        }
      return;
    }
    var counts = [], max = 0, colTot = [];
    drows.forEach(function (r, ri) {
      counts[ri] = [];
      for (w = 0; w < 7; w++) {
        var v = aggBuckets(r.getAttribute("data-h" + w), lo, hi).sum[0] || 0;
        counts[ri][w] = v; if (v > max) max = v; colTot[w] = (colTot[w] || 0) + v;
      }
    });
    if (max < 1) max = 1;
    drows.forEach(function (r, ri) {
      for (w = 0; w < 7; w++) {
        c = r.cells[w + 1]; if (!c) continue;
        var v = counts[ri][w];
        if (v === 0) { c.textContent = ""; c.className = "num"; }
        else { var rr = v / max, t = rr <= 0.25 ? 1 : rr <= 0.5 ? 2 : rr <= 0.75 ? 3 : 4; c.textContent = String(v); c.className = "num heat" + t; }
      }
    });
    totalRows(table).forEach(function (tr) {
      for (w = 0; w < 7; w++) { c = tr.cells[w + 1]; if (c) c.textContent = String(colTot[w] || 0); }
    });
  }


  function asPlain(s) {
    if (/^-?\d{1,3}(?:\.\d{3}){1,2}$/.test(s)) return parseFloat(s.replace(/\./g, ""));   // dot-grouped integer (root tables; see parseNum)
    return /^-?[\d,]+(?:\.\d+)?$/.test(s) ? parseFloat(s.replace(/,/g, "")) : null;
  }
  function asBytes(s) {
    var m = /^([\d,]+(?:\.\d+)?)\s*(B|KB|MB|GB|TB|PB)$/i.exec(s);
    return m ? parseFloat(m[1].replace(/,/g, "")) * SIZE[m[2].toLowerCase()] : null;
  }
  // Remember each total cell's original text once, so it can be restored exactly.
  function initTotals(table) {
    totalRows(table).forEach(function (tr) {
      for (var i = 0; i < tr.cells.length; i++)
        if (!tr.cells[i].hasAttribute("data-orig")) tr.cells[i].setAttribute("data-orig", tr.cells[i].textContent);
    });
  }
  // Recompute total cells from the currently VISIBLE data rows, driven by each
  // total cell's ORIGINAL content — the report's own per-column declaration
  // (a numeric total = the author summed it, so the column is additive; a
  // BLANK total = the author declared it non-additive; anything else — an
  // average, "59 stale", "53 OK, 5 Error", a throughput — cannot be recomputed
  // client-side). Never infer summability from how the row cells happen to
  // look: that filled intentionally-blank totals and clobbered labels.
  //   label cell        cell 0 when its original is not a number/bytes/blank,
  //                     plus any cell whose original starts with "Total(s)"
  //                     (session-stats keeps its label LAST, spanning columns):
  //                     refresh the "(N …)" count and the "for/over N days"
  //                     phrase; a full-set annotation after the parens
  //                     ("Total (50 rows): 14.95 h") is dropped while filtered
  //   blank original    stays blank, always
  //   data-noagg col    "–" (distinct counts: not summable over a sub-range)
  //   data-pct col      100·Σnum/Σden over the visible rows
  //   plain number      Σ of the visible cells that parse as numbers
  //   byte size         Σ of the visible byte cells, re-humanized
  //   anything else     "–" while filtered (an all-rows figure would be false)
  // The exact original is restored whenever nothing is hidden.
  function recomputeTotals(table, force) {
    // Bucket (data-recalc) tables are re-totalled exactly by recalcTable on the
    // date-filter path, so skip them here — UNLESS forced. The search path forces
    // it (recalcTable never runs for a search), otherwise a searched summary table
    // keeps its full-dataset total above a handful of visible rows.
    if (!force && table.querySelector && table.querySelector("[data-buckets]")) return;
    var trs = totalRows(table); if (!trs.length) return;
    var drows = dataRows(table);
    var visible = drows.filter(function (r) { return r.style.display !== "none"; });
    // Entity Search builds only the matching rows (esBuild), so the rows that
    // did NOT match are absent from the DOM rather than hidden in it. Without
    // counting them the table looks unfiltered (hiddenCount 0) and the footer
    // would restore the baked full-table totals over a handful of matches.
    var hiddenCount = drows.length - visible.length + (+(table.getAttribute("data-es-omitted") || 0));
    var noagg = {}, na = (table.getAttribute("data-noagg") || "").split(",");
    for (var z = 0; z < na.length; z++) if (na[z] !== "") noagg[+na[z]] = 1;
    // Ratio columns "pctCol:numCol:denCol" recompute as 100·Σnum/Σden from the
    // visible rows (num/den must be summed columns to the LEFT of the ratio).
    var pctMap = {}, pc = (table.getAttribute("data-pct") || "").split(";"), colPlain = {};
    for (var y = 0; y < pc.length; y++) if (pc[y]) { var pt = pc[y].split(":"); pctMap[+pt[0]] = [+pt[1], +pt[2]]; }
    trs.forEach(function (tr) {
      var dataCol = 0, ci, cell, span, orig, isNum, isBytes;
      for (ci = 0; ci < tr.cells.length; ci++) {
        cell = tr.cells[ci]; span = cell.colSpan || 1;
        orig = cell.getAttribute("data-orig"); if (orig === null) orig = cell.textContent;
        isNum = asPlain(orig) !== null; isBytes = !isNum && asBytes(orig) !== null;
        // the Search page's footer label counts BOTH sides, always:
        // "N rows showed from a total of M rows" — M respects the type
        // checkboxes (setupSearchConfig stamps data-typecount per apply)
        if (ci === 0 && table.getAttribute("data-esearch") && /^Totals?\b/.test(orig)) {
          var tot5 = parseInt(table.getAttribute("data-typecount"), 10);
          if (isNaN(tot5)) tot5 = drows.length;
          cell.textContent = visible.length + " rows showed from a total of " + tot5 + " rows";
          dataCol += span; continue;
        }
        if (hiddenCount === 0) {
          cell.textContent = orig;                                   // unfiltered -> exact original
        } else if (/^Totals?\b/.test(orig) || (ci === 0 && orig !== "" && !isNum && !isBytes)) {
          var lbl = orig.replace(/\((\s*)[\d,]+/, "($1" + visible.length);           // "Total (N …)"
          lbl = lbl.replace(/\b(for|over)\s+[\d,]+\s+days?\b/,                       // "Total(s) for N day(s)" (Top view), "… over N days" (concurrency)
                            "$1 " + visible.length + (visible.length === 1 ? " day" : " days"));
          var rp = lbl.lastIndexOf(")");                             // "Total (50 rows): 14.95 h" -> drop the full-set annotation
          if (rp !== -1 && rp < lbl.length - 1) lbl = lbl.slice(0, rp + 1);
          cell.textContent = lbl;
        } else if (orig === "") {
          cell.textContent = "";                                // declared non-additive: never filled
        } else if (noagg[dataCol]) {
          cell.textContent = "–";                               // distinct count: not summable over a narrowed range
        } else if (pctMap[dataCol]) {                           // ratio: 100·Σnum/Σden over the visible rows
          var nd = pctMap[dataCol], den = colPlain[nd[1]];
          cell.textContent = (den ? (100 * ((colPlain[nd[0]]) || 0) / den).toFixed(1) : "0.0") + "%";
        } else if (isNum) {                                     // declared additive count
          var plain = 0, k, p;
          for (k = 0; k < visible.length; k++) {
            var c = visible[k].cells[dataCol]; if (!c) continue;
            p = asPlain(c.textContent.trim());
            if (p !== null) plain += p;                         // blank / "-" / text cells contribute 0
          }
          colPlain[dataCol] = plain;                            // remember for any ratio column referencing it
          cell.textContent = String(plain);
        } else if (isBytes) {                                   // declared additive volume
          var bytes = 0, k2, b;
          for (k2 = 0; k2 < visible.length; k2++) {
            var c2 = visible[k2].cells[dataCol]; if (!c2) continue;
            b = asBytes(c2.textContent.trim());
            if (b !== null) bytes += b;
          }
          cell.textContent = visible.length === 0 ? "0 B" : humanBytes(bytes);
        } else {
          cell.textContent = "–";                               // average/summary text: an all-rows figure would be false here
        }
        dataCol += span;
      }
    });
  }

  // A table can respond to the date filter only if it carries a date dimension:
  // a re-aggregatable data-buckets row, or at least one parseable date cell
  // (per-day tables, and First/Last columns on the summary tables). Aggregate
  // tables (by protocol, by direction, remote hosts, ciphers, ...) have neither,
  // so a narrowed range leaves their all-period numbers unchanged — which reads
  // as "filtered" unless we say otherwise.
  function isDateAware(table) {
    if (table.dateAware != null) return table.dateAware;   // structural; cache it
    if (table.getAttribute("data-nofilter")) { table.dateAware = false; return false; }   // full-period by design -> show the badge when narrowed
    if (table.getAttribute("data-recalc") || table.getAttribute("data-heat")) { table.dateAware = true; return true; }
    var rows = dataRows(table), i, j, res = false;
    for (i = 0; i < rows.length && !res; i++) {
      if (rows[i].getAttribute("data-buckets") !== null) { res = true; break; }
      for (j = 0; j < rows[i].cells.length; j++)
        if (parseDate(rows[i].cells[j].textContent.trim()) !== null) { res = true; break; }
    }
    table.dateAware = res;
    return res;
  }
  // A row is visible only if none of the date filter (data-dhide), the search
  // box (data-shide) or Entity Search's view/type filter (data-vhide) has
  // hidden it.
  function applyRowVis(tr) {
    tr.style.display = (tr.getAttribute("data-dhide") === "1" || tr.getAttribute("data-shide") === "1" || tr.getAttribute("data-vhide") === "1" || tr.getAttribute("data-fhide") === "1") ? "none" : "";
  }

  // ---- Entity Search: the collapsed "Search configuration" panel ------------
  // The search table (data-esearch, one page) gets a <details> panel at the
  // top holding (a) the All / Seen / Not seen view and (b) one checkbox per
  // entity type — both filter rows client-side via data-vhide, no separate
  // view pages. All types default ON. The
  // "IP" box covers both IP row types (resolved-host aliases and whitelisted
  // IPs). Rows only appear once a search term is typed (start-empty), the
  // configuration just narrows what a search may match.
  // The search-syntax hint shown below the search box on Entity Search AND on
  // the ordinary report pages (setupSearch) — one source of truth.
  var SEARCH_HINT = "Wildcards: ? = 1 character, * = 0..n characters. A space means AND; operators: and / or / not";
  function setupSearchConfig() {
    var table = document.querySelector("table[data-esearch]");
    if (!table) return;
    // The panel's checkboxes filter the Type column and its view toggle the
    // seen flags — both Entity Search concepts. A second esearch page exists
    // since 2026-08 (File search: Name/Date/Subscription/State/Size/CoreId),
    // where the panel filtered nothing: build it only when the table actually
    // HAS a Type header, and stamp data-escfg so the zero-results hint knows.
    var hasType = false, hr = table.tHead ? table.tHead.rows[0] : table.rows[0];
    if (hr) for (var hi = 0; hi < hr.cells.length; hi++)
      if (hr.cells[hi].textContent.trim() === "Type") { hasType = true; break; }
    if (!hasType) return;
    table.setAttribute("data-escfg", "1");
    // Every type box starts OFF; with NO box checked the search covers EVERY
    // kind — a checked box narrows to the checked kinds only.
    var TYPES = [
      { label: "Logical",      types: ["Logical"],                     on: false },
      { label: "Partner",      types: ["Partner"],                     on: false },
      { label: "Subscription", types: ["Subscription"],                on: false },
      { label: "Account",      types: ["Account"],                     on: false },
      { label: "Host",         types: ["Remote Host"],                 on: false },
      { label: "Login",        types: ["Login"],                       on: false },
      { label: "Application",  types: ["Application"],                 on: false },
      { label: "Domain",       types: ["Domain"],                      on: false },
      { label: "IP",           types: ["Remote Host (IP)", "Whitelist"], on: false },
      { label: "Source",       types: ["Source"],                      on: false },
      { label: "Target",       types: ["Target"],                      on: false }
    ];
    // Array order IS the button order — nothing keys off the index (the filter
    // map is keyed by TYPE NAME and each box closes over its own entry), so a
    // reorder here is purely presentational.
    // The selection PERSISTS per page (sessionStorage, the search's own key
    // family) and is RECONCILED with the DOM on pageshow: a browser Back that
    // reloads the page restores the checkboxes' checked state (form
    // restoration) WITHOUT firing change, so this closure state — and the
    // results — silently ignored what the boxes visibly showed (2026-08).
    try {
      var est = sessionStorage.getItem("estypes:" + searchStoreKey());
      if (est !== null) {
        est = est ? est.split("\x1f") : [];
        TYPES.forEach(function (t) { t.on = est.indexOf(t.label) >= 0; });
      }
    } catch (e) {}
    function saveTypes() {
      try {
        var on = [];
        TYPES.forEach(function (t) { if (t.on) on.push(t.label); });
        sessionStorage.setItem("estypes:" + searchStoreKey(), on.join("\x1f"));
      } catch (e) {}
    }
    var typeOn = {}, anyOn = false;
    function refreshMap() {
      anyOn = false;
      TYPES.forEach(function (t) { if (t.on) anyOn = true; t.types.forEach(function (ty) { typeOn[ty] = t.on; }); });
    }
    // The only filter is the TYPE one: every row of the checked kinds shows,
    // whatever its seen-ness (the row colour already carries that). Every
    // column stays visible.
    function apply() {
      closeDetails(table);   // a filter change tears down any open Source/Target expansion
      dataRows(table).forEach(function (tr) {
        var ty = tr.cells[2] ? tr.cells[2].textContent.trim() : "";   // col 0 Name, col 1 Direction, col 2 Type
        var hide = anyOn ? !typeOn[ty] : false;   // all boxes off = every kind
        tr.setAttribute("data-vhide", hide ? "1" : "0");
        applyRowVis(tr);
      });
      // "N rows showed from a total of M": M is every entity of the selected
      // KINDS, not just the ones the current query built — so it is counted
      // over the whole data set (esTypes), never over the rows in the DOM.
      var elig = 0, all = esTypes();
      if (all) { for (var i = 0; i < all.length; i++) if (!anyOn || typeOn[all[i]]) elig++; }
      else dataRows(table).forEach(function (tr) {
        if (!anyOn || typeOn[esTypeOf(tr)]) elig++;
      });
      table.setAttribute("data-typecount", String(elig));   // the footer's "total of M rows"
      recomputeTotals(table, true);
      updateEmptyState(table);
    }
    // esBuild replaces the tbody on every query, so the freshly built rows
    // carry no data-vhide yet — it re-runs this to re-apply the type filter.
    table.esApplyTypes = apply;
    // The controls sit OPEN at the top of the page, stacked vertically and
    // left-aligned: the type checkboxes (Partner .. Target) first, then the
    // SEARCH INPUT (adopted from the div.controls setupSearch built earlier —
    // setupSearchConfig runs after it — its "Search this page" placeholder
    // dropped on this page) on its OWN line, with the syntax hint on the line
    // below it.
    var box = document.createElement("div");
    box.className = "searchcfg";
    var srow = document.createElement("p"); srow.className = "essearch";
    var ctr = document.querySelector("div.controls");
    if (ctr) {
      while (ctr.firstChild) srow.appendChild(ctr.firstChild);
      if (ctr.parentNode) ctr.parentNode.removeChild(ctr);
      var inp = srow.querySelector("input.search");
      if (inp) { inp.placeholder = ""; }
    }
    var hint = document.createElement("span"); hint.className = "searchhint";
    hint.textContent = SEARCH_HINT;
    var row = document.createElement("div"); row.className = "cfgtypes";
    TYPES.forEach(function (t) {
      var lab = document.createElement("label");
      var cb = document.createElement("input"); cb.type = "checkbox"; cb.checked = t.on;
      t.cb = cb;   // the reconcile below reads the LIVE checkbox state
      cb.addEventListener("change", function () { t.on = cb.checked; refreshMap(); saveTypes(); apply(); });
      lab.appendChild(cb); lab.appendChild(document.createTextNode(t.label));
      row.appendChild(lab);
    });
    // Adopt whatever the boxes VISIBLY show into the closure state — the fix
    // for the form-restoration mismatch above. Deferred a tick past pageshow
    // because the browser applies the restored form state around load, after
    // this (deferred) script already ran; pageshow fires on a bfcache return
    // too, where this is a harmless no-op (the closure survived with the DOM).
    function reconcileTypes() {
      var changed = false;
      TYPES.forEach(function (t) { if (t.cb && t.cb.checked !== t.on) { t.on = t.cb.checked; changed = true; } });
      if (changed) { refreshMap(); saveTypes(); apply(); }
    }
    window.addEventListener("pageshow", function () { setTimeout(reconcileTypes, 0); });
    // Row 1: the type checkboxes, flush left.
    var cline = document.createElement("div"); cline.className = "cfgline";
    cline.appendChild(row);
    box.appendChild(cline);
    box.appendChild(srow);  // row 2: the search input, alone on its line
    var hrow = document.createElement("p"); hrow.className = "essearchhint";
    hrow.appendChild(hint); // row 4: the syntax hint, on its OWN line below the box
    box.appendChild(hrow);
    // insert AFTER the page's intro paragraph(s) (p.range follows the h1 in
    // the static HTML), so the intro text stays right below the title
    var h1 = document.getElementsByTagName("h1")[0];
    if (h1 && h1.parentNode) {
      var anchor = h1, nx = h1.nextElementSibling;
      while (nx && nx.tagName === "P" && (" " + nx.className + " ").indexOf(" range ") >= 0) { anchor = nx; nx = nx.nextElementSibling; }
      h1.parentNode.insertBefore(box, anchor.nextSibling);
    }
    refreshMap(); apply();   // the defaults take effect immediately
    // put the cursor in the search field on load (Entity Search is search-first)
    var sfocus = box.querySelector("input.search");
    if (sfocus) sfocus.focus();
  }

  // ---- The Report finder (docs/<env>/report-finder.html) -------------------
  // A static catalog table (data-rfinder) + its own search box (#rfq): the
  // query matches each report's TITLE (data-t) and INTRO (data-i) with the
  // site search grammar (wildcards ? and *, or/and/not); TITLE matches rank
  // ABOVE intro-only matches, both keeping their catalog order. An empty
  // query shows the full catalog in the original order.
  function setupReportFinder() {
    var table = document.querySelector("table[data-rfinder]"); if (!table) return;
    var box = document.getElementById("rfq"); if (!box) return;
    var orig = dataRows(table);
    // the page's FILE NAME is searchable too (e.g. "went-kaput" finds the
    // "Trouble after Success" report): index each row's link href once —
    // ranked with the keyword hits, below title hits
    orig.forEach(function (r) {
      var a0 = r.cells[0] && r.cells[0].getElementsByTagName("a")[0];
      r.setAttribute("data-f", ((a0 && a0.getAttribute("href")) || "").toLowerCase());
    });
    function hits(groups, text) {
      return groups.some(function (g) {
        return g.every(function (term) {
          var f = term.m(text);
          return term.neg ? !f : f;
        });
      });
    }
    function apply() {
      var q = foldSep(box.value.toLowerCase().replace(/^\s+|\s+$/g, ""));
      var groups = q ? parseQuery(q) : null;
      if (groups && !groups.length) groups = null;
      var body = table.tBodies[0] || table;
      if (!groups) {
        orig.forEach(function (r) { r.style.display = ""; body.appendChild(r); });
        return;
      }
      var tHits = [], iHits = [];
      orig.forEach(function (r) {
        var t = foldSep(r.getAttribute("data-t") || "");
        var i2 = foldSep(r.getAttribute("data-i") || "");
        var k = foldSep(r.getAttribute("data-k") || "");
        var f = foldSep(r.getAttribute("data-f") || "");
        if (hits(groups, t)) { tHits.push(r); r.style.display = ""; }
        else if (hits(groups, t + " " + i2 + " " + k + " " + f)) { iHits.push(r); r.style.display = ""; }
        else r.style.display = "none";
      });
      tHits.concat(iHits).forEach(function (r) { body.appendChild(r); });
    }
    box.addEventListener("input", apply);
  }

  // Detail pages only: hide a section whose every data row is hidden (e.g. by
  // the search or date filter) — table plus its title, if any — and hide a
  // table with no data rows at all. Idempotent; re-run after any visibility
  // change so a table reappears when its rows do (e.g. a search is cleared).
  // NOTE: nothing here filters by entity name — blacklist/skip filtering is
  // done entirely at parse time; report.js has no client-side blacklist net
  // and must not gain one (CLAUDE.md).
  // DETAIL pages: a sticky header — the page <h1> plus one anchor tab per
  // section — pinned under the fixed top bar while scrolling. Labels come
  // from each section's <h2> (the long ones shortened) or, for the
  // title-less dimension tables, the table's first column header. Anchor
  // targets get a scroll margin so a jump lands clear of the pinned header.
  function setupSectionTabs() {
    if (location.pathname.indexOf("/details/") < 0) return;
    var h1 = document.getElementsByTagName("h1")[0];
    if (!h1) return;
    var SHORT = { "Activity per day": "Day", "Activity per week": "Week",
                  "Load by hour": "Hour", "Load by weekday": "Weekday",
                  "Latest 100 Files": "Latest 100", "Whitelisted IPs": "Whitelist",
                  "Last server log messages": "Server log",
                  "Last 25 log lines": "Log lines",
                  "Last 10 server log lines": "Server log" };
    // a SIDE-BY-SIDE row (div.sxs) gets ONE combined button — labeled by the
    // row's FIRST visible table, mapped to a row name (fallback: that table's
    // own short label)
    var ROWLABEL = { "Load by weekday": "Load", "Load by hour": "Load",
                     "Incoming connections": "Connections", "Outgoing connections": "Connections",
                     "Dwell": "Statistics", "Duration": "Statistics",
                     "Domain": "Groups", "Application": "Groups" };
    function sxsOf(el) {
      while (el && el !== document.body) {
        if ((" " + (el.className || "") + " ").indexOf(" sxs ") >= 0) return el;
        el = el.parentNode;
      }
      return null;
    }
    var tables = document.getElementsByTagName("table"), i, made = 0;
    var bar = document.createElement("p");
    bar.className = "tabs sectabs";
    var targets = [], seenSxs = [];
    for (i = 0; i < tables.length; i++) {
      var u = tunit(tables[i]);
      if (u.style.display === "none") continue;            // empty section, hidden
      var prev = u.previousElementSibling, label = "", target = u;
      if (prev && prev.tagName === "H2") { label = prev.textContent.trim(); target = prev; }
      if (!label) {
        var hr0 = headerRow(tables[i]);
        label = hr0 && hr0.cells[0] ? hr0.cells[0].textContent.replace(/[▲▼]/g, "").trim() : "";
        // the Subscription table leads with a Direction column — name its
        // button after the table's subject, not the first column
        if (label === "Direction" && hr0.cells[1] &&
            hr0.cells[1].textContent.replace(/[▲▼]/g, "").trim() === "Subscription") label = "Subscriptions";
      }
      if (!label) continue;
      var sxs = sxsOf(u);
      if (sxs) {
        if (seenSxs.indexOf(sxs) >= 0) continue;           // one button per side-by-side row
        seenSxs.push(sxs);
        label = ROWLABEL[label] || SHORT[label] || label;
        target = sxs;
      }
      if (!target.id) target.id = "sec" + (i + 1);
      var a = document.createElement("a");
      a.className = "tab";
      a.href = "#" + target.id;
      a.textContent = sxs ? label : (SHORT[label] || label);
      bar.appendChild(a);
      targets.push(target);
      made++;
    }
    if (made <= 1) return;   // a single section (e.g. a never-seen subscription's lone Summary) needs no tab bar
    var head = document.createElement("div");
    head.className = "detailhead";
    h1.parentNode.insertBefore(head, h1);
    head.appendChild(h1);
    head.appendChild(bar);
    // the header is position:fixed (out of flow): a spacer holds its place in
    // the page, and anchor jumps must land below the pinned bars (top bar +
    // this header); both re-measure on resize (the tab bar wraps)
    var spacer = document.createElement("div");
    head.parentNode.insertBefore(spacer, head.nextSibling);
    function sizeHead() {
      var tb = document.querySelector(".topbar");
      // pin FLUSH under the top bar (the CSS 3.2rem fallback leaves a thin
      // gap where content scrolls visibly through)
      if (tb) head.style.top = tb.offsetHeight + "px";
      spacer.style.height = head.offsetHeight + "px";
      var off = ((tb ? tb.offsetHeight : 0) + head.offsetHeight + 10) + "px";
      for (var j = 0; j < targets.length; j++) targets[j].style.scrollMarginTop = off;
    }
    sizeHead();
    window.addEventListener("resize", sizeHead);
  }

  function hideEmptyTables() {
    if (location.pathname.indexOf("/details/") < 0) return;
    var tables = document.getElementsByTagName("table"), t, k;
    for (t = 0; t < tables.length; t++) {
      var rows = dataRows(tables[t]), any = false;
      for (k = 0; k < rows.length; k++) if (rows[k].style.display !== "none") { any = true; break; }
      if (!any && tables[t].querySelector("tr.foldrow")) any = true;   // an all-folded table is not empty — its summary row shows
      var u = tunit(tables[t]);
      u.style.display = any ? "" : "none";                    // hide the whole scroll box
      var prev = u.previousElementSibling;
      if (prev && prev.tagName === "H2") prev.style.display = any ? "" : "none";
    }
  }

  // Expandable drill-down: a clickable element (a whole row, or a single Error /
  // OK cell) inserts a full-width detail row under its row listing the
  // "date time  coreid" entries, one open at a time. Duplicate Files and Dwell
  // Time use a row-level list (data-coreids); Arrived/Left uses per-cell lists
  // (data-coreids-failed / data-coreids-processed on the row, bound to the
  // matching cell). The detail rows are excluded from dataRows and torn down
  // before any sort/filter/search.
  function closeDetails(table) {
    var d = table.getElementsByClassName("coreid-detail"), ex;
    while (d.length) d[0].parentNode.removeChild(d[0]);
    ex = table.getElementsByClassName("expanded");
    while (ex.length) ex[0].classList.remove("expanded");
  }
  function closeAllDetails() {
    var tables = document.getElementsByTagName("table"), i;
    for (i = 0; i < tables.length; i++) closeDetails(tables[i]);
  }
  // Bind a click on `el` (row or cell) to toggle a detail row under `row`,
  // listing `list` (split on `sep`, default ","); `noun` (""/"Error"/
  // "OK") tags the head and `unit` names the entries (default
  // "File"; physical-leg tables pass "transfer"; the server reports pass
  // "log line" with a \x1f separator, since log messages contain commas).
  function bindDrill(el, row, table, list, noun, sep, unit) {
    el.classList.add("expandable");
    el.addEventListener("click", function (ev) {
      // a link inside the element (the ↗ detail-page icon, a date link)
      // NAVIGATES — it never toggles the drill
      var tgt = ev.target;
      while (tgt && tgt !== el) { if (tgt.tagName === "A") return; tgt = tgt.parentNode; }
      ev.stopPropagation();
      var wasOpen = el.classList.contains("expanded");
      closeDetails(table);                          // collapse whatever was open first
      if (wasOpen) return;
      var entries = list.split(sep || ",");
      var td = document.createElement("td");
      td.colSpan = row.cells.length;
      td.className = "coreid-cell";
      var h = document.createElement("div");
      h.className = "coreid-head";
      h.textContent = "Last " + entries.length + " " + (noun ? noun + " " : "") +
        (unit || "File") + (entries.length === 1 ? "" : "s") +
        (curRange && curRange.narrowed ? " (full period, not the selected range)" : "") + ":";
      td.appendChild(h);
      entries.forEach(function (e) {
        var line = document.createElement("div");
        line.className = "coreid-item";
        line.textContent = e;                       // "ccyy-mm-dd hh:mm:ss.mmm  <coreid>" / "ccyy-mm-dd  <message>"
        td.appendChild(line);
      });
      var dtr = document.createElement("tr");
      dtr.className = "coreid-detail";
      dtr.appendChild(td);
      row.parentNode.insertBefore(dtr, row.nextSibling);
      el.classList.add("expanded");
    });
  }
  function setupExpandable(table) {
    var du = table.getAttribute("data-drill-unit") || undefined; // per-table entry noun (default "File"; physical tables pass "transfer")
    dataRows(table).forEach(function (tr) {
      var whole = tr.getAttribute("data-coreids");
      if (whole) bindDrill(tr, tr, table, whole, "");           // patterns: whole-row list
      var lines = tr.getAttribute("data-loglines");             // server reports: last-10 raw log lines
      if (lines) bindDrill(tr, tr, table, lines, "", "\u001F", "log line");
      var cf = tr.getAttribute("data-coreids-failed");
      var cp = tr.getAttribute("data-coreids-processed");
      if (cf || cp) {                                           // per-outcome cell lists
        var failedCells = [], processedCells = [];
        for (var i = 0; i < tr.cells.length; i++) {
          var cls = " " + tr.cells[i].className + " ";
          if (cls.indexOf(" z ") >= 0) continue;                // blank 0-value cell: not clickable
          if (cls.indexOf(" failed ") >= 0)    failedCells.push(tr.cells[i]);
          if (cls.indexOf(" processed ") >= 0) processedCells.push(tr.cells[i]);
        }
        // Bind only when the outcome maps to ONE cell. A both-direction row has
        // two Error (and two OK) cells sharing one COMBINED list that can't be
        // attributed to a direction — leave those unbound rather than drill the
        // In-Error cell to Out-direction files. (When only one direction has
        // failures the other is a blank z cell, so the single survivor is right.)
        if (cf && failedCells.length === 1)    bindDrill(failedCells[0], tr, table, cf, "Error", null, du);
        if (cp && processedCells.length === 1) bindDrill(processedCells[0], tr, table, cp, "OK", null, du);
      }
      var dcol = tr.getAttribute("data-drill-col");             // session-topview: drill on one named column
      var dlist = tr.getAttribute("data-drill-list");
      if (dcol !== null && dlist && tr.cells[+dcol]) bindDrill(tr.cells[+dcol], tr, table, dlist, "", null, du);
      // Per-cell drill lists (duration.sh's Duration per day table): EVERY cell
      // carries data-drill-cell-<i> = its own \x1f-separated "files nearest this
      // value" list, bound to cell i.
      for (var dci = 0; dci < tr.cells.length; dci++) {
        var dcl = tr.getAttribute("data-drill-cell-" + dci);
        if (dcl) bindDrill(tr.cells[dci], tr, table, dcl, "", "\u001F", du);
      }
      // (the former data-srv Server-log drill is gone: the server-log mentions
      // live on the not-seen detail pages' "Last 10 server log lines" table)
    });
  }

  // Entity Search: a Source/Target PATH used by more than one subscription is
  // collapsed by the report into ONE aggregate row "<path> (N)" whose
  // Files/Error/OK are the SUM across the N subscriptions. The row carries
  // data-subrows = per-subscription entries ("<sub>|<href>|<files>|<err>|<ok>|
  // <res>|<lastseen>", \x1f-joined); clicking it expands one row per subscription, each
  // showing THAT subscription's own counts and linking to its detail page
  // (so closed = all subscriptions, open = per subscription). The injected
  // rows reuse the coreid-detail class, so closeDetails tears them down before
  // any sort/search/view change and dataRows never counts/sorts/searches them
  // (one group open at a time, like the other drills).
  function setupSubrows(table) {
    dataRows(table).forEach(function (tr) {
      var payload = tr.getAttribute("data-subrows");
      if (!payload) return;
      tr.classList.add("expandable");
      tr.addEventListener("click", function (ev) {
        var t = ev.target;
        while (t && t !== tr) { if (t.tagName === "A") return; t = t.parentNode; }  // a link inside navigates
        ev.stopPropagation();
        var wasOpen = tr.classList.contains("expanded");
        closeDetails(table);                          // collapse whatever was open first
        if (wasOpen) return;
        var dir  = tr.cells[1] ? tr.cells[1].textContent : "";
        var type = tr.cells[2] ? tr.cells[2].textContent : "";
        var anchor = tr;
        payload.split("\u001F").forEach(function (e) {
          var f = e.split("|");                       // subname, href, files, err, ok, res, lastseen
          var dtr = document.createElement("tr");
          dtr.className = "coreid-detail subrow";
          if (f[5]) dtr.setAttribute("data-res", f[5]);
          function cell(cls, txt) { var td = document.createElement("td"); if (cls) td.className = cls; if (txt != null) td.textContent = txt; return td; }
          var name = cell("subname", null);
          if (f[1]) { var a = document.createElement("a"); a.href = f[1]; a.textContent = f[0]; name.appendChild(a); }
          else name.textContent = f[0];
          // columns: Name · Direction · Type · Error · OK · Last seen (Files
          // removed; payload still carries f[2]=files, unused here). Direction
          // and Type are the PARENT row's: every subscription under one path
          // shares them, and an aggregate whose members disagree already shows
          // a blank Direction. Last seen is the SUBSCRIPTION's own stamp.
          var cells = [name, cell("", dir), cell("", type), cell("num failed", f[3]), cell("num processed", f[4]), cell("", f[6] || "")];
          cells.forEach(function (td, i) {
            if (tr.cells[i]) td.style.display = tr.cells[i].style.display;   // match the current column-hide state
            dtr.appendChild(td);
          });
          anchor.parentNode.insertBefore(dtr, anchor.nextSibling);
          anchor = dtr;
        });
        tr.classList.add("expanded");
      });
    });
  }

  // Collapsible multi-line cells (KIND clines — the patterns report's Pattern
  // and Last 10 files columns): the renderer emits a 3+-line cell collapsed to
  // its first and last line with an ellipsis between (span.ce; the middle
  // lines sit CSS-hidden in span.cm). Clicking the cell toggles `open` on the
  // td (style.css swaps the two spans). One delegated listener suffices —
  // recalc restores rewrite the cell's innerHTML, never replace the td, and
  // the open/collapsed state lives on the td's class.
  function setupCollapsible() {
    document.addEventListener("click", function (e) {
      var n = e.target;
      while (n && n !== document && n.tagName !== "TD") {
        if (n.tagName === "A") return;             // a link click navigates, never toggles
        n = n.parentNode;
      }
      if (!n || n === document || n.tagName !== "TD") return;
      if ((" " + n.className + " ").indexOf(" clps ") < 0) return;
      n.classList.toggle("open");
    });
  }

  // Foldable result rows (TABLE modifier fold=<res>|<label> -> data-fold; the
  // detail pages' Incoming IPs table): at load, every data row whose data-res
  // equals <res> hides (data-fhide) behind ONE injected full-width summary row
  // carrying <label> ({n} = the folded count; "IPs" degrades to "IP" for 1).
  // Clicking the summary row toggles the folded rows. The row sits as the
  // LAST row of the table (after the last data row), carries the same
  // data-res tint, and is excluded from dataRows so sorts/filters/totals
  // never move or count it.
  function setupRowFold(table) {
    var spec = table.getAttribute("data-fold");
    if (!spec) return;
    var all = dataRows(table);
    // NO size threshold (2026-07): the no-traffic rows ALWAYS fold behind the
    // summary row, however small the table — the user opens them on demand.
    var p = spec.indexOf("|");
    var res = p < 0 ? spec : spec.slice(0, p);
    var label = p < 0 ? "{n} folded rows" : spec.slice(p + 1);
    var rows = all.filter(function (r) { return r.getAttribute("data-res") === res; });
    if (!rows.length) return;
    var txt = label.replace("{n}", rows.length);
    if (rows.length === 1) txt = txt.replace("IPs", "IP");
    var tr = document.createElement("tr");
    tr.className = "foldrow";
    tr.setAttribute("data-res", res);
    var td = document.createElement("td");
    var hr = headerRow(table);
    td.colSpan = hr ? hr.cells.length : rows[0].cells.length;
    tr.appendChild(td);
    var open = false;
    function paint() {
      td.textContent = (open ? "▾ " : "▸ ") + txt;
      rows.forEach(function (r) { r.setAttribute("data-fhide", open ? "0" : "1"); applyRowVis(r); });
    }
    var all = dataRows(table), last = all[all.length - 1];
    last.parentNode.insertBefore(tr, last.nextSibling);
    paint();
    tr.addEventListener("click", function () { open = !open; paint(); });
  }

  // Show/hide a one-line "not adjusted by the date filter" note above a table.
  function markUnfiltered(table, show) {
    var note = table.filterNote;
    if (!note) {
      if (!show) return;
      note = document.createElement("p");
      note.className = "filter-note";
      note.textContent = "⚠ The date filter does not adjust this table; values cover the full period.";
      // Put the note INSIDE the wrapper (above the table) so hideEmptyTables hides
      // it together with the table (no orphan note) and still finds the section's
      // <h2> as the wrapper's previousElementSibling. Falls back to before an
      // unwrapped table.
      var u = tunit(table);
      if (u !== table) u.insertBefore(note, u.firstChild); else u.parentNode.insertBefore(note, u);
      table.filterNote = note;
    }
    note.style.display = show ? "" : "none";
  }

  // Sort key for a text cell: lowercased with "_" folded onto "-", so the two
  // separator spellings of a name sort as neighbours. Used by sortTable only —
  // it is an ORDERING rule, never an identity one (matching and linking still
  // use the raw name).
  function sepFold(s) { return s.toLowerCase().replace(/_/g, "-"); }

  function sortTable(table, col, dir) {
    closeDetails(table);                 // drop drill-down rows so they don't get orphaned
    var rows = dataRows(table);
    ungroup(table);
    // Ordinal label columns (size/duration/dwell buckets): every row carries
    // data-ord (emitted by the report) — sort column 0 by that ordinal, so
    // "1 KB - 10 KB" never lands between "1 MB" and "10 MB" lexically.
    var useOrd = col === 0 && rows.length > 0;
    if (useOrd) for (var oi = 0; oi < rows.length; oi++)
      if (rows[oi].getAttribute("data-ord") === null) { useOrd = false; break; }
    var numeric = 0, seen = 0;
    rows.forEach(function (tr) {
      var c = tr.cells[col]; if (!c) return;
      if (numKey(c) !== null) { numeric++; seen++; }   // a number (a 0-blanked "z" cell is 0)
      else if (c.textContent.trim() !== "") seen++;    // genuine non-numeric text
      // an EMPTY non-z cell is ABSENT, not text — excluded so it cannot drag the
      // numeric ratio below half. Without this, a view with many blank cells (the
      // Entities "all" pages: not-seen rows have no Volume / % of Files) misreads
      // those columns as text and sorts "3.01 GB" before "540.66 MB".
    });
    var asNum = seen > 0 && numeric >= seen / 2;
    rows.sort(function (a, b) {
      if (useOrd) {
        var oa = +a.getAttribute("data-ord"), ob = +b.getAttribute("data-ord");
        return dir * (oa < ob ? -1 : oa > ob ? 1 : 0);
      }
      var ca = a.cells[col], cb = b.cells[col];
      var sa = ca ? ca.textContent.trim() : "", sb = cb ? cb.textContent.trim() : "", r;
      if (asNum) {
        var ka = numKey(ca), kb = numKey(cb);     // 0-blanked -> 0; other non-numeric -> null
        if (ka === null && kb === null) r = 0;
        else if (ka === null) return 1;           // genuine non-numeric sinks last, BOTH directions
        else if (kb === null) return -1;
        else r = ka < kb ? -1 : ka > kb ? 1 : 0;
      } else {
        // A TEXT column sorts with "-" and "_" treated as the SAME character.
        // The two spellings of one name (FRE-SAPCD-FLANDERIJN /
        // FRE_SAPCD_FLANDERIJN) are DIFFERENT entities — separator folding is
        // never an identity rule here, see CLAUDE.md — but they belong next to
        // each other in a sorted list. Raw ASCII puts "-" (0x2D) before every
        // digit and "_" (0x5F) after every capital, so today the twins land
        // pages apart with unrelated names ("FREDDY") between them.
        var la = sepFold(sa), lb = sepFold(sb);
        r = la < lb ? -1 : la > lb ? 1 : 0;
        // Tie-break on the RAW value so two names differing only by separator
        // still have a defined, stable order instead of comparing equal.
        if (r === 0) {
          var ra = sa.toLowerCase(), rb = sb.toLowerCase();
          r = ra < rb ? -1 : ra > rb ? 1 : 0;
        }
      }
      return dir * r;
    });
    var body = table.tBodies[0] || table;
    if (table.getAttribute("data-total-top") === "1") {
      totalRows(table).forEach(function (tr) { body.appendChild(tr); }); // pinned first
      rows.forEach(function (tr) { body.appendChild(tr); });
    } else {
      rows.forEach(function (tr) { body.appendChild(tr); });
      totalRows(table).forEach(function (tr) { body.appendChild(tr); }); // keep totals last
    }
    repositionFoldrow(table);         // the fold summary sits after the (re-ordered) data rows
    applyGroup(table);   // re-blank repeats in the new order
    repositionPairs(table);           // keep each message row above its (re-ordered) data row
    repage(table);                    // a sort reshuffles the pages
  }

  // The fold summary row ("N folded rows") is excluded from dataRows/totalRows,
  // so any re-append (sort, reset) leaves it stranded at the TOP of the tbody:
  // move it back after the last data row, before the totals.
  function repositionFoldrow(table) {
    var fr = table.querySelector("tr.foldrow");
    if (!fr) return;
    var body = table.tBodies[0] || table;
    var tots = totalRows(table);
    if (tots.length && table.getAttribute("data-total-top") !== "1") body.insertBefore(fr, tots[0]);
    else body.appendChild(fr);
  }

  // Remember each table's sort (column + asc/desc) for the browsing session.
  // The table part of the key is the first header label plus its position
  // among same-labeled tables on the page.
  // Page identity: "<dir>/<report key or basename>", so one report's pages
  // share their remembered sort and search, while different reports never
  // bleed into each other.
  // The active ENVIRONMENT segment of this page's path ("acceptance" /
  // "production"), or "" on the shared root pages (home, build report). Both
  // env trees serve the same page names, so every sessionStorage key that
  // identifies a page or area must carry this to keep the envs apart.
  function pageEnv() {
    var m = location.pathname.match(/\/(acceptance|production)\//);
    return m ? m[1] : "";
  }
  function pageKeyBase() {
    var segs = location.pathname.split("/").filter(Boolean);
    var pdir = segs.length > 1 ? segs[segs.length - 2] : "";
    // Env prefix: /acceptance/transfer/x.html and /production/transfer/x.html
    // must never share a sort/search store.
    var env = pageEnv();
    if (env) pdir = env + ":" + pdir;
    // Report pages carry a report-key meta: the SAME key on every page of one
    // report — all its table-tab pages (All/Seen/Not Seen, Summary/Detail, …)
    // — so the search text and sort survive tab switches.
    var mk = document.querySelector('meta[name="report-key"]');
    if (mk && mk.getAttribute("content")) return pdir + "/" + mk.getAttribute("content");
    // Fallback (detail pages, older pages): the page basename.
    var base = (segs.length ? segs[segs.length - 1] : "index").replace(/\.html$/, "");
    return pdir + "/" + base;
  }
  function sortStoreKey(table) {
    var hr = headerRow(table);
    var label = hr && hr.cells[0] ? hr.cells[0].textContent.replace(/[▲▼]/g, "").trim() : "";
    var tables = document.getElementsByTagName("table"), n = 0;
    for (var i = 0; i < tables.length; i++) {
      if (tables[i] === table) break;
      var h2 = headerRow(tables[i]);
      if (h2 && h2.cells[0] && h2.cells[0].textContent.replace(/[▲▼]/g, "").trim() === label) n++;
    }
    return "sort:" + pageKeyBase() + ":" + label + ":" + n;
  }
  function saveSort(table, col, dir) { try { sessionStorage.setItem(sortStoreKey(table), col + ":" + dir); } catch (e) {} }
  function loadSort(table)           { try { return sessionStorage.getItem(sortStoreKey(table)); } catch (e) { return null; } }

  // ---- Transfer > Entities: ONE shared sort, an hour long ------------------
  // The seven Entities reports are one catalog seen through seven entities, so
  // a sort made on Accounts must still be in force on Logins. Those pages
  // therefore do NOT use the per-report store above (its key carries the
  // report-key meta, which is the entity name — a different key per entity):
  // they share a single entry.
  //
  // Stored by COLUMN LABEL, never by index: the Partner views carry an extra
  // Direction column, so index 2 is Files there and Error everywhere else.
  // Column 0 is the entity name, whose label differs per entity (Account /
  // Login / Partner …), so it is stored as the sentinel "#name". A label that
  // does not exist on the page being opened (Volume, when landing on a
  // name-only Not seen view) resolves to nothing and that page keeps its own
  // default.
  //
  // localStorage, not sessionStorage — the lifetime is a 1-hour SLIDING
  // expiry, not the tab's: every Entities page view renews the hour (init and
  // the bfcache pageshow), and an hour with no such view drops the entry, so
  // the pages fall back to their own default (Files descending).
  var ENT_TTL = 3600000;   // 1 hour, in ms
  function isEntitiesPage() { return location.pathname.indexOf("/transfer/entities/") >= 0; }
  function entKey()  { var e = pageEnv(); return "axway-entities-sort" + (e ? ":" + e : ""); }
  function entLabel(th) { return th ? th.textContent.replace(/[▲▼]/g, "").trim() : ""; }
  function entLoad() {
    try {
      var raw = localStorage.getItem(entKey()); if (!raw) return null;
      var v = JSON.parse(raw);
      if (!v || typeof v.c !== "string" || !v.t) return null;
      if (Date.now() - v.t > ENT_TTL) { localStorage.removeItem(entKey()); return null; }
      return v;
    } catch (e) { return null; }
  }
  function entSave(col, dir, ths) {
    var lbl = col === 0 ? "#name" : entLabel(ths[col]);
    if (!lbl) return;
    try { localStorage.setItem(entKey(), JSON.stringify({ c: lbl, d: dir === -1 ? -1 : 1, t: Date.now() })); } catch (e) {}
  }
  // Slide the hour: called on every Entities page view, whether or not the
  // remembered column applies to the view being opened.
  function entTouch() {
    if (!isEntitiesPage()) return;
    var v = entLoad(); if (!v) return;
    v.t = Date.now();
    try { localStorage.setItem(entKey(), JSON.stringify(v)); } catch (e) {}
  }
  function entResolve(v, ths) {   // stored label -> this page's column index, or -1
    if (!v) return -1;
    if (v.c === "#name") return 0;
    for (var i = 0; i < ths.length; i++) if (entLabel(ths[i]) === v.c) return i;
    return -1;
  }
  // ?axway_sort=COL[:DIR] (the detail pages' Ranking links): sort the page's
  // FIRST sortable table on that 0-based column at load — DIR 1/-1, default
  // the column's own first-click direction (a #rank column opens ascending) —
  // overriding the remembered sort and persisting like a user click (the
  // ?axway_search pattern).
  var urlSort = null, urlSortDone = false;
  (function () {
    var m = /[?&]axway_sort=(\d+)(?::(-?1))?/.exec(window.location.search || "");
    if (m) urlSort = { col: parseInt(m[1], 10), dir: m[2] ? parseInt(m[2], 10) : 0 };
  })();
  // ?axway_row=NAME (the detail pages' Ranking rows): mark that entity's own
  // row, page the table to it and scroll it into view, so a click on "#12"
  // lands on the line it names with its neighbours around it. It also makes
  // the page open at the FULL range (see setupDateFilter): the position that
  // was clicked is a full-period figure, and a remembered range carried over
  // from another report would answer with a different number than the link
  // promised. The user's stored range is only skipped, never overwritten.
  var urlRow = null;
  (function () {
    var m = /[?&]axway_row=([^&]*)/.exec(window.location.search || "");
    if (m) { try { urlRow = decodeURIComponent(m[1].replace(/\+/g, " ")); } catch (e) { urlRow = m[1]; } }
  })();
  // A page whose <body> carries the sort-fresh class (analyses/accounts.html,
  // cronjobs.html, use-cases.html) never remembers sorting: every load starts
  // at the generated order.
  var SORT_FRESH = (" " + (document.body.className || "") + " ").indexOf(" sort-fresh ") >= 0;

  function makeSortable(table) {
    if (table.getAttribute("data-nosort") === "1") return;   // e.g. paired 2-row entries that must not be reordered
    var hr = headerRow(table); if (!hr) return;
    var ths = hr.cells;
    var origOrder = dataRows(table);      // .rpt order (colFirstDir samples it)
    function applySort(col, dir) {
      table.setAttribute("data-sort-col", String(col));
      table.setAttribute("data-sort-dir", String(dir));
      sortTable(table, col, dir);
      var arrows = hr.getElementsByClassName("arrow");
      for (var j = 0; j < arrows.length; j++) arrows[j].textContent = "";
      var a = ths[col].getElementsByClassName("arrow");
      if (a[0]) a[0].textContent = dir > 0 ? " ▲" : " ▼";
    }
    // (the former third-click "back to the original order" reset was REMOVED
    // 2026-07 — clicks now just toggle between the two directions)
    // First-click direction of a column: NUMERIC columns (counts, sizes,
    // percentages, durations, dates) open DESCENDING — the big/new end first —
    // EXCEPT #rank columns ("#1" is the top and must lead, so ascending).
    // Text columns open ascending. Decided from the first non-blank cell.
    function colFirstDir(col) {
      // Entity Search builds its rows on demand, so at init origOrder is EMPTY
      // and this could not tell a count column from a text one — the first
      // click on Error sorted ascending instead of "biggest first". Sample the
      // rows that are actually in the table when the header is clicked.
      var sample = origOrder.length ? origOrder : dataRows(table);
      for (var i = 0; i < sample.length; i++) {   // no row cap: a count column whose top rows are all blank zeros (logon's No account) must still be detected numeric
        var c = sample[i].cells[col]; if (!c) break;
        var t = c.textContent.trim();
        if (t === "" || t === "-") {
          // a zero-blanked count cell (class z) IS numeric — decide right here
          if ((" " + c.className + " ").indexOf(" z ") >= 0) return -1;
          continue;
        }
        if (/^#\d+$/.test(t)) return 1;          // rank: #1 first
        return numKey(c) !== null ? -1 : 1;
      }
      return 1;
    }
    var row0 = origOrder[0];
    for (var i = 0; i < ths.length; i++) {
      (function (col, th) {
        // A bar column has nothing sortable to show — no header affordance.
        // Neither has a .sp spacer column (the root index's group gaps).
        var c0 = row0 && row0.cells[col];
        if (c0 && ((" " + c0.className + " ").indexOf(" bar ") >= 0 ||
                   (" " + c0.className + " ").indexOf(" sp ") >= 0)) return;
        th.className += (th.className ? " " : "") + "sortable";
        var arrow = document.createElement("span");
        arrow.className = "arrow";
        th.appendChild(arrow);
        th.addEventListener("click", function () {
          var same = table.getAttribute("data-sort-col") === String(col);
          var f = colFirstDir(col);   // first-dir, then TOGGLE (no reset state)
          var cur = same ? table.getAttribute("data-sort-dir") : null;
          var dir = (same && cur === String(f)) ? -f : f;
          applySort(col, dir);
          // Entities pages write the SHARED hour-long entry instead of the
          // per-report one, so the pick carries to the next entity.
          if (isEntitiesPage()) entSave(col, dir, ths);
          else if (!SORT_FRESH) saveSort(table, col, dir);   // survives unit switches + page revisits this session
        });
      })(i, ths[i]);
    }
    // Optional initial sort: data-sort-init="col:dir" (dir 1 asc, -1 desc).
    var init = table.getAttribute("data-sort-init");
    if (init) {
      var p = init.split(":"), col = parseInt(p[0], 10), dir = parseInt(p[1], 10) || 1;
      if (col >= 0 && col < ths.length) applySort(col, dir);
    } else {
      // GENERIC DEFAULT: a table whose report gives no sort of its own
      // (no sort= TABLE modifier) and whose FIRST column holds dates opens
      // NEWEST-FIRST — descending on that date column. Detection over the
      // first few rows: at least one first cell parses as a date and none is
      // anything else (blank and "-" placeholders don't disqualify). Like
      // data-sort-init this is a page default, not a user choice: it is not
      // persisted, and the header toggle still works (the date column's
      // first-dir IS descending, so a click sorts ascending, the next back).
      var dd = 0, di, dc, dt;
      for (di = 0; di < origOrder.length && di < 5; di++) {
        dc = origOrder[di].cells[0]; if (!dc) { dd = 0; break; }
        dt = dc.textContent.trim();
        if (dt === "" || dt === "-") continue;
        if (parseDate(dt) === null) { dd = 0; break; }
        dd++;
      }
      if (dd > 0) applySort(0, -1);
    }
    // ?axway_sort beats everything on the page's FIRST sortable table and
    // persists like a user click; else a sort the user made earlier this
    // session (possibly on another unit variant of this page) wins over the
    // page's default.
    if (urlSort && !urlSortDone && urlSort.col >= 0 && urlSort.col < ths.length) {
      urlSortDone = true;
      var udir = urlSort.dir || colFirstDir(urlSort.col);
      applySort(urlSort.col, udir);
      if (!SORT_FRESH) saveSort(table, urlSort.col, udir);
      return;
    }
    // Entities pages: the shared hour-long entry REPLACES the per-report one
    // (one catalog, seven entities — see entLoad above). An entry whose column
    // this view does not have leaves the page on its own default.
    if (isEntitiesPage()) {
      var ev = entLoad(), ecol = entResolve(ev, ths);
      if (ecol >= 0 && ecol < ths.length) applySort(ecol, ev.d);
      return;
    }
    var stored = SORT_FRESH ? null : loadSort(table);
    if (stored) {
      var sp = stored.split(":"), scol = parseInt(sp[0], 10), sdir = parseInt(sp[1], 10) || 1;
      if (scol >= 0 && scol < ths.length) applySort(scol, sdir);
    }
  }

  // ---- client-side pagination (data-pager=N: the detail pages' Activity ----
  // per day table, TABLE modifier pager=30). Pager-hidden rows get a CSS
  // class (tr.pghide), NOT an inline display — so totals, recalc and the
  // empty state still count them: the pager is pure presentation layered on
  // the filter-visible set. Re-run by every path that changes visibility or
  // order (search, date filter, seen tabs, sorting).
  function repage(table) {
    if (!table.pagerNav) return;
    var N = parseInt(table.getAttribute("data-pager"), 10) || 10;
    closeDetails(table);                       // an open drill must not straddle pages
    var vis = dataRows(table).filter(function (r) { return r.style.display !== "none"; });
    var pages = Math.max(1, Math.ceil(vis.length / N));
    if (table.pagerPage == null || table.pagerPage < 1) table.pagerPage = 1;
    if (table.pagerPage > pages) table.pagerPage = pages;
    var lo = (table.pagerPage - 1) * N, hi = lo + N, i;
    dataRows(table).forEach(function (r) { r.classList.remove("pghide"); });
    for (i = 0; i < vis.length; i++) if (i < lo || i >= hi) vis[i].classList.add("pghide");
    var nav = table.pagerNav;
    nav.row.style.display = vis.length > N ? "" : "none";
    nav.pgInfo.textContent = "Page " + table.pagerPage + " of " + pages;
    nav.pgPrev.className = "tab" + (table.pagerPage <= 1 ? " disabled" : "");
    nav.pgNext.className = "tab" + (table.pagerPage >= pages ? " disabled" : "");
  }
  // ?axway_row=NAME: find the row whose FIRST cell is that entity, mark it
  // (.rowmark — an outline, so it reads on top of the restint row tints),
  // turn the pager to the page holding it and scroll it into view. Runs last,
  // after sorting, the date filter and the pager have settled the order. No
  // match (a name that is not ranked) leaves the page untouched.
  function markUrlRow() {
    if (!urlRow) return;
    var tables = document.getElementsByTagName("table"), t, rows, i, c, hit = null, tbl = null;
    for (t = 0; t < tables.length && !hit; t++) {
      rows = dataRows(tables[t]);
      for (i = 0; i < rows.length; i++) {
        c = rows[i].cells[0];
        if (c && c.textContent.trim() === urlRow) { hit = rows[i]; tbl = tables[t]; break; }
      }
    }
    if (!hit) return;
    hit.className = hit.className ? hit.className + " rowmark" : "rowmark";
    if (tbl.pagerNav) {
      var N = parseInt(tbl.getAttribute("data-pager"), 10) || 10;
      var vis = dataRows(tbl).filter(function (r) { return r.style.display !== "none"; }), idx = -1;
      for (i = 0; i < vis.length; i++) if (vis[i] === hit) { idx = i; break; }
      if (idx >= 0) { tbl.pagerPage = Math.floor(idx / N) + 1; repage(tbl); }
    }
    if (hit.scrollIntoView) hit.scrollIntoView({ block: "center" });
  }
  function setupPager() {
    var tables = document.getElementsByTagName("table"), t;
    for (t = 0; t < tables.length; t++) (function (table) {
      if (!table.getAttribute("data-pager")) return;
      // the pager is PART of the table: a <tfoot> row spanning every column
      // (browsers render tfoot last no matter how the tbody is reordered, so
      // sorting/re-appending rows never displaces it), with its own tint
      var hr = headerRow(table);
      var ncols = hr ? hr.cells.length : 1;
      var prev = document.createElement("span"); prev.textContent = "\u2039 Previous";
      var info = document.createElement("span"); info.className = "pagerinfo";
      var next = document.createElement("span"); next.textContent = "Next \u203a";
      prev.addEventListener("click", function () { if (table.pagerPage > 1) { table.pagerPage--; repage(table); } });
      next.addEventListener("click", function () { table.pagerPage++; repage(table); });
      var bar = document.createElement("div"); bar.className = "pagerbar";
      bar.appendChild(prev); bar.appendChild(info); bar.appendChild(next);
      var td = document.createElement("td"); td.colSpan = ncols; td.appendChild(bar);
      var tr = document.createElement("tr"); tr.className = "pagerrow"; tr.appendChild(td);
      var tf = document.createElement("tfoot"); tf.appendChild(tr);
      table.appendChild(tf);
      table.pagerNav = { row: tr, pgPrev: prev, pgNext: next, pgInfo: info };
      repage(table);
    })(tables[t]);
  }

  // The date range currently applied by the From/To filter, kept module-wide so
  // the search path can re-aggregate a data-recalc table for the SAME range
  // (a cleared search must not resurrect full-period values into a narrowed
  // table). null until the filter first applies; narrowed=false at full range.
  var curRange = null;
  // Date-path hook set by setupSearch() when the page has a search box:
  // a date change rewrites cell text, so an active
  // search must be re-evaluated against the NEW text — otherwise a row stays
  // hidden although its recalculated values now match (or stays visible after
  // they stop matching). Called with pre=true BEFORE the re-aggregation to
  // lift the search dimension (recalcTable rewrites only VISIBLE rows — a
  // search-hidden row would keep stale text and be matched against it), then
  // without arguments AFTER it to re-filter. No-op while the box is empty.
  var searchReapply = null;

  function setupDateFilter() {
    // The date list comes from a per-page <meta name="report-dates"> injected by
    // build.sh. The From/To selectors appear only when the page has at least
    // one DATE-AWARE table: on a page with none (stale-accounts — its one
    // table is data-nofilter; av-scan-blocked when its only row is the
    // placeholder) the controls would change nothing locally, yet a selection
    // made there was SAVED to the shared per-area range and silently narrowed
    // every other page. Zero date-aware tables -> no controls, no restore of
    // the stored range, nothing persisted, no badge.
    var meta = document.querySelector('meta[name="report-dates"]');
    var content = meta ? meta.getAttribute("content") : "";
    var dates = (content ? content.split(",") : []).filter(Boolean);
    if (!dates.length) return;
    // Days whose collection window ended mid-day (report-partial, from
    // publish_lib's area_partial): the exports are a snapshot, so the newest
    // day usually stops at the pull time. The Week/Month presets end at the last FULL
    // day — counting a half day would quietly make it six and a bit.
    var pmeta = document.querySelector('meta[name="report-partial"]');
    var partial = {}, pl = (pmeta ? pmeta.getAttribute("content") : "").split(",");
    for (var pj = 0; pj < pl.length; pj++) if (pl[pj]) partial[pl[pj]] = 1;
    var tabs0 = document.getElementsByTagName("table"), anyAware = false, ti;
    for (ti = 0; ti < tabs0.length && !anyAware; ti++) if (isDateAware(tabs0[ti])) anyAware = true;
    // slotchart pages (the dashboards) are date-aware too: the charts clip to
    // the range via the slotchartSetRange hook below (2026-08)
    if (!anyAware && document.querySelector(".slotchart")) anyAware = true;
    if (!anyAware) return;

    var epochOf = {};
    dates.forEach(function (d) { var e = parseDate(d); if (e !== null) epochOf[d] = e; });
    dates = dates.filter(function (d) { return epochOf[d] != null; })
                 .sort(function (a, b) { return epochOf[a] - epochOf[b]; });
    if (!dates.length) return;

    function mkSelect(sel) {
      // options NEWEST FIRST (the dates array itself stays ascending — the
      // range math is value-based; only the selectedIndex checks mind this)
      for (var di = dates.length - 1; di >= 0; di--) {
        var o = document.createElement("option");
        o.value = String(epochOf[dates[di]]); o.textContent = dates[di];
        sel.appendChild(o);
      }
    }
    var from = document.createElement("select"), to = document.createElement("select");
    mkSelect(from); mkSelect(to);
    from.selectedIndex = dates.length - 1; to.selectedIndex = 0;   // full range: oldest From, newest To

    // Persist the From/To selection across pages: keyed by AREA (the
    // report-area meta publish emits), so all transfer pages share one setting
    // and all server pages another — deterministically, not just while the two
    // calendars happen to coincide. restoreSel() validates the stored values
    // against this page's option list, so a changed dataset degrades to the
    // full range instead of misapplying. Falls back to the old content key on
    // pages without the meta.
    var ameta = document.querySelector('meta[name="report-area"]');
    var storeKey = "datefilter:" + ((ameta && ameta.getAttribute("content")) || content);
    // Top view dashboards always load at the full range AND keep any narrowing
    // page-local — so they neither restore nor SAVE the shared From/To (saving
    // would leak a transient dashboard range onto every normal page).
    var resetDates = !!document.querySelector("[data-date-reset]");
    function saveSel() {
      if (resetDates) return;
      try { sessionStorage.setItem(storeKey, from.value + " " + to.value); } catch (e) {}
    }
    function restoreSel() {           // -> true when a narrowed range was restored
      var v = null, p, i, okF = false, okT = false;
      try { v = sessionStorage.getItem(storeKey); } catch (e) {}
      if (!v) return false;
      p = v.split(" ");
      if (p.length !== 2) return false;
      for (i = 0; i < from.options.length; i++) if (from.options[i].value === p[0]) okF = true;
      for (i = 0; i < to.options.length; i++) if (to.options[i].value === p[1]) okT = true;
      if (!okF || !okT) return false;
      from.value = p[0]; to.value = p[1];
      return from.selectedIndex < dates.length - 1 || to.selectedIndex > 0;
    }

    var DAY = 86400000;
    // seed the shared range with the full span, so updateTotalVis knows a
    // one-data-day page is single-day even before any apply() runs
    curRange = { lo: epochOf[dates[0]], hi: epochOf[dates[dates.length - 1]] + DAY - 1, narrowed: false };
    function apply(src) {
      closeAllDetails();                 // drill-down rows are full-period; drop them on any date change
      var loMid = +from.value, hiMid = +to.value;
      if (loMid > hiMid) {
        // An impossible range is resolved by moving the control the user did
        // NOT touch: dragging From past To pulls To forward, dragging To
        // before From pulls From backward. Programmatic calls (no src — the
        // load-time restore) keep the From-wins snap.
        if (src === "to") { loMid = hiMid; from.value = to.value; }
        else { hiMid = loMid; to.value = from.value; }
      }
      saveSel();
      var lo = loMid, hi = hiMid + DAY - 1;
      var narrowed = from.selectedIndex < dates.length - 1 || to.selectedIndex > 0;
      curRange = { lo: lo, hi: hi, narrowed: narrowed };
      // the slotchart hook (the dashboards): hand the range over as DATE
      // STRINGS — the slots carry ISO dates, so a lexical clip is exact; the
      // stash covers the load order (slotchart may init after this runs)
      var _fO = from.options[from.selectedIndex], _tO = to.options[to.selectedIndex];
      window._slotRange = { from: _fO ? _fO.textContent : null, to: _tO ? _tO.textContent : null, narrowed: narrowed };
      if (window.slotchartSetRange) window.slotchartSetRange(window._slotRange.from, window._slotRange.to, narrowed);
      if (window.daytopSetRange) window.daytopSetRange(window._slotRange.from, window._slotRange.to, narrowed);
      if (searchReapply) searchReapply(true);   // lift an active search so the recalc below rewrites EVERY row
      var tables = document.getElementsByTagName("table"), t, ri, tr, rows, i, e, mn, mx;
      for (t = 0; t < tables.length; t++) {
        if (tables[t].getAttribute("data-nofilter")) continue;   // full-period table: never hide rows (the badge says so)
        if (tables[t].getAttribute("data-topsel")) { recalcTopsel(tables[t], lo, hi, narrowed); continue; }
        if (tables[t].getAttribute("data-seenmode")) { recalcSeen(tables[t], lo, hi, narrowed); continue; }
        if (tables[t].getAttribute("data-heat")) { recalcHeat(tables[t], lo, hi, narrowed); continue; }
        if (tables[t].getAttribute("data-recalc")) { recalcTable(tables[t], lo, hi, narrowed); continue; }
        rows = tables[t].rows;                                          // date-cell tables: show/hide rows by their date span
        for (ri = 0; ri < rows.length; ri++) {
          tr = rows[ri];
          if (tr.getElementsByTagName("th").length) continue;           // header
          if ((" " + tr.className + " ").indexOf(" total ") >= 0) continue;  // total
          mn = null; mx = null;
          for (i = 0; i < tr.cells.length; i++) {
            e = parseDate(tr.cells[i].textContent.trim());
            if (e !== null) { if (mn === null || e < mn) mn = e; if (mx === null || e > mx) mx = e; }
          }
          tr.setAttribute("data-dhide", (mn === null || (mn <= hi && mx >= lo)) ? "0" : "1"); applyRowVis(tr);
        }
      }
      recalcStats(lo, hi, narrowed);   // the date-aware STAT boxes (data-tok)
      // the period tags on table headings (the period= TABLE modifier): show
      // the selected range, restore the baked full-period text at the full one
      var h2ps = document.querySelectorAll("h2 .h2period"), hpi, hpe;
      for (hpi = 0; hpi < h2ps.length; hpi++) {
        hpe = h2ps[hpi];
        if (!hpe.hasAttribute("data-orig")) hpe.setAttribute("data-orig", hpe.textContent);
        hpe.textContent = narrowed
          ? ("— " + (window._slotRange.from === window._slotRange.to ? window._slotRange.from
                                                                     : window._slotRange.from + " to " + window._slotRange.to))
          : hpe.getAttribute("data-orig");
      }
      if (searchReapply) searchReapply();   // re-evaluate the active search against the recalculated text
      for (t = 0; t < tables.length; t++) if (!tables[t].getAttribute("data-recalc") && !tables[t].getAttribute("data-heat")) recomputeTotals(tables[t]);   // recalcHeat owns their totals
      for (t = 0; t < tables.length; t++) {                             // an active sort must hold on the re-aggregated values
        var sc = tables[t].getAttribute("data-sort-col");
        if (sc !== null) sortTable(tables[t], parseInt(sc, 10), parseInt(tables[t].getAttribute("data-sort-dir"), 10) || 1);
      }
      for (t = 0; t < tables.length; t++) applyGroup(tables[t]);        // re-blank on the visible set
      for (t = 0; t < tables.length; t++) markUnfiltered(tables[t], narrowed && !isDateAware(tables[t]));
      for (t = 0; t < tables.length; t++) updateEmptyState(tables[t]);
      for (t = 0; t < tables.length; t++) repage(tables[t]);
      hideEmptyTables();
    }
    from.addEventListener("change", function () { apply("from"); });
    to.addEventListener("change", function () { apply("to"); });
    // ?axway_date=YYYY-MM-DD (the day pages' links): open narrowed to that
    // single day. An explicit link beats both the remembered range and
    // data-date-reset, and persists like a user selection (apply() saves it),
    // so follow-up pages in the area keep the day.
    // ?axway_date=YYYY-MM-DD..YYYY-MM-DD (the Overview's See-more links,
    // 2026-08): a RANGE. Each bound snaps to the page's own date list — From
    // up to the first data day inside, To down to the last — so a bound that
    // is not a data day here still lands on the same period; a range with no
    // data days at all is ignored (full range).
    var um = /[?&]axway_date=([0-9]{4}-[0-9]{2}-[0-9]{2})(?:\.\.([0-9]{4}-[0-9]{2}-[0-9]{2}))?/.exec(window.location.search);
    var urlLo = null, urlHi = null;
    if (um && !um[2]) {
      if (epochOf[um[1]] != null) { urlLo = epochOf[um[1]]; urlHi = urlLo; }
    } else if (um) {
      var eLo = parseDate(um[1]), eHi = parseDate(um[2]), i2;
      if (eLo != null && eHi != null && eLo <= eHi) {
        for (i2 = 0; i2 < dates.length; i2++) if (epochOf[dates[i2]] >= eLo) { urlLo = epochOf[dates[i2]]; break; }
        for (i2 = dates.length - 1; i2 >= 0; i2--) if (epochOf[dates[i2]] <= eHi) { urlHi = epochOf[dates[i2]]; break; }
        if (urlLo == null || urlHi == null || urlLo > urlHi) { urlLo = null; urlHi = null; }
      }
    }
    var urlDay = urlLo != null;
    // Carry a narrowed range across pages — unless this page opts to always load
    // at the full range (data-date-reset, the Top view dashboards). The From/To
    // still work; a change from here on persists as usual.
    // Show-Seen pages must ALSO run apply() at load even with no saved range: the
    // seen/not-seen partitioning (recalcSeen, inside apply()) is what hides the
    // not-seen rows on the Seen tab (and vice-versa) — without this they'd all show.
    if (urlDay) {
      from.value = String(urlLo);
      to.value = String(urlHi);
      apply();
    } else if ((!resetDates && !urlRow && restoreSel()) || document.querySelector("table[data-seenmode]")) apply();

    // DASHBOARDS MODE (2026-08): on the dashboards the controls lead the
    // page — right under the title, before the KPI row — because EVERYTHING
    // below follows the range: the KPI cards re-sum, the graph clips, the
    // Top-5 tables re-select. The FULL button set renders (Last day and
    // Previous/Next day included — a single-day pick shows that day's slots
    // and re-selects the Top 5 for it). Until 2026-08 the wrap joined the
    // hero card's own .chartbtns row and dropped the day buttons.
    var _dfArea = document.querySelector('meta[name="report-area"]');
    var dashHero = !!(_dfArea && /-dashboards$/.test(_dfArea.getAttribute("content") || "") &&
                      document.querySelector(".dash-grid .chartbtns"));
    var wrap = document.createElement("div");
    wrap.className = "controls";
    var l1 = document.createElement("label"); l1.textContent = "From";
    var l2 = document.createElement("label"); l2.textContent = "To";
    wrap.appendChild(l1); wrap.appendChild(from);
    wrap.appendChild(l2); wrap.appendChild(to);

    // Quick-range buttons next to the From/To pulldowns. They set the two selects
    // and apply like a manual change (persisted across the area by apply()'s
    // saveSel). Reset = the full range; Last day = the last FULL data day;
    // Week / Month = the last 7 / 30 calendar days of FULL days — all three
    // end on the last full day, a partial newest day never counts (2026-08,
    // Week/Month replacing "Last 7 days"). Dates are DATA days, so every value
    // set is a real option (an arbitrary calendar epoch could select nothing).
    var newest = epochOf[dates[dates.length - 1]], oldest = epochOf[dates[0]];
    function setRange(f, tv) { from.value = String(f); to.value = String(tv); apply(); }
    function mkRangeBtn(label, fn) {
      var b = document.createElement("button");
      b.type = "button"; b.className = "daterange"; b.textContent = label;
      b.addEventListener("click", fn);
      return b;
    }
    // Each preset knows the range it would set, so a preset whose range is
    // ALREADY selected is grayed out — the same "nothing to do" affordance the
    // Previous/Next day buttons have (2026-08). Ranges are recomputed on every
    // update rather than cached: the data days are fixed, but keeping it a
    // function means one definition serves both the click and the disable test.
    var presets = [];
    function mkPresetBtn(label, targetFn, bold, covFn) {
      var b = mkRangeBtn(label, function () { var r = targetFn(); setRange(r[0], r[1]); });
      presets.push({ b: b, t: targetFn, bold: !!bold, cov: covFn || null });
      return b;
    }
    // the newest day the collection window covers COMPLETELY (all days partial
    // — a one-day window pulled mid-day — falls back to the newest day, so the
    // preset still selects something)
    function newestFull() {
      var i;
      for (i = dates.length - 1; i >= 0; i--) if (!partial[dates[i]]) return epochOf[dates[i]];
      return newest;
    }
    // "All" = the full range (renamed from "Reset", 2026-08); bold when
    // active like the period presets
    wrap.appendChild(mkPresetBtn("All", function () { return [oldest, newest]; }, true));
    // A span preset only exists as a CHOICE when the data actually reaches
    // back that far: on a short estate its From clamps to the first data day,
    // so its range collapses into what All (or First day) already selects and
    // the button could never show as the chosen one. Those are grayed out —
    // the same "nothing to do" affordance the Previous/Next day buttons have.
    function mkSpanBtn(label, days) {
      var b = mkPresetBtn(label, function () {
        var end = newestFull(), lo = end - (days - 1) * DAY, fd = dates[0], i;
        for (i = 0; i < dates.length; i++) if (epochOf[dates[i]] >= lo) { fd = dates[i]; break; }
        return [epochOf[fd], end];
      }, true, function () { return newestFull() - (days - 1) * DAY >= oldest; });
      if (newestFull() !== newest) b.title = "The " + days + " days ending on the last full day — the newest day's collection window stopped mid-day, so it does not count";
      return b;
    }
    wrap.appendChild(mkSpanBtn("Week", 7));
    wrap.appendChild(mkSpanBtn("4 weeks", 28));
    // Month = one CALENDAR month back from the end day, not a fixed 30 days
    // (2026-08): the previous month's same day-of-month + 1 through the last
    // full day — ending 08-20 it starts 07-21; a day the shorter previous
    // month lacks clamps to that month's last day.
    function monthStartStr() {
      var end = newestFull(), es = "", i;
      for (i = 0; i < dates.length; i++) if (epochOf[dates[i]] === end) { es = dates[i]; break; }
      var y = +es.slice(0, 4), m = +es.slice(5, 7) - 1, d = +es.slice(8, 10) + 1;
      if (m < 1) { m = 12; y -= 1; }
      var dim = new Date(Date.UTC(y, m, 0)).getUTCDate();   // days in 1-based month m
      if (d > dim) d = dim;
      return y + "-" + (m < 10 ? "0" : "") + m + "-" + (d < 10 ? "0" : "") + d;
    }
    var bmo = mkPresetBtn("Month", function () {
      var end = newestFull(), ss = monthStartStr(), fd = dates[0], i;
      for (i = 0; i < dates.length; i++) if (dates[i] >= ss) { fd = dates[i]; break; }
      return [epochOf[fd], end];
    }, true, function () { return monthStartStr() >= dates[0]; });
    if (newestFull() !== newest) bmo.title = "One month back from the last full day — the newest day's collection window stopped mid-day, so it does not count";
    wrap.appendChild(bmo);
    // First day = the OLDEST data day; Last day = the NEWEST data day — the
    // really-last one, partial or not (2026-08; only Week/4 weeks/Month skip
    // a partial newest day)
    wrap.appendChild(mkPresetBtn("First day", function () { return [oldest, oldest]; }, true));
    wrap.appendChild(mkPresetBtn("Last day", function () { return [newest, newest]; }, true));
    // Previous/Next day: step a SINGLE-DAY selection (From == To) through the
    // data-day list. Grayed out when the current range is not one day, or no
    // adjacent data day exists in that direction.
    function dayIdx(ep) { var i; for (i = 0; i < dates.length; i++) if (epochOf[dates[i]] === ep) return i; return -1; }
    var prevBtn = mkRangeBtn("Previous day", function () {
      var i = dayIdx(parseInt(from.value, 10));
      if (from.value === to.value && i > 0) setRange(epochOf[dates[i - 1]], epochOf[dates[i - 1]]);
    });
    var nextBtn = mkRangeBtn("Next day", function () {
      var i = dayIdx(parseInt(from.value, 10));
      if (from.value === to.value && i >= 0 && i < dates.length - 1) setRange(epochOf[dates[i + 1]], epochOf[dates[i + 1]]);
    });
    function updateStepBtns() {
      var single = from.value === to.value, i = single ? dayIdx(parseInt(from.value, 10)) : -1;
      prevBtn.disabled = !(single && i > 0);
      nextBtn.disabled = !(single && i >= 0 && i < dates.length - 1);
      // a preset whose range IS the current selection goes BOLD and stays
      // clickable (a re-apply is a no-op) — All / Week / 4 weeks / Month /
      // Last day alike; the non-bold branch remains for any future preset
      // that prefers the grayed disable
      var cf = parseInt(from.value, 10), ct = parseInt(to.value, 10), pi, p, tr, on;
      for (pi = 0; pi < presets.length; pi++) {
        p = presets[pi];
        if (p.t0 == null) p.t0 = p.b.title || "";   // stash the built-time tooltip once
        // a span preset whose window reaches past the first data day (see
        // mkSpanBtn) is grayed — it could only re-select what All or First
        // day already give, so it can never show as the chosen range
        if (p.cov && !p.cov()) {
          // the period is not in the data at all: the button is HIDDEN, not
          // grayed (2026-08 — a choice that can never apply is not a choice)
          p.b.style.display = "none";
          continue;
        }
        p.b.style.display = "";
        tr = p.t();
        on = (cf === tr[0] && ct === tr[1]);
        if (p.bold) {
          p.b.disabled = false;
          p.b.className = "daterange" + (on ? " active" : "");
          p.b.title = p.t0;
        } else p.b.disabled = on;
      }
    }
    wrap.appendChild(prevBtn); wrap.appendChild(nextBtn);
    var applyBase = setRange;
    setRange = function (f, tv) { applyBase(f, tv); updateStepBtns(); };
    from.addEventListener("change", updateStepBtns);
    to.addEventListener("change", updateStepBtns);
    updateStepBtns();

    // Insert the From/To controls before the first content block — the first
    // <h2> OR the first table's wrapper, whichever comes FIRST in the document.
    // Many pages open with an untitled table (empty TABLE heading) whose first
    // <h2> belongs to a later section; anchoring on the h2 alone would drop the
    // date controls mid-page.
    var t0 = document.getElementsByTagName("table")[0];
    var h0 = document.getElementsByTagName("h2")[0];
    var w0 = t0 && tunit(t0);
    var anchor = (h0 && w0) ? ((h0.compareDocumentPosition(w0) & 2) ? w0 : h0) : (h0 || w0);
    // The dashboards have NEITHER at init time — their tables are built later
    // by slotchart.js — so anchor on the first chart card instead (its section
    // wrapper, so the controls sit above the card grid, not inside a card).
    if (!anchor) {
      var sc0 = document.querySelector(".slotchart");
      // hoist all the way to the card GRID: inserted inside it the controls
      // become a grid CELL wedged between two cards — above it they sit
      // under the H1 like on every report page
      if (sc0) anchor = (sc0.closest && (sc0.closest(".dash-grid") || sc0.closest("section.card"))) || sc0;
    }
    // If that anchor sits inside a side-by-side (.sxs) block, hoist to the block:
    // otherwise the controls land inside ONE column and shove its title down,
    // misaligning it against the other column's title.
    if (anchor && anchor.closest) { var sx = anchor.closest(".sxs"); if (sx) anchor = sx; }
    // A baked tab row carrying class "undertabs" (the Failed Subscriptions view
    // switches) belongs BELOW the From/To controls: hoist the anchor back
    // over it, so the controls insert above the row rather than between it
    // and its table.
    while (anchor && anchor.previousElementSibling && anchor.previousElementSibling.tagName === "P" &&
           (" " + anchor.previousElementSibling.className + " ").indexOf(" undertabs ") >= 0)
      anchor = anchor.previousElementSibling;
    if (dashHero) {
      // above everything the range drives — before the KPI row (fallback:
      // the card grid)
      var _dk = document.querySelector("main.dash .kpi-row") || document.querySelector(".dash-grid");
      if (_dk && _dk.parentNode) _dk.parentNode.insertBefore(wrap, _dk);
    }
    else if (anchor && anchor.parentNode) anchor.parentNode.insertBefore(wrap, anchor);
    // the single-day/single-row total rule must also hold for the LOAD state
    // (apply() may not have run — a full range that is one data day)
    var tvAll = document.getElementsByTagName("table"), tv;
    for (tv = 0; tv < tvAll.length; tv++) updateTotalVis(tvAll[tv]);
  }

  // Build a matcher for one search TERM (already lower-cased, trimmed). When the
  // term uses a * or ? wildcard it becomes a glob: ? matches exactly one
  // character, * matches any run (including empty). Otherwise it stays a plain
  // substring test — the original behaviour, and the fast path. Matching is
  // unanchored (the pattern may sit anywhere in a cell), like the substring search
  // it replaces, so "ab*cd" means "…ab<anything>cd…".
  // Treat "-" and "_" as the same character when searching, so a query written
  // with either separator matches a value written with the other (e.g.
  // "ab_europort" matches "AB-EUROPORT"). Applied to BOTH the query and each
  // cell's text, so the substring and glob paths are both separator-insensitive.
  // Mirrors the separator-insensitive key behind the Accounts vs Profiles match.
  function foldSep(s) { return s.replace(/_/g, "-"); }

  function makeMatcher(q) {
    if (q.indexOf("*") < 0 && q.indexOf("?") < 0)
      return function (text) { return text.indexOf(q) >= 0; };
    // Escape every regex metacharacter EXCEPT * and ?, then translate those two.
    var src = q.replace(/[.+^${}()|[\]\\]/g, "\\$&")
               .replace(/\*/g, ".*").replace(/\?/g, ".");
    var rx = null;
    try { rx = new RegExp(src); } catch (e) { rx = null; }   // q is already lower-cased
    if (!rx) return function (text) { return text.indexOf(q) >= 0; };
    return function (text) { return rx.test(text); };
  }

  // Parse a whole query into boolean groups, so terms can be combined with the
  // keywords "and" / "or" / "not". They act as operators only when whole words
  // with whitespace on BOTH sides (the query is already lower-cased, so any case
  // works, e.g. "RABO or SAP"); a bare "or", or a name that contains it with no
  // split, stays a literal substring. OR has lower precedence than AND — "a and b
  // or c" reads as "(a AND b) OR c". A term prefixed with "not " is NEGATED — the
  // row must NOT contain it — so "not x" excludes x, "a and not b" keeps rows with
  // a but not b, and a leading "not b or c" negates only b. Returns an array of
  // AND-groups, each an array of {neg, m} terms; a row matches when ANY group
  // matches in full, and a group matches when EVERY positive term is found in SOME
  // cell AND every negated term is found in NO cell (the terms of an AND may live
  // in different columns).
  // IMPLICIT AND: two or more space-separated terms with NO explicit operator are
  // AND-ed automatically — "abc xyz" == "abc and xyz", "abc klm xyz" == all three
  // AND-ed. This is SKIPPED when any whitespace token is itself an operator word
  // (and / or / not): then the query is taken exactly as written, so a LITERAL
  // "and"/"or"/"not" is reached by giving the operator explicitly — "abc and and"
  // searches for "abc" AND the literal word "and".
  function parseQuery(q) {
    var toks = q.split(/\s+/).filter(Boolean);
    var hasOp = toks.some(function (t) { return t === "and" || t === "or" || t === "not"; });
    if (toks.length > 1 && !hasOp) q = toks.join(" and ");   // implicit AND between bare terms
    return q.split(/\s+or\s+/).map(function (part) {          // OR: lower precedence
      return part.split(/\s+and\s+/)                          // AND: higher precedence
                 .map(function (t) { return t.replace(/^\s+|\s+$/g, ""); })
                 .filter(Boolean)
                 .map(function (t) {                          // "not <term>" -> a negated term (bare "not" stays literal)
                   var mm = /^not\s+(.+)$/.exec(t);
                   if (mm) return { neg: true, m: makeMatcher(mm[1].replace(/^\s+|\s+$/g, "")) };
                   return { neg: false, m: makeMatcher(t) };
                 });
    }).filter(function (g) { return g.length; });
  }

  // The search text currently applied, as typed (for the empty-state message).
  var activeQuery = "";

  // Zero-result EMPTY STATE. A table filtered down to nothing shows only its
  // "Total (0 rows)" footer, which explains neither WHY nor what to do — the
  // worst case being Entity Search, where a query can match rows that the
  // Search-configuration type/Seen filters exclude (Flow is
  // OFF by default), reading as "no matches" when it isn't. This renders a
  // note right under the table naming the reason and the recovery:
  //   - matching rows hidden by the view filters -> their count (per entity
  //     type on Entity Search) + "open Search configuration / adjust filters"
  //   - matching rows outside the selected date range -> their count + widen
  //   - a genuine miss -> "No matches for X. Clear or change the search."
  //   - no query, narrowed range emptied the table -> widen the From/To
  // Re-rendered by every path that changes row visibility (search, date
  // filter, the Seen tabs, the Entity Search type checkboxes).
  // General rule: when the From/To range is a SINGLE day and the table shows
  // exactly ONE data row, the total row is pure repetition — hide it. Any
  // wider range, a second visible row, or a full-period (data-nofilter)
  // table brings it back. Runs from updateEmptyState, i.e. on every path
  // that changes row visibility.
  function updateTotalVis(table) {
    var hide = false;
    if (curRange !== null && (curRange.hi - curRange.lo) < 86400000 &&
        !table.getAttribute("data-nofilter")) {
      var rows = dataRows(table), vis = 0, i;
      for (i = 0; i < rows.length && vis < 2; i++) if (rows[i].style.display !== "none") vis++;
      hide = (vis === 1);
    }
    totalRows(table).forEach(function (tr) { tr.style.display = hide ? "none" : ""; });
  }
  function updateEmptyState(table) {
    updateTotalVis(table);
    var wrap = tunit(table); if (!wrap || !wrap.querySelector) return;
    // Entity Search (start-empty): hide the empty <table> itself (its column
    // headers + "Total (0 rows)" footer) whenever no rows are visible, so the
    // page shows just the search controls until a query matches. The wrapper
    // stays visible, so a "No matches" note (added below) still appears.
    if (table.getAttribute("data-esearch") !== null) {
      var esVis = false, esRows = dataRows(table), esI;
      for (esI = 0; esI < esRows.length; esI++)
        if (esRows[esI].style.display !== "none") { esVis = true; break; }
      table.style.display = esVis ? "" : "none";
      // the "Row colors" NOTE explains the row tints — show it only when
      // there ARE rows (it trails the tablewrap as <p class="note"> siblings)
      var esN = wrap.nextElementSibling;
      while (esN && esN.tagName === "P" && (" " + esN.className + " ").indexOf(" note ") >= 0) {
        esN.style.display = esVis ? "" : "none";
        esN = esN.nextElementSibling;
      }
    }
    var old = wrap.querySelector(".empty-state");
    if (old && old.parentNode) old.parentNode.removeChild(old);
    if (table.getAttribute("data-nosearch") === "1") return;
    var rows = dataRows(table), hasQ = activeQuery !== "";
    if (!rows.length && table.getAttribute("data-start-empty") !== "1") return;
    var visible = 0, hidV = 0, hidD = 0, typc = {}, isES = table.getAttribute("data-escfg") !== null;   // the CONFIG PANEL's presence, not mere esearch — File search has no panel (2026-08)
    rows.forEach(function (tr) {
      if (tr.style.display !== "none") { visible++; return; }
      if (!hasQ) return;                                          // no query: only the date-range message below
      if (tr.getAttribute("data-shide") === "1") return;          // does not match the query
      if (tr.getAttribute("data-vhide") === "1") {
        hidV++;
        if (isES && tr.cells[2]) {
          var ty = tr.cells[2].textContent.trim();
          if (ty) typc[ty] = (typc[ty] || 0) + 1;
        }
      } else if (tr.getAttribute("data-dhide") === "1") hidD++;
    });
    if (visible > 0) return;
    var msg, hint;
    if (hasQ && hidV + hidD > 0) {
      var parts = [];
      if (hidV) {
        var tl = [], k;
        for (k in typc) tl.push(typc[k] + " " + k);
        tl.sort();
        parts.push(hidV + " matching row" + (hidV === 1 ? "" : "s") +
                   (tl.length ? " (" + tl.join(", ") + ")" : "") +
                   (isES ? " excluded by the Search configuration" : " excluded by the Seen filter"));
      }
      if (hidD) parts.push(hidD + " matching row" + (hidD === 1 ? "" : "s") + " outside the selected date range");
      msg = "No visible matches for “" + activeQuery + "” — " + parts.join("; ") + ".";
      hint = isES ? "Open “Search configuration” above to include more entity types, or clear the search."
                  : (hidD && !hidV ? "Widen the From/To above, or clear the search."
                                   : "Adjust the filters above, or clear the search.");
    } else if (hasQ) {
      msg = "No matches for “" + activeQuery + "”.";
      hint = "Clear or change the search (wildcards: ? = one character, * = any run).";
    } else if (curRange && curRange.narrowed) {
      msg = "No rows in the selected date range.";
      hint = "Widen the From/To above.";
    } else return;   // start-empty idle state (the page intro explains it) / nothing to say
    var div = document.createElement("div");
    div.className = "empty-state";
    var s1 = document.createElement("span"); s1.textContent = msg;
    var s2 = document.createElement("span"); s2.className = "es-hint"; s2.textContent = " " + hint;
    div.appendChild(s1); div.appendChild(s2);
    table.parentNode.insertBefore(div, table.nextSibling);
  }

  // Filter a table's data rows by a free-text query over ALL columns. Runs on
  // top of the date filter (a date-hidden row stays hidden), so it searches
  // within the selected date range. Grouped tables are ungrouped first so a
  // blanked repeat cell still matches its real value, then re-blanked.
  // ---- Entity Search: rows arrive as DATA, not as markup --------------------
  // search.html ships window.AXWAY_SEARCH (assets-style search-data.js): one
  // rendered <tr> per line, written by publish_lib.sh's split_search_rows. The
  // page itself carries an EMPTY table, so the browser parses ~600 DOM nodes
  // instead of 44,854 for rows that are invisible until a query is typed (the
  // table is data-start-empty; a no-JS visitor never saw them either).
  //
  // esBuild() replaces the tbody with just the matching rows, so everything
  // downstream — the tint CSS, the whole-cell links, the type checkboxes, the
  // totals, the data-subrows expansion — operates on ordinary DOM rows exactly
  // as it did when they were baked into the page.
  var ES_ROWS = null, ES_NAME = null, ES_TYPE = null;
  function esData() {
    if (ES_ROWS && ES_ROWS.length) return ES_ROWS;   // never cache an empty payload

    var raw = (typeof window !== "undefined" && window.AXWAY_SEARCH) || "";
    ES_ROWS = raw ? raw.split("\n").filter(function (l) { return l.charAt(0) === "<"; }) : [];
    // Name (cell 1) and Type (cell 3 — Direction sits between them) are sliced
    // out of the row string ONCE; carrying them alongside in the payload measured
    // 21 KB gzipped, this costs about 10 ms on the first query and nothing after.
    ES_NAME = new Array(ES_ROWS.length); ES_TYPE = new Array(ES_ROWS.length);
    var cellRe = /<td[^>]*>([\s\S]*?)<\/td>/g;
    for (var i = 0; i < ES_ROWS.length; i++) {
      cellRe.lastIndex = 0;
      var m1 = cellRe.exec(ES_ROWS[i]);
      cellRe.exec(ES_ROWS[i]);                       // cell 2 = Direction, not indexed
      var m2 = cellRe.exec(ES_ROWS[i]);
      ES_NAME[i] = m1 ? m1[1].replace(/<[^>]*>/g, "").replace(/^\s+|\s+$/g, "") : "";
      ES_TYPE[i] = m2 ? m2[1].replace(/<[^>]*>/g, "").replace(/^\s+|\s+$/g, "") : "";
    }
    return ES_ROWS;
  }
  function esTypes() { return (typeof window !== "undefined" && window.AXWAY_SEARCH) ? (esData(), ES_TYPE) : null; }
  function esTypeOf(tr) {   // the Type of a BUILT row, for the checkbox filter
    return tr.cells[2] ? tr.cells[2].textContent.replace(/^\s+|\s+$/g, "") : "";
  }
  // Build the rows whose NAME matches; groups===null means "no query" -> none.
  function esBuild(table, groups) {
    var rows = esData(); if (!rows.length) return false;
    var out = [], i, name;
    if (groups) {
      for (i = 0; i < rows.length; i++) {
        name = foldSep(ES_NAME[i].toLowerCase());
        var hit = groups.some(function (group) {
          return group.every(function (term) {
            var found = term.m(name);
            return term.neg ? !found : found;
          });
        });
        if (hit) out.push(rows[i]);
      }
    }
    // Replace ONLY the data rows. The header and the total row keep their
    // ORIGINAL DOM nodes: initTotals snapshotted the total row at load, and
    // rebuilding it from markup threw that away — the Error/OK totals then
    // showed the baked full-table figures instead of the sum over the matches.
    var body = table.tBodies[0] || table;
    var doomed = [];
    for (i = 0; i < body.rows.length; i++) {
      var r = body.rows[i];
      if (!r.getElementsByTagName("th").length && (" " + r.className + " ").indexOf(" total ") < 0) doomed.push(r);
    }
    var totalRow = null;
    for (i = 0; i < body.rows.length; i++)
      if ((" " + body.rows[i].className + " ").indexOf(" total ") >= 0) { totalRow = body.rows[i]; break; }
    for (i = 0; i < doomed.length; i++) body.removeChild(doomed[i]);
    if (out.length) {
      var frag = document.createElement("tbody");
      frag.innerHTML = out.join("");
      var built = [];
      while (frag.rows.length) built.push(frag.rows[0]), frag.removeChild(frag.rows[0]);
      for (i = 0; i < built.length; i++) {
        if (totalRow) body.insertBefore(built[i], totalRow); else body.appendChild(built[i]);
      }
    }
    table.setAttribute("data-es-omitted", String(rows.length - out.length));   // see recomputeTotals
    setupSubrows(table);                              // the 38 Source/Target rows expand again
    if (table.esApplyTypes) table.esApplyTypes();      // re-apply the type checkboxes
    // an esearch table that is ALSO rowlink (the Failed Subscriptions All
    // views): the materialised rows are fresh DOM nodes, so the whole-row
    // link binding at load never saw them — bind each build's rows here
    if (out.length && ((" " + table.className + " ").indexOf(" index ") >= 0 || table.getAttribute("data-rowlink"))) {
      var body2 = table.tBodies[0] || table;
      for (i = 0; i < body2.rows.length; i++) {
        var r2 = body2.rows[i];
        if (!r2.getElementsByTagName("th").length && (" " + r2.className + " ").indexOf(" total ") < 0 &&
            (" " + r2.className + " ").indexOf(" rowlink ") < 0) bindRowlink(r2);
      }
    }
    return true;
  }

  function runSearch(table, q) {
    activeQuery = q.replace(/^\s+|\s+$/g, "");
    q = foldSep(q.toLowerCase().replace(/^\s+|\s+$/g, ""));
    closeDetails(table);
    ungroup(table);
    var groups = q ? parseQuery(q) : null;
    if (groups && !groups.length) groups = null;   // query was only operators -> no filter
    var startEmpty = table.getAttribute("data-start-empty") === "1" && !groups;   // entity-search: hide all rows until a real query
    // Entity Search: materialise the matching rows first (see esBuild). The
    // loop below then runs over just those — every one of them a match, so it
    // only clears data-shide and lets the type filter and totals do their work.
    if (table.getAttribute("data-esearch") && window.AXWAY_SEARCH) esBuild(table, groups);
    dataRows(table).forEach(function (tr) {
      var match = true, i, cells;
      if (startEmpty) match = false;
      else if (groups) {
        // Entity Search matches the NAME column only: the helper columns
        // would leak — every Partner row contains an "r" in its Type cell,
        // every seen row a "yes" — and the type filter is the checkboxes.
        if (table.getAttribute("data-esearch")) {
          cells = [foldSep((tr.cells[0] ? tr.cells[0].textContent : "").toLowerCase())];
        } else {
        cells = [];                                // fold each cell's text once per row
        for (i = 0; i < tr.cells.length; i++)
          cells.push(foldSep(tr.cells[i].textContent.toLowerCase()));
        }
        match = groups.some(function (group) {     // OR across groups...
          return group.every(function (term) {     // ...AND within a group...
            var found = cells.some(function (c) { return term.m(c); });   // term in some cell
            return term.neg ? !found : found;      // "not" term: must be ABSENT
          });
        });
      }
      tr.setAttribute("data-shide", match ? "0" : "1");
      applyRowVis(tr);
    });
    // A data-recalc table under a NARROWED date range must be re-aggregated for
    // that range, not text-summed: recalcTable only rewrites visible rows, so a
    // row hidden while the range was applied still holds full-period text —
    // clearing the search would resurrect those stale values (and the forced
    // recomputeTotals below would restore full-range totals). Re-run the exact
    // bucket aggregation over the post-search visible set instead.
    if (table.getAttribute("data-recalc") && curRange && curRange.narrowed) {
      recalcTable(table, curRange.lo, curRange.hi, true);
    } else {
      recomputeTotals(table, true);   // force: bucket tables too (recalcTable doesn't run for a full-range search)
    }
    applyGroup(table);
    updateEmptyState(table);
    repage(table);
    hideEmptyTables();
  }

  // The search text persists for the browsing session PER REPORT (keyed like
  // the sort memory, so the Transfers/Sessions/Files variants of one report
  // share it) — typing on one report no longer silently pre-filters every
  // other report you open later. It only ever filters the searchable tables
  // (a data-nosearch table is never searched).
  // EXCEPTION — the Entities group (pages under .../entities/): all entity TYPES
  // (account/login/subscription/host/partner/application/domain) AND their
  // All/Seen/Not seen/Server/Detail views share ONE search, so a filter typed on
  // Accounts survives a switch to Logins. (Sort stays per-entity via pageKeyBase.)
  function searchStoreKey() {
    if (location.pathname.indexOf("/entities/") >= 0) {
      var env = pageEnv();
      return (env ? env + ":" : "") + "entities";
    }
    return pageKeyBase();
  }
  function saveSearch(v) { try { sessionStorage.setItem("search:" + searchStoreKey(), v); } catch (e) {} }
  function loadSearch()  { try { return sessionStorage.getItem("search:" + searchStoreKey()) || ""; } catch (e) { return ""; } }
  // Keep ?axway_search= in the address bar equal to the ACTIVE search, so the
  // URL never shows a stale query (arrive with ?axway_search=RAISIN, type
  // EQUENS -> the URL now says EQUENS and a reload keeps it) and any search —
  // typed or remembered — can be bookmarked/shared. replaceState rewrites the
  // current history entry in place: no history spam, no navigation.
  function syncSearchUrl(v) {
    if (!window.history || !history.replaceState) return;
    var s = window.location.search.replace(/^\?/, ""), parts = s ? s.split("&") : [], out = [], i;
    for (i = 0; i < parts.length; i++) if (parts[i].indexOf("axway_search=") !== 0) out.push(parts[i]);
    if (v) out.push("axway_search=" + encodeURIComponent(v));
    var q = out.length ? "?" + out.join("&") : "";
    try { history.replaceState(null, "", window.location.pathname + q + window.location.hash); } catch (e) {}
  }

  // ONE search box per page, filtering every table on it at once. A
  // data-nosearch table (TABLE …⇥nosearch) is excluded: it is never filtered
  // and doesn't bring the box up. The box appears when any searchable table
  // has more than 25 data rows (or starts empty, e.g. Entity Search), carries
  // a right-aligned "×" clear button, restores the remembered value, and
  // joins the date filter's From/To controls row when the page has one.
  function setupSearch() {
    // The per-entity detail pages carry NO search box (2026-07): like the
    // From/To filter (whose report-dates meta publish-details.sh no longer
    // emits) they always show the complete data. The per-subdir index.html
    // link lists keep their box.
    if (location.pathname.indexOf("/details/") >= 0 && !/\/(index\.html)?$/.test(location.pathname)) return;
    var stored = loadSearch();
    // The top-bar quick-search submits to Entity Search with ?axway_search=…
    // — it overrides the remembered search and is persisted like a typed one.
    var qm = /[?&]axway_search=([^&]*)/.exec(window.location.search);
    if (qm) { stored = decodeURIComponent(qm[1].replace(/\+/g, " ")); saveSearch(stored); }
    var tables = document.getElementsByTagName("table"), t, searchable = [], needBox = false;
    for (t = 0; t < tables.length; t++) {
      if (tables[t].getAttribute("data-nosearch") === "1") continue;   // opt-out (TABLE …⇥nosearch)
      // the charts' own "Data table" is the chart in numbers, not a report
      // table: it must never pull a search box onto a dashboard page, nor be
      // filtered by one typed for the real tables (2026-07)
      if (tables[t].closest && tables[t].closest("details.chart-data")) continue;
      searchable.push(tables[t]);
      if (dataRows(tables[t]).length > 25 || tables[t].getAttribute("data-start-empty") === "1") needBox = true;
    }
    if (needBox) {
      (function () {
        var box = document.createElement("input");
        box.type = "text"; box.className = "search"; box.placeholder = "Search this page…";
        box.title = "Filters every table on this page. Wildcards: ? = one character, * = any run (e.g. FE?????, ab*cd). Keywords: and, or (e.g. RABO or SAP, ABC and XYZ)";
        var clear = document.createElement("span");
        clear.className = "search-clear"; clear.textContent = "×"; clear.title = "Clear search";
        function refresh() {                       // reflect the box: toggle ×, persist, sync the URL, filter
          clear.style.display = box.value ? "block" : "none";
          saveSearch(box.value);
          syncSearchUrl(box.value);
          for (var i = 0; i < searchable.length; i++) runSearch(searchable[i], box.value);
        }
        box.addEventListener("input", refresh);
        clear.addEventListener("click", function () { box.value = ""; box.focus(); refresh(); });
        // Re-evaluation hook for the date path (see the declaration next to
        // curRange). pre=true only lifts the filter (data-shide=0) so the
        // recalc that follows rewrites every row; the main call re-runs the
        // search, whose narrowed-range branch also re-derives shares/totals
        // over the final visible set.
        searchReapply = function (pre) {
          if (!box.value) return;
          for (var i = 0; i < searchable.length; i++) {
            if (pre) dataRows(searchable[i]).forEach(function (tr) { tr.setAttribute("data-shide", "0"); applyRowVis(tr); });
            else runSearch(searchable[i], box.value);
          }
        };
        var sw = document.createElement("span"); sw.className = "search-wrap";
        sw.appendChild(box); sw.appendChild(clear);
        var lbl = document.createElement("label"); lbl.textContent = "Search";
        // The date filter's From/To controls row sits before the first content
        // block — join it so From/To and Search share one row; on a page with
        // no date controls, make a controls row at that same anchor.
        var ctr = document.querySelector("div.controls");
        if (ctr) {
          // Search goes FIRST, then the From/To controls, with extra space
          // between them (the .sepafter margin on the search wrap).
          sw.className = "search-wrap sepafter";
          ctr.insertBefore(sw, ctr.firstChild);
          ctr.insertBefore(lbl, sw);
        } else {
          var wrap = document.createElement("div"); wrap.className = "controls";
          wrap.appendChild(lbl); wrap.appendChild(sw);
          var t0 = document.getElementsByTagName("table")[0];
          var h0 = document.getElementsByTagName("h2")[0];
          var w0 = t0 && tunit(t0);
          var anchor = (h0 && w0) ? ((h0.compareDocumentPosition(w0) & 2) ? w0 : h0) : (h0 || w0);
          // hoist out of a side-by-side (.sxs) block so the box lands above it,
          // not inside one column (which would shove that column's title down)
          if (anchor && anchor.closest) { var sx = anchor.closest(".sxs"); if (sx) anchor = sx; }
          // a baked "undertabs" row belongs below the controls (see the date
          // filter's identical hoist)
          while (anchor && anchor.previousElementSibling && anchor.previousElementSibling.tagName === "P" &&
                 (" " + anchor.previousElementSibling.className + " ").indexOf(" undertabs ") >= 0)
            anchor = anchor.previousElementSibling;
          if (anchor && anchor.parentNode) anchor.parentNode.insertBefore(wrap, anchor);
          ctr = wrap;
        }
        // The search-syntax hint on its OWN line below the controls (like the
        // Search page). NOT on Entity Search — setupSearchConfig renders its own.
        if (ctr && !document.querySelector("table[data-esearch]")) {
          var hrow = document.createElement("p"); hrow.className = "controlshint";
          var hnt = document.createElement("span"); hnt.className = "searchhint"; hnt.textContent = SEARCH_HINT;
          hrow.appendChild(hnt);
          if (ctr.parentNode) ctr.parentNode.insertBefore(hrow, ctr.nextSibling);
        }
        if (stored) { box.value = stored; clear.style.display = "block"; }
        syncSearchUrl(box.value);   // the address bar reflects the search that actually applies (also strips a stale empty param)
      })();
    }
    for (t = 0; t < searchable.length; t++) {
      if (needBox && stored) runSearch(searchable[t], stored);
      else if (searchable[t].getAttribute("data-start-empty") === "1") runSearch(searchable[t], "");   // start-empty: hide all rows until searched
    }
  }

  // Index tables (report lists, entity lists, detail-page indexes): make the
  // whole row a link to the row's first anchor, not just the name — a click
  // anywhere in the row navigates; clicks on the anchor itself stay native
  // (middle-click, ctrl-click etc. keep working).
  // Bind the whole-row link of ONE row. Split out of setupIndexRows (2026-08)
  // so esBuild can re-bind the rows it materialises on an esearch page that
  // also carries rowlink (the Failed Subscriptions All views) — those rows
  // did not exist when setupIndexRows ran at load.
  function bindRowlink(tr) {
    var href = tr.getAttribute("data-href");
    var a = href ? { getAttribute: function () { return href; } } : tr.getElementsByTagName("a")[0];
    if (!a) return;
    tr.className += (tr.className ? " " : "") + "rowlink";
    tr.addEventListener("click", function (ev) {
      // let native links work, and let a collapsed <details> cell (the
      // coverage member/IP cells) toggle open without navigating away
      var el = ev.target, td = null;
      while (el && el !== tr) {
        if (el.tagName === "A" || el.tagName === "SUMMARY" || el.tagName === "DETAILS") return;
        if (el.tagName === "TD") td = el;
        el = el.parentNode;
      }
      // a list cell is not a click target (class wrap: the coverage
      // pages' Accounts / Endpoints / Whitelisted IPs columns — their own
      // links + <details> disclosures live there), and neither is an
      // EMPTY cell (the CSS shows the default cursor there —
      // tr.rowlink td:empty)
      if (td && (" " + td.className + " ").indexOf(" wrap ") >= 0) return;
      if (td && td.textContent.trim() === "") return;
      window.location.href = a.getAttribute("href");
    });
  }
  function setupIndexRows() {
    var tables = document.getElementsByTagName("table"), t;
    for (t = 0; t < tables.length; t++) {
      // the index tables, plus any table the report opted in with the rowlink
      // modifier (Last 100 failed files: the whole row opens the file's error
      // page — see data-href in bindRowlink, which beats the row's first link
      // because that one is the Subscription cell, a different destination)
      if ((" " + tables[t].className + " ").indexOf(" index ") < 0 &&
          !tables[t].getAttribute("data-rowlink")) continue;
      dataRows(tables[t]).forEach(bindRowlink);
    }
  }

  // Day pages: the hero chart's view switch. The publish renders one hero
  // card per view — the per-hour Files histogram by start time first, then
  // (class althero, CSS-hidden) the alternates: by END time (start +
  // duration), Volume, Duration, Errors, Error % Files, Accounts — under a
  // ---- the Overview's KPIs + Top-5 tables follow the From/To range ----------
  // The dashboards publish bakes the FULL-PERIOD figures plus a raw-text
  // payload (#daytopdata) with two line shapes: per ENTITY
  // "kind TAB name TAB YYYYMMDD:files:vol:errs|…" behind the six Top-5
  // tables, and per DAY "K TAB YYYYMMDD TAB files TAB failed TAB vol TAB
  // records TAB errors" behind the five KPI cards. A narrowed range must
  // RE-SELECT the five per table, not just re-sum the baked rows — the
  // busiest of a week need not be the busiest of the period — so each table
  // is rebuilt from the payload: sum per entity over the range, sort
  // descending with ties broken on NAME (the .rpt writer's rule), keep five.
  // The KPI values re-sum the K days (the formats mirror the writers:
  // knum_files/knum_recs/humanbytes and the two %.1f rates). The full range
  // restores the baked values exactly (the recalcTable rule); a metric with
  // nothing in range hides its card, leaving the grid hole the CSS column
  // pinning expects. The day pages carry the same tables but no payload (the
  // page IS one day), so this no-ops there. Driven from the date filter's
  // apply() via window.daytopSetRange, like the slot charts.
  function setupDaytop() {
    var el = document.getElementById("daytopdata");
    if (!el) return;
    var data = { P: [], S: [] }, kdays = [];
    el.textContent.split("\n").forEach(function (ln) {
      var p = ln.split("\t");
      if (p[0] === "K" && p.length >= 7) { kdays.push([p[1], +p[2], +p[3], +p[4], +p[5], +p[6]]); return; }
      if (p.length < 3 || !data[p[0]]) return;
      var days = p[2].split("|"), cells = [], i, q;
      for (i = 0; i < days.length; i++) {
        q = days[i].split(":");
        if (q.length === 4) cells.push([q[0], +q[1], +q[2], +q[3]]);
      }
      if (cells.length) data[p[0]].push({ n: p[1], c: cells });
    });
    // the five KPI cards, matched by their baked label (the K columns are
    // fixed: files, failed, volume, records, errors)
    var kpis = [];
    if (kdays.length) {
      var kmap = { "Files transferred": "files", "Transfer failure rate": "fpct",
                   "Volume moved": "vol", "Server records": "recs", "Server error rate": "epct" };
      var kels = document.querySelectorAll(".kpi-row .kpi");
      for (var ke = 0; ke < kels.length; ke++) {
        var kl = kels[ke].querySelector(".kpi-lbl"), kv = kels[ke].querySelector(".kpi-val");
        var what = kl && kv ? kmap[kl.textContent.trim()] : null;
        if (what) kpis.push({ v: kv, what: what, baked: kv.textContent });
      }
    }
    // the six cards: kind from the .dt-p/.dt-s column class, metric from the
    // unit header the publish baked
    var cards = [], secs = document.querySelectorAll(".daytop section.card"), s;
    for (s = 0; s < secs.length; s++) {
      var t = secs[s].getElementsByTagName("table")[0];
      if (!t || t.rows.length < 2) continue;
      var th = t.querySelector("th.num"), unit = th ? th.textContent.trim() : "";
      var mi = unit === "Files" ? 1 : unit === "Volume" ? 2 : unit === "Errors" ? 3 : 0;
      if (!mi) continue;
      var kind = (" " + secs[s].className + " ").indexOf(" dt-p ") >= 0 ? "P" : "S";
      t.dateAware = true;   // the filter adjusts these — no full-period badge
      var baked = [], r;
      for (r = 1; r < t.rows.length; r++) baked.push(t.rows[r]);
      // the See-more link + its baked full-range href: a narrowed dashboard
      // rewrites it with ?axway_date so the Entities view opens on the SAME
      // period the table was showing (2026-08)
      var more = secs[s].querySelector("a.seemore");
      cards.push({ sec: secs[s], t: t, kind: kind, mi: mi, baked: baked,
                   more: more, mhref: more ? more.getAttribute("href") : null });
    }
    if (!cards.length && !kpis.length) return;
    // the title carries the active period — "Dashboard - 2026-08-01 to
    // 2026-08-10", a single day alone — and drops it at the full range
    var h1 = document.querySelector("main.dash > h1"), h1base = h1 ? h1.textContent : "";
    // swap the data rows, keeping the header row (its sort listeners) in place
    function setRows(t, rows) {
      while (t.rows.length > 1) t.deleteRow(1);
      var tb = t.rows[0].parentNode, i;
      for (i = 0; i < rows.length; i++) tb.appendChild(rows[i]);
    }
    window.daytopSetRange = function (from, to, narrowed) {
      var c, i, j, k;
      if (!narrowed || !from || !to) {
        for (c = 0; c < cards.length; c++) {
          setRows(cards[c].t, cards[c].baked); cards[c].sec.style.display = "";
          if (cards[c].more) cards[c].more.setAttribute("href", cards[c].mhref);
        }
        for (i = 0; i < kpis.length; i++) kpis[i].v.textContent = kpis[i].baked;
        if (h1) h1.textContent = h1base;
        return;
      }
      if (h1) h1.textContent = h1base + " - " + (from === to ? from : from + " to " + to);
      // See more carries the period: a single day as ?axway_date=day (the day
      // pages' form), a span as from..to — the target snaps each bound to its
      // own date list
      for (c = 0; c < cards.length; c++) if (cards[c].more)
        cards[c].more.setAttribute("href", cards[c].mhref +
          (cards[c].mhref.indexOf("?") >= 0 ? "&" : "?") +
          "axway_date=" + from + (to === from ? "" : ".." + to));
      var lo = from.replace(/-/g, ""), hi = to.replace(/-/g, "");
      if (kpis.length) {
        var sf = 0, sx = 0, sv = 0, sr = 0, se = 0, kd;
        for (i = 0; i < kdays.length; i++) {
          kd = kdays[i];
          if (kd[0] >= lo && kd[0] <= hi) { sf += kd[1]; sx += kd[2]; sv += kd[3]; sr += kd[4]; se += kd[5]; }
        }
        for (i = 0; i < kpis.length; i++) {
          var w = kpis[i].what, x;
          if (w === "files")     x = sf >= 1e6 ? (sf / 1e6).toFixed(2) + "M" : sf >= 1e3 ? (sf / 1e3).toFixed(1) + "k" : String(sf);
          else if (w === "fpct") x = (sf ? sx * 100 / sf : 0).toFixed(1) + "%";
          else if (w === "vol")  x = humanBytes(sv);
          else if (w === "recs") x = sr >= 1e6 ? (sr / 1e6).toFixed(1) + "M" : sr >= 1e3 ? Math.round(sr / 1e3) + "k" : String(sr);
          else                   x = (sr ? se * 100 / sr : 0).toFixed(1) + "%";
          kpis[i].v.textContent = x;
        }
      }
      for (c = 0; c < cards.length; c++) {
        var card = cards[c], list = data[card.kind], top = [];
        for (i = 0; i < list.length; i++) {
          var v = 0, cl = list[i].c;
          for (j = 0; j < cl.length; j++) if (cl[j][0] >= lo && cl[j][0] <= hi) v += cl[j][card.mi];
          if (v <= 0) continue;
          k = top.length;
          while (k >= 1 && (top[k - 1].v < v || (top[k - 1].v === v && top[k - 1].n > list[i].n))) k--;
          top.splice(k, 0, { n: list[i].n, v: v });
          if (top.length > 5) top.length = 5;
        }
        if (!top.length) { card.sec.style.display = "none"; continue; }
        card.sec.style.display = "";
        var rows = [];
        for (i = 0; i < top.length; i++) {
          var tr = document.createElement("tr"), td1 = document.createElement("td"), td2 = document.createElement("td");
          td1.textContent = top[i].n;
          td2.className = "num";
          td2.textContent = card.mi === 2 ? humanBytes(top[i].v) : String(top[i].v);
          tr.appendChild(td1); tr.appendChild(td2);
          rows.push(tr);
        }
        setRows(card.t, rows);
      }
    };
    // the load-order guard: pick up a range the date filter applied before
    // this ran (init calls this first, so normally there is none)
    if (window._slotRange && window._slotRange.narrowed)
      window.daytopSetRange(window._slotRange.from, window._slotRange.to, true);
  }

  // ---- "Show all" (the home per-day tables, capped to the newest 14 days) ----
  // The publish caps a table (class cap14) with the older rows and the
  // Total row class-hidden (capx); the button removes the cap and itself.
  // A button uncaps EVERY capped table inside its adjacent wrapper: the
  // home's per-day tables share one button under their .sxs flex row (the
  // five must cap and uncap together — their rows align on the shared Date
  // spine), while a button directly under one .tablewrap still finds just
  // its own table. The baked Total keeps the FULL-window figures:
  // recomputeTotals counts inline display only, so class-hidden rows never
  // leave its sums.
  function setupShowAll() {
    var btns = document.querySelectorAll("button.showallbtn"), i;
    for (i = 0; i < btns.length; i++) btns[i].addEventListener("click", function () {
      var w = this.previousElementSibling;
      var ts = w && w.querySelectorAll ? w.querySelectorAll("table.cap14") : [], j;
      for (j = 0; j < ts.length; j++) ts[j].className = ts[j].className.replace(/\s*\bcap14\b/, "");
      this.style.display = "none";
    });
  }

  // .herotabs button row whose buttons match the cards IN ORDER (button i ↔
  // grid card i). The picked view's label persists in sessionStorage under
  // ONE key, so the previous/next day pages (and every other day page in the
  // session) open in the same view; an unknown stored label (an older page
  // set, or a view that was renamed) falls back to the first view.
  // The Overview adds an optional SECOND button row (2026-08): a row-1 button
  // carrying data-herogroup ("Seen", "Use cases") owns a .herotabs2 row of
  // member buttons, shown only while that group is picked. Member labels are
  // "<group>|<member>" so one flat mode string still identifies a view (and
  // still persists in the one sessionStorage key). The publish renders the
  // grouped cards LAST, in group order, so the DOM order of [data-hero]
  // buttons — row 1, then each group's row 2 — matches the cards index for
  // index, which is what this function walks on.
  function setupHeroToggle() {
    var bar = document.querySelector(".herotabs");
    if (!bar) return;
    var grid = document.querySelector(".dash-grid");
    if (!grid) return;
    var tabs = document.querySelectorAll(".herotabs [data-hero], .herotabs2 [data-hero]");
    var groups = document.querySelectorAll(".herotabs [data-herogroup]");
    var rows2 = document.querySelectorAll(".herotabs2");
    var cards = grid.children;
    if (tabs.length < 2 || cards.length < tabs.length) return;
    var KEY = "axway-day-hero";
    function groupOf(m) { var i = m.indexOf("|"); return i < 0 ? "" : m.substring(0, i); }
    // the member a group opens on: the last one picked in this page view, else
    // its first button
    var lastOf = {};
    for (var t0 = 0; t0 < tabs.length; t0++) {
      var g0 = groupOf(tabs[t0].getAttribute("data-hero"));
      if (g0 && !(g0 in lastOf)) lastOf[g0] = tabs[t0].getAttribute("data-hero");
    }
    function apply(mode) {
      var idx = 0, i, j;
      for (i = 0; i < tabs.length; i++) if (tabs[i].getAttribute("data-hero") === mode) idx = i;
      var g = groupOf(tabs[idx].getAttribute("data-hero"));
      if (g) lastOf[g] = tabs[idx].getAttribute("data-hero");
      for (j = 0; j < tabs.length; j++) {
        tabs[j].className = "tab" + (j === idx ? " active" : "");
        cards[j].style.display = j === idx ? "block" : "none";
      }
      for (j = 0; j < groups.length; j++)
        groups[j].className = "tab" + (groups[j].getAttribute("data-herogroup") === g ? " active" : "");
      for (j = 0; j < rows2.length; j++)
        rows2[j].style.display = (rows2[j].getAttribute("data-herogrouprow") === g) ? "block" : "none";
    }
    var mode = "";
    try { mode = sessionStorage.getItem(KEY) || ""; } catch (e) {}
    // ?axway_hero=<view label> (the Anomalies report links): open on that view.
    // An explicit link beats the remembered pick and persists like one (same
    // idea as ?axway_date); an unknown label falls back to the first view.
    var um = /[?&]axway_hero=([^&]+)/.exec(window.location.search);
    if (um) {
      mode = decodeURIComponent(um[1].replace(/\+/g, " "));
      try { sessionStorage.setItem(KEY, mode); } catch (e) {}
    }
    apply(mode);
    function onClick(ev) {
      var el = ev.target;
      if (!el || !el.getAttribute) return;
      var m = el.getAttribute("data-hero");
      if (!m) {
        // a GROUP button: open its remembered member (or its first)
        var g = el.getAttribute("data-herogroup");
        if (!g || !(g in lastOf)) return;
        m = lastOf[g];
      }
      try { sessionStorage.setItem(KEY, m); } catch (e) {}
      apply(m);
    }
    bar.addEventListener("click", onClick);
    for (var r2 = 0; r2 < rows2.length; r2++) rows2[r2].addEventListener("click", onClick);
  }

  // Home-page status tables: the "including server log" switch in the h2 row
  // (bin/publish.sh _status_table). Toggling flips .srvon on the button's own
  // .sxscol: the Transfer/Server columns (.colsrv) and the server-inclusive
  // .von figures show, the transfer-only .voff figures hide (style.css).
  // Default OFF; state is per table and not persisted.
  function setupSrvToggle() {
    var btns = document.querySelectorAll("button.srvtoggle");
    if (!btns.length) return;
    // Each "including server log" button drives ONLY ITS OWN table's .sxscol —
    // the two home status tables toggle independently.
    function colOf(btn) {
      var col = btn.parentNode;
      while (col && col !== document.body && (!col.className || col.className.indexOf("sxscol") < 0)) col = col.parentNode;
      return (col && col !== document.body) ? col : null;
    }
    for (var i = 0; i < btns.length; i++) {
      btns[i].addEventListener("click", function () {
        var col = colOf(this); if (!col) return;
        var on = this.getAttribute("aria-pressed") !== "true";
        if (on) { if (col.className.indexOf("srvon") < 0) col.className += " srvon"; }
        else col.className = col.className.replace(/\s*\bsrvon\b/, "");
        this.setAttribute("aria-pressed", on ? "true" : "false");
      });
    }
  }

  // The top-bar ENVIRONMENT label (html_head's .envswitch, right after the
  // brand). Two behaviors:
  //  - On an env page (path contains /acceptance/ or /production/): the link
  //    to this page's TWIN in the other environment is resolved at BUILD time
  //    by bin/crosslink.sh — the twin page when it exists, else the other
  //    env's own 404 page — so the switch never hits the webserver's 404.
  //    The click handler only carries the current ?query/#hash over (e.g. a
  //    live ?axway_search). A page the crosslink pass has not touched (a
  //    partial local publish) falls back to the plain pathname swap.
  //  - On the shared root home (body.home): the label shows the ACTIVE env
  //    (sessionStorage "axway-env", default acceptance) and clicking toggles
  //    it — body gains/loses .env-production so CSS swaps the baked .envblock
  //    tables, and the topbar's env-scoped links (dropdown menus, Entities,
  //    the search form action — emitted acceptance-rooted) are rewritten to
  //    the active env.
  // ---- The RUNTIME top bar (2026-07) ---------------------------------------
  // Every html_head page bakes only `<div class="topbar" data-eb=… data-b=…
  // [data-env=…] [data-help=…] [data-twin=…]></div>` (~0.1 KB instead of the
  // ~2.7 KB baked bar × ~4,000 pages) — this renders the full bar from
  // window.AXWAY_TB (assets/topbar-data.js, the three dropdown menu strings
  // with their "@" env-prefix placeholder; rewritten by every publish, so a
  // MENU change no longer needs a site-wide page republish). data-twin is the
  // crosslink.sh-stamped env-switch target; without it setupEnvSwitch's
  // pathname-swap fallback still works. The baked-chrome pages (help pages,
  // the build report — render_shared_topbar) arrive with a NON-empty topbar
  // div and are left untouched. Must run before setupEnvSwitch/setupSrvToggle,
  // which bind into the bar.
  // ---- the shared hero-slot charts (svg_slots): styled hover tooltip -------
  // Every slot rect (.dbz) carries data-l (the slot label) + data-a/-b/-c
  // (the humanized series values); the chart's g.slotmeta carries the series
  // names/colors and the empty-slot text. ONE floating .dbtip per chart (all
  // three baked styles of a card share the box, each svg gets its own tip);
  // the native <title> tooltips are removed here — they stay in the markup
  // only as the no-JS fallback. Series rows render LAST first (P98 on top).
  // (setupSlotTips and the Line/Bar/Solid + interval switcher moved to
  // docs/assets/slotchart.js in 2026-07, with the charts themselves: the
  // tooltip has to be rebound on every redraw, so it belongs to the renderer.)

  function buildTopbar() {
    var tb = document.querySelector("div.topbar");
    if (!tb || tb.firstChild) return;                     // baked bar (help/build) — leave it
    var M = window.AXWAY_TB || {};
    var eb = tb.getAttribute("data-eb") || "";
    var b = tb.getAttribute("data-b") || "";
    var env = tb.getAttribute("data-env") || "";
    var help = tb.getAttribute("data-help") || "";
    var twin = tb.getAttribute("data-twin") || "";
    function cap(e) { return e.charAt(0).toUpperCase() + e.slice(1); }
    function menu(s) { return (s || "").replace(/@/g, eb); }
    var pair;
    if (env) {
      // env page: the active env is a bold non-clickable span, the other an
      // anchor with the crosslinked twin href (or href-less -> fallback)
      var other = env === "production" ? "acceptance" : "production";
      var sw = '<a class="envswitch" data-env="' + env + '"' +
               (twin ? ' href="' + twin + '" title="Switch to ' + cap(other) + '"' : "") +
               ">" + cap(other) + "</a>";
      pair = env === "production"
        ? sw + '<span class="envsep">/</span><span class="envcur">Production</span>'
        : '<span class="envcur">Acceptance</span><span class="envsep">/</span>' + sw;
    } else {
      // shared root pages: BOTH anchors, data-target — the home env toggle
      pair = '<a class="envswitch" data-target="acceptance">Acceptance</a>' +
             '<span class="envsep">/</span>' +
             '<a class="envswitch" data-target="production">Production</a>';
    }
    tb.innerHTML =
      '<a class="brand" href="' + b + 'index.html">Cloud</a>' +
      '<span class="envpair">' + pair + "</span>" +
      '<span class="entgroup"><a class="entlabel" href="' + eb + 'transfer/entities/subscription-all.html">Entities</a>' +
      '<a class="searchbtn" href="' + eb + 'search.html" title="Search" aria-label="Search">🔍</a></span>' +
      // the FILE SEARCH entry (2026-08): the leader of the windowed pages,
      // between the search icon and the report menus
      '<a class="dashlink" href="' + eb + 'file-search-24-hours.html">Files</a>' +
      '<nav class="nav">' +
      '<div class="dd"><span class="ddlabel">Transfer reports ▾</span><div class="ddm">' + menu(M.transfer) + "</div></div>" +
      (M.server ? '<div class="dd"><span class="ddlabel">Server reports ▾</span><div class="ddm">' + menu(M.server) + "</div></div>" : "") +
      (M.analyses ? '<div class="dd"><span class="ddlabel">Analyses ▾</span><div class="ddm">' + menu(M.analyses) + "</div></div>" : "") +
      "</nav>" +
      '<a class="dashlink" href="' + eb + 'dashboards/index.html">Dashboard</a>' +
      // the Monitor dashboard link renders only for an env that HAS one
      // (M.monitor = the per-env flags ensure_assets bakes into topbar-data.js
      // from monitor.rpt's existence). The shared root pages carry no data-env:
      // there the anchor is emitted hidden whenever ANY env has a monitor, and
      // setupEnvSwitch's apply() shows/hides + rewrites it per the ACTIVE env.
      (env
        ? (M.monitor && M.monitor[env] ? '<a class="dashlink" href="' + eb + 'dashboards/monitor.html">Monitor</a>' : "")
        : (M.monitor && (M.monitor.acceptance || M.monitor.production)
            ? '<a class="dashlink monlink" style="display:none" href="' + eb + 'dashboards/monitor.html">Monitor</a>' : "")) +
      '<span class="tr-group">' +
      '<a class="searchbtn" href="' + eb + 'report-finder.html" title="Report finder" aria-label="Report finder">🔎</a>' +
      '<a class="searchbtn" href="' + eb + 'sitemap.html" title="Site map" aria-label="Site map">🗺</a>' +
      (help ? '<a class="helpbtn" href="' + b + "help/" + help + '.html" title="Help" aria-label="Help">?</a>' : "") +
      "</span>";
  }

  function setupEnvSwitch() {
    var sws = document.querySelectorAll("a.envswitch");
    if (!sws.length) return;
    function cap(e) { return e.charAt(0).toUpperCase() + e.slice(1); }
    var env = pageEnv();
    if (env) {
      // Record the env being VIEWED (sessionStorage "axway-env", the key the
      // shared home reads): switching environments through the top bar and
      // then clicking the brand link used to land on a home still showing the
      // env stored by its own toggle — the page you came from, not the one
      // you were browsing. Every env page visit now keeps the key current.
      try { sessionStorage.setItem("axway-env", env); } catch (e) {}
      // env page: ONE anchor — the OTHER env's name (the active env is the
      // baked non-clickable .envcur span next to it)
      var sw = sws[0];
      var other = env === "acceptance" ? "production" : "acceptance";
      sw.textContent = cap(other);
      sw.setAttribute("title", "Switch to " + cap(other));
      var built = sw.getAttribute("href");
      if (built) {
        // build-time link (crosslink.sh): augment with the live query/hash at
        // click time — but never onto a 404 target (nothing to restore there)
        sw.addEventListener("click", function () {
          if ((location.search || location.hash) && !/\/404\.html$/.test(built))
            sw.setAttribute("href", built + location.search + location.hash);
        });
        return;
      }
      sw.setAttribute("href", location.pathname.replace("/" + env + "/", "/" + other + "/") + location.search + location.hash);
      return;
    }
    if ((" " + (document.body.className || "") + " ").indexOf(" home ") < 0) return;   // build report etc.: label only
    // Home: BOTH anchors carry data-target — the stored env becomes the
    // bold non-clickable .envcur, the other one switches the baked blocks.
    var KEY = "axway-env";
    function active() {
      var v = "";
      try { v = sessionStorage.getItem(KEY) || ""; } catch (e) {}
      return v === "production" ? "production" : "acceptance";
    }
    function apply(e) {
      var body = document.body;
      if (e === "production") {
        if (body.className.indexOf("env-production") < 0) body.className += " env-production";
      } else {
        body.className = body.className.replace(/\s*\benv-production\b/, "");
      }
      for (var j = 0; j < sws.length; j++) {
        var t = sws[j].getAttribute("data-target");
        if (t === e) {
          sws[j].className = "envswitch envcur";
          sws[j].removeAttribute("title");
        } else {
          sws[j].className = "envswitch";
          sws[j].setAttribute("title", "Switch to " + cap(t));
        }
      }
      // rewrite the env-scoped topbar links to the active env — including the
      // Dashboard + Monitor dashlinks (missing them left every "next click"
      // from a production-toggled home on an acceptance page)
      var from = (e === "production" ? "acceptance/" : "production/"), to = e + "/";
      var bar = document.querySelector(".topbar");
      if (!bar) return;
      var as = bar.querySelectorAll(".ddm a, a.entlabel, a.searchbtn, a.dashlink");
      for (var i = 0; i < as.length; i++) {
        var h = as[i].getAttribute("href") || "";
        if (h.indexOf(from) === 0) as[i].setAttribute("href", to + h.slice(from.length));
      }
      // the Monitor link exists on the home only as a hidden anchor; show it
      // exactly when the ACTIVE env has a monitor
      var ml = bar.querySelector("a.monlink");
      if (ml) {
        var mm = (window.AXWAY_TB || {}).monitor || {};
        ml.style.display = mm[e] ? "" : "none";
      }
    }
    apply(active());
    for (var k = 0; k < sws.length; k++) {
      sws[k].addEventListener("click", function (ev) {
        ev.preventDefault();
        var t = this.getAttribute("data-target");
        if (!t || t === active()) return;   // the active one is inert
        try { sessionStorage.setItem(KEY, t); } catch (e) {}
        apply(t);
      });
    }
  }

  // ---- CSV download (2026-08-30, user request): every table exports itself
  // as a .csv via a small hotspot in the UPPER-RIGHT CORNER of the LAST
  // header cell — faint until the header is hovered (style.css .csvbtn); its
  // click never reaches the th's sort handler. The export is the table AS
  // SHOWN: the field header row plus the rows the active search/date/view
  // filters leave visible (pager-hidden rows count as visible — the pager is
  // pure presentation), in the current sort order; total rows stay out (a
  // spreadsheet recomputes them, and mixed-in totals break sorting there).
  // Cells export their DISPLAYED text — stacked <br> lines joined with "; ",
  // the clines ⋯ marker and the sort arrow skipped — UTF-8 with BOM, CRLF.
  function csvCellText(cell) {
    var out = "";
    (function walk(n) {
      var i, c, cl;
      for (i = 0; i < n.childNodes.length; i++) {
        c = n.childNodes[i];
        if (c.nodeType === 3) { out += c.nodeValue; continue; }
        if (c.nodeType !== 1) continue;
        if (c.tagName === "BR") { out += "; "; continue; }
        cl = " " + c.className + " ";
        if (cl.indexOf(" arrow ") >= 0 || cl.indexOf(" csvbtn ") >= 0 || cl.indexOf(" ce ") >= 0) continue;
        // skip what CSS hides: the von/voff toggle twin not in effect, a
        // collapsed clines middle — the export is the cell AS DISPLAYED
        try { if (window.getComputedStyle && getComputedStyle(c).display === "none") continue; } catch (err) {}
        walk(c);
      }
    })(cell);
    return out.replace(/\u00a0/g, " ").replace(/\s+/g, " ").replace(/^ | $/g, "");
  }
  function csvField(s) { return /[",\n\r]/.test(s) ? '"' + s.replace(/"/g, '""') + '"' : s; }
  function tableCsv(table) {
    var hr = headerRow(table), rows = dataRows(table), lines = [], i;
    function line(tr) {
      var out = [], j;
      for (j = 0; j < tr.cells.length; j++) out.push(csvField(csvCellText(tr.cells[j])));
      return out.join(",");
    }
    if (hr) lines.push(line(hr));
    for (i = 0; i < rows.length; i++) if (rows[i].style.display !== "none") lines.push(line(rows[i]));
    return "\ufeff" + lines.join("\r\n") + "\r\n";
  }
  // <page basename>[-<its h2 slug> | -<n>].csv — the heading names the file
  // when the table has one; multiple heading-less tables number themselves.
  function csvName(table) {
    // a page served as its directory ("/", the home) has no basename, and
    // "index" says nothing — those pages name the file by the heading alone
    // (2026-08-30, user request: no "table-" fallback prefix)
    var base = (location.pathname.split("/").pop() || "").replace(/\.html?$/, "");
    if (base === "index") base = "";
    var el = tunit(table).previousElementSibling, ttl = "", tg, i, c;
    while (el) {
      tg = el.tagName ? el.tagName.toLowerCase() : "";
      if (tg === "h2") {
        // the heading's OWN text — direct text nodes only, so an embedded
        // button (srvtoggle) or muted period span stays out of the filename
        for (i = 0; i < el.childNodes.length; i++) { c = el.childNodes[i]; if (c.nodeType === 3) ttl += c.nodeValue; }
        if (!ttl.replace(/\s+/g, "")) ttl = el.textContent;
        break;
      }
      if (tg === "h1" || (tg === "div" && (" " + el.className + " ").indexOf(" tablewrap ") >= 0)) break;
      el = el.previousElementSibling;
    }
    var slug = ttl.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "").slice(0, 60);
    if (!slug) {
      var all = document.getElementsByTagName("table"), idx = -1, n = 0, i;
      for (i = 0; i < all.length; i++) { if (all[i] === table) idx = n; n++; }
      if (n > 1 && idx >= 0) slug = String(idx + 1);
    }
    if (base && slug) return base + "-" + slug + ".csv";
    return (base || slug || "table") + ".csv";
  }
  function downloadCsv(table) {
    var blob = new Blob([tableCsv(table)], { type: "text/csv;charset=utf-8" });
    var url = URL.createObjectURL(blob);
    var a = document.createElement("a");
    a.href = url;
    a.download = csvName(table);
    document.body.appendChild(a);   // Firefox needs the anchor in the DOM
    a.click();
    document.body.removeChild(a);
    setTimeout(function () { URL.revokeObjectURL(url); }, 1000);
  }
  function setupCsvBtn(table) {
    var hr = headerRow(table); if (!hr || !hr.cells.length) return;
    var th = hr.cells[hr.cells.length - 1];
    var b = document.createElement("span");
    b.className = "csvbtn";
    b.textContent = "csv";
    b.title = "Download this table as CSV";
    b.addEventListener("click", function (e) {
      e.preventDefault(); e.stopPropagation();   // never reach the th's sort handler
      downloadCsv(table);
    });
    th.className += (th.className ? " " : "") + "csvhost";
    th.appendChild(b);
  }

  function init() {
    buildTopbar();          // FIRST: setupEnvSwitch/setupSrvToggle bind into the bar
    entTouch();             // Entities: slide the shared sort's hour on every view
    var tables = document.getElementsByTagName("table");
    for (var i = 0; i < tables.length; i++) {
      initGroup(tables[i]);   // record real group values FIRST — before makeSortable's data-sort-init
      bindPairs(tables[i]);   // bind 2-row message/data pairs BEFORE any sort restore
      makeSortable(tables[i]); // sorts/blanks col 0, which would otherwise memorize a blanked value
      applyGroup(tables[i]);
      setupExpandable(tables[i]);  // clickable drill-down BEFORE the data-origc snapshots below,
                                   // so a recalc/seenmode className restore keeps the .expandable affordance
      setupSubrows(tables[i]);     // Entity Search: multi-use Source/Target rows expand into per-subscription rows
      setupRowFold(tables[i]);     // fold=<res> rows collapse behind one summary row (Incoming IPs)
      initTotals(tables[i]);  // remember original totals so the filter can restore them
      initRecalc(tables[i]);  // remember originals of re-aggregatable cells
      initSeen(tables[i]);    // Show-Seen tables: remember originals + full-period seen flag
      if (tables[i].getAttribute("data-heat")) initHeat(tables[i]);   // heatmap: remember each cell's text + tint
      recomputeTotals(tables[i]);  // fold the skipped rows out of the totals (non-bucket tables)
      setupCsvBtn(tables[i]);      // the CSV-download hotspot in the last header cell's corner
    }
    setupPager();
    // SVG chart anchors (the per-day charts' clickable day columns): navigate
    // explicitly on click. Native SVG <a> activation is left to the browser
    // everywhere else, but synthesized/edge-case clicks proved unreliable —
    // this makes the day columns deterministic without changing plain links.
    document.addEventListener("click", function (e) {
      if (e.defaultPrevented || e.button !== 0 || e.metaKey || e.ctrlKey || e.shiftKey || e.altKey) return;
      var n = e.target, a = null;
      while (n && n !== document) {
        if (n.tagName && n.tagName.toLowerCase() === "a" && n.namespaceURI === "http://www.w3.org/2000/svg") { a = n; break; }
        n = n.parentNode;
      }
      if (!a) return;
      var h = a.getAttribute("href");
      if (h) { e.preventDefault(); window.location.href = h; }
    });        // before the date filter: its apply() re-pages
    setupDaytop();       // overview: BEFORE the date filter — it marks its
                         // tables date-aware and defines the range hook the
                         // filter's load-time apply() may already call
    setupDateFilter();
    setupSearch();
    setupIndexRows();    // whole-row links on the index tables
    setupShowAll();      // home: the per-day table's 14-day cap lifter
    setupHeroToggle();   // overview + day pages: the hero view switch
    setupSrvToggle();    // home page: the status tables' "including server log" switch
    setupEnvSwitch();    // top bar: the Acceptance/Production label (twin-page link / home toggle)
    setupSearchConfig(); // Entity Search: the collapsed configuration panel
    setupReportFinder(); // Report finder: title/intro/keyword search over the catalog
    setupCollapsible();  // clines cells (patterns): click toggles the collapsed middle lines
    hideEmptyTables();   // after the search/date filters have hidden rows
    setupSectionTabs();  // detail pages: the fixed h1 + section-tab header (after empty sections are hidden)
    setupStatFilter();   // Subscriptions in boxes: the stat boxes narrow the table
    setupSelFilter();    // coverage partners page: Connection / Movement / Use case selectors
    markUrlRow();        // LAST: the sort/date/pager order it scrolls to must be final
  }

  // Clickable STAT boxes as row filters (Subscriptions in boxes): each
  // .stat[data-pf] box narrows the table to the rows whose data-pf token list
  // contains the box's key; the data-pf="" box (the left one) shows all rows.
  // The active box carries .pfon. Rows without data-pf (the total row) are
  // never hidden. The p.pfdesc[data-pf] explanations between the boxes and the
  // table follow the pick: the matching one carries .pfshow, the rest are
  // display:none, so the text always describes the ACTIVE box.
  function setupStatFilter() {
    var boxes = document.querySelectorAll(".stat[data-pf]"); if (!boxes.length) return;
    var rows = document.querySelectorAll("tr[data-pf]"); if (!rows.length) return;
    var descs = document.querySelectorAll("p.pfdesc[data-pf]");

    // Column hiding. The publisher stamps each flag column's <th> with the same
    // data-pf token the boxes and rows carry, which is the whole flag -> column
    // map: without those attributes this degrades to plain row filtering.
    // A filtered view hides any column with no hit left among the visible rows.
    // The ACTIVE box's own column stays, every visible row carrying its flag —
    // the filter confirmed in the table itself.
    // Hidden by ONE generated stylesheet rule of :nth-child() selectors rather
    // than by touching cells: a filter would otherwise write to 13 cells x 524
    // rows on every click, and the rule covers the header and total rows for
    // free (they are `tr > *` like the rest).
    var table = rows[0].parentNode;
    while (table && table.tagName !== "TABLE") table = table.parentNode;
    var colOf = {}, heads = table ? table.querySelectorAll("th[data-pf]") : [], i, j, kids;
    for (i = 0; i < heads.length; i++) {
      kids = heads[i].parentNode.children;
      for (j = 0; j < kids.length; j++)
        if (kids[j] === heads[i]) { colOf[heads[i].getAttribute("data-pf")] = j + 1; break; }
    }
    var style = null;
    function hideCols(cols) {
      if (!style) {
        if (!cols.length) return;                       // nothing to hide, nothing to create
        style = document.createElement("style"); document.head.appendChild(style);
        if (!table.id) table.id = "pftable";
      }
      var sel = [];
      for (var i = 0; i < cols.length; i++) sel.push("#" + table.id + " tr > :nth-child(" + cols[i] + ")");
      style.textContent = sel.length ? sel.join(",") + "{display:none}" : "";
    }

    // The generic recomputeTotals sums the cells that parse as numbers; these
    // cells hold the box NAME ("ok", "quiet"), so the footer has to be counted
    // from the same data-pf tokens instead — exact, and free once they are read.
    var totalRow = table ? table.querySelector("tr.total") : null;
    // the unit for that footer: "subscription" on Subscriptions in boxes (which
    // predates the attribute and so does not carry it), "account" on Accounts in
    // boxes. The row label is rewritten on every click, so a hardcoded noun here
    // was the one thing stopping a second box page from reusing all of this.
    var pfNoun = (table && table.getAttribute("data-pf-noun")) || "subscription";

    function apply(k) {
      var i, b, on, count = {}, nvis = 0, toks, t, f;
      for (i = 0; i < boxes.length; i++) {
        b = boxes[i]; on = (b.getAttribute("data-pf") === k);
        b.className = b.className.replace(/ ?\bpfon\b/, "") + (on ? " pfon" : "");
      }
      for (i = 0; i < descs.length; i++) {
        b = descs[i]; on = (b.getAttribute("data-pf") === k);
        b.className = b.className.replace(/ ?\bpfshow\b/, "") + (on ? " pfshow" : "");
      }
      for (i = 0; i < rows.length; i++) {
        on = (!k || (" " + rows[i].getAttribute("data-pf") + " ").indexOf(" " + k + " ") >= 0);
        rows[i].style.display = on ? "" : "none";
        // a row's data-pf already lists its boxes, so both the surviving columns
        // and the footer counts come off the attributes — no cell is inspected
        if (on) {
          nvis++;
          toks = rows[i].getAttribute("data-pf").split(" ");
          for (t = 0; t < toks.length; t++) if (toks[t]) count[toks[t]] = (count[toks[t]] || 0) + 1;
        }
      }
      var hide = [];
      for (f in colOf)
        if (Object.prototype.hasOwnProperty.call(colOf, f) && !count[f]) hide.push(colOf[f]);
      hideCols(hide);
      if (totalRow) {
        totalRow.cells[0].textContent = "Total (" + nvis + " " + pfNoun + (nvis === 1 ? "" : "s") + ")";
        for (f in colOf)                              // colOf is 1-based (nth-child), cells[] is 0-based
          if (Object.prototype.hasOwnProperty.call(colOf, f) && totalRow.cells[colOf[f] - 1])
            totalRow.cells[colOf[f] - 1].textContent = count[f] || 0;
      }
    }
    for (var b0 = 0; b0 < boxes.length; b0++) (function (b) {
      b.addEventListener("click", function () { apply(b.getAttribute("data-pf")); });
    })(boxes[b0]);
    // The page opens on the box the publisher stamped as the default (the OK
    // box on the Boxes pages); no stamp — or a stamp naming no box — opens the
    // baked all-rows view, which is also the no-JS fallback.
    var dflt = "", pfb = document.querySelector(".pfboxes[data-pf-default]");
    if (pfb) {
      dflt = pfb.getAttribute("data-pf-default") || "";
      if (dflt && !document.querySelector('.stat[data-pf="' + dflt + '"]')) dflt = "";
    }
    apply(dflt);
  }

  // Selector-group row filters (the coverage partners page): each
  // <span class="selgrp" data-sel="KEY"> holds .tab buttons, each carrying
  // data-v ("" = the All option). A group is single-select; the active
  // choices of ALL groups combine with AND. A row matches a group when its
  // data-KEY attribute — one value or a space-separated token list
  // (data-uc="1 3") — contains the chosen value; a row without the attribute
  // fails any non-All choice. Hiding goes through data-fhide + applyRowVis
  // like the other filters, so the search box composes, and the footer
  // re-totals over the visible rows (recomputeTotals restores the exact
  // baked originals when every group is back on All).
  function setupSelFilter() {
    var grps = document.querySelectorAll(".selgrp[data-sel]"); if (!grps.length) return;
    var wrap = document.querySelector(".tablewrap table"); if (!wrap) return;
    var sel = {};
    function apply() {
      dataRows(wrap).forEach(function (tr) {
        var ok = true, k, rv;
        for (k in sel) {
          if (!Object.prototype.hasOwnProperty.call(sel, k) || !sel[k]) continue;
          rv = " " + (tr.getAttribute("data-" + k) || "") + " ";
          if (rv.indexOf(" " + sel[k] + " ") < 0) { ok = false; break; }
        }
        tr.setAttribute("data-fhide", ok ? "0" : "1"); applyRowVis(tr);
      });
      recomputeTotals(wrap, true);
    }
    Array.prototype.forEach.call(grps, function (g) {
      var key = g.getAttribute("data-sel"), btns = g.querySelectorAll(".tab[data-v]");
      sel[key] = "";
      Array.prototype.forEach.call(btns, function (b) {
        b.addEventListener("click", function () {
          sel[key] = b.getAttribute("data-v") || "";
          Array.prototype.forEach.call(btns, function (x) {
            x.className = x.className.replace(/ ?\bactive\b/, "") + (x === b ? " active" : "");
          });
          apply();
        });
      });
    });
  }


  // A back/forward restore from the bfcache does not re-run init, but it IS a
  // page view — renew the Entities sort's hour there too.
  window.addEventListener("pageshow", function (e) { if (e.persisted) entTouch(); });

  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", init);
  else init();
})();
