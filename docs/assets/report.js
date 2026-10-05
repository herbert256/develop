/* Cloud log reports — client-side interactivity (loaded by every page).
 * Works off the rendered markup only (no per-page code):
 *   - click a column header to sort (numeric / date / size / duration / text aware);
 *     the tr.total footer stays pinned at the bottom.
 *   - if a table has a "Date" column, a From/To date pulldown pair filters rows.
 * No framework, ES5-compatible. */
(function () {
  "use strict";

  var SIZE = { b: 1, kb: 1024, mb: 1048576, gb: 1073741824, tb: 1099511627776, pb: 1125899906842624 };
  // d and the spelled-out forms (2026-09-13): the Entities pages' whole-day
  // durations ("1 d" sorted as 1 ms before) and the prose ages ("5 days",
  // "12 hours") of the Pickups report
  var TIME = { ms: 1, s: 1000, sec: 1000, second: 1000, seconds: 1000, m: 60000, min: 60000, minute: 60000, minutes: 60000,
               h: 3600000, hour: 3600000, hours: 3600000, d: 86400000, day: 86400000, days: 86400000 };

  // A URL query value, "+" as a space: decodeURIComponent THROWS on a malformed
  // escape ("?axway_search=100%"), which stopped the whole script — the raw
  // value then (2026-09-28 fix; axway_row/axway_column already did this)
  function urlParam(v) {
    v = v.replace(/\+/g, " ");
    try { return decodeURIComponent(v); } catch (e) { return v; }
  }

  // "2026-06-28[ HH:MM:SS[.mmm]]" or "06/28/2026[ HH:MM:SS]" -> epoch ms, else null.
  function parseDate(s) {
    var m = /^(\d{4})-(\d{2})-(\d{2})(?:[ T](\d{2}):(\d{2}):(\d{2}))?/.exec(s);
    if (m) return Date.UTC(+m[1], +m[2] - 1, +m[3], +(m[4] || 0), +(m[5] || 0), +(m[6] || 0));
    m = /^(\d{2})\/(\d{2})\/(\d{4})(?:[ T](\d{2}):(\d{2}):(\d{2}))?/.exec(s);
    if (m) return Date.UTC(+m[3], +m[1] - 1, +m[2], +(m[4] || 0), +(m[5] || 0), +(m[6] || 0));
    return null;
  }

  // "1.59 GB" / "574 ms" / "45.1%" / "+14.2%" / "1.33 MB/s" / "12,345" -> comparable number, else null.
  // A COMPOUND duration (2026-09-13) — "1h 53m", "2d 5h 45m", "66d 0h", "3m 12s":
  // the Waiting report's Waiting for and the UC2 detail pages' Pickup cells —
  // is the SUM of its parts (every part a number + time unit); before, no part
  // matched the single-token shape, the cell fell out of the numeric order
  // (sank last, or flipped the whole column to text where "2h" < "9m"). A
  // "<" / ">" bound ("<1 s", "<1m", "> 24 h") sorts a hair below / above its
  // value instead of dropping out of the order the same way.
  var COMPOUND = /^([-+]?)((?:\d+(?:\.\d+)?\s*(?:ms|min|minutes?|m|sec|seconds?|s|hours?|h|days?|d)\s*){2,})$/i;
  function parseNum(s) {
    var t = s.trim(), bound = 0, v;
    if (/^[<>]/.test(t)) { bound = t.charAt(0) === "<" ? -1e-3 : 1e-3; t = t.slice(1).trim(); }
    v = parseNum1(t);
    return v === null ? null : v + bound;
  }
  function parseNum1(t) {
    if (t === "" || t === "-") return null;
    var c = COMPOUND.exec(t);
    if (c) {
      var sum = 0, part, pr = /(\d+(?:\.\d+)?)\s*([A-Za-z]+)/g;
      while ((part = pr.exec(c[2]))) sum += parseFloat(part[1]) * TIME[part[2].toLowerCase()];
      return c[1] === "-" ? -sum : sum;
    }
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

  // ---- Column order: drag a header left or right, remembered (2026-09-05) ----
  // Every cell of a MOVABLE table carries data-ci, its column index in the
  // BUILT order. Everything that addresses a column by number — the RECALC
  // tokens, data-noagg / data-pct, the group column, the total label, the
  // remembered sort — goes through that index (cellByCi / colByCi), so the
  // DOM order is free to change under it. Rows added later (drill-downs, the
  // pager, fold summaries, message rows) are single full-width cells and are
  // never touched.
  //
  // A total row whose label spans columns is split on the FIRST move (the
  // label keeps its own column, the covered ones become empty cells), so it
  // keeps its baked look on a table nobody reorders.
  //
  // Fixed tables: a grouped header band (GHEAD), the hour x weekday heat map,
  // Entity Search (builds its rows on demand), the day-rows layout and the root
  // index (spacer columns), and any row whose spans cannot be split cleanly.
  //
  // The order is stored in localStorage — it must outlive the tab — under the
  // report key plus
  // the built header labels, so a report whose columns change simply falls
  // back to its built order. Reset at the foot of the cols picker restores it.
  function cellByCi(tr, ci) {
    var cs = tr.cells, i, k = String(ci);
    for (i = 0; i < cs.length; i++) if (cs[i].getAttribute("data-ci") === k) return cs[i];
    return null;
  }
  function ciOf(cell) {              // the built index of a cell (its position where not stamped)
    var v = cell.getAttribute("data-ci");
    return v === null ? cell.cellIndex : +v;
  }
  function colByCi(hr, ci) {         // built index -> current header position (-1: absent)
    var c = cellByCi(hr, ci);
    return c ? c.cellIndex : -1;
  }
  function cell0(tr) { return cellByCi(tr, 0) || tr.cells[0]; }   // the built first column's cell
  // a header cell's LABEL: its text without the hotspots this script adds —
  // the csv / cols buttons, the sort arrows (2026-09-29: a regex stripping a
  // trailing "csv"/"cols" also ate the end of "Protocols", and the dashboard
  // Top-5 cards compared the whole text, "Filescsv", and never matched)
  function thLabel(th) {
    var s = "", k = th.childNodes, i, n;
    for (i = 0; i < k.length; i++) {
      n = k[i];
      if (n.nodeType === 3) s += n.nodeValue;
      else if (n.nodeType === 1 && !/(^| )(arrow|csvbtn|pickbtn|colpick|cpid|stgo)( |$)/.test(n.className || "")) s += n.textContent;
    }
    return s.replace(/[▲▼]/g, "").trim();
  }
  function colMovable(table, hr) {
    var n = hr.cells.length, i, j, r, cs, sum;
    if (n < 2) return false;
    if (table.getAttribute("data-heat") || table.getAttribute("data-esearch") || table.getAttribute("data-nocolmove")) return false;
    // (spacer columns — th/td.spc, the home per-day table and the root index —
    // are fine since 2026-09-06: never listed, never moved, group boundaries)
    for (i = 0; i < table.rows.length; i++) {
      r = table.rows[i]; cs = r.cells;
      if (r.getElementsByTagName("th").length) {
        if (r === hr) { for (j = 0; j < cs.length; j++) if ((cs[j].colSpan || 1) > 1) return false; continue; }   // the field header must be flat
        // a GROUP BANNER row (GHEAD: cells spanning column groups) is fine as
        // long as its spans cover the table exactly (2026-09-06, user request:
        // grouped tables get the picker too, moves stay inside a group)
        sum = 0; for (j = 0; j < cs.length; j++) sum += cs[j].colSpan || 1;
        if (sum !== n) return false;
        continue;
      }
      if (cs.length === 1) continue;                      // full-width message / divider / drill row
      sum = 0; for (j = 0; j < cs.length; j++) sum += cs[j].colSpan || 1;
      if (sum !== n) return false;
      if (cs.length !== n && !isTotal(r)) return false;   // a spanned DATA row cannot be split
    }
    return true;
  }
  function colOrderKey(table, hr) {
    var labels = [], i;
    for (i = 0; i < hr.cells.length; i++) labels.push(thLabel(hr.cells[i]));
    return "colorder:" + pageKeyBase() + ":" + labels.join("|");
  }
  function loadOrder(key, n) {
    try {
      var v = JSON.parse(localStorage.getItem(key) || "null"), seen = {}, i;
      if (!v || v.length !== n) return null;
      for (i = 0; i < n; i++) { if (typeof v[i] !== "number" || v[i] < 0 || v[i] >= n || seen[v[i]]) return null; seen[v[i]] = 1; }
      return v;
    } catch (e) { return null; }
  }
  function saveOrder(key, order, identity) {
    try { if (identity) localStorage.removeItem(key); else localStorage.setItem(key, JSON.stringify(order)); } catch (e) {}
  }
  function isIdentity(order) { for (var i = 0; i < order.length; i++) if (order[i] !== i) return false; return true; }
  function curOrder(hr) { var o = [], i; for (i = 0; i < hr.cells.length; i++) o.push(ciOf(hr.cells[i])); return o; }
  function splitSpans(tr) {          // a spanned total label -> one cell per column
    var cs = tr.cells, i, c, sp, k, e;
    for (i = 0; i < cs.length; i++) {
      c = cs[i]; sp = c.colSpan || 1; if (sp < 2) continue;
      var base = ciOf(c); c.colSpan = 1;
      for (k = 1; k < sp; k++) {
        e = document.createElement("td"); e.setAttribute("data-ci", String(base + k)); e.setAttribute("data-orig", "");
        if (c.nextSibling) tr.insertBefore(e, cs[i + k]); else tr.appendChild(e);
      }
    }
  }
  // Hotspots: csv lives in the LAST header cell; the column tools (cols and
  // its picker) sit bottom-right in the last VISIBLE cell of the TOTAL
  // row — of the last visible data row when the table has no total, of the
  // header when it has no rows at all (2026-09-05, user request). That host
  // cell is rewritten by the recalc and totals paths (textContent drops the
  // hotspots) and changes with every sort, filter, page and column move, so
  // placeHotspots re-attaches the elements the table remembers (_colTools)
  // and runs after each of those paths, with a mouseover safety net.
  function colHostCell(table) {
    // the LAST visible row of the table, total or data — a Total pinned at
    // the top (data-total-top, the Top view) is not the last row and must
    // not host the tools (2026-09-06, user request)
    var rows = table.rows, row = null, i, cs, r;
    for (i = rows.length - 1; i >= 0; i--) {
      r = rows[i];
      if (r.getElementsByTagName("th").length) continue;
      if (/\b(coreid-detail|pagerrow|foldrow)\b/.test(r.className)) continue;
      if (r.style.display === "none" || getComputedStyle(r).display === "none") continue;
      row = r; break;
    }
    if (!row) row = headerRow(table);
    if (!row) return null;
    cs = row.cells;
    for (i = cs.length - 1; i >= 0; i--) if (!cs[i].hidden && !isSpacer(cs[i])) return cs[i];
    return null;
  }
  function placeHotspots(table, hr) {
    // NOT before init() has taken its snapshots (initTotals / initRecalc /
    // initSeen store each cell's text and markup as data-orig / data-html):
    // tools already inside the host cell would be captured as the literal text
    // "↺cols" and written back top-left by every restore (2026-09-06 fix)
    if (!table._toolsOn) return;
    // csv: the last VISIBLE header cell — a hidden last column must not take
    // the export with it (2026-09-06 fix)
    var last = null, i, th, b, tools = table._colTools, host, old;
    for (i = hr.cells.length - 1; i >= 0; i--) if (!hr.cells[i].hidden && !isSpacer(hr.cells[i])) { last = hr.cells[i]; break; }
    if (!last) last = hr.cells[hr.cells.length - 1];
    for (i = 0; i < hr.cells.length; i++) {
      th = hr.cells[i];
      if (th !== last) while ((b = th.querySelector(".csvbtn"))) last.appendChild(b);
      th.className = th.className.replace(/ ?\bcsvhost\b/, "");
    }
    if (last.querySelector(".csvbtn")) last.className += (last.className ? " " : "") + "csvhost";
    if (!tools) return;
    host = colHostCell(table); if (!host) return;
    old = table.querySelectorAll(".colhost");
    for (i = 0; i < old.length; i++) if (old[i] !== host) old[i].className = old[i].className.replace(/ ?\bcolhost\b/, "");
    if (tools.pb.parentNode !== host) host.appendChild(tools.pb);
    if (tools.pop.parentNode !== host) host.appendChild(tools.pop);
    if (!/\bcolhost\b/.test(host.className)) host.className += (host.className ? " " : "") + "colhost";
  }
  function replaceHotspots(table) {   // after a path that may have rewritten or re-ordered the host cell
    if (!table || !table._colTools) return;
    var hr = headerRow(table); if (hr) placeHotspots(table, hr);
  }
  function applyOrder(table, hr, order) {
    var n = hr.cells.length, rows = table.rows, i, j, r, cs, byCi, sortedCi = null, sc, c;
    if (table.hasAttribute("data-sort-col")) { sc = hr.cells[+table.getAttribute("data-sort-col")]; if (sc) sortedCi = ciOf(sc); }
    for (i = 0; i < rows.length; i++) {
      r = rows[i]; cs = r.cells;
      if (cs.length === 1 && !r.getElementsByTagName("th").length) continue;   // full-width rows stay
      if (cs.length !== n && isTotal(r)) splitSpans(r);
      if (cs.length !== n) continue;
      byCi = {}; for (j = 0; j < cs.length; j++) byCi[ciOf(cs[j])] = cs[j];
      for (j = 0; j < n; j++) { c = byCi[order[j]]; if (c) r.appendChild(c); }
    }
    if (sortedCi !== null) { var np = colByCi(hr, sortedCi); if (np >= 0) table.setAttribute("data-sort-col", String(np)); }
    syncGroups(table, hr);
    placeHotspots(table, hr);
  }
  // Column GROUPS (a banner row of spanned header cells above the flat
  // header, the gsep= dividers on each group's first column): initGroups maps
  // every built column to its group and remembers each banner cell's columns
  // and each group's divider class; syncGroups, after any move or hide, sets
  // every banner cell's span to its VISIBLE column count (hidden when none)
  // and moves the divider to the group's first visible column — mirrored into
  // data-origc so a recalc restore keeps it. Drags never cross a group.
  function initGroups(table, hr) {
    var n = hr.cells.length, gid = [], banners = [], seps = {}, labels = {}, i, j, r, cs, g = 0, ci, k, sp;
    for (i = 0; i < n; i++) gid[i] = 0;
    for (i = 0; i < table.rows.length; i++) {
      r = table.rows[i]; if (r === hr || !r.getElementsByTagName("th").length) continue;
      var defines = !table._bannerRow;               // the FIRST banner row defines the groups
      if (defines) table._bannerRow = r;
      cs = r.cells; ci = 0; g = 0;
      for (j = 0; j < cs.length; j++) {
        sp = cs[j].colSpan || 1; var cis = [];
        for (k = 0; k < sp; k++) { cis.push(ci + k); if (defines) gid[ci + k] = g; }
        banners.push({ cell: cs[j], cis: cis });
        if (defines) labels[g] = cs[j].textContent.trim();
        ci += sp; g++;
      }
    }
    for (i = 0; i < n; i++) {
      var th = hr.cells[i], m = / (gsep)( |$)/.exec(" " + th.className + " ");
      if (m && !(gid[i] in seps)) seps[gid[i]] = m[1];
    }
    table._colGroup = gid; table._banners = banners; table._groupSep = seps; table._groupLabel = labels;
    table._nGroups = table._bannerRow ? table._bannerRow.cells.length : 1;
  }
  function groupOf(table, ci) { return (table._colGroup && table._colGroup[ci] !== undefined) ? table._colGroup[ci] : 0; }
  function isSpacer(cell) { return !!cell && / (spc|sp) /.test(" " + cell.className + " "); }
  function spacerCi(table, hr, ci) { var c = cellByCi(hr, ci); return isSpacer(c); }
  function syncGroups(table, hr) {
    if (!table._banners || !table._banners.length) return;
    var n = hr.cells.length, hidden = table._colHiddenAll || table._colHidden || [], hid = {}, i, j, b, vis, order, firstVis = {}, g, rows, r, cs, c, ci, cls, want, has;
    for (i = 0; i < hidden.length; i++) hid[hidden[i]] = 1;
    var gvis = {}, lastVis = {}, sp = {}, spHide = {}, nextG;
    for (i = 0; i < table._banners.length; i++) {
      b = table._banners[i]; vis = 0;
      for (j = 0; j < b.cis.length; j++) if (!hid[b.cis[j]]) vis++;
      b.cell.colSpan = vis || 1; b.cell.hidden = vis === 0;
    }
    // the divider: each group's first VISIBLE column in the current order —
    // and its last, for the edge classes of the home per-day table
    order = curOrder(hr);
    for (i = 0; i < order.length; i++) { ci = order[i]; if (spacerCi(table, hr, ci)) { sp[ci] = 1; continue; } if (hid[ci]) continue; g = groupOf(table, ci); gvis[g] = (gvis[g] || 0) + 1; if (!(g in firstVis)) firstVis[g] = ci; lastVis[g] = ci; }
    // a spacer column stands before a group: hidden when that group is fully
    // hidden (else the gap would double up), shown again with it
    for (i = 0; i < order.length; i++) {
      ci = order[i]; if (!sp[ci]) continue;
      nextG = null; for (j = i + 1; j < order.length; j++) if (!sp[order[j]]) { nextG = groupOf(table, order[j]); break; }
      spHide[ci] = (nextG !== null && !gvis[nextG]) ? 1 : 0;
    }
    rows = table.rows;
    for (i = 0; i < rows.length; i++) {
      r = rows[i]; cs = r.cells; if (cs.length !== n) continue;
      for (j = 0; j < cs.length; j++) {
        c = cs[j]; ci = ciOf(c); g = groupOf(table, ci); want = table._groupSep[g] || "";
        if (sp[ci]) { c.hidden = !!spHide[ci]; continue; }   // a spacer: follows its group, carries no divider or edge
        // the group EDGES (the home per-day table, class-based since the
        // visible first/last column of a group moves with the picker)
        var el = (firstVis[g] === ci), er = (lastVis[g] === ci), cl2 = c.className.replace(/ ?\bgedge-[lr]\b/g, "");
        if (el) cl2 += " gedge-l"; if (er) cl2 += " gedge-r";
        if (cl2 !== c.className) c.className = cl2.replace(/^ /, "");
        if (c.hasAttribute("data-origc")) { var oc2 = c.getAttribute("data-origc").replace(/ ?\bgedge-[lr]\b/g, ""); if (el) oc2 += " gedge-l"; if (er) oc2 += " gedge-r"; c.setAttribute("data-origc", oc2.replace(/^ /, "")); }
        cls = " " + c.className + " "; has = / gsep /.test(cls);
        if (want && firstVis[g] === ci) { if (!(new RegExp(" " + want + " ")).test(cls)) c.className = (c.className.replace(/ ?\bgsep\b/g, "") + " " + want).replace(/^ /, ""); }
        else if (has) c.className = c.className.replace(/ ?\bgsep\b/g, "");
        if (c.hasAttribute("data-origc")) {   // keep the restore in step
          var oc = c.getAttribute("data-origc").replace(/ ?\bgsep\b/g, "");
          if (want && firstVis[g] === ci) oc = (oc + " " + want).replace(/^ /, "");
          c.setAttribute("data-origc", oc);
        }
      }
    }
  }
  // Hidden columns (the "cols" picker): the cells carry the hidden ATTRIBUTE —
  // a class would not survive the className restores of the recalc paths.
  function loadHidden(key, n) {
    try {
      var v = JSON.parse(localStorage.getItem(key) || "null"), out = [], i;
      if (!v || !v.length) return [];
      for (i = 0; i < v.length; i++) if (typeof v[i] === "number" && v[i] >= 0 && v[i] < n && out.indexOf(v[i]) < 0) out.push(v[i]);
      return out.length >= n ? [] : out;   // never every column
    } catch (e) { return []; }
  }
  function saveHidden(key, hidden) {
    try { if (hidden.length) localStorage.setItem(key, JSON.stringify(hidden)); else localStorage.removeItem(key); } catch (e) {}
  }
  // `hidden` is the USER's list (the picker, persisted); the AUTO-hidden
  // columns (autoHideGroups — an empty group after a range change or a
  // search, table._autoHidden) join it for the cells and the banner spans
  // but never enter the stored list.
  function applyHidden(table, hr, hidden) {
    var n = hr.cells.length, rows = table.rows, i, j, r, cs, set = {}, c, all = hidden.slice(), auto = table._autoHidden || [];
    for (i = 0; i < auto.length; i++) if (all.indexOf(auto[i]) < 0) all.push(auto[i]);
    for (i = 0; i < all.length; i++) set[all[i]] = 1;
    table._colHidden = hidden; table._colHiddenAll = all;
    for (i = 0; i < rows.length; i++) {
      r = rows[i]; cs = r.cells;
      if (cs.length === 1 && !r.getElementsByTagName("th").length) continue;
      if (cs.length !== n && isTotal(r) && all.length) splitSpans(r);
      for (j = 0; j < cs.length; j++) { c = cs[j]; c.hidden = !!set[ciOf(c)]; }
    }
    syncGroups(table, hr);
    placeHotspots(table, hr);
  }
  // AUTO-HIDE an EMPTY column group (the autohide= TABLE modifier ->
  // data-autohide="Group;Group", the Entities pages' Retry / Resubmit and
  // State, 2026-09-13, user request): when every VISIBLE data row's cells of
  // a named group are empty — after a date-range change or a search — the
  // group's columns hide (the hidden attribute, the banner cell with them,
  // via applyHidden); they come back the moment a visible row carries a
  // value. The full period's empty groups are already gone at publish time
  // (publish_lib entity_hide_groups); this is the same rule for the range.
  function autoHideGroups(table) {
    var spec = table.getAttribute("data-autohide");
    if (!spec || !table._colGroup || !table._groupLabel) return;
    var hr = headerRow(table); if (!hr) return;
    var want = {}, groups = {}, hide = [], ci, g, k, rows, i, j, cis, any, cell;
    spec.split(";").forEach(function (s) { s = s.trim(); if (s) want[s] = 1; });
    for (ci = 0; ci < hr.cells.length; ci++) {
      k = ciOf(hr.cells[ci]); g = groupOf(table, k);
      if (want[table._groupLabel[g]]) (groups[g] = groups[g] || []).push(k);
    }
    rows = dataRows(table).filter(function (r) { return r.style.display !== "none"; });
    for (g in groups) {
      cis = groups[g]; any = false;
      for (i = 0; i < rows.length && !any; i++)
        for (j = 0; j < cis.length; j++) { cell = cellByCi(rows[i], cis[j]) || rows[i].cells[cis[j]]; if (cell && cell.textContent.trim() !== "") { any = true; break; } }
      if (!any) for (j = 0; j < cis.length; j++) hide.push(cis[j]);
    }
    var before = (table._autoHidden || []).join(","), after = hide.join(",");
    if (before === after) return;
    table._autoHidden = hide;
    applyHidden(table, hr, table._colHidden || []);
  }
  function initColOrder(table) {
    var hr = headerRow(table); if (!hr) return;
    if (!colMovable(table, hr)) return;
    var n = hr.cells.length, i, j, r, cs, ci;
    for (i = 0; i < table.rows.length; i++) {           // stamp the built index on every cell
      r = table.rows[i]; cs = r.cells;
      if (cs.length === 1 && !r.getElementsByTagName("th").length) continue;
      ci = 0;
      for (j = 0; j < cs.length; j++) { cs[j].setAttribute("data-ci", String(ci)); ci += cs[j].colSpan || 1; }
    }
    initGroups(table, hr);
    var key = colOrderKey(table, hr), hkey = "colhide:" + key.slice(9), labels = [];
    for (i = 0; i < n; i++) labels.push(thLabel(hr.cells[i]));
    // the reset: the Reset link at the foot of the picker (the ↺ hotspot it
    // replaced is gone, user request 2026-09-06) — built order AND every column
    function resetColumns() {
      var idn = [], k; for (k = 0; k < n; k++) idn.push(k);
      applyHidden(table, hr, []); saveHidden(hkey, []);
      applyOrder(table, hr, idn); saveOrder(key, idn, true);
    }
    // the "cols" hotspot + its picker: one checkbox per column, in the current order
    var pb = document.createElement("span"), pop = document.createElement("div"), host = null;
    pb.className = "pickbtn"; pb.textContent = "cols"; pb.title = "Choose the columns to show";
    pop.className = "colpick";
    // The popover is positioned against the VIEWPORT (position:fixed), not the
    // host cell: the .tablewrap scroll box clips anything that sticks out of
    // it, which cut the list off at the top of a table shorter than the list
    // (2026-09-06). Above the button when there is room, else below, else on
    // the larger side with a matching max-height; re-placed on scroll/resize.
    function pickPlace() {
      var br = pb.getBoundingClientRect(), vh = window.innerHeight, vw = window.innerWidth, h, w, above, below, top, left;
      pop.style.maxHeight = ""; h = pop.offsetHeight; w = pop.offsetWidth;
      above = br.top - 6; below = vh - br.bottom - 6;
      if (h <= above) top = br.top - h;
      else if (h <= below) top = br.bottom;
      else if (above >= below) { pop.style.maxHeight = above + "px"; h = pop.offsetHeight; top = br.top - h; }
      else { pop.style.maxHeight = below + "px"; top = br.bottom; }
      left = br.right - w; if (left < 4) left = 4; if (left + w > vw - 4) left = Math.max(4, vw - 4 - w);
      pop.style.top = Math.max(2, top) + "px"; pop.style.left = left + "px";
    }
    function pickClose() {
      pop.className = "colpick"; host = null;
      window.removeEventListener("scroll", pickPlace, true); window.removeEventListener("resize", pickPlace);
    }
    function pickOpen() {
      pop.innerHTML = "";
      var hid = table._colHidden || [], k, th, ci, lab, cb, row, grip, dragCi = null, lastG = null, gh;
      function clearOver() { var rs = pop.querySelectorAll(".cprow"); for (var q = 0; q < rs.length; q++) rs[q].className = rs[q].className.replace(/ ?\bover-[tb]\b/g, ""); }
      for (k = 0; k < hr.cells.length; k++) {
        th = hr.cells[k]; ci = ciOf(th);
        if (isSpacer(th)) continue;   // spacer columns are not offered
        if (table._nGroups > 1 && groupOf(table, ci) !== lastG) {   // a heading per column group; moves stay under it
          lastG = groupOf(table, ci);
          gh = document.createElement("div"); gh.className = "cpgrp";
          gh.textContent = (table._groupLabel && table._groupLabel[lastG]) || (labels[ci] + " …");   // an unlabelled band (the leading Date/First/Last block): its first column names it
          pop.appendChild(gh);
        }
        // one row per column, in the current order: a grip, the checkbox, the
        // label. The row is draggable — dropping it on another row moves the
        // column there (user request 2026-09-06). This is the ONE way to
        // reorder: dragging the header itself was removed the same day
        // (user request — the picker handles it)
        row = document.createElement("div"); row.className = "cprow"; row.draggable = true;
        grip = document.createElement("span"); grip.className = "grip"; grip.textContent = "⋮⋮"; grip.title = "Drag up or down to move this column";
        lab = document.createElement("label"); cb = document.createElement("input"); cb.type = "checkbox";
        cb.checked = hid.indexOf(ci) < 0; lab.className = cb.checked ? "" : "off";
        lab.appendChild(cb); lab.appendChild(document.createTextNode(labels[ci] || ""));
        row.appendChild(grip); row.appendChild(lab);
        (function (ci, lab, cb, row) {
          cb.addEventListener("change", function () {
            var cur = (table._colHidden || []).slice(), at = cur.indexOf(ci);
            if (cb.checked) { if (at >= 0) cur.splice(at, 1); }
            else { if (at < 0) cur.push(ci); if (cur.length >= n) { cur.pop(); cb.checked = true; return; } }   // never every column
            lab.className = cb.checked ? "" : "off";
            applyHidden(table, hr, cur); saveHidden(hkey, cur);
          });
          row.addEventListener("dragstart", function (e) {
            dragCi = ci; row.className += " dragging";
            try { e.dataTransfer.effectAllowed = "move"; e.dataTransfer.setData("text/plain", String(ci)); } catch (x) {}
            e.stopPropagation();
          });
          row.addEventListener("dragend", function () { dragCi = null; row.className = row.className.replace(/ ?\bdragging\b/, ""); clearOver(); });
          row.addEventListener("dragover", function (e) {
            if (dragCi === null || dragCi === ci) return;
            if (groupOf(table, dragCi) !== groupOf(table, ci)) return;   // a move never leaves its group
            e.preventDefault(); try { e.dataTransfer.dropEffect = "move"; } catch (x) {}
            var rc = row.getBoundingClientRect(), upper = e.clientY < rc.top + rc.height / 2;
            clearOver(); row.className += upper ? " over-t" : " over-b";
          });
          row.addEventListener("dragleave", function () { row.className = row.className.replace(/ ?\bover-[tb]\b/g, ""); });
          row.addEventListener("drop", function (e) {
            if (dragCi === null || dragCi === ci) return;
            if (groupOf(table, dragCi) !== groupOf(table, ci)) return;
            e.preventDefault(); e.stopPropagation();
            var rc = row.getBoundingClientRect(), upper = e.clientY < rc.top + rc.height / 2;
            var order = curOrder(hr), from = order.indexOf(dragCi), to = order.indexOf(ci) + (upper ? 0 : 1);
            if (from < 0 || to < 0) return;
            var moved = order.splice(from, 1)[0]; if (to > from) to--; order.splice(to, 0, moved);
            dragCi = null; clearOver();
            applyOrder(table, hr, order); saveOrder(key, order, isIdentity(order));
            pickOpen();   // the list in the new order, still open
          });
        })(ci, lab, cb, row);
        pop.appendChild(row);
      }
      var all = document.createElement("span"); all.className = "cpall"; all.textContent = "Reset";
      all.title = "Back to the built columns: the original order, every column shown";
      all.addEventListener("click", function () { resetColumns(); pickOpen(); });
      pop.appendChild(all);
      pop.className = "colpick open";
      pickPlace();
      window.addEventListener("scroll", pickPlace, true); window.addEventListener("resize", pickPlace);
      host = pop.parentNode;
    }
    pb.addEventListener("click", function (e) {
      e.preventDefault(); e.stopPropagation();
      if (/\bopen\b/.test(pop.className)) pickClose(); else pickOpen();
    });
    pop.addEventListener("click", function (e) { e.stopPropagation(); });   // never the header's sort click
    pop.addEventListener("mousedown", function (e) { e.stopPropagation(); });
    document.addEventListener("click", function (e) { if (/\bopen\b/.test(pop.className) && !pop.contains(e.target) && e.target !== pb) pickClose(); });
    document.addEventListener("keydown", function (e) { if (e.key === "Escape" && /\bopen\b/.test(pop.className)) pickClose(); });
    table._colTools = { pb: pb, pop: pop };
    var stored = loadOrder(key, n);
    if (stored && !isIdentity(stored)) applyOrder(table, hr, stored);
    var hidden = loadHidden(hkey, n);
    if (hidden.length) applyHidden(table, hr, hidden);
    else if (table._banners && table._banners.length) syncGroups(table, hr);   // the edge classes of a grouped table, from the start
    // (the tools are attached by init() once every snapshot is taken — see placeHotspots)
    // NOTE: syncGroups ran inside applyOrder/applyHidden when a stored setting
    // existed; without one the built markup already agrees with itself
    // the safety net: whatever rewrote or re-ordered the host cell, the next
    // pointer pass over the table puts the tools back where they belong
    table.addEventListener("mouseover", function () { if (table._toolsOn && pb.parentNode !== colHostCell(table)) placeHotspots(table, hr); });
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
    var out = [], r = table.rows, i;
    for (i = 0; i < r.length; i++) {
      if (!r[i].getElementsByTagName("th").length && !isTotal(r[i]) &&
          r[i].className.indexOf("coreid-detail") < 0 &&
          r[i].className.indexOf("pagerrow") < 0 &&
          r[i].className.indexOf("foldrow") < 0) out.push(r[i]);   // skip injected drill-down rows, the pager footer and fold summaries
    }
    return out;
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
      var c0 = cell0(tr);
      if (c0 && !tr.hasAttribute("data-g")) tr.setAttribute("data-g", c0.innerHTML);
    });
  }
  // Put the real value back into col 0 (undo blanking) — used before sorting.
  function ungroup(table) {
    if (!isGrouped(table)) return;
    dataRows(table).forEach(function (tr) {
      var g = tr.getAttribute("data-g"), c0 = cell0(tr);
      if (c0 && g !== null) c0.innerHTML = g;
    });
  }
  // Blank col 0 when it repeats the previous VISIBLE row's value.
  function applyGroup(table) {
    if (!isGrouped(table)) return;
    var last = null;
    dataRows(table).forEach(function (tr) {
      var c = cell0(tr); if (!c) return;
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
  // The grouped-Entities spellings (2026-09-13, user request; bin/transfer/reports/
  // entities.sh spells the baked cells the same way): bytes in WHOLE units,
  // a duration as a whole number with a one-letter unit (s m h d), tinted by
  // its unit — s green (processed) · m amber (warn) · h/d red (failed). The
  // tint classes are the row-tint-proof ones (.failed / .processed keep their
  // background inside a tinted row; .warn does by its own rule).
  function humanBytesInt(b) {
    var u = ["B", "KB", "MB", "GB", "TB", "PB"], i = 0, v = b;
    while (v >= 1024 && i < 5) { v /= 1024; i++; }
    return Math.round(v) + " " + u[i];
  }
  function humanDurShort(ms) {
    var v = ms / 1000;
    if (v < 59.5) return Math.round(v) + " s";
    v /= 60; if (v < 59.5) return Math.round(v) + " m";
    v /= 60; if (v < 23.5) return Math.round(v) + " h";
    return Math.round(v / 24) + " d";
  }
  function durTint(ms) { var v = ms / 1000; if (v < 59.5) return "processed"; if (v / 60 < 59.5) return "warn"; return "failed"; }

  // ---- generic per-date re-aggregation (the date filter) --------------------
  // A row carries data-buckets = "date:m0:m1:...,date:m0:m1:..." (raw per-date
  // base metrics); the table carries data-recalc = one token per column telling
  // how to rebuild that column's cell from the metrics summed over the selected
  // range. Tokens: "-"/"k" keep · sN sum(N) · hN humanBytes(sum N) · %N share
  // (100*sumN/columnTotalN) · pN.M 100*sumN/sumM · aN round(sumN/days) · c
  // in-range day count · dN count of in-range days with metric N > 0 ·
  // qN.M humanDur(sumN/sumM) · xN humanDur(max N) · tN.M
  // humanBytes(sumN*1000/sumM)+"/s" · bN bar
  // of sumN vs column max · rN position by column N descending (rN.a
  // ascending, rN.z zeros last) — see rankCols.
  // The grouped-Entities variants (2026-09-13): SN sum, BLANK when 0 · eN.M the
  // pN.M rate, BLANK when sumN is 0 (an empty Error keeps an empty rate) ·
  // HN the hN bytes in WHOLE units · VN.M sumN/sumM bytes in whole units · PN the nearest-rank
  // percentile N of the row's per-day DURATION histograms (data-durdays, see
  // aggDurDays), spelled s/m/h/d and TINTED by its unit (writeRecalc).
  // `dates` = the in-range dates themselves (a set): recalcTable unions them
  // over the visible rows so the TOTAL row's `c`/`a` tokens count DISTINCT
  // days, not 0 (2026-09-13; the total's day count was never set before).
  function aggBuckets(str, lo, hi) {
    var sum = {}, max = {}, pos = {}, dates = {}, days = 0, i, v;
    if (str) str.split(",").forEach(function (seg) {
      if (!seg) return;
      var pp = seg.split(":"), e = parseDate(pp[0]);
      if (e === null || e < lo || e > hi) return;
      days++; dates[pp[0]] = 1;
      for (i = 1; i < pp.length; i++) {
        v = +pp[i] || 0; sum[i - 1] = (sum[i - 1] || 0) + v;
        if (max[i - 1] == null || v > max[i - 1]) max[i - 1] = v;
        if (v > 0) pos[i - 1] = (pos[i - 1] || 0) + 1;
      }
    });
    return { sum: sum, max: max, pos: pos, days: days, dates: dates };
  }
  // Per-day DURATION histograms (the Entities Duration group, 2026-09-13):
  // data-durdays = "date:q.c;q.c,date:…" — per date the humanDur display-grid
  // value q (ms) and its count c, written by bin/transfer/reports/entities.sh.
  // aggDurDays merges the in-range days into one histogram, mergeDur folds
  // rows together (the TOTAL row), and pctlHist picks the nearest-rank
  // percentile the writers use — T[int((N-1)·P/100+0.5)+1] over the sorted
  // values — so the full-range figure equals the baked one.
  function aggDurDays(str, lo, hi) {
    var h = {}, n = 0;
    if (str) str.split(",").forEach(function (seg) {
      var p = seg.indexOf(":"); if (p < 1) return;
      var e = parseDate(seg.slice(0, p)); if (e === null || e < lo || e > hi) return;
      seg.slice(p + 1).split(";").forEach(function (qc) {
        var d = qc.indexOf("."); if (d < 1) return;
        var q = +qc.slice(0, d), c = +qc.slice(d + 1) || 0;
        if (!(c > 0)) return;
        h[q] = (h[q] || 0) + c; n += c;
      });
    });
    return { h: h, n: n };
  }
  function mergeDur(into, d) { var q; if (!d) return; for (q in d.h) into.h[q] = (into.h[q] || 0) + d.h[q]; into.n += d.n; }
  function pctlHist(d, P) {
    if (!d || !d.n) return null;
    var keys = Object.keys(d.h).map(Number).sort(function (a, b) { return a - b; });
    var r = Math.floor((d.n - 1) * P / 100 + 0.5) + 1, cum = 0, i;
    for (i = 0; i < keys.length; i++) { cum += d.h[keys[i]]; if (cum >= r) return keys[i]; }
    return keys[keys.length - 1];
  }
  // ---- date-aware STAT boxes ------------------------------------------------
  // A .stat carrying data-tok recomputes its value for the selected range from
  // its data-sb per-day payload; the full range restores the baked original
  // (the recalcTable rule). Payload "date:V,date:V" — V per token:
  //   sum     V = count                    -> plain sum
  //   share   V = total:matching           -> 100*sum(matching)/sum(total) "%"
  //   uniq    V = id|id|...                -> size of the id UNION over the
  //           range (recovered-files: distinct subscriptions/protocols).
  // (the maxdur / p50 / p90 tokens and the data-thr retint went 2026-09-29:
  // their one producer, recovered-files.sh, emits sum / share / uniq only)
  function recalcStats(lo, hi, narrowed) {
    var els = document.querySelectorAll(".stat[data-tok]"), i, j, k;
    for (i = 0; i < els.length; i++) {
      var el = els[i], vEl = el.querySelector(".stat-v");
      if (!vEl) continue;
      if (!el.hasAttribute("data-vorig")) el.setAttribute("data-vorig", vEl.textContent);
      if (!narrowed) { vEl.textContent = el.getAttribute("data-vorig"); continue; }
      var tok = el.getAttribute("data-tok"), segs = (el.getAttribute("data-sb") || "").split(","), out = "-";
      var tot = 0, mt = 0, map = {}, pp, e;
      for (j = 0; j < segs.length; j++) {
        if (!segs[j]) continue;
        pp = segs[j].split(":"); e = parseDate(pp[0]);
        if (e === null || e < lo || e > hi) continue;
        if (tok === "sum") tot += +pp[1] || 0;
        else if (tok === "share") { tot += +pp[1] || 0; mt += +pp[2] || 0; }
        else if (tok === "uniq") { var us = pp[1].split("|"); for (k = 0; k < us.length; k++) if (us[k]) map[us[k]] = 1; }
      }
      if (tok === "sum") out = String(tot);
      else if (tok === "uniq") out = String(Object.keys(map).length);
      else if (tok === "share") out = (tot ? 100 * mt / tot : 0).toFixed(1) + "%";
      vEl.textContent = out;
    }
  }
  function recalcCell(tok, agg, colSum) {
    var t = tok.charAt(0), rest = tok.slice(1), N, p, den, pv;
    if (t === "P") { pv = pctlHist(agg.dur, +rest); return pv === null ? "" : humanDurShort(pv); }
    if (t === "S") { pv = agg.sum[+rest] || 0; return pv ? String(pv) : ""; }
    if (t === "e") { p = rest.split("."); pv = agg.sum[+p[0]] || 0; den = agg.sum[+p[1]] || 0; return (pv && den) ? (100 * pv / den).toFixed(1) + "%" : ""; }
    if (t === "H") return humanBytesInt(agg.sum[+rest] || 0);
    if (t === "V") { p = rest.split("."); den = agg.sum[+p[1]] || 0; return den ? humanBytesInt((agg.sum[+p[0]] || 0) / den) : ""; }
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
    if (t === "P") return pctlHist(agg.dur, +rest);
    if (t === "s" || t === "h" || t === "S" || t === "H") return agg.sum[+rest] || 0;
    if (t === "e") { p = rest.split("."); den = agg.sum[+p[1]] || 0; return den ? 100 * (agg.sum[+p[0]] || 0) / den : 0; }
    if (t === "V") { p = rest.split("."); den = agg.sum[+p[1]] || 0; return den ? (agg.sum[+p[0]] || 0) / den : null; }
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
    var ci, c, span = 0, byci = cellByCi(tr, dcol);
    if (byci) { byci.textContent = txt; return; }
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
          // The tinted count kinds (Error/OK, the tint-only errc/okc pairs and the amber
          // warn cells — Cured, Recovered) remember their class so the 0->blank toggle can
          // restore it; without the snapshot writeRecalc has nothing to key its blanking on
          // and a narrowed range printed a literal 0 (2026-09-10, the Cured column).
          if (/ (failed|processed|errc|okc|warn) /.test(" " + c.className + " ") && !c.hasAttribute("data-origc")) c.setAttribute("data-origc", c.className);
        }
      }
    }
  }
  // Rewrite one row's cells from its aggregated metrics (dcol tracks the logical
  // column across colspans). Bars need the column max; shares need the column sum.
  function writeRecalc(tr, toks, agg, colSum, colMax, colMaxA, isTot) {
    var dcol = 0, ci, c, span, tok, v, N, mx, w, oc, base, av, pms;
    for (ci = 0; ci < tr.cells.length; ci++) {
      c = tr.cells[ci]; span = c.colSpan || 1; tok = toks[c.hasAttribute("data-ci") ? +c.getAttribute("data-ci") : dcol] || "-";
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
            if (tok.charAt(0) === "P") {
              // a Duration percentile cell: the value AND its unit tint (s
              // green · m amber · h/d red); the divider class stays
              base = (oc !== null ? oc : c.className).replace(/\b(processed|failed|warn|okc|errc|z)\b/g, "").replace(/\s+/g, " ").trim();
              pms = pctlHist(agg.dur, +tok.slice(1));
              setCellVal(c, v); c.className = pms === null ? base : base + " " + durTint(pms);
            } else if (oc !== null && /failed|processed|errc|okc|warn/.test(oc)) {    // tinted count kinds: a 0 -> blank + no tint (matches render_rpt's z rule; warn untints via td.warn:empty)
              base = oc.replace(/ ?\bz\b/g, "");
              if (v === "0") { c.textContent = ""; c.className = base + " z"; }
              else { setCellVal(c, v); c.className = base; }
            } else { setCellVal(c, v); }
          }
        }
      }
      dcol += span;
    }
  }
  // A recalculated value keeps the cell's ONE link (2026-09-30: the Entities
  // Waiting / Expired cells link their pages — writing the cell's textContent
  // dropped the <a> while a range was narrowed). A blank value blanks the whole
  // cell (a 0 links nothing); the full-range restore brings the link back.
  function setCellVal(c, v) {
    var a = (c.children.length === 1 && c.firstElementChild.tagName === "A") ? c.firstElementChild : null;
    if (a && v !== "") a.textContent = v; else c.textContent = v;
  }
  function updateTotalLabel(tr, vis) {
    var c = cell0(tr); if (!c) return;
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
      autoHideGroups(table);   // an empty group hidden for the range comes back with its full-period values
      replaceHotspots(table);
      return;
    }
    var drows = dataRows(table), aggs = [];
    var zh = table.getAttribute("data-zerohide");
    zh = zh == null || zh === "" ? null : +zh;
    drows.forEach(function (r, x) {
      aggs[x] = aggBuckets(r.getAttribute("data-buckets"), lo, hi);
      if (r.hasAttribute("data-durdays")) aggs[x].dur = aggDurDays(r.getAttribute("data-durdays"), lo, hi);   // the Duration percentiles (P tokens)
    });
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
    var colSum = {}, colMax = {}, colMaxA = {}, vis = 0, totDates = {}, totDays = 0, dk, totDur = { h: {}, n: 0 };
    drows.forEach(function (r, x) {
      if (r.style.display === "none") return;
      var s = aggs[x].sum, m, d = aggs[x].days || 0, av;
      for (m in s) { colSum[m] = (colSum[m] || 0) + s[m]; if (colMax[m] == null || s[m] > colMax[m]) colMax[m] = s[m];
        av = d ? s[m] / d : 0; if (colMaxA[m] == null || av > colMaxA[m]) colMaxA[m] = av; }
      // the TOTAL row's day count = the DISTINCT in-range dates over the
      // visible rows (a per-row sum would count a shared day once per row)
      for (dk in (aggs[x].dates || {})) if (!totDates[dk]) { totDates[dk] = 1; totDays++; }
      mergeDur(totDur, aggs[x].dur);   // the TOTAL row's Duration percentiles: every visible row's in-range histogram
    });
    drows.forEach(function (r, x) {
      if (r.style.display === "none") return;
      vis++;
      if (!r.hasAttribute("data-buckets") && r.hasAttribute("data-seen")) return;   // config-only row: keep its blank cells
      writeRecalc(r, toks, aggs[x], colSum, colMax, colMaxA, false);
    });
    rankCols(toks, drows, aggs, colSum);   // positions renumber over the rows the range left standing
    var totAgg = { sum: colSum, max: {}, days: totDays, dur: totDur };
    // A TOTAL row that ships its OWN per-day buckets (2026-09-29: the Entities
    // totals of an OVERLAPPING membership — a File counts for every BL /
    // partner / application it belongs to, so the rows sum to more than the
    // distinct total the page bakes): its in-range DISTINCT figures — as long
    // as only the date filter hides rows. A search or view filter leaves the
    // visible-row sum the only honest total.
    var onlyDate = drows.every(function (r) {
      return r.getAttribute("data-shide") !== "1" && r.getAttribute("data-vhide") !== "1" && r.getAttribute("data-fhide") !== "1";
    });
    totalRows(table).forEach(function (r) {
      var ta = totAgg, tb;
      if (onlyDate && r.hasAttribute("data-buckets")) {
        tb = aggBuckets(r.getAttribute("data-buckets"), lo, hi);
        ta = { sum: tb.sum, max: {}, days: totDays, dur: totDur };
      }
      writeRecalc(r, toks, ta, colSum, colMax, colMaxA, true); updateTotalLabel(r, vis);
    });
    autoHideGroups(table);   // a group the range left empty on every visible row hides (data-autohide)
    replaceHotspots(table);
  }
  // ---- seen-rows tables (data-seenrows: the detail pages' entity tables) -----
  // Every data row carries data-seen (its full-period seen flag, 1/0) — the
  // green / red row tint recalcTable moves with the date range. (The Show-Seen
  // tables — data-seenmode all / seen / notseen and their seenword= intro
  // noun — went 2026-09-29: no writer emits them since showseen.sh stopped.)
  function initSeen(table) {
    // only the seen-rows tables (2026-09-29: it snapshotted every cell of
    // EVERY table — 28,000 on one page — while initRecalc already covers the
    // re-aggregatable ones)
    if (!table.getAttribute("data-seenrows")) return;
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
        if (/ (failed|processed|errc|okc|warn) /.test(" " + c.className + " ") && !c.hasAttribute("data-origc")) c.setAttribute("data-origc", c.className);
      }
    });
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
    // Marginal columns after the 7 weekday cells (the server Errors heatmap,
    // 2026-09-28: Errors / Warnings / Total per hour): re-summed from the
    // row's data-buckets (date:v1:v2:…), in column order; a zero failed/warn
    // cell stays blank like the renderer's z cells.
    var mTot = [];
    drows.forEach(function (r) {
      var b = r.getAttribute("data-buckets"); if (!b) return;
      var s = aggBuckets(b, lo, hi).sum;
      for (w = 8; w < r.cells.length; w++) {
        var v = s[w - 8] || 0; c = r.cells[w];
        mTot[w] = (mTot[w] || 0) + v;
        setMarginal(c, v);
      }
    });
    totalRows(table).forEach(function (tr) {
      for (w = 0; w < 7; w++) { c = tr.cells[w + 1]; if (c) c.textContent = String(colTot[w] || 0); }
      for (w = 8; w < tr.cells.length; w++) if (mTot[w] != null) setMarginal(tr.cells[w], mTot[w]);
    });
  }
  function setMarginal(c, v) {
    var zc = / (failed|warn) /.test(" " + c.className + " ");
    c.textContent = v || !zc ? String(v) : "";
    if (zc) c.classList.toggle("z", !v);
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
    // num / den may each be a "+"-joined LIST of columns (2026-09-13, the
    // Entities error rates: Error over Ok+Error, Error over In+Out).
    var pctMap = {}, pc = (table.getAttribute("data-pct") || "").split(";"), colPlain = {};
    // the column's RECALC token, where the table has one: the Entities
    // spellings (S = blank on 0, e = blank rate on 0, H = whole-unit bytes)
    // hold on the searched total too (2026-09-13)
    var rtoks = (table.getAttribute("data-recalc") || "").split(/\s+/);
    function rtok(ci) { return (rtoks[ci] || "-").charAt(0); }
    function pctCols(s) { return s.split("+").map(function (q) { return +q; }); }
    function pctSum(cols) { var s = 0, q; for (q = 0; q < cols.length; q++) s += colPlain[cols[q]] || 0; return s; }
    for (var y = 0; y < pc.length; y++) if (pc[y]) { var pt = pc[y].split(":"); pctMap[+pt[0]] = [pctCols(pt[1]), pctCols(pt[2])]; }
    // the visible-row sums of every additive column FIRST (by built index):
    // a moved ratio column may sit left of the columns it is computed from
    trs.forEach(function (tr) {
      var ci, cell, orig, dc, k, c, p;
      for (ci = 0; ci < tr.cells.length; ci++) {
        cell = tr.cells[ci]; dc = ciOf(cell);
        orig = cell.getAttribute("data-orig"); if (orig === null) orig = cell.textContent;
        if (asPlain(orig) === null || /^Totals?\b/.test(orig)) continue;
        var plain0 = 0;
        for (k = 0; k < visible.length; k++) {
          c = cellByCi(visible[k], dc) || visible[k].cells[dc]; if (!c) continue;
          p = asPlain(c.textContent.trim()); if (p !== null) plain0 += p;
        }
        colPlain[dc] = plain0;
      }
    });
    trs.forEach(function (tr) {
      var dataCol = 0, ci, cell, span, orig, isNum, isBytes;
      for (ci = 0; ci < tr.cells.length; ci++) {
        cell = tr.cells[ci]; span = cell.colSpan || 1;
        if (cell.hasAttribute("data-ci")) dataCol = +cell.getAttribute("data-ci");   // moved columns: the BUILT index
        orig = cell.getAttribute("data-orig"); if (orig === null) orig = cell.textContent;
        isNum = asPlain(orig) !== null; isBytes = !isNum && asBytes(orig) !== null;
        // the Search page's footer label counts BOTH sides, always:
        // "N of M rows shown" (2026-09-30: "N rows showed from a total of M
        // rows" before) — M respects the type
        // checkboxes (setupSearchConfig stamps data-typecount per apply)
        if (dataCol === 0 && table.getAttribute("data-esearch") && /^Totals?\b/.test(orig)) {
          var tot5 = parseInt(table.getAttribute("data-typecount"), 10);
          if (isNaN(tot5)) tot5 = drows.length;
          cell.textContent = visible.length + " of " + tot5 + (tot5 === 1 ? " row" : " rows") + " shown";
          dataCol += span; continue;
        }
        if (hiddenCount === 0) {
          cell.textContent = orig;                                   // unfiltered -> exact original
        } else if (/^Totals?\b/.test(orig) || (dataCol === 0 && orig !== "" && !isNum && !isBytes)) {
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
          var nd = pctMap[dataCol], den = pctSum(nd[1]), num = pctSum(nd[0]);
          cell.textContent = (rtok(dataCol) === "e" && !(num > 0)) ? "" : (den ? (100 * num / den).toFixed(1) : "0.0") + "%";
        } else if (isNum) {                                     // declared additive count
          cell.textContent = (rtok(dataCol) === "S" && !(colPlain[dataCol] > 0)) ? "" : String(colPlain[dataCol] || 0);   // summed in the first pass (blank / "-" / text cells contribute 0)
        } else if (isBytes) {                                   // declared additive volume
          var bytes = 0, k2, b;
          for (k2 = 0; k2 < visible.length; k2++) {
            var c2 = cellByCi(visible[k2], dataCol) || visible[k2].cells[dataCol]; if (!c2) continue;
            b = asBytes(c2.textContent.trim());
            if (b !== null) bytes += b;
          }
          cell.textContent = visible.length === 0 ? "0 B" : (rtok(dataCol) === "H" ? humanBytesInt(bytes) : humanBytes(bytes));
        } else {
          cell.textContent = "–";                               // average/summary text: an all-rows figure would be false here
        }
        dataCol += span;
      }
    });
    replaceHotspots(table);
  }

  // A table can respond to the date filter only if it carries a date dimension:
  // a re-aggregatable data-buckets row, or at least one parseable date cell
  // (per-day tables, and First/Last columns on the summary tables). Aggregate
  // tables (by protocol, by direction, remote hosts, ciphers, ...) have neither,
  // so a narrowed range leaves their all-period numbers unchanged — which reads
  // as "filtered" unless we say otherwise.
  function isDateAware(table) {
    if (table.dateAware != null) return table.dateAware;   // structural; cache it
    // an ENGINE-owned table (rangehook, search/all-files.html): its rows follow the
    // range through the page engine's hook (apply() below) — date-aware, so the
    // From/To controls appear and no full-period badge shows, while its
    // nofilter keeps apply() from hiding the engine's rows itself
    if (table.getAttribute("data-rangehook")) { table.dateAware = true; return true; }
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
  // (The one-line search-syntax hint below the search boxes (wildcards,
  // quotes, and / or / not) went 2026-09-30, user request: "Remove below text everywhere on the
  // site"; the search syntax is on the help page, help/general.html)
  function setupSearchConfig() {
    var table = document.querySelector("table[data-esearch]");
    if (!table) return;
    // The panel's checkboxes filter the Type column and its view toggle the
    // seen flags — both Entity Search concepts. A second esearch page existed
    // 2026-08..09-29 (File search: Name/Date/Subscription/State/Size/CoreId),
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
      { label: "BL",           types: ["BL"],                          on: false },
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
      // "N of M rows shown": M is every entity of the selected
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
    // insert right after the title (a report page renders no intro)
    var h1 = document.getElementsByTagName("h1")[0];
    if (h1 && h1.parentNode) h1.parentNode.insertBefore(box, h1.nextSibling);
    refreshMap(); apply();   // the defaults take effect immediately
    // put the cursor in the search field on load (Entity Search is search-first)
    var sfocus = box.querySelector("input.search");
    if (sfocus) sfocus.focus();
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
    var SHORT = { "Activity per day": "Day",
                  "Load by hour": "Hour", "Load by weekday": "Weekday",
                  "Whitelisted by": "Whitelist",
                  "Last server log messages": "Server log",
                  "Last server log errors": "Server errors" };
    // a SIDE-BY-SIDE row (div.sxs) gets ONE combined button — labeled by the
    // row's FIRST visible table, mapped to a row name (fallback: that table's
    // own short label)
    var ROWLABEL = { "Load by weekday": "Load", "Load by hour": "Load",
                     "Incoming connections": "Connections", "Outgoing connections": "Connections",
                     "Dwell": "Statistics", "Duration per leg": "Statistics" };
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
      if (!label) continue;                               // every detail-page section has its <h2>
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
      if (tables[t].getAttribute("data-subfiles")) continue;   // the Files table: sub-files.js fills it later
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
  // "date time  coreid" entries, one open at a time. A row-level list
  // (data-coreids) binds the row; per-cell lists (data-coreids-failed /
  // data-coreids-processed, drill-cell-N, drillcols= keys) bind their cell. The detail rows are excluded from dataRows and torn down
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
      // A LISTED FILE THAT HAS A FILE PAGE LINKS IT (2026-09-29 audit — the
      // 2026-09-21 rule linked only the FIRST entry under a red / orange
      // cell; with the published File-page set, per subscription the newest
      // OK and the three newest Failed Files, that hid most pages): render_rpt
      // names on the row (data-fp) every File of its shipped File lists that
      // has a page, so any entry whose CoreId is listed there opens
      // files/<coreid>.html, whatever the cell. The File Tracking link stays:
      // addCoreIdLinks puts its ↗ after an id that already is a link. A list
      // whose unit is not the File (the leg tables, unit "transfer": their
      // ids are TRANSFER ids) stays text.
      var fpset = " " + (row.getAttribute("data-fp") || "") + " ";
      var ro = (!unit || unit === "File") && fpset !== "  ";
      var tb9 = ro ? document.querySelector("div.topbar") : null;
      var root9 = tb9 ? (tb9.getAttribute("data-b") || "") : "";
      entries.forEach(function (e) {
        var line = document.createElement("div");
        // a server-log LINE never wraps (2026-09-30, user request): class
        // logline (style.css) — the drill cell widens the table instead
        line.className = unit === "log line" ? "coreid-item logline" : "coreid-item";
        var m9 = ro ? /\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b/.exec(e) : null;
        if (m9 && fpset.indexOf(" " + m9[0] + " ") < 0) m9 = null;   // no published page: plain text
        if (m9) {
          var fa = document.createElement("a");
          fa.href = root9 + "files/" + m9[0] + ".html";
          fa.textContent = m9[0];
          line.appendChild(document.createTextNode(e.slice(0, m9.index)));
          line.appendChild(fa);
          line.appendChild(document.createTextNode(e.slice(m9.index + m9[0].length)));
        } else {
          line.textContent = e;                     // "ccyy-mm-dd hh:mm:ss.mmm  <coreid>" / "ccyy-mm-dd  <message>"
        }
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
      // (The classic Entities pages' data-coreids-retry / data-coreids-resubmit
      // cell lists went with those pages, 2026-09-13: the grouped Entities
      // pages drill their Retry / Resubmit cells through drillcols= below —
      // keys rauto / rmok / rmerr.)
      // Per-CELL drills by BUILT column index (the drillcols= TABLE modifier
      // -> data-drill-cols="key:col[:Noun_words],…", 2026-09-13, the Entities
      // pages): the row's data-coreids-<key> list opens under the cell at
      // <col>; the noun (underscores = spaces) heads the list, else the
      // column's own header label. The keys are the table's own, so the
      // failed/processed bindings above never double-bind a
      // cell. A blank z cell (0) stays unclickable.
      var dcs = table.getAttribute("data-drill-cols");
      if (dcs) {
        var hr8 = headerRow(table);
        dcs.split(",").forEach(function (spec) {
          var sp8 = spec.split(":"), lst8 = tr.getAttribute("data-coreids-" + sp8[0]);
          if (!lst8 || sp8.length < 2) return;
          var cell8 = cellByCi(tr, +sp8[1]) || tr.cells[+sp8[1]];
          if (!cell8 || (" " + cell8.className + " ").indexOf(" z ") >= 0) return;
          var noun8 = sp8[2] ? sp8[2].replace(/_/g, " ") : "";
          if (!noun8 && hr8 && hr8.cells[cell8.cellIndex]) noun8 = hr8.cells[cell8.cellIndex].textContent.replace(/[▲▼]/g, "").replace(/\s+/g, " ").trim();
          bindDrill(cell8, tr, table, lst8, noun8, null, du);
        });
      }
      // Per-cell drill lists (duration.sh's Duration per day table): EVERY cell
      // carries data-drill-cell-<i> = its own \x1f-separated "files nearest this
      // value" list, bound to the cell BUILT at column i.
      for (var dci = 0; dci < tr.cells.length; dci++) {
        var dcl = tr.getAttribute("data-drill-cell-" + dci);
        var dce = dcl ? (cellByCi(tr, dci) || tr.cells[dci]) : null;
        if (dce) bindDrill(dce, tr, table, dcl, "", "\u001F", du);
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

  // One sort key: {ci, dir} — ci the BUILT column index (a position on a
  // table without data-ci), dir 1 asc / -1 desc. Several keys (shift-click)
  // sort by the first and break its ties by the next.
  function keyCell(tr, k) { return cellByCi(tr, k.ci) || tr.cells[k.ci]; }
  function sortKeys(table, keys) {
    closeDetails(table);                 // drop drill-down rows so they don't get orphaned
    var rows = dataRows(table);
    ungroup(table);
    keys.forEach(function (k) {
      // Ordinal label columns (size/duration/dwell buckets): every row carries
      // data-ord (emitted by the report) — sort the BUILT column 0 by that
      // ordinal, so "1 KB - 10 KB" never lands between "1 MB" and "10 MB" lexically.
      k.ord = k.ci === 0 && rows.length > 0;
      if (k.ord) for (var oi = 0; oi < rows.length; oi++)
        if (rows[oi].getAttribute("data-ord") === null) { k.ord = false; break; }
      var numeric = 0, seen = 0;
      rows.forEach(function (tr) {
        var c = keyCell(tr, k); if (!c) return;
        if (numKey(c) !== null) { numeric++; seen++; }   // a number (a 0-blanked "z" cell is 0)
        else if (c.textContent.trim() !== "") seen++;    // genuine non-numeric text
        // an EMPTY non-z cell is ABSENT, not text — excluded so it cannot drag the
        // numeric ratio below half. Without this, a view with many blank cells (the
        // Entities "all" pages: not-seen rows have no Volume / % of Files) misreads
        // those columns as text and sorts "3.01 GB" before "540.66 MB".
      });
      k.num = seen > 0 && numeric >= seen / 2;
    });
    function cmp1(a, b, k) {
      if (k.ord) {
        var oa = +a.getAttribute("data-ord"), ob = +b.getAttribute("data-ord");
        return k.dir * (oa < ob ? -1 : oa > ob ? 1 : 0);
      }
      var ca = keyCell(a, k), cb = keyCell(b, k);
      var sa = ca ? ca.textContent.trim() : "", sb = cb ? cb.textContent.trim() : "", r;
      if (k.num) {
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
      return k.dir * r;
    }
    rows.sort(function (a, b) {
      for (var i = 0; i < keys.length; i++) { var r = cmp1(a, b, keys[i]); if (r) return r; }
      return 0;
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
    table.pagerPage = 1;              // a new order starts on its FIRST page (2026-09-29: a sort on page 2 showed ranks 11-20)
    repage(table);                    // a sort reshuffles the pages
    table._sortKeys = keys;
    replaceHotspots(table);
  }
  // position-based entry: col is the CURRENT header position
  function sortTable(table, col, dir) {
    var hr = headerRow(table), ci = (hr && hr.cells[col]) ? ciOf(hr.cells[col]) : col;
    sortKeys(table, [{ ci: ci, dir: dir }]);
  }
  // re-apply whatever sort a table holds (after a re-aggregation)
  function resort(table) {
    if (table._sortKeys && table._sortKeys.length) { sortKeys(table, table._sortKeys); return; }
    var sc = table.getAttribute("data-sort-col");
    if (sc !== null) sortTable(table, parseInt(sc, 10), parseInt(table.getAttribute("data-sort-dir"), 10) || 1);
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
  // (One site = one environment since 2026-09-11: the keys carry no
  // environment segment any more.)
  function pageKeyBase() {
    var segs = location.pathname.split("/").filter(Boolean);
    var pdir = segs.length > 1 ? segs[segs.length - 2] : "";
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
    // thLabel: the label WITHOUT the sort arrow, its shift-click rank and the
    // hotspots — a "Name ▲²" header keyed the save apart from the load
    var label = hr && cell0(hr) ? thLabel(cell0(hr)) : "";
    var tables = document.getElementsByTagName("table"), n = 0;
    for (var i = 0; i < tables.length; i++) {
      if (tables[i] === table) break;
      var h2 = headerRow(tables[i]);
      if (h2 && cell0(h2) && thLabel(cell0(h2)) === label) n++;
    }
    return "sort:" + pageKeyBase() + ":" + label + ":" + n;
  }
  function saveSort(table, keys) {   // "ci:dir,ci:dir" — the built index, primary key first
    try { sessionStorage.setItem(sortStoreKey(table), keys.map(function (k) { return k.ci + ":" + k.dir; }).join(",")); } catch (e) {}
  }
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
  function entKey()  { return "axway-entities-sort"; }
  // The label of a header cell — on the grouped Entities layout (2026-09-13)
  // prefixed with its GROUP banner ("Files › Error"): Ok / Error / Error %
  // repeat across the groups, so the bare label would land the remembered
  // sort on the wrong group. The csv / cols hotspot text is stripped.
  function entLabel(th) {
    if (!th) return "";
    var lab = thLabel(th);
    var t = th.closest ? th.closest("table") : null;
    if (t && t._groupLabel && t._colGroup) { var g = groupOf(t, ciOf(th)); if (t._groupLabel[g]) lab = t._groupLabel[g] + " › " + lab; }
    return lab;
  }
  function entLoad() {
    try {
      var raw = localStorage.getItem(entKey()); if (!raw) return null;
      var v = JSON.parse(raw);
      if (!v || typeof v.c !== "string" || !v.t) return null;
      if (Date.now() - v.t > ENT_TTL) { localStorage.removeItem(entKey()); return null; }
      return v;
    } catch (e) { return null; }
  }
  // EVERY sort key (2026-09-29: only the primary one was kept, so a
  // shift-click multi-key sort came back as a single key) — k = [{c, d}],
  // c/d = the primary one too (an entry written before this reads the same);
  // the name column (BUILT index 0) is "#name" whatever each entity calls it
  function entSave(keys, hr, ths) {
    var ks = [], i, pos, lbl;
    for (i = 0; i < keys.length; i++) {
      pos = colByCi(hr, keys[i].ci);
      lbl = keys[i].ci === 0 ? "#name" : (pos >= 0 ? entLabel(ths[pos]) : "");
      if (lbl) ks.push({ c: lbl, d: keys[i].dir === -1 ? -1 : 1 });
    }
    if (!ks.length) return;
    try { localStorage.setItem(entKey(), JSON.stringify({ c: ks[0].c, d: ks[0].d, k: ks, t: Date.now() })); } catch (e) {}
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
  // COL may also be a header LABEL (2026-09-13 — the grouped Entities pages,
  // whose column positions shift when an empty group is hidden): the first
  // header cell reading it, e.g. ?axway_sort=Error:-1 (the Files group's
  // Error, the first match) or Total:-1 (Volume). The csv / cols hotspot
  // text on a header cell is ignored.
  var urlSort = null, urlSortDone = false;
  (function () {
    var m = /[?&]axway_sort=([^&:]+)(?::(-?1))?/.exec(window.location.search || ""), c;
    if (m) { c = urlParam(m[1]); urlSort = { col: /^\d+$/.test(c) ? parseInt(c, 10) : -1, label: /^\d+$/.test(c) ? "" : c, dir: m[2] ? parseInt(m[2], 10) : 0 }; }
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
  // ?axway_column=LABEL (2026-09-14, user request — the home page's per-day
  // Error cells into the Entities subscription page): mark that column — the
  // first header cell reading LABEL (the axway_sort label rule), on the first
  // table that has one — and scroll it into view. The row twin is axway_row;
  // the two combine (a row AND a column marked = one cell singled out).
  var urlCol = null;
  (function () {
    var m = /[?&]axway_column=([^&]*)/.exec(window.location.search || "");
    if (m) { try { urlCol = decodeURIComponent(m[1].replace(/\+/g, " ")); } catch (e) { urlCol = m[1]; } }
  })();
  // A page whose <body> carries the sort-fresh class (analyses/accounts.html,
  // use-cases.html — cronjobs.html until 2026-09-05) never remembers sorting: every load starts
  // at the generated order.
  var SORT_FRESH = (" " + (document.body.className || "") + " ").indexOf(" sort-fresh ") >= 0;

  function makeSortable(table) {
    if (table.getAttribute("data-nosort") === "1") return;   // e.g. paired 2-row entries that must not be reordered
    var hr = headerRow(table); if (!hr) return;
    var ths = hr.cells;
    var origOrder = dataRows(table);      // .rpt order (colFirstDir samples it)
    var keys = [];                        // the active sort, primary key first
    var SUP = ["", "", "²", "³", "⁴", "⁵", "⁶", "⁷", "⁸", "⁹"];
    function applyKeys(ks) {
      keys = ks;
      var p = colByCi(hr, ks[0].ci); if (p < 0) p = ks[0].ci;
      table.setAttribute("data-sort-col", String(p));
      table.setAttribute("data-sort-dir", String(ks[0].dir));
      sortKeys(table, ks);
      var arrows = hr.getElementsByClassName("arrow");
      for (var j = 0; j < arrows.length; j++) arrows[j].innerHTML = "";
      ks.forEach(function (k, i) {
        var th = cellByCi(hr, k.ci) || ths[k.ci], a = th && th.getElementsByClassName("arrow")[0];
        if (a) a.innerHTML = (k.dir > 0 ? " ▲" : " ▼") + (i > 0 ? "<sup>" + (SUP[i + 1] || (i + 1)) + "</sup>" : "");
      });
    }
    function applySort(col, dir) { applyKeys([{ ci: ciOf(ths[col]), dir: dir }]); }   // col: a CURRENT position
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
      for (var i = 0; i < sample.length; i++) {   // no row cap: a count column whose top rows are all blank zeros (a sparse error count) must still be detected numeric
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
        th.addEventListener("click", function (e) {
          col = th.cellIndex;   // the CURRENT position — a dragged column keeps its header
          var ci = ciOf(th), f = colFirstDir(col), dir, ks, ix = -1;
          if (e.shiftKey && keys.length) {
            // shift-click: ADD the column as the next key (or flip it if it is one)
            ks = keys.slice();
            ks.forEach(function (k, i) { if (k.ci === ci) ix = i; });
            if (ix >= 0) ks[ix] = { ci: ci, dir: -ks[ix].dir }; else ks.push({ ci: ci, dir: f });
            applyKeys(ks); dir = ks[0].dir;
          } else {
            var same = keys.length === 1 && keys[0].ci === ci;   // first-dir, then TOGGLE (no reset state)
            dir = (same && keys[0].dir === f) ? -f : f;
            applyKeys([{ ci: ci, dir: dir }]);
          }
          // Entities pages write the SHARED hour-long entry instead of the
          // per-report one, so the pick carries to the next entity.
          if (isEntitiesPage()) entSave(keys, hr, ths);
          else if (!SORT_FRESH) saveSort(table, keys);   // survives unit switches + page revisits this session (stored by BUILT index)
        });
      })(i, ths[i]);
    }
    // Optional initial sort: data-sort-init="col:dir" (dir 1 asc, -1 desc).
    var init = table.getAttribute("data-sort-init");
    if (init) {
      var p = init.split(":"), col = parseInt(p[0], 10), dir = parseInt(p[1], 10) || 1;
      // sort= names a BUILT column index: after a stored column move the
      // position differs (2026-09-29 fix — applySort took it as a position)
      if (col >= 0 && col < ths.length) applyKeys([{ ci: col, dir: dir }]);
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
        dc = cell0(origOrder[di]); if (!dc) { dd = 0; break; }   // the BUILT first column, wherever it was moved
        dt = dc.textContent.trim();
        if (dt === "" || dt === "-") continue;
        if (parseDate(dt) === null) { dd = 0; break; }
        dd++;
      }
      if (dd > 0) applyKeys([{ ci: 0, dir: -1 }]);
    }
    // ?axway_sort beats everything on the page's FIRST sortable table and
    // persists like a user click; else a sort the user made earlier this
    // session (possibly on another unit variant of this page) wins over the
    // page's default.
    if (urlSort && !urlSortDone && urlSort.label) {   // a header label -> its first position on this table
      for (var ul = 0; ul < ths.length; ul++)
        if (thLabel(ths[ul]) === urlSort.label) { urlSort.col = ul; break; }
    }
    if (urlSort && !urlSortDone && urlSort.col >= 0 && urlSort.col < ths.length) {
      urlSortDone = true;
      // a LABEL resolved to a current position above; a NUMBER is a BUILT
      // index (the ?axway_sort=N contract) — map it to where that column is now
      var upos = urlSort.col;
      if (!urlSort.label) for (var up = 0; up < ths.length; up++) if (ciOf(ths[up]) === urlSort.col) { upos = up; break; }
      var udir = urlSort.dir || colFirstDir(upos);
      applySort(upos, udir);
      if (!SORT_FRESH) saveSort(table, keys);
      return;
    }
    // Entities pages: the shared hour-long entry REPLACES the per-report one
    // (one catalog, seven entities — see entLoad above). An entry whose column
    // this view does not have leaves the page on its own default.
    if (isEntitiesPage()) {
      var ev = entLoad(), ekeys = [];
      if (ev) (ev.k && ev.k.length ? ev.k : [{ c: ev.c, d: ev.d }]).forEach(function (e) {
        var p = entResolve(e, ths);
        if (p >= 0 && p < ths.length) ekeys.push({ ci: ciOf(ths[p]), dir: e.d === -1 ? -1 : 1 });
      });
      if (ekeys.length) applyKeys(ekeys);
      return;
    }
    var stored = SORT_FRESH ? null : loadSort(table);
    if (stored) {
      var ks = [], parts = stored.split(","), q;
      for (q = 0; q < parts.length; q++) {
        var sp = parts[q].split(":"), sci = parseInt(sp[0], 10), sdir = parseInt(sp[1], 10) || 1;
        if (isNaN(sci)) continue;
        if (colByCi(hr, sci) >= 0 || (!hr.cells[0].hasAttribute("data-ci") && sci >= 0 && sci < ths.length)) ks.push({ ci: sci, dir: sdir });
      }
      if (ks.length) applyKeys(ks);
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
    replaceHotspots(table);   // the last visible row changed
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
        c = cell0(rows[i]);   // the BUILT first column, wherever it was moved
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
  // ROWDAY TABLES (2026-10-02, user request: "/transfer/duration.html?axway_row
  // — if called with the axway_row parameter, the Duration distribution table
  // must be about that day only"): a RECALC table carrying data-rowday is
  // re-aggregated for the ?axway_row DATE alone — the page itself stays at
  // the full range (axway_row's rule) and the per-day table only marks the
  // day — and its heading names the day. Not a date of the page's list: the
  // table stays as it is. The next From/To change (rowDayOff, from apply)
  // lifts it: the table then follows the range like every other one.
  var rowDayOn = [];
  function rowDayTables(epochOf, DAY) {
    if (!urlRow || epochOf[urlRow] == null) return;
    var tables = document.querySelectorAll("table[data-rowday][data-recalc]"), i;
    for (i = 0; i < tables.length; i++) {
      var t = tables[i], u = tunit(t), h = u && u.previousElementSibling;
      recalcTable(t, epochOf[urlRow], epochOf[urlRow] + DAY - 1, true);
      updateEmptyState(t); repage(t); replaceHotspots(t);
      if (h && h.tagName === "H2") { h.setAttribute("data-rowday-orig", h.textContent); h.textContent = h.textContent + " \u2014 " + urlRow; }
      rowDayOn.push(t);
    }
  }
  function rowDayOff() {
    rowDayOn.forEach(function (t) {
      var u = tunit(t), h = u && u.previousElementSibling;
      if (h && h.hasAttribute("data-rowday-orig")) { h.textContent = h.getAttribute("data-rowday-orig"); h.removeAttribute("data-rowday-orig"); }
    });
    rowDayOn = [];
  }
  // ?axway_column=LABEL: find the header cell reading LABEL (the first one, on
  // the first table that has it), stamp data-colmark on it and on that
  // column's cell in every data and total row, and scroll it into view
  // (style.css: side borders down the column, the header outlined). An
  // ATTRIBUTE, like the hidden columns: the recalc / seen-rows className
  // restores would drop a class. Cells are matched by their built index
  // (data-ci), so a remembered column order or hidden neighbours do not
  // matter; the GHEAD banner, spanning message rows, the pager row and drill
  // subrows are left alone. Runs LAST, right before markUrlRow.
  function markUrlColumn() {
    if (!urlCol) return;
    var tables = document.getElementsByTagName("table"), t, hr = null, ths, i, th = null, tbl = null, ci, rows, r, c;
    for (t = 0; t < tables.length && !th; t++) {
      hr = headerRow(tables[t]); if (!hr) continue;
      ths = hr.cells;
      for (i = 0; i < ths.length; i++)
        if (thLabel(ths[i]) === urlCol) { th = ths[i]; tbl = tables[t]; break; }
    }
    if (!th) return;
    th.setAttribute("data-colmark", "1");
    ci = ciOf(th); rows = tbl.rows;
    for (i = 0; i < rows.length; i++) {
      r = rows[i];
      if (r === hr || r.getElementsByTagName("th").length || r.cells.length === 1) continue;
      if (/coreid-detail|subrow|pagerrow/.test(r.className)) continue;
      c = cellByCi(r, ci);
      if (!c && r.cells[ci] && ciOf(r.cells[ci]) === ci) c = r.cells[ci];   // an unstamped (fixed-column) table
      if (c) c.setAttribute("data-colmark", "1");
    }
    if (th.scrollIntoView) th.scrollIntoView({ block: "nearest", inline: "center" });
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
    // one DATE-AWARE table: on a page with none (e.g. a nofilter-only page — its one
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
    // the ACTIVE date selection as a URL value (2026-09-15 — the Entities
    // subscription pages' Error cells carry it into Failed files): "all" at
    // the full range, else "from..to" (the ?axway_date range form)
    window.AXWAY_DATESEL = function () {
      var f = from.options[from.selectedIndex], t = to.options[to.selectedIndex];
      if (!f || !t || (from.selectedIndex === dates.length - 1 && to.selectedIndex === 0)) return "all";
      return f.textContent + ".." + t.textContent;
    };

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
      rowDayOff();                       // a From/To change ends the ?axway_row day view of the rowday tables
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
      // the page ENGINE of a rangehook table (all-files-search.js)
      // register a function here — (from, to, narrowed), date strings
      if (window.AXWAY_RANGEHOOKS) for (var rh = 0; rh < window.AXWAY_RANGEHOOKS.length; rh++)
        window.AXWAY_RANGEHOOKS[rh](window._slotRange.from, window._slotRange.to, narrowed);
      if (searchReapply) searchReapply(true);   // lift an active search so the recalc below rewrites EVERY row
      var tables = document.getElementsByTagName("table"), t, ri, tr, rows, i, e, mn, mx;
      for (t = 0; t < tables.length; t++) {
        if (tables[t].getAttribute("data-nofilter")) continue;   // full-period table: never hide rows (the badge says so)
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
      if (searchReapply) searchReapply();   // re-evaluate the active search against the recalculated text
      for (t = 0; t < tables.length; t++) if (!tables[t].getAttribute("data-recalc") && !tables[t].getAttribute("data-heat")) recomputeTotals(tables[t]);   // recalcHeat owns their totals
      for (t = 0; t < tables.length; t++) resort(tables[t]);          // an active sort must hold on the re-aggregated values
      for (t = 0; t < tables.length; t++) applyGroup(tables[t]);        // re-blank on the visible set
      for (t = 0; t < tables.length; t++) markUnfiltered(tables[t], narrowed && !isDateAware(tables[t]));
      for (t = 0; t < tables.length; t++) updateEmptyState(tables[t]);
      for (t = 0; t < tables.length; t++) repage(tables[t]);
      for (t = 0; t < tables.length; t++) replaceHotspots(tables[t]);   // the last visible row may have changed
      hideEmptyTables();
    }
    // Keep ?axway_date= in the address bar equal to the range ON SCREEN after
    // a USER change — the From/To pulldowns and the range buttons, never the
    // load-time restore (2026-09-29 audit F14: a day link, then All, still
    // read ?axway_date=<day>, so a reload or a shared link opened the day
    // again). A narrowed range writes from..to (one day: the day); the full
    // range writes "all" when the URL carried a date (it must beat another
    // tab's remembered range) and nothing otherwise. A data-date-reset page
    // keeps its narrowing page-local unless its URL already carries a date.
    // The syncSearchUrl twin: replaceState, other parameters and the hash kept.
    function syncDateUrl() {
      if (!window.history || !history.replaceState) return;
      var s = window.location.search.replace(/^\?/, ""), parts = s ? s.split("&") : [], out = [], i, had = false;
      for (i = 0; i < parts.length; i++) { if (parts[i].indexOf("axway_date=") === 0) had = true; else out.push(parts[i]); }
      if (resetDates && !had) return;
      var v = window.AXWAY_DATESEL(), p = v.split("..");
      if (v !== "all") out.push("axway_date=" + (p[0] === p[1] ? p[0] : v));
      else if (had) out.push("axway_date=all");
      var q = out.length ? "?" + out.join("&") : "";
      try { history.replaceState(null, "", window.location.pathname + q + window.location.hash); } catch (e) {}
    }
    from.addEventListener("change", function () { apply("from"); syncDateUrl(); });
    to.addEventListener("change", function () { apply("to"); syncDateUrl(); });
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
    // ?axway_date=all (2026-09-14, user request — the home Duration group's
    // banner, p-headers and Total): the whole date list, exactly what the All
    // button selects, persisted like a user selection
    if (!um && /[?&]axway_date=all(&|$)/.test(window.location.search) && dates.length) {
      urlLo = epochOf[dates[0]]; urlHi = epochOf[dates[dates.length - 1]];
    }
    var urlDay = urlLo != null;
    // Carry a narrowed range across pages — unless this page opts to always load
    // at the full range (data-date-reset, the Top view dashboards). The From/To
    // still work; a change from here on persists as usual.
    if (urlDay) {
      from.value = String(urlLo);
      to.value = String(urlHi);
      apply();
    } else if (!resetDates && !urlRow && restoreSel()) apply();
    rowDayTables(epochOf, DAY);
    // THE NARROWED-RANGE BLINK (2026-10-01, user request: "after loading a
    // page and there are date period selection fields with a selection other
    // then 'All' highlight and blink the from/to dates for a second"): a page
    // that OPENS on less than the full range (a remembered or linked From/To)
    // flashes its From / To once, so the reader sees the data is narrowed.
    // On load only — a user change never blinks (style.css select.dateblink;
    // prefers-reduced-motion gets a static highlight for the second instead).
    if (dates.length && (String(from.value) !== String(epochOf[dates[0]]) ||
                         String(to.value) !== String(epochOf[dates[dates.length - 1]]))) {
      from.classList.add("dateblink"); to.classList.add("dateblink");
      setTimeout(function () { from.classList.remove("dateblink"); to.classList.remove("dateblink"); }, 1100);
    }

    // DASHBOARDS MODE (2026-08): on the dashboards the controls lead the
    // page — right under the title, before the KPI row — because EVERYTHING
    // below follows the range: the KPI cards re-sum, the graph clips, the
    // Top-5 tables re-select. The FULL button set renders (Last day and
    // Previous/Next day included — a single-day pick shows that day's slots
    // and re-selects the Top 5 for it). Until 2026-08 the wrap joined the
    // hero card's own .chartbtns row and dropped the day buttons.
    var _dfArea = document.querySelector('meta[name="report-area"]');
    var dashHero = !!(_dfArea && /(^|-)dashboards$/.test(_dfArea.getAttribute("content") || "") &&
                      document.querySelector(".dash-grid .chartbtns"));
    var wrap = document.createElement("div");
    wrap.className = "controls";
    var l1 = document.createElement("label"); l1.textContent = "From";
    var l2 = document.createElement("label"); l2.textContent = "To";
    wrap.appendChild(l1); wrap.appendChild(from);
    wrap.appendChild(l2); wrap.appendChild(to);

    // Quick-range buttons next to the From/To pulldowns. They set the two selects
    // and apply like a manual change (persisted across the area by apply()'s
    // saveSel). All = the full range; Week / 4 weeks = the last 7 / 28 days
    // of FULL days — a partial newest day never counts (2026-08, replacing
    // "Last 7 days"); Month = one calendar month back from the NEWEST data
    // day (2026-09-29); Current / Previous month = calendar months; First /
    // Last day = the oldest / newest data day. Dates are DATA days, so every
    // value set is a real option (an arbitrary calendar epoch could select
    // nothing).
    var newest = epochOf[dates[dates.length - 1]], oldest = epochOf[dates[0]];
    function setRange(f, tv) { from.value = String(f); to.value = String(tv); apply(); syncDateUrl(); }
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
    // (2026-08): the previous month's same day-of-month + 1 through the end
    // day — ending 09-17 it starts 08-18; a day the shorter previous month
    // lacks clamps to that month's last day BEFORE the + 1, so ending 03-31
    // it starts 03-01 (2026-09-28 fix: the clamp came after the + 1 and
    // started 02-28, a 32-day "month"). THE END DAY IS THE NEWEST DATA DAY
    // (2026-09-29, user request: "if the last day with data is 17 september
    // it must show 18 august to 17 september") — partial or not, unlike
    // Week / 4 weeks, which end on the last FULL day.
    function monthStartStr() {
      var es = dates[dates.length - 1];
      var y = +es.slice(0, 4), m = +es.slice(5, 7) - 1, d = +es.slice(8, 10);
      if (m < 1) { m = 12; y -= 1; }
      var dim = new Date(Date.UTC(y, m, 0)).getUTCDate();   // days in 1-based month m
      if (d > dim) d = dim;
      var st = new Date(Date.UTC(y, m - 1, d) + 86400000);
      var sm = st.getUTCMonth() + 1, sd = st.getUTCDate();
      return st.getUTCFullYear() + "-" + (sm < 10 ? "0" : "") + sm + "-" + (sd < 10 ? "0" : "") + sd;
    }
    // ALWAYS shown (2026-09-29, user request — between 4 weeks and Current
    // month): no coverage test, so a data set shorter than a month still
    // offers it; From is then the first data day (the part of the month the
    // data holds). Week / 4 weeks keep their hide-when-unreachable rule.
    var bmo = mkPresetBtn("Month", function () {
      var ss = monthStartStr(), fd = dates[0], i;
      for (i = 0; i < dates.length; i++) if (dates[i] >= ss) { fd = dates[i]; break; }
      return [epochOf[fd], newest];
    }, true);
    bmo.title = "One month back from the newest data day: " + monthStartStr() + " to " + dates[dates.length - 1];
    wrap.appendChild(bmo);
    // Current month / Previous month = the CALENDAR month of the newest data
    // day and the one before it, every data day of the month (2026-09-29 —
    // "Current month" was "This month" until the same day, user request). A
    // month without data days is hidden like an unreachable span preset.
    function calMonth(back) {
      var ns = dates[dates.length - 1], y = +ns.slice(0, 4), m = +ns.slice(5, 7) - back;
      while (m < 1) { m += 12; y -= 1; }
      return y + "-" + (m < 10 ? "0" : "") + m;
    }
    function monthRange(back) {
      var ym = calMonth(back), lo = null, hi = null, i;
      for (i = 0; i < dates.length; i++) if (dates[i].slice(0, 7) === ym) { if (lo == null) lo = epochOf[dates[i]]; hi = epochOf[dates[i]]; }
      return lo == null ? [oldest, newest] : [lo, hi];
    }
    function monthHas(back) { var ym = calMonth(back), i; for (i = 0; i < dates.length; i++) if (dates[i].slice(0, 7) === ym) return true; return false; }
    var bthis = mkPresetBtn("Current month", function () { return monthRange(0); }, true, function () { return monthHas(0); });
    bthis.title = "Every data day of " + calMonth(0) + ", the calendar month of the newest data day";
    wrap.appendChild(bthis);
    var bprev = mkPresetBtn("Previous month", function () { return monthRange(1); }, true, function () { return monthHas(1); });
    bprev.title = "Every data day of " + calMonth(1) + ", the calendar month before the newest data day";
    wrap.appendChild(bprev);
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
    // Likewise any element carrying class "underdates" (2026-09-27): a page
    // engine's own controls row — search/all-files.html's File / Subscription
    // fields — sits BELOW the date selection.
    while (anchor && anchor.previousElementSibling &&
           ((anchor.previousElementSibling.tagName === "P" &&
             (" " + anchor.previousElementSibling.className + " ").indexOf(" undertabs ") >= 0) ||
            (" " + anchor.previousElementSibling.className + " ").indexOf(" underdates ") >= 0))
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
    // a "QUOTED" term (2026-09-15, user request — the subscription pages'
    // Activity per day Error cells open Failed files with the subscription in
    // quotes): the WHOLE cell must equal the text between the quotes, so
    // "UC1_FIN_BILLING_GLOBEX" no longer also matches …GLOBEXX; no wildcards
    if (q.length > 2 && q.charAt(0) === '"' && q.charAt(q.length - 1) === '"') {
      var exact = q.slice(1, -1);
      return function (text) { return text.replace(/^\s+|\s+$/g, "") === exact; };
    }
    if (q.indexOf("*") < 0 && q.indexOf("?") < 0)
      return function (text) { return text.indexOf(q) >= 0; };
    return globMatcher(q);
  }

  // The glob test WITHOUT a RegExp (2026-09-29 audit F12: every * became a
  // .* and a short "************z" backtracked for seconds on one long name,
  // freezing the page): the classic two-pointer walk that, on a mismatch,
  // retries only from the LAST star — at most text x pattern steps. Unanchored
  // like the substring search: the pattern is wrapped in stars, runs of stars
  // collapse. The ONE copy: all-files-search.js uses it (window.AXWAY_UTIL).
  function globMatcher(q) {
    var p = ("*" + q + "*").replace(/\*+/g, "*"), m = p.length;
    return function (s) {
      var i = 0, j = 0, star = -1, mark = 0, n = s.length, c;
      while (i < n) {
        c = j < m ? p.charAt(j) : "";
        if (c === "*") { star = j++; mark = i; }
        else if (c !== "" && (c === "?" || c === s.charAt(i))) { i++; j++; }
        else if (star >= 0) { j = star + 1; i = ++mark; }
        else return false;
      }
      while (j < m && p.charAt(j) === "*") j++;
      return j === m;
    };
  }

  // SHARED WITH THE FILE ENGINES (2026-09-30, the lean round: sub-files.js
  // and all-files-search.js carried their own copies — globMatcher was a
  // KEEP-IN-STEP pair): the glob matcher, the byte format, the File State
  // words and row colours (the shard flag: "" / d delivered, o delivered after
  // a retry or resubmit, e errored, w waiting, x expired — _files.tsv col 25)
  // and the File-table cell builder (a linked cell is a whole-cell link, cl).
  // The engines read them when they render, after this file ran.
  function fileCell(tr, cls, text, href, mono) {
    var c = document.createElement("td"), t = null, a;
    if (href) cls = cls ? cls + " cl" : "cl";
    if (cls) c.className = cls;
    if (mono) { t = document.createElement("code"); t.textContent = text; }
    if (href) {
      a = document.createElement("a"); a.setAttribute("href", href);
      if (t) a.appendChild(t); else a.textContent = text;
      c.appendChild(a);
    } else if (t) c.appendChild(t);
    else c.textContent = text;
    tr.appendChild(c);
  }
  window.AXWAY_UTIL = {
    globMatcher: globMatcher,
    humanBytes: humanBytes,
    fileState: { "": "OK", d: "OK", o: "OK", e: "Error", w: "Waiting", x: "Expired" },
    fileTint: { "": "green", d: "green", o: "orange", e: "red", w: "orange", x: "red" },
    fileCell: fileCell
  };

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
  // A bare "not" BETWEEN two terms reads as "and not" (2026-09-29 audit:
  // "hooli not match" searched for that literal phrase): "a not b" == "a and
  // not b". A "not" after an operator, or leading, keeps its meaning above.
  // A "QUOTED PHRASE" is ONE term (2026-09-29 audit F10: the Failing reasons
  // links search "io error" in quotes, and the whitespace split below cut it
  // into two halves that each failed the whole-cell match — 21 of 22 reason
  // links opened an empty Failed files page): each phrase is swapped for a
  // placeholder without whitespace before the operator parse, so an
  // and / or / not INSIDE quotes is text, and put back in the term.
  function parseQuery(q) {
    var phr = [];
    q = q.replace(/"[^"]+"/g, function (m) { phr.push(m); return "\u0000" + (phr.length - 1) + "\u0000"; });
    function unq(t) { return t.replace(/\u0000(\d+)\u0000/g, function (m, n) { return phr[+n]; }); }
    var toks = q.split(/\s+/).filter(Boolean), ti, t2 = [];
    for (ti = 0; ti < toks.length; ti++) {
      if (toks[ti] === "not" && ti > 0 && ti < toks.length - 1 && !/^(and|or|not)$/.test(toks[ti - 1])) t2.push("and");
      t2.push(toks[ti]);
    }
    if (t2.length !== toks.length) { toks = t2; q = toks.join(" "); }
    var hasOp = toks.some(function (t) { return t === "and" || t === "or" || t === "not"; });
    if (toks.length > 1 && !hasOp) q = toks.join(" and ");   // implicit AND between bare terms
    return q.split(/\s+or\s+/).map(function (part) {          // OR: lower precedence
      return part.split(/\s+and\s+/)                          // AND: higher precedence
                 .map(function (t) { return t.replace(/^\s+|\s+$/g, ""); })
                 .filter(Boolean)
                 .map(function (t) {                          // "not <term>" -> a negated term (bare "not" stays literal)
                   var mm = /^not\s+(.+)$/.exec(t);
                   if (mm) return { neg: true, m: makeMatcher(unq(mm[1].replace(/^\s+|\s+$/g, ""))) };
                   return { neg: false, m: makeMatcher(unq(t)) };
                 });
    }).filter(function (g) { return g.length; });
  }

  // The search text currently applied, as typed (for the empty-state message).
  var activeQuery = "";

  // Zero-result EMPTY STATE. A table filtered down to nothing shows only its
  // "Total (0 rows)" footer, which explains neither WHY nor what to do — the
  // worst case being Entity Search, where a query can match rows that its
  // entity-type checkboxes exclude, reading as "no matches" when it isn't.
  // This renders a note right under the table naming the reason and the
  // recovery:
  //   - matching rows hidden by the type checkboxes -> their count per entity
  //     type + "tick more entity types"
  //   - matching rows outside the selected date range -> their count + widen
  //   - a genuine miss -> "No matches for X. Clear or change the search."
  //   - no query, narrowed range emptied the table -> widen the From/To
  // Re-rendered by every path that changes row visibility (search, date
  // filter, the Entity Search type checkboxes).
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
    }
    var old = wrap.querySelector(".empty-state");
    if (old && old.parentNode) old.parentNode.removeChild(old);
    // a table without a search box still gets the DATE-RANGE message
    // (2026-09-29: it returned here, and a narrowed Failed Subscriptions list
    // showed a bare "Total (0 rows)"); an engine-built table (rangehook)
    // says its own thing
    if (table.getAttribute("data-rangehook")) return;
    var noSearch = table.getAttribute("data-nosearch") === "1";
    // (a cell-less <tr> — the header-less no-data stub's — is no data row)
    var rows = dataRows(table).filter(function (tr) { return tr.cells.length > 0; }), hasQ = !noSearch && activeQuery !== "";
    var msg, hint;
    if (!rows.length && table.getAttribute("data-start-empty") !== "1") {
      // a table with NO data rows at all (2026-09-29 audit): a report page
      // renders no INTRO / NOTE, so a report's own "nothing in this window"
      // prose — and the no-data stub's note — never shows, and the page read
      // as a bare header over "Total (0 …)". Say it here. The subscription
      // Files table and Entity Search build their rows later and say their own
      // thing; a detail page hides an empty table whole (hideEmptyTables).
      if (table.getAttribute("data-subfiles") || table.getAttribute("data-esearch") !== null) return;
      msg = "No rows in this data window."; hint = "";
    } else {
    var visible = 0, hidV = 0, hidD = 0, typc = {}, isES = table.getAttribute("data-escfg") !== null;   // the CONFIG PANEL's presence, not mere esearch (an esearch table need not have one)
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
    if (hasQ && hidV + hidD > 0) {
      var parts = [];
      if (hidV) {
        var tl = [], k;
        for (k in typc) tl.push(typc[k] + " " + k);
        tl.sort();
        parts.push(hidV + " matching row" + (hidV === 1 ? "" : "s") +
                   (tl.length ? " (" + tl.join(", ") + ")" : "") +
                   " excluded by the entity-type checkboxes");   // data-vhide: only Entity Search's type filter sets it
      }
      if (hidD) parts.push(hidD + " matching row" + (hidD === 1 ? "" : "s") + " outside the selected date range");
      msg = "No visible matches for “" + activeQuery + "” — " + parts.join("; ") + ".";
      hint = hidV ? "Tick more entity types above, or clear the search."
                  : "Widen the From/To above, or clear the search.";
    } else if (hasQ) {
      msg = "No matches for “" + activeQuery + "”.";
      hint = "Clear or change the search (wildcards: ? = one character, * = any run).";
    } else if (curRange && curRange.narrowed) {
      msg = "No rows in the selected date range.";
      hint = "Widen the From/To above.";
    } else return;   // start-empty idle state (the page intro explains it) / nothing to say
    }
    var div = document.createElement("div");
    div.className = "empty-state";
    var s1 = document.createElement("span"); s1.textContent = msg;
    div.appendChild(s1);
    if (hint) { var s2 = document.createElement("span"); s2.className = "es-hint"; s2.textContent = " " + hint; div.appendChild(s2); }
    table.parentNode.insertBefore(div, table.nextSibling);
  }
  // the load-time pass for the tables with NO data rows at all (their message,
  // above) — every other empty state follows a search / date / view change
  function markEmptyTables() {
    var ts = document.getElementsByTagName("table"), i;
    for (i = 0; i < ts.length; i++)
      if (!dataRows(ts[i]).some(function (tr) { return tr.cells.length > 0; })) updateEmptyState(ts[i]);
  }

  // Filter a table's data rows by a free-text query over ALL columns. Runs on
  // top of the date filter (a date-hidden row stays hidden), so it searches
  // within the selected date range. Grouped tables are ungrouped first so a
  // blanked repeat cell still matches its real value, then re-blanked.
  // ---- Entity Search: rows arrive as DATA, not as markup --------------------
  // search/search.html ships window.AXWAY_SEARCH (assets-style search-data.js): one
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
  // the TEXT of a rendered cell's markup: tags dropped, the escapes the
  // renderer writes decoded (2026-09-28 fix: "A&B" was matched and shown as
  // "A&amp;B" by Entity Search)
  var UNENT = { amp: "&", lt: "<", gt: ">", quot: '"', apos: "'" };
  function htmlText(s) {
    s = s.replace(/<[^>]*>/g, "");
    if (s.indexOf("&") < 0) return s;
    return s.replace(/&(#x[0-9a-fA-F]+|#[0-9]+|[a-z]+);/g, function (m, e) {
      if (e.charAt(0) === "#") {
        var n = e.charAt(1) === "x" ? parseInt(e.slice(2), 16) : parseInt(e.slice(1), 10);
        return isFinite(n) && n > 0 && n < 0x110000 ? String.fromCodePoint(n) : m;
      }
      return UNENT.hasOwnProperty(e) ? UNENT[e] : m;
    });
  }
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
      ES_NAME[i] = m1 ? htmlText(m1[1]).replace(/^\s+|\s+$/g, "") : "";
      ES_TYPE[i] = m2 ? htmlText(m2[1]).replace(/^\s+|\s+$/g, "") : "";
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
    // (The group-HEADING hide for a hand-built catalog — the Reports start
    // page — went 2026-09-30 with that page, audit A6-01: its only target
    // left was the First seen table's repeated bottom header row, which it
    // hid for good after the first keystroke.)
    // A data-recalc table under a NARROWED date range must be re-aggregated for
    // that range, not text-summed: recalcTable only rewrites visible rows, so a
    // row hidden while the range was applied still holds full-period text —
    // clearing the search would resurrect those stale values (and the forced
    // recomputeTotals below would restore full-range totals). Re-run the exact
    // bucket aggregation over the post-search visible set instead.
    if (table.getAttribute("data-recalc") && curRange && curRange.narrowed) {
      recalcTable(table, curRange.lo, curRange.hi, true);   // (runs autoHideGroups itself)
    } else {
      recomputeTotals(table, true);   // force: bucket tables too (recalcTable doesn't run for a full-range search)
      autoHideGroups(table);          // a group the search left empty on every visible row hides (data-autohide)
    }
    applyGroup(table);
    updateEmptyState(table);
    repage(table);
    replaceHotspots(table);   // the last visible row changed (repage returns early on an unpaged table)
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
    if (location.pathname.indexOf("/entities/") >= 0) return "entities";
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
    if (location.pathname.indexOf("/details/") >= 0) return;
    var stored = loadSearch();
    // The top-bar quick-search submits to Entity Search with ?axway_search=…
    // — it overrides the remembered search and is persisted like a typed one.
    var qm = /[?&]axway_search=([^&]*)/.exec(window.location.search);
    if (qm) { stored = urlParam(qm[1]); saveSearch(stored); }
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
        box.title = "Filters every table on this page";   // (the wildcard wording went 2026-09-30 with the search-syntax hint, audit A6-12)
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
  // A row carrying data-norowlink keeps its plain cell links (2026-10-01:
  // the recovered day lists — only a row whose File has a page opens it as a
  // whole; the fallback below would send the others to the Subscription cell).
  function bindRowlink(tr) {
    if (tr.getAttribute("data-norowlink")) return;
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
        if ((el.tagName === "TD" || el.tagName === "TH") && el.getAttribute("data-href")) return;   // a cell link (setupCellLinks) owns the click
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
  // CELL LINKS (2026-09-13, user request): a td/th carrying data-href opens
  // that page on click — the home Per day table's Duration group (banner,
  // p-headers, every day cell, the Total) all go to transfer/duration.html at
  // the FULL date range: the banner, p-headers and Total with ?axway_date=all,
  // a day cell with ?axway_row=<its date> — that day's row marked, the range
  // full (2026-09-14). The cell listener runs before the row's rowlink listener
  // (bubbling: target → cell → row) and stops propagation, so the click never
  // reaches the row link, which would open the day page; bindRowlink also
  // steps aside for such a cell. A native link inside the cell still wins.
  // ENTITIES SUBSCRIPTION pages (2026-09-15, user request): the Files group's
  // Error count opens transfer/failed-files.html for THAT subscription and the
  // ACTIVE date selection. The URL is built at CLICK time — From/To change
  // without a reload and the counts re-aggregate — from the row's name link
  // and window.AXWAY_DATESEL ("all" when the page has no date filter). The
  // column is found by its BUILT index (the first "Error" header, the Files
  // group), so a moved column still resolves; a 0 / blank cell does nothing.
  // entities.sh leaves this cell's drill out on the subscription pages; the
  // listener stops the click before any row handler.
  function setupEntityErrorLinks() {
    if (!/\/transfer\/entities\/subscription-[^\/]*\.html$/.test(location.pathname)) return;
    var tables = document.querySelectorAll("table[data-drill-cols]"), t;
    for (t = 0; t < tables.length; t++) (function (table) {
      var hr = headerRow(table); if (!hr) return;
      var ci = -1, i, k;
      for (i = 0; i < hr.cells.length; i++) {
        if (thLabel(hr.cells[i]) !== "Error") continue;
        k = ciOf(hr.cells[i]); if (ci < 0 || k < ci) ci = k;
      }
      if (ci < 0) return;
      dataRows(table).forEach(function (tr) {
        var c = cellByCi(tr, ci) || tr.cells[ci]; if (!c) return;
        c.classList.add("errlink");
        c.addEventListener("click", function (ev) {
          if (!(parseFloat(c.textContent.replace(/[^0-9.]/g, "")) > 0)) return;
          var a0 = tr.cells[0] && tr.cells[0].getElementsByTagName("a")[0];
          var nm = (a0 ? a0.textContent : (tr.cells[0] ? tr.cells[0].textContent : "")).trim();
          if (!nm) return;
          ev.preventDefault(); ev.stopPropagation();
          var ds = (typeof window.AXWAY_DATESEL === "function") ? window.AXWAY_DATESEL() : "all";
          window.location.href = "../failed-files.html?axway_date=" + encodeURIComponent(ds) + "&axway_search=" + encodeURIComponent('"' + nm + '"');
        });
      });
    })(tables[t]);
  }
  function setupCellLinks() {
    var cells = document.querySelectorAll("td[data-href], th[data-href]"), i;
    for (i = 0; i < cells.length; i++) (function (c) {
      c.addEventListener("click", function (ev) {
        var el = ev.target;
        while (el && el !== c) { if (el.tagName === "A") return; el = el.parentNode; }
        ev.stopPropagation();
        window.location.href = c.getAttribute("data-href");
      });
    })(cells[i]);
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
      // p[3] = the detail-page slug ("" = no page, 2026-09-30) — the rebuilt
      // rows link their names like the baked ones
      if (cells.length) data[p[0]].push({ n: p[1], c: cells, s: p[3] || "" });
    });
    var tbd = document.querySelector(".topbar"), dbase = tbd ? (tbd.getAttribute("data-b") || "") : "";
    // the five KPI cards, matched by their baked label (the K columns are
    // fixed: files, failed, volume, records, errors)
    var kpis = [];
    if (kdays.length) {
      // the Overview KPI labels = the day pages labels (2026-09-30 audit D-06)
      var kmap = { "Files": "files", "File error rate": "fpct",
                   "Volume": "vol", "Server records": "recs", "Server error rate": "epct" };
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
      var th = t.querySelector("th.num"), unit = th ? thLabel(th) : "";
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
          top.splice(k, 0, { n: list[i].n, v: v, s: list[i].s });
          if (top.length > 5) top.length = 5;
        }
        if (!top.length) { card.sec.style.display = "none"; continue; }
        card.sec.style.display = "";
        var rows = [];
        for (i = 0; i < top.length; i++) {
          var tr = document.createElement("tr"), td1 = document.createElement("td"), td2 = document.createElement("td");
          if (top[i].s) {
            var a1 = document.createElement("a");
            a1.href = dbase + "details/" + (card.kind === "P" ? "partners/" : "subscriptions/") + top[i].s + ".html";
            a1.textContent = top[i].n;
            td1.className = "cl";
            td1.appendChild(a1);
          } else td1.textContent = top[i].n;
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
  // Switch groups (2026-09-03): tables sharing data-switch="KEY" (the TABLE
  // modifier switch=KEY:LABEL) are alternatives — one shows at a time. A
  // button row built from their labels is inserted above the group's first
  // table (above its <h2> when it has one); the pick is remembered per
  // report + key (sessionStorage), the first table being the default. The
  // hidden tables keep everything else (recalc, totals, search) — only their
  // wrapper and heading are display:none.
  function setupSwitches() {
    var tables = document.querySelectorAll("table[data-switch]");
    if (!tables.length) return;
    var groups = {}, order = [];
    for (var i = 0; i < tables.length; i++) {
      var k = tables[i].getAttribute("data-switch");
      if (!groups[k]) { groups[k] = []; order.push(k); }
      groups[k].push(tables[i]);
    }
    for (var g = 0; g < order.length; g++) (function (key, members) {
      if (members.length < 2) return;
      var KEY = "axway-switch:" + pageKeyBase() + ":" + key;
      var units = [], m;
      for (m = 0; m < members.length; m++) {
        var wrap = tunit(members[m]);
        var h2 = wrap && wrap.previousElementSibling && wrap.previousElementSibling.tagName === "H2" ? wrap.previousElementSibling : null;
        units.push({ label: members[m].getAttribute("data-switch-label") || ("Option " + (m + 1)), wrap: wrap, h2: h2 });
      }
      var bar = document.createElement("p");
      bar.className = "tabs switchbtns";
      for (m = 0; m < units.length; m++) {
        var s = document.createElement("span");
        s.className = "tab"; s.setAttribute("data-swl", String(m)); s.textContent = units[m].label;
        bar.appendChild(s);
      }
      var anchor = units[0].h2 || units[0].wrap;
      anchor.parentNode.insertBefore(bar, anchor);
      function apply(idx) {
        for (var j = 0; j < units.length; j++) {
          var on = j === idx;
          units[j].wrap.style.display = on ? "" : "none";
          if (units[j].h2) units[j].h2.style.display = on ? "" : "none";
          bar.children[j].className = "tab" + (on ? " active" : "");
        }
      }
      var pick = 0;
      try { var sv = sessionStorage.getItem(KEY); if (sv !== null && /^\d+$/.test(sv) && +sv < units.length) pick = +sv; } catch (e) {}
      apply(pick);
      bar.addEventListener("click", function (e) {
        var v = e.target && e.target.getAttribute && e.target.getAttribute("data-swl");
        if (v === null || v === undefined) return;
        apply(+v);
        try { sessionStorage.setItem(KEY, v); } catch (e2) {}
      });
    })(order[g], groups[order[g]]);
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
      mode = urlParam(um[1]);
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


  // (the slot charts' hover tooltip and their Line/Bar/Solid + interval
  // switches live in assets/slotchart.js, with the charts themselves)


  // ---- Relative dates (2026-09-05): hovering a date cell (or the footer's
  // "Generated on …") shows "3 days ago" as its tooltip. Lazy, by event
  // delegation — nothing is touched until the pointer reaches the element.
  function relTime(ms, hasTime) {
    var n = new Date();                                   // the literal is server-local; compare in that frame
    var nowLit = Date.UTC(n.getFullYear(), n.getMonth(), n.getDate(), n.getHours(), n.getMinutes(), n.getSeconds());
    var days = Math.floor(nowLit / 86400000) - Math.floor(ms / 86400000), diff = nowLit - ms, v;
    function pl(v, u) { return v + " " + u + (v === 1 ? "" : "s"); }
    if (days < 0) return days === -1 ? "tomorrow" : "in " + pl(-days, "day");
    if (hasTime && days === 0) {
      if (diff < 60000) return "just now";
      if (diff < 3600000) return pl(Math.floor(diff / 60000), "minute") + " ago";
      return pl(Math.floor(diff / 3600000), "hour") + " ago";
    }
    if (days === 0) return "today";
    if (days === 1) return "yesterday";
    if (days < 14) return pl(days, "day") + " ago";
    if (days < 61) { v = Math.floor(days / 7); return pl(v, "week") + " ago (" + days + " days)"; }
    if (days < 365) { v = Math.floor(days / 30.44); return pl(v, "month") + " ago (" + days + " days)"; }
    v = Math.floor(days / 365.25); return pl(v, "year") + " ago (" + days + " days)";
  }
  function setupRelDates() {
    var re = /^(?:Generated on |Built |as of |Last poll |Last file )?(\d{4}-\d{2}-\d{2})(?:[ T](\d{2}:\d{2}(?::\d{2})?))?(?:\s|$)/;
    document.addEventListener("mouseover", function (e) {
      var el = e.target, t, m, ms;
      if (!el || el.nodeType !== 1 || el.hasAttribute("data-rel")) return;
      if (!/^(TD|TH|SPAN|P|LI|STRONG|B|TIME|DIV|A|CODE|DD|DT|SMALL|EM)$/.test(el.tagName)) return;
      t = el.textContent.trim(); if (t.length > 90) return;
      m = re.exec(t); if (!m) return;
      ms = parseDate(m[1] + (m[2] ? " " + (m[2].length === 5 ? m[2] + ":00" : m[2]) : ""));
      if (ms === null) return;
      el.setAttribute("data-rel", "1");
      if (!el.title) el.title = relTime(ms, !!m[2]);
    });
  }

  // ---- Copy-to-clipboard icons on ids (2026-09-06, user request): every
  // CoreId / transfer id shown on a page (they are UUIDs) gets a small ⧉
  // after it; a click copies the id. Covers the baked cells (files / errors
  // pages, Item/Value rows, code cells) and whatever the page adds later
  // (drill-down lists, Entity Search rows, the Files page) through a
  // MutationObserver, plus a mouseover net for cells a restore rewrote.
  var ID_RE = /\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b/g;
  // idAt(s): the first id of s that stands ON ITS OWN, or null. A UUID inside
  // a longer name is no CoreId (2026-10-05, user report: the file name
  // "sB0005FRC.RBW20261002_{acc9b1d2-be35-11f1-9726-0a81094c0000}.xml" got the
  // File Tracking link and the ⧉) — a match with a brace, hyphen, dot or slash
  // right before it, or a brace or hyphen right after it, is skipped.
  function idAt(s) {
    var m, b, a;
    ID_RE.lastIndex = 0;
    while ((m = ID_RE.exec(s)) !== null) {
      b = m.index > 0 ? s.charAt(m.index - 1) : "";
      a = s.charAt(m.index + m[0].length);
      if (!/[{.\-\/\\]/.test(b) && !/[}\-]/.test(a)) { ID_RE.lastIndex = 0; return m; }
    }
    return null;
  }
  function isIcon(n) { return n && n.nodeType === 1 && (" " + n.className + " ").indexOf(" cpid ") >= 0; }
  function makeIcon(id) {
    var i = document.createElement("span");
    i.className = "cpid"; i.textContent = "⧉"; i.title = "Copy " + id + " to the clipboard"; i.setAttribute("data-id", id);
    return i;
  }
  function addCopyIcons(root) {
    if (!root || root.nodeType !== 1) return;
    var els = Array.prototype.slice.call(root.querySelectorAll("td, th, code, .coreid-item, dd, li"));
    if (root.matches && root.matches("td, th, code, .coreid-item, dd, li")) els.unshift(root);
    for (var e = 0; e < els.length; e++) {
      var el = els[e], t = el.textContent, lc = isLinesCell(el);
      if ((!lc && t.length > 200) || t.indexOf("-") < 0) continue;
      if (!idAt(t)) continue;
      if (el.closest && el.closest(".colpick, .topbar")) continue;
      // the text nodes carrying an id, one icon after each (after the node's
      // element when that element IS the id — <code>id</code>, <a>id</a>)
      var walker = document.createTreeWalker(el, NodeFilter.SHOW_TEXT, null), node, nodes = [], count = 0;
      while ((node = walker.nextNode())) { if (!isIcon(node.parentNode)) nodes.push(node); }
      for (var k = 0; k < nodes.length && (lc || count < 4); k++) {
        node = nodes[k];
        var m = idAt(node.nodeValue); if (!m) continue;
        var par = node.parentNode, anchor = node;
        if (par !== el && par.textContent.trim() === m[0]) anchor = par;   // wrap-the-id element: icon after it
        if (isIcon(anchor.nextSibling)) continue;                          // already there
        if (anchor === node && par.textContent.trim() === m[0] && isIcon(par.nextSibling)) continue;   // the enclosing <code>/<a> already carries it (placed by an outer scan)
        anchor.parentNode.insertBefore(makeIcon(m[0]), anchor.nextSibling);
        count++;
      }
    }
  }
  function copyText(text, done) {
    function fallback() {
      var ta = document.createElement("textarea"); ta.value = text; ta.setAttribute("readonly", "");
      ta.style.position = "fixed"; ta.style.top = "-1000px"; document.body.appendChild(ta); ta.select();
      try { document.execCommand("copy"); } catch (e) {}
      document.body.removeChild(ta);
    }
    if (navigator.clipboard && navigator.clipboard.writeText) navigator.clipboard.writeText(text).then(done, function () { fallback(); done(); });
    else { fallback(); done(); }
  }
  // ---- CoreId links to SecureTransport's File Tracking (2026-09-07, user
  // request): every UUID the copy pass covers also OPENS the platform's own
  // file-tracking search for that id, in a new tab. The URL template —
  // "@COREID@" where the id goes — is baked into topbar-data.js from
  // input/coreid-url.txt (ensure_assets); a site without the file gets no
  // links. An id that already IS a link (a File page, an
  // error page, a record page) keeps it and gets a small ↗ after it instead,
  // so the internal page and the platform one are each one click away. Runs
  // BEFORE the copy pass, so the ⧉ lands after the link element the way it
  // lands after any wrap-the-id element. Row links and drills ignore clicks
  // on anchors, so a click on the id opens the platform and nothing else.
  function coreidUrlTemplate() {
    var t = (window.AXWAY_TB || {}).coreid || "";
    return (typeof t === "string" && t.indexOf("@COREID@") >= 0) ? t : "";
  }
  function coreidHref(tpl, id) { return tpl.split("@COREID@").join(encodeURIComponent(id)); }
  function isStGo(n) { return n && n.nodeType === 1 && (" " + n.className + " ").indexOf(" stgo ") >= 0; }
  function makeStLink(tpl, id, cls, text) {
    var a = document.createElement("a");
    a.className = cls; a.textContent = text; a.href = coreidHref(tpl, id); a.target = "_blank"; a.rel = "noopener";
    a.title = "Open " + id + " in SecureTransport File Tracking";
    return a;
  }
  // A TRANSFER id is a UUID too, but File Tracking searches by CoreId — a cell
  // under a "Transfer ID" header (the record / File / error pages' records
  // table) or beside a "Transfer ID" label (a facts row, a <dt>) gets the ⧉
  // only, never the link.
  function isTransferIdCell(el) {
    var lbl = "";
    if (el.tagName === "TD" || el.tagName === "TH") {
      var tbl = el.closest ? el.closest("table") : null;
      if (tbl) {
        var ci = el.getAttribute("data-ci"), th = null;
        if (ci !== null) th = tbl.querySelector('thead th[data-ci="' + ci + '"], tr:first-child th[data-ci="' + ci + '"]');
        if (!th && tbl.rows.length && el.cellIndex >= 0) th = tbl.rows[0].cells[el.cellIndex] || null;
        if (th) lbl = th.textContent;
      }
      var prev = el.previousElementSibling;
      if (prev && (prev.tagName === "TD" || prev.tagName === "TH")) lbl += " " + prev.textContent;
    } else if (el.tagName === "DD") {
      var dt = el.previousElementSibling; if (dt && dt.tagName === "DT") lbl = dt.textContent;
    }
    return /transfer\s*id/i.test(lbl);
  }
  // a multi-line list cell (td.lines — KIND clines / clinks: the Patterns
  // Last 5 Files, the drill-style lists) holds one id per line: the
  // 200-character cap and the 4-ids cap of the two id passes skipped it
  // whole, so its ids got no File Tracking link, ↗ or ⧉ (2026-09-30 audit
  // A5-04) — such a cell is scanned in full
  function isLinesCell(el) { return el.tagName === "TD" && (" " + el.className + " ").indexOf(" lines ") >= 0; }
  function addCoreIdLinks(root) {
    if (!root || root.nodeType !== 1) return;
    var tpl = coreidUrlTemplate(); if (!tpl) return;
    // the copy pass's element set PLUS the prose that names an id — a page
    // title ("Transfer <id>"), an intro ("… for CoreId `<id>`") — where the
    // 200-character cap of the cell scan would skip a long paragraph
    var SEL = "td, th, code, .coreid-item, dd, li, p, h1, h2, h3";
    var els = Array.prototype.slice.call(root.querySelectorAll(SEL));
    if (root.matches && root.matches(SEL)) els.unshift(root);
    for (var e = 0; e < els.length; e++) {
      var el = els[e], t = el.textContent, prose = /^(P|H1|H2|H3)$/.test(el.tagName), lc = isLinesCell(el);
      if ((!prose && !lc && t.length > 200) || t.indexOf("-") < 0) continue;
      if (!idAt(t)) continue;
      if (el.closest && el.closest(".colpick, .topbar")) continue;
      if (isTransferIdCell(el) || (el.tagName === "CODE" && el.parentNode && el.parentNode.closest && isTransferIdCell(el.parentNode.closest("td, dd") || el))) continue;
      var walker = document.createTreeWalker(el, NodeFilter.SHOW_TEXT, null), node, nodes = [], count = 0;
      while ((node = walker.nextNode())) { if (!isIcon(node.parentNode) && !isStGo(node.parentNode)) nodes.push(node); }
      for (var k = 0; k < nodes.length && (lc || count < 4); k++) {
        node = nodes[k];
        var m = idAt(node.nodeValue); if (!m) continue;
        var par = node.parentNode, a = par.closest ? par.closest("a") : null;
        if (a) {
          // already a link: our own wrap (a re-run) — nothing to do; an
          // internal page link — the ↗ after it, once (the ⧉ may sit between)
          if ((" " + a.className + " ").indexOf(" stid ") >= 0) { count++; continue; }
          var s = a.nextSibling, has = false;
          while (s && (isIcon(s) || isStGo(s))) { if (isStGo(s)) { has = true; break; } s = s.nextSibling; }
          if (!has) {
            // the link, its ⧉ (added after this pass, right after the link)
            // and the ↗ stay on ONE line: a no-wrap span around them, so a
            // narrow cell never breaks the ↗ onto a line of its own
            var w = document.createElement("span"); w.className = "stwrap";
            a.parentNode.insertBefore(w, a); w.appendChild(a);
            w.appendChild(makeStLink(tpl, m[0], "stgo", "↗"));
          }
          count++; continue;
        }
        // plain text: the id itself becomes the link; the text around it stays
        var before = node.nodeValue.slice(0, m.index), after = node.nodeValue.slice(m.index + m[0].length);
        var link = makeStLink(tpl, m[0], "stid", m[0]);
        par.insertBefore(link, node);
        if (before) par.insertBefore(document.createTextNode(before), link);
        if (after) { node.nodeValue = after; nodes.push(node); } else par.removeChild(node);   // a second id in the same text is scanned next
        // a cell holding ONLY the id: the whole cell is the link's click
        // target (the whole-cell rule, 2026-09-30 audit J-02 — wholeCellLinks
        // ran before this pass and never saw the link); the ⧉ added after
        // stays clickable above the stretched link (style.css .cpid)
        if (!before && !after && par.tagName === "TD" && par.querySelectorAll("a").length === 1 &&
            par.textContent.replace(/\s+/g, "") === m[0]) par.classList.add("cl");
        count++;
      }
    }
  }
  function setupCopyIds() {
    addCoreIdLinks(document.body);
    addCopyIcons(document.body);
    document.addEventListener("click", function (e) {
      var i = e.target && e.target.closest ? e.target.closest(".cpid") : null; if (!i) return;
      e.preventDefault(); e.stopPropagation();   // never the row link, the drill or the sort behind it
      var id = i.getAttribute("data-id");
      copyText(id, function () {
        i.textContent = "✓"; i.className = "cpid done"; i.title = "Copied";
        setTimeout(function () { i.textContent = "⧉"; i.className = "cpid"; i.title = "Copy " + id + " to the clipboard"; }, 3000);   // 3 s (user request: longer, bigger)
      });
    }, true);
    // content the page adds later (drill-down lists, Entity Search, the Files page)
    if (window.MutationObserver) {
      var pending = [], queued = false;
      new MutationObserver(function (muts) {
        for (var m = 0; m < muts.length; m++) for (var a = 0; a < muts[m].addedNodes.length; a++)
          if (muts[m].addedNodes[a].nodeType === 1) pending.push(muts[m].addedNodes[a]);
        if (!pending.length || queued) return;
        queued = true;
        setTimeout(function () { var p = pending; pending = []; queued = false; for (var x = 0; x < p.length; x++) if (!isIcon(p[x]) && !isStGo(p[x])) { addCoreIdLinks(p[x]); addCopyIcons(p[x]); } }, 50);
      }).observe(document.body, { childList: true, subtree: true });
    }
    // a restore that rewrote a cell's text (data-orig) drops its icon: put it back on the next pointer pass
    document.addEventListener("mouseover", function (e) {
      var el = e.target; if (!el || el.nodeType !== 1 || !el.matches || !el.matches("td, th, code, .coreid-item")) return;
      if (el.querySelector(".cpid")) return;
      addCoreIdLinks(el);
      addCopyIcons(el);
    });
  }

  // (THE TOP BAR — buildTopbar, fitTopbar and the environment switch — lives
  // in assets/topbar.js since 2026-09-30: ONE implementation for every page,
  // the help pages and the build report included; it runs before this file.)

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
        if (cl.indexOf(" arrow ") >= 0 || cl.indexOf(" csvbtn ") >= 0 || cl.indexOf(" pickbtn ") >= 0 || cl.indexOf(" colpick ") >= 0 || cl.indexOf(" cpid ") >= 0 || cl.indexOf(" stgo ") >= 0 || cl.indexOf(" ce ") >= 0) continue;   // the hotspots (csv, cols, the picker, the copy icon, the File Tracking ↗) are not cell text
        // skip what CSS hides: the von/voff toggle twin not in effect, a
        // collapsed clines middle — the export is the cell AS DISPLAYED
        try { if (window.getComputedStyle && getComputedStyle(c).display === "none") continue; } catch (err) {}
        walk(c);
      }
    })(cell);
    return out.replace(/\u00a0/g, " ").replace(/\s+/g, " ").replace(/^ | $/g, "");
  }
  // a cell a spreadsheet would read as a FORMULA (=, +, @, or a "-" that is
  // no number) is exported with a leading apostrophe, the text marker Excel
  // and LibreOffice honour (2026-09-28: a logged file name or message went
  // into the CSV verbatim)
  function csvField(s) {
    if (/^[=+@\t\r]/.test(s) || (/^-./.test(s) && !/^-[\d.,]+ ?[%A-Za-z]*$/.test(s))) s = "'" + s;   // a lone "-" (the empty-value dash) stays
    return /[",\n\r]/.test(s) ? '"' + s.replace(/"/g, '""') + '"' : s;
  }
  // all (optional): an ENGINE table's full row set — arrays of cell texts in
  // BUILT column order, supplied by the page engine through table._csvAll
  // (sub-files.js: the subscription Files table shows 25 rows of thousands);
  // exported instead of the DOM rows, through the same header and quoting
  function tableCsv(table, all) {
    var hr = headerRow(table), rows = dataRows(table), lines = [], i;
    function line(tr) {
      var out = [], j;
      for (j = 0; j < tr.cells.length; j++) if (!tr.cells[j].hidden) out.push(csvField(csvCellText(tr.cells[j])));   // a picker-hidden column stays out
      return out.join(",");
    }
    // a GROUPED table (a GHEAD banner \u2014 Files / Transfers / \u2026) prefixes each
    // header with its group, "Files Error" / "Transfers Error" (2026-09-29:
    // the export read "Error" three times, "Ok" twice, and lost the group)
    if (hr) {
      var hout = [], hj, hc, hl, hg;
      for (hj = 0; hj < hr.cells.length; hj++) {
        hc = hr.cells[hj]; if (hc.hidden) continue;
        hl = csvCellText(hc);
        if (table._groupLabel && table._colGroup) { hg = table._groupLabel[groupOf(table, ciOf(hc))]; if (hg) hl = hg + " " + hl; }
        hout.push(csvField(hl));
      }
      lines.push(hout.join(","));
    }
    if (all) {
      for (i = 0; i < all.length; i++) {
        var aout = [], aj, ac;
        if (hr) { for (aj = 0; aj < hr.cells.length; aj++) { ac = hr.cells[aj]; if (!ac.hidden) aout.push(csvField(String(all[i][ciOf(ac)] == null ? "" : all[i][ciOf(ac)]))); } }
        else for (aj = 0; aj < all[i].length; aj++) aout.push(csvField(String(all[i][aj])));
        lines.push(aout.join(","));
      }
    } else
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
        // button or muted period span stays out of the filename
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
  // An ENGINE table (its rows built page by page in the browser) may hand over
  // its WHOLE row set: table._csvAll(cb) calls cb(rows) — rows as tableCsv's
  // `all` — or cb(null, why) when it cannot. Then NOTHING is saved: the rows
  // on screen used to go out as if they were the whole history (2026-09-29
  // audit F13); the hotspot reads "csv ✗", its title says why, a click
  // retries. The hotspot reads "…" while the engine loads.
  function downloadCsv(table, btn) {
    if (typeof table._csvAll === "function") {
      if (btn) { if (btn._busy) return; btn._busy = true; btn.textContent = "…"; }
      table._csvAll(function (all, why) {
        if (btn) btn._busy = false;
        if (!all) {
          if (btn) { btn.textContent = "csv \u2717"; btn.title = "Not exported: " + (why || "the rows could not be loaded") + " — click to retry"; }
          return;
        }
        if (btn) { btn.textContent = "csv"; btn.title = "Download this table as CSV"; }
        saveCsv(table, tableCsv(table, all));
      });
      return;
    }
    saveCsv(table, tableCsv(table));
  }
  function saveCsv(table, text) {
    var blob = new Blob([text], { type: "text/csv;charset=utf-8" });
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
      downloadCsv(table, b);
    });
    th.className += (th.className ? " " : "") + "csvhost";
    th.appendChild(b);
  }

  // Whole-cell links (2026-09-14, user rule): a cell whose only content is
  // ONE link gets class `cl` — style.css stretches that link over the whole
  // cell, so the click target is the cell, not just its text. The renderer
  // bakes `cl` for link=/href=/entity cells (render_rpt.awk); this pass
  // catches the hand-built tables (the index lists, the
  // configuration pages) and any writer that forgot. A cell with text beside its
  // link, or more than one element, is left alone; header cells too (their
  // click sorts). Runs before the data-origc snapshots, which copy className.
  function wholeCellLinks(table) {
    var as = table.querySelectorAll("td > a[href]"), i, a, td;
    for (i = 0; i < as.length; i++) {
      a = as[i]; td = a.parentNode;
      if (td.children.length !== 1 || (" " + td.className + " ").indexOf(" cl ") >= 0) continue;
      if (td.textContent.replace(/\s+/g, " ").trim() !== a.textContent.replace(/\s+/g, " ").trim()) continue;
      td.className = (td.className ? td.className + " " : "") + "cl";
    }
  }
  // ---- KEYBOARD access (2026-09-29 audit) ----------------------------------
  // The site's clickable SPANS — the tab-style buttons (hero views, chart
  // style / interval / scale, switch groups, the pagers), the csv / cols
  // hotspots — and the sortable headers are neither links nor buttons, so a
  // keyboard could not reach them: each gets a tab stop (and a span the button
  // role), and ONE delegated handler turns Enter / Space on it into the click
  // its own handler already listens for (shift kept: shift+Enter on a header
  // adds a sort key like shift-click). Engine scripts
  // that build such spans after init (sub-files.js) stamp their own.
  var KB_SEL = "span.tab, .csvbtn, .pickbtn, th.sortable";
  function kbStamp(root) {
    var els = root.querySelectorAll(KB_SEL), i, el;
    for (i = 0; i < els.length; i++) {
      el = els[i];
      if (!el.hasAttribute("tabindex")) el.setAttribute("tabindex", "0");
      if (el.tagName === "SPAN" && !el.hasAttribute("role")) el.setAttribute("role", "button");
    }
  }
  function setupKeyboard() {
    kbStamp(document);
    document.addEventListener("keydown", function (e) {
      var t = e.target;
      // (the Escape key left the Reports pulldown — gone 2026-09-30 with it)
      if (e.key !== "Enter" && e.key !== " " && e.key !== "Spacebar") return;
      if (!t || !t.matches || !(t.matches(KB_SEL) || (t.getAttribute("role") === "button" && t.tagName === "SPAN"))) return;
      if (e.altKey || e.ctrlKey || e.metaKey) return;
      e.preventDefault();                             // Space would scroll the page
      if (/(^| )disabled( |$)/.test(t.className)) return;
      t.dispatchEvent(new MouseEvent("click", { bubbles: true, cancelable: true, view: window, shiftKey: e.shiftKey }));
    });
  }

  // (The Latest files pages' latestRows() — docs/latest/<slug>.html rows
  // shipped as DATA — went 2026-09-29 with the pages: a subscription page's
  // Files table is built by assets/sub-files.js.)

  // THE ENTITIES ROW PAYLOAD (2026-09-30, publish_lib entity_payload_split):
  // an Entities view page ships its rows' data-buckets / data-durdays /
  // data-fp / data-coreids-* ONCE per entity in <entity>-data.js
  // (window.AXWAY_EP, `<tr data-k="N" …></tr>` lines); each page row carries
  // data-k="N". Parsed by the browser's own HTML parser (a <template>), so the
  // attribute values decode exactly as they did inline, and copied back onto
  // the rows — FIRST in init(), before anything reads them.
  function attachEntityPayload() {
    var src = window.AXWAY_EP;
    if (typeof src !== "string" || !src) return;
    var rows = document.querySelectorAll("tr[data-k]");
    if (!rows.length) return;
    var tpl = document.createElement("template");
    tpl.innerHTML = "<table><tbody>" + src + "</tbody></table>";
    var map = {}, prs = tpl.content.querySelectorAll("tr[data-k]"), i, j;
    for (i = 0; i < prs.length; i++) map[prs[i].getAttribute("data-k")] = prs[i];
    for (i = 0; i < rows.length; i++) {
      var tr = rows[i], p = map[tr.getAttribute("data-k")];
      tr.removeAttribute("data-k");
      if (!p) continue;
      for (j = 0; j < p.attributes.length; j++) {
        var at = p.attributes[j];
        if (at.name !== "data-k") tr.setAttribute(at.name, at.value);
      }
    }
    window.AXWAY_EP = null;
  }

  // THE COMPACT ROW PAYLOAD (2026-09-30, the lean round): render_rpt ships a
  // drill list that repeats an earlier one of the SAME row as a reference —
  // data-coreids-<key>="=<first key>", data-drill-cell-<n>="=<m>". Expanded
  // here, right after attachEntityPayload, so every reader sees the full
  // lists exactly as they were rendered before.
  // …and data-buckets / data-durdays name their day by its INDEX in the
  // page's report-dates list (a date the list lacks stays literal), a bucket
  // metric of "0" ships empty and an originally empty one as "~"
  // (render_rpt benc / denc) — decoded back to the dated form here.
  function expandDays(v, rd, isBuckets) {
    if (!v) return v;
    var it = v.split(","), i, f, j;
    for (i = 0; i < it.length; i++) {
      f = it[i].split(":");
      if (/^\d+$/.test(f[0]) && rd[+f[0]] !== undefined) f[0] = rd[+f[0]];
      if (isBuckets) for (j = 1; j < f.length; j++) f[j] = f[j] === "" ? "0" : (f[j] === "~" ? "" : f[j]);
      it[i] = f.join(":");
    }
    return it.join(",");
  }
  // …and a File drill list marked "#" ships its CoreIds without dashes and,
  // on a row whose first cell is a date, its entries without that date
  // (render_rpt fenc) — the mirror of render_rpt's dsplit + redash: the
  // date back before an entry that starts with a time, the dashes on every
  // 32-hex run with no hex character on either side.
  function expandFileList(v, rowDate) {
    v = v.slice(1);
    if (rowDate) {
      var segs = v.split(/([,\x1f])/), k;
      for (k = 0; k < segs.length; k += 2) if (/^\d\d:\d\d:\d\d/.test(segs[k])) segs[k] = rowDate + " " + segs[k];
      v = segs.join("");
    }
    var out = "", re = /[0-9a-f]{32}/g, m, last = 0, pre, post, t;
    while ((m = re.exec(v)) !== null) {
      pre = m.index > 0 ? v.charAt(m.index - 1) : "";
      post = v.charAt(m.index + 32);
      t = m[0];
      if (!/[0-9a-f]/.test(pre) && !/[0-9a-f]/.test(post))
        t = t.slice(0, 8) + "-" + t.slice(8, 12) + "-" + t.slice(12, 16) + "-" + t.slice(16, 20) + "-" + t.slice(20);
      out += v.slice(last, m.index) + t; last = m.index + 32;
    }
    return out + v.slice(last);
  }
  function expandPayload() {
    var trs = document.getElementsByTagName("tr"), i, j, tr, at, v, nm, ref, fixes;
    var dm = document.querySelector('meta[name="report-dates"]'), rd = dm ? (dm.getAttribute("content") || "").split(",") : [];
    for (i = 0; i < trs.length; i++) {
      tr = trs[i]; fixes = null;
      if (dm) {   // encoded only on a page WITH a date list (render_rpt rdates)
        v = tr.getAttribute("data-buckets"); if (v) tr.setAttribute("data-buckets", expandDays(v, rd, true));
        v = tr.getAttribute("data-durdays"); if (v) tr.setAttribute("data-durdays", expandDays(v, rd, false));
      }
      var rowDate = null;
      for (j = 0; j < tr.attributes.length; j++) {
        at = tr.attributes[j]; v = at.value;
        if (v.charAt(0) === "#" && (at.name === "data-coreids" || at.name.indexOf("data-coreids-") === 0 || at.name.indexOf("data-drill-cell-") === 0)) {
          if (rowDate === null) {
            rowDate = tr.cells.length ? (tr.cells[0].textContent || "") : "";
            if (!/^\d{4}-\d{2}-\d{2}$/.test(rowDate)) rowDate = "";
          }
          at.value = expandFileList(v, rowDate);
          continue;
        }
        if (v.charAt(0) !== "=") continue;
        nm = at.name;
        if (nm.indexOf("data-coreids-") === 0) ref = "data-coreids-" + v.slice(1);
        else if (nm.indexOf("data-drill-cell-") === 0) ref = "data-drill-cell-" + v.slice(1);
        else continue;
        (fixes || (fixes = [])).push([nm, ref]);
      }
      if (fixes) for (j = 0; j < fixes.length; j++) tr.setAttribute(fixes[j][0], tr.getAttribute(fixes[j][1]) || "");
    }
  }

  function init() {
    attachEntityPayload();  // FIRST of all: the Entities rows get their payload back (see above)
    expandPayload();        // … and every compact attribute its full value
    setupRelDates();        // "3 days ago" tooltips on date cells, lazily
    entTouch();             // Entities: slide the shared sort's hour on every view
    var tables = document.getElementsByTagName("table");
    for (var i = 0; i < tables.length; i++) {
      initColOrder(tables[i]); // FIRST: stamp the built column index + apply a remembered column order
      wholeCellLinks(tables[i]); // single-link cells become whole-cell click targets (class cl) — before the className snapshots below
      initGroup(tables[i]);   // record real group values — before makeSortable's data-sort-init
      makeSortable(tables[i]); // sorts/blanks col 0, which would otherwise memorize a blanked value
      applyGroup(tables[i]);
      setupExpandable(tables[i]);  // clickable drill-down BEFORE the data-origc snapshots below,
                                   // so a recalc/seen-rows className restore keeps the .expandable affordance
      setupSubrows(tables[i]);     // Entity Search: multi-use Source/Target rows expand into per-subscription rows
      setupRowFold(tables[i]);     // fold=<res> rows collapse behind one summary row (Incoming IPs)
      initTotals(tables[i]);  // remember original totals so the filter can restore them
      initRecalc(tables[i]);  // remember originals of re-aggregatable cells
      initSeen(tables[i]);    // seen-rows tables: remember originals + full-period seen flag
      if (tables[i].getAttribute("data-heat")) initHeat(tables[i]);   // heatmap: remember each cell's text + tint
      recomputeTotals(tables[i]);  // fold the skipped rows out of the totals (non-bucket tables)
      setupCsvBtn(tables[i]);      // the CSV-download hotspot in the last header cell's corner
      if (tables[i]._colTools) { tables[i]._toolsOn = true; replaceHotspots(tables[i]); }   // the column tools LAST: after every data-orig / data-html snapshot
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
    setupCellLinks();    // td/th[data-href] cell links (the home Duration group), outranking the row link
    setupEntityErrorLinks(); // Entities subscription pages: the Files Error count opens Failed files for that subscription + the active dates
    setupSwitches();     // switch=KEY table groups: one table of the group at a time behind a button row
    setupHeroToggle();   // overview + day pages: the hero view switch
    setupSearchConfig(); // Entity Search: the collapsed configuration panel
    setupCollapsible();  // clines cells (patterns): click toggles the collapsed middle lines
    hideEmptyTables();   // after the search/date filters have hidden rows
    markEmptyTables();   // a table with NO data rows says so (the report pages render no no-data prose)
    setupSectionTabs();  // detail pages: the fixed h1 + section-tab header (after empty sections are hidden)
    setupSelFilter();    // coverage partners page: Connection / Movement / Use case selectors
    markUrlColumn();     // LAST with markUrlRow: the column order it marks and scrolls to must be final
    markUrlRow();        // LAST: the sort/date/pager order it scrolls to must be final
    setupCopyIds();      // after every snapshot: the File Tracking link + the ⧉ on each id must not be captured as cell text
    setupKeyboard();     // LAST: every clickable span / sortable header built above gets its tab stop
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
