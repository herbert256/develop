/* slotchart.js — the SLOT charts (the hero graph of the dashboards overview
   and of every day page), rendered in the BROWSER.
   ------------------------------------------------------------------------
   They used to be baked as SVG by bin/dashboards/charts_lib.sh: with three
   styles x three intervals that meant NINE copies of the same card in the
   HTML, and the overview weighed 1.2 MB. Now the publish emits one compact
   placeholder per card carrying the series as data attributes, and this file
   draws the SVG, the data table and the tooltip, redrawing on a style or
   interval click. It is a SEPARATE asset from report.js: only the two page
   kinds that own a slot chart load it.

   Placeholder contract (bin/dashboards/publish.sh, bin/day/publish.sh):
     <div class="slotchart" data-kind="dur|durfit|count|bytes|rate|pesit"
          data-cid="ch1" data-title="…" data-link="../day/{}.html?…"
          data-base="360" data-iv360="…" [data-iv240="…" data-iv720="…" …]></div>
   Each data-iv<MINUTES> is one resolution, "label:v1[:v2[:v3]]:date|…" — the
   same string the .rpt carries — and data-base names the one that starts
   visible: 360 (6 h) on the overview, 30 (min) on a day page. The interval
   row lists whatever tags the card carries, so the overview offers 4h/6h/12h/
   1 day and a day page 15/30 min/1 hour; a card missing the picked tag (the
   day PeSIT card has no 15-minute sidecar) falls back to its base.

   Everything here mirrors the awk generator it replaced, pixel for pixel:
   the 760x230 frame, the fixed 12-tick duration axis, the mirrored y labels,
   the per-style marks and the transparent per-slot hover columns. */
(function () {
  "use strict";

  var W = 760, H = 230, L = 46, R = 46, T0 = 16, B = 34;
  var BASE = H - B, IW = W - L - R, IH = BASE - T0;
  var GRID = "#e9edf2", MUTE = "#8a97a4";
  var CB = "#3b82c4", CG = "#3f9d52", CR = "#df5a4c", CP = "#7d63c6", CO = "#d9821c";
  var CBL = "#8fb8d8", COL = "#f0c07a";   // the light blue / light orange the UC-status ramp needs
  var SKEY = "axway-chart-style", IKEY = "axway-chart-interval", SCKEY = "axway-chart-scale";

  // the fixed duration axis: 5 s .. >= 48 h, equal tick spacing, linear
  // between ticks; the LAST tick is the clamp ceiling (a value at or above
  // it draws at the top) and its label names the beyond-the-previous band
  var DT = [5000, 10000, 30000, 60000, 300000, 1800000, 3600000, 10800000, 21600000, 36000000, 86400000, 172800000];
  var DTL = ["5 s", "10 s", "30 s", "1 m", "5 m", "30 m", "1 h", "3 h", "6 h", "10 h", "24 h", ">= 48 h"];

  // The FITTED duration axis (kind `durfit`, the Monitor charts): identical
  // bands and piecewise-linear segments, but the ticks come from this chart's
  // OWN data — the monitor loop is floored at ~5 min by the :05 poll, so the
  // shared 1 s..1 h axis parks it in a sliver. Ticks are picked from a
  // nice-duration ladder spanning [min, max] of the plotted values (every
  // entry integral in its display unit), thinned to at most 8.
  var DLAD = [1000, 2000, 5000, 10000, 15000, 30000, 60000, 120000, 300000, 600000, 900000, 1200000, 1800000, 2700000, 3600000, 7200000, 14400000, 43200000, 86400000];
  function dtick(ms) { return ms < 60000 ? ms / 1000 + " s" : ms < 3600000 ? ms / 60000 + " m" : ms / 3600000 + " h"; }
  function fitTicks(slots) {
    var mn = Infinity, mxv = 0, i, q, t;
    for (i = 0; i < slots.length; i++) if (slots[i].has)
      for (q = 0; q < slots[i].v.length; q++) { t = slots[i].v[q]; if (t < mn) mn = t; if (t > mxv) mxv = t; }
    if (mxv === 0) return { t: DT, l: DTL };
    var lo = 0, hi = DLAD.length - 1;
    while (lo < DLAD.length - 1 && DLAD[lo + 1] <= mn) lo++;
    while (hi > 0 && DLAD[hi - 1] >= mxv) hi--;
    if (hi <= lo) hi = lo + 1;
    var t2 = DLAD.slice(lo, hi + 1);
    while (t2.length > 8) {
      var th = [], j;
      for (j = 0; j < t2.length - 1; j += 2) th.push(t2[j]);
      th.push(t2[t2.length - 1]);
      t2 = th;
    }
    var l2 = [], k;
    for (k = 0; k < t2.length; k++) l2.push(dtick(t2[k]));
    return { t: t2, l: l2 };
  }

  function esc(s) { return String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;"); }

  // ---- value formatting (hn/hb/hdur in charts_lib.sh) ----------------------
  function hn(t) {
    t = +t;
    if (t >= 1e9) return (t / 1e9).toFixed(1) + "B";
    if (t >= 1e6) return (t / 1e6).toFixed(1) + "M";
    if (t >= 1e3) return (t / 1e3).toFixed(1) + "k";
    if (t !== Math.floor(t) && t < 100) return t.toFixed(1);
    return String(Math.floor(t));
  }
  function hb(b) {
    var u = ["B", "KB", "MB", "GB", "TB", "PB"], i = 0, v = +b;
    while (v >= 1024 && i < 5) { v /= 1024; i++; }
    return i === 0 ? Math.floor(v) + " B" : v.toFixed(2) + " " + u[i];
  }
  function hmbs(x) {
    x = +x;
    return (x >= 100 ? x.toFixed(0) : x >= 10 ? x.toFixed(1) : x.toFixed(2)) + " MB/s";
  }
  function hdur(ms) {
    ms = +ms;
    if (ms < 1000) return Math.floor(ms) + " ms";
    if (ms < 60000) return (ms / 1000).toFixed(1) + " s";
    if (ms < 3600000) return (ms / 60000).toFixed(1) + " min";
    return (ms / 3600000).toFixed(1) + " h";
  }

  // ---- per-KIND setup (series count, colours, names, empty text) -----------
  function kindSpec(kind) {
    if (kind === "dur" || kind === "durfit") return { ns: 3, col: ["#1e6b38", "#d9821c", "#95241e"], name: ["P50", "P90", "P98"], empty: "no OK Files in this slot", fmt: hdur };
    if (kind === "pesit") return { ns: 2, col: [CR, CP], name: ["ST → CFT", "CFT → ST"], empty: "no data", fmt: hn };
    // the CUMULATIVE "seen" curves (Subscriptions seen / Partners seen). FOUR
    // counts: v0 blue = seen in transfer + server (the union, always the highest),
    // v1 orange = seen in the transfer log, then v1 split into v2 green (its
    // latest File was OK) and v3 red (it was not), so v2 + v3 === v1 always.
    // The three STYLES differ here, unlike every other kind — see draw():
    //   line   all 4 as absolute lines: blue, orange, green, red
    //   bar    stacked, no orange: red, then green (topping out AT orange), then
    //          blue as the remaining blue - orange
    //   solid  the same stack as areas
    if (kind === "seen") return { ns: 4, col: [CB, CO, CG, CR], name: ["Transfer + server", "Transfer", "Green", "Red"], empty: "no data", fmt: hn };
    // the UC-status STACKS (UC1/UC3/UC4 share one 7-series shape, UC2 has its
    // own 5). The stack is TOTAL-PRESERVING — every slot sums to the configured
    // subscription count, which does not change (we hold no config history), so
    // the top edge is flat and the card reads as a composition over time.
    // Bottom-up = ascending severity: green OK first, the never-seen bucket
    // (light orange) last, the problem states ramping in between.
    if (kind === "ucst") return { ns: 7, stack: 1, col: [CG, CBL, CB, CP, CO, CR, COL],
      name: ["OK", "No result", "No files", "Server error", "OK + error", "Error", "Not seen"], empty: "no data", fmt: hn };
    if (kind === "ucst2") return { ns: 5, stack: 1, col: [CG, CB, CO, CR, COL],
      name: ["OK", "Both", "No files", "Never collected", "Nothing"], empty: "no data", fmt: hn };
    if (kind === "count") return { ns: 1, col: [CB], name: ["OK Files"], empty: "no data", fmt: hn };
    if (kind === "bytes") return { ns: 1, col: [CG], name: ["Volume"], empty: "no data", fmt: hb };
    // wire SPEED, not bytes: the slot's counted bytes over its counted leg
    // durations. Only legs big and slow enough to measure a rate count (the
    // Route throughput report's floors), so a slot can legitimately be empty.
    // Token "speed", NOT "rate" (2026-08): "rate" is the ERROR-PERCENTAGE kind
    // the overview AND every day page have always emitted — claiming it here
    // painted the Error % Files hero in MB/s.
    if (kind === "speed") return { ns: 1, col: [CP], name: ["Throughput"], empty: "no measurable transfers in this slot", fmt: hmbs };
    if (kind === "rate") return { ns: 1, col: [CR], name: ["Error % Files"], empty: "no Files in this slot", fmt: function (x) { return (+x).toFixed(1) + "%"; } };
    // connections OPENED in the slot (one technical session = one), split by
    // who dialled: the partner's client, or us
    if (kind === "conns") return { ns: 2, stack: 1, col: [CB, CBL], name: ["Partner dialled in", "We dialled out"], empty: "no data", fmt: hn };
    if (kind === "errs") return { ns: 1, col: [CR], name: ["Transfer errors"], empty: "no data", fmt: hn };
    return { ns: 1, col: [CR], name: ["Error % Files"], empty: "no Files in this slot", fmt: function (x) { return (+x).toFixed(1) + "%"; } };
  }

  // "label:v1[:v2[:v3]]:date|…" -> [{lab, v:[…], dt, has}]
  function parse(data, ns) {
    var out = [], seg = data ? data.split("|") : [], i, p, s;
    for (i = 0; i < seg.length; i++) {
      p = seg[i].split(":");
      s = { lab: p[0], dt: p[ns + 1], v: [], has: false };
      if (p[1] !== "" && p[1] !== undefined) {
        s.has = true;
        for (var k = 0; k < ns; k++) s.v.push(+p[1 + k]);
      }
      out.push(s);
    }
    return out;
  }

  // ---- the drawing ---------------------------------------------------------
  // scale: "log" (default) or "lin". A few series swing over three orders of
  // magnitude — a 22k-File batch dump next to a 2k day, 44k connections next
  // to a few hundred — and on a linear axis every ordinary slot is pressed
  // flat against the floor, so log is the DEFAULT — except the "seen" kind,
  // which opens LINEAR (2026-09-03, user request; init()'s scaleFor); the
  // Linear/Log buttons switch per kind, and the axis is never silent: the tick labels always carry the
  // log-spaced values (an unlabelled log axis misreads as linear). log10(v+1) so a
  // real zero stays on the floor. On a STACKED kind the segment tops are
  // log-placed, so the bands still order correctly but their heights are no
  // longer proportional shares — the tooltip and the data table keep the real
  // numbers. Duration keeps its own fixed ms->h axis, which is already
  // non-linear, so it is never offered the toggle.
  function draw(kind, style, slots, linkpat, cid, title, scale) {
    // durfit = dur on a per-chart fitted axis; remapped HERE so every other
    // dur branch (marks, tooltip, data table) is shared untouched
    var DTv = DT, DTLv = DTL;
    if (kind === "durfit") { var ft = fitTicks(slots); DTv = ft.t; DTLv = ft.l; kind = "dur"; }
    var K = kindSpec(kind), ns = K.ns, n = slots.length, i, s, g;
    var step = n > 1 ? IW / (n - 1) : 0, gw = IW / n, bw = gw * 0.6, mx = 1;
    if (kind !== "dur") {
      for (i = 0; i < n; i++) if (slots[i].has) {
        var tv = kind === "pesit" ? slots[i].v[0] + slots[i].v[1] : slots[i].v[0];
        if (K.stack) { tv = 0; for (var q0 = 0; q0 < ns; q0++) tv += slots[i].v[q0]; }
        if (tv > mx) mx = tv;
      }
      // WHOLE-NUMBER axis for the kinds whose values are counts. The five
      // gridlines are max*4/4 … 0, so a max under 100 gave fractional ticks
      // (47 -> 47, 35.3, 23.5, 11.8, 0) for things you cannot have a fraction
      // of — subscriptions, partners, Files, problem lines. Rounding the MAX up
      // to a multiple of 4 makes every quarter an exact integer, and scales the
      // plot to the same rounded top; the log-spaced ticks round the same way
      // below. (rate is a percentage and bytes are humanised, so both keep
      // their decimals; dur has its own fixed axis.)
      var whole = kind === "seen" || kind === "count" || kind === "errs" || kind === "pesit" || K.stack;
      if (whole) mx = Math.ceil(mx / 4) * 4;
    }
    var LOG = (scale === "log" && kind !== "dur");
    function l10(v) { return Math.log((+v) + 1) / Math.LN10; }
    function ypos(val) {
      if (kind === "dur") {
        if (val <= DTv[0]) return BASE;
        if (val >= DTv[DTv.length - 1]) return T0;
        for (var q = 0; q < DTv.length - 1; q++)
          if (val <= DTv[q + 1]) return BASE - (q + (val - DTv[q]) / (DTv[q + 1] - DTv[q])) / (DTv.length - 1) * IH;
        return T0;
      }
      if (LOG) return BASE - (l10(mx) > 0 ? l10(val) / l10(mx) : 0) * IH;
      return BASE - val / mx * IH;
    }
    function slotx(i) { return style === "bar" ? L + (i + 0.5) * gw : (n > 1 ? L + i * step : L + IW / 2); }
    function pt(x, y) { return x.toFixed(1) + "," + y.toFixed(1) + " "; }

    var o = [];
    // The accessible NAME is an aria-label, not a <title> child: a root <title>
    // makes the browser draw its own one-line tooltip anywhere over the SVG,
    // which showed up beside the styled .dbtip as a second, poorer tip. Same
    // reason the per-slot rect.dbz hover targets carry no <title> either. The
    // <desc> below stays — it is read by screen readers and draws nothing.
    o.push('<svg viewBox="0 0 ' + W + " " + H + '" class="svg svg-slots slots-' + style +
           '" preserveAspectRatio="none" role="img" aria-label="' + esc(title) +
           '" aria-describedby="' + cid + '-d">');

    // accessible description — the same sentences the awk generator wrote
    var seen = 0, mxv = -1, mxi = 0, to = 0, ti = 0;
    for (i = 0; i < n; i++) if (slots[i].has) {
      seen++;
      // the "peak" series: dur's is P98 (its largest), seen's is v0 (blue, the union)
      var pv = K.stack ? slots[i].v[ns - 1]
             : ns === 3 ? (kind === "dur" ? slots[i].v[2] : slots[i].v[0])
             : (ns === 2 ? slots[i].v[0] + slots[i].v[1] : slots[i].v[0]);
      if (pv > mxv) { mxv = pv; mxi = i; }
      if (kind === "pesit") { to += slots[i].v[0]; ti += slots[i].v[1]; }
    }
    var ds;
    if (!n) ds = "No data.";
    else if (kind === "dur")
      ds = seen + " slots from " + slots[0].lab + " to " + slots[n - 1].lab + ". Stacked bands: the top edge of each colour is that slot P50, P90 and P98 OK-File duration. Highest P98 " + hdur(mxv) + " in the " + slots[mxi].lab + " slot.";
    else if (kind === "pesit")
      ds = seen + " slots from " + slots[0].lab + " to " + slots[n - 1].lab + ". ST to CFT " + hn(to) + " and CFT to ST " + hn(ti) + " problem lines; busiest slot " + slots[mxi].lab + " (" + K.fmt(mxv) + ").";
    else if (kind === "seen")
      ds = seen + " slots from " + slots[0].lab + " to " + slots[n - 1].lab + ". Cumulative sightings, so blue and orange only rise; green and red move both ways and always sum to orange. By the last slot: " + hn(slots[n - 1].v[0]) + " seen in the transfer + server logs, " + hn(slots[n - 1].v[1]) + " in the transfer log, of which " + hn(slots[n - 1].v[2]) + " green and " + hn(slots[n - 1].v[3]) + " red.";
    else if (K.stack) {
      var lv = slots[n - 1].v, tot9 = 0, parts = [];
      for (i = 0; i < ns; i++) { tot9 += lv[i]; if (lv[i] > 0) parts.push(hn(lv[i]) + " " + K.name[i]); }
      ds = seen + " slots from " + slots[0].lab + " to " + slots[n - 1].lab + ". A stack of " + hn(tot9) +
           " subscriptions, always that total, composed bottom-up from OK to not seen. By the last slot: " + parts.join(", ") + ".";
    } else
      ds = seen + " slots from " + slots[0].lab + " to " + slots[n - 1].lab + ". Peak " + K.fmt(mxv) + " in the " + slots[mxi].lab + " slot.";
    o.push('<desc id="' + cid + '-d">' + esc(ds) + "</desc>");

    // grid + y labels on BOTH sides
    if (kind === "dur") {
      for (g = 0; g < DTv.length; g++) {
        var yy = BASE - g / (DTv.length - 1) * IH;
        o.push('<line x1="' + L + '" y1="' + yy.toFixed(1) + '" x2="' + (W - R) + '" y2="' + yy.toFixed(1) + '" stroke="' + GRID + '"/>');
        o.push('<text x="' + (L - 6) + '" y="' + (yy + 3).toFixed(1) + '" text-anchor="end" class="c-axis" fill="' + MUTE + '">' + esc(DTLv[g]) + "</text>");
        o.push('<text x="' + (W - R + 6) + '" y="' + (yy + 3).toFixed(1) + '" text-anchor="start" class="c-axis" fill="' + MUTE + '">' + esc(DTLv[g]) + "</text>");
      }
    } else {
      for (g = 0; g <= 4; g++) {
        var y2 = T0 + IH * g / 4,
            val = LOG ? Math.pow(10, l10(mx) * (4 - g) / 4) - 1 : mx * (4 - g) / 4;
        if (whole) val = Math.round(val);
        o.push('<line x1="' + L + '" y1="' + y2.toFixed(1) + '" x2="' + (W - R) + '" y2="' + y2.toFixed(1) + '" stroke="' + GRID + '"/>');
        o.push('<text x="' + (L - 6) + '" y="' + (y2 + 4).toFixed(1) + '" text-anchor="end" class="c-axis" fill="' + MUTE + '">' + esc(K.fmt(val)) + "</text>");
        o.push('<text x="' + (W - R + 6) + '" y="' + (y2 + 4).toFixed(1) + '" text-anchor="start" class="c-axis" fill="' + MUTE + '">' + esc(K.fmt(val)) + "</text>");
      }
    }

    // ---- the marks, per style ----------------------------------------------
    // `seen` stacks red -> green -> blue (see seenTop): red at the bottom, green
    // topping out exactly AT orange (red + green === orange), then blue filling
    // the rest up to the union total. Orange is not drawn in the stacked styles —
    // it IS the green/red boundary.
    function seenTop(i, s) {
      var v = slots[i].v;                              // v = [blue, orange, green, red]
      if (s === 0) return v[3];                        // red
      if (s === 1) return v[3] + v[2];                 // + green  === orange
      return v[0];                                     // + (blue - orange) === blue
    }
    // the plain cumulative top for a total-preserving stack kind
    function stackTop(i, s) { var t = 0, v = slots[i].v; for (var q = 0; q <= s; q++) t += v[q]; return t; }
    var seenCol = kind === "seen" ? [K.col[3], K.col[2], K.col[0]] : K.col;
    var seenNS = kind === "seen" ? 3 : ns;

    if (style === "solid") {
      // stacked bands: series s fills from the band below up to its own top
      for (s = 0; s < seenNS; s++) {
        var poly = "";
        for (i = 0; i < n; i++) if (slots[i].has) {
          var top = K.stack ? stackTop(i, s)
                  : kind === "seen" ? seenTop(i, s)
                  : kind === "dur" ? slots[i].v[s]
                  : (kind === "pesit" && s === 1 ? slots[i].v[0] + slots[i].v[1] : slots[i].v[0]);
          poly += pt(slotx(i), ypos(top));
        }
        for (i = n - 1; i >= 0; i--) if (slots[i].has) {
          if (s === 0) poly += pt(slotx(i), BASE);
          else poly += pt(slotx(i), ypos(K.stack ? stackTop(i, s - 1)
                                       : kind === "seen" ? seenTop(i, s - 1)
                                       : kind === "dur" ? slots[i].v[s - 1] : slots[i].v[0]));
        }
        if (poly) o.push('<polygon points="' + poly + '" fill="' + seenCol[s] + '"/>');
      }
      if (ns === 1) {
        var pl1 = "";
        for (i = 0; i < n; i++) if (slots[i].has) pl1 += pt(slotx(i), ypos(slots[i].v[0]));
        if (pl1) o.push('<polyline points="' + pl1 + '" fill="none" stroke="' + K.col[0] + '" stroke-width="2" stroke-linejoin="round"/>');
      }
    } else if (style === "line") {
      // every series as its own absolute line (pesit not stacked; `seen` draws
      // all FOUR — blue, orange, green and red — where the stacked styles fold
      // red and green into the orange they sum to)
      for (s = 0; s < ns; s++) {
        var pl = "", dots = "";
        for (i = 0; i < n; i++) if (slots[i].has) {
          // a stack kind draws each band's cumulative TOP EDGE, so the same
          // composition reads out of all three styles (the top line is the flat
          // total); every other kind draws its series absolutely
          var lv9 = K.stack ? stackTop(i, s) : slots[i].v[s];
          pl += pt(slotx(i), ypos(lv9));
          dots += '<circle cx="' + slotx(i).toFixed(1) + '" cy="' + ypos(lv9).toFixed(1) + '" r="2" fill="' + K.col[s] + '"/>';
        }
        if (pl) o.push('<polyline points="' + pl + '" fill="none" stroke="' + K.col[s] + '" stroke-width="2" stroke-linejoin="round" stroke-linecap="round"/>' + dots);
      }
    } else {
      for (i = 0; i < n; i++) {
        if (!slots[i].has) continue;
        var bx = slotx(i) - bw / 2, v = slots[i].v;
        function bar(y, h, c) { o.push('<rect x="' + bx.toFixed(1) + '" y="' + y.toFixed(1) + '" width="' + bw.toFixed(1) + '" height="' + h.toFixed(1) + '" fill="' + c + '"/>'); }
        if (kind === "dur") {                          // painter layering: P98, P90, P50
          bar(ypos(v[2]), BASE - ypos(v[2]), K.col[2]);
          bar(ypos(v[1]), BASE - ypos(v[1]), K.col[1]);
          bar(ypos(v[0]), BASE - ypos(v[0]), K.col[0]);
        } else if (kind === "pesit") {                 // true stacking
          if (v[0] > 0) bar(ypos(v[0]), BASE - ypos(v[0]), K.col[0]);
          if (v[1] > 0) bar(ypos(v[0] + v[1]), ypos(v[0]) - ypos(v[0] + v[1]), K.col[1]);
        } else if (K.stack) {                          // the same stack as solid
          for (var z9 = 0; z9 < ns; z9++) {
            var lo8 = z9 === 0 ? 0 : stackTop(i, z9 - 1), hi8 = stackTop(i, z9);
            if (hi8 > lo8) bar(ypos(hi8), ypos(lo8) - ypos(hi8), K.col[z9]);
          }
        } else if (kind === "seen") {                  // the same stack as solid
          for (var z = 0; z < 3; z++) {
            var lo9 = z === 0 ? 0 : seenTop(i, z - 1), hi9 = seenTop(i, z);
            if (hi9 > lo9) bar(ypos(hi9), ypos(lo9) - ypos(hi9), seenCol[z]);
          }
        } else if (v[0] > 0 || kind !== "rate") {
          bar(ypos(v[0]), BASE - ypos(v[0]), K.col[0]);
        }
      }
    }

    // hover columns (and the {} day links): one transparent rect per slot
    for (i = 0; i < n; i++) {
      var rx, rw;
      if (style === "bar") { rx = L + i * gw; rw = gw; }
      else {
        rx = n > 1 ? L + i * step - step / 2 : L; if (rx < L) rx = L;
        rw = n > 1 ? step : IW; if (rx + rw > W - R) rw = W - R - rx;
      }
      // ONE data-v attribute carrying every formatted value, "|"-joined —
      // per-letter data-a/-b/-c/-d capped the tooltip at four series, and the
      // UC-status stacks have seven. No fmt() output can contain a "|".
      var da = ' data-l="' + esc(slots[i].lab) + '"';
      if (slots[i].has) {
        var fv = [];
        for (s = 0; s < ns; s++) fv.push(K.fmt(slots[i].v[s]));
        da += ' data-v="' + esc(fv.join("|")) + '"';
      }
      var rect = '<rect class="dbz"' + da + ' x="' + rx.toFixed(1) + '" y="' + T0 + '" width="' + rw.toFixed(1) + '" height="' + (BASE - T0) + '" fill="transparent"/>';
      if (linkpat && slots[i].dt) o.push('<a href="' + esc(linkpat.replace("{}", slots[i].dt)) + '">' + rect + "</a>");
      else o.push(rect);
    }

    // thinned x labels at the regular stride; a midnight tick on the overview
    // reads as its date alone (a day-page label has no space, so it keeps its)
    var every = Math.floor(n / 6) || 1;
    for (i = 0; i < n; i++) if (i % every === 0) {
      var xl = slots[i].lab.replace(/ 00h$/, "");
      o.push('<text x="' + slotx(i).toFixed(1) + '" y="' + (BASE + 16) + '" text-anchor="middle" class="c-axis" fill="' + MUTE + '">' + esc(xl) + "</text>");
    }
    o.push("</svg>");
    return o.join("");
  }

  // ---- the floating tooltip (one per card, delegated so a redraw is free) --
  function bindTip(host) {
    var tip = document.createElement("div");
    tip.className = "dbtip";
    host.parentNode.appendChild(tip);
    host.addEventListener("mousemove", function (e) {
      var r = e.target;
      if (!r || !r.getAttribute || r.getAttribute("class") !== "dbz") { tip.style.display = "none"; return; }
      var K = host._spec, h = "<b>" + esc(r.getAttribute("data-l")) + "</b>";
      if (r.getAttribute("data-v")) {
        var v = r.getAttribute("data-v").split("|");
        for (var s = K.name.length - 1; s >= 0; s--)
          h += '<div class="r"><span><span class="sw" style="background:' + K.col[s] + '"></span><i>' + esc(K.name[s]) + "</i></span><span>" + esc(v[s]) + "</span></div>";
      } else h += '<div class="r"><i>' + esc(K.empty) + "</i></div>";
      tip.innerHTML = h;
      tip.style.display = "block";
      var br = host.parentNode.getBoundingClientRect();
      var px = e.clientX - br.left + 14, py = e.clientY - br.top + 14;
      if (px + tip.offsetWidth > br.width - 8) px = e.clientX - br.left - tip.offsetWidth - 14;
      tip.style.left = px + "px"; tip.style.top = py + "px";
    });
    host.addEventListener("mouseleave", function () { tip.style.display = "none"; });
  }

  function init() {
    var hosts = document.querySelectorAll("div.slotchart");
    if (!hosts.length) return;
    var style = "solid", iv = "";
    // The axis scale is PER KIND (2026-09-03, user request): the "seen" graphs
    // open LINEAR — a cumulative count of entities seen climbs gently and a
    // log axis squashes exactly the growth they are there to show — every
    // other kind opens on log (see draw()). A click on a card's Linear/Log
    // buttons is remembered for that card's kind, so the seen graphs and the
    // volume graphs each keep their own choice.
    function scaleKey(kind) { return SCKEY + ":" + kind; }
    function scaleFor(kind) {
      try {
        var sc = sessionStorage.getItem(scaleKey(kind));
        if (sc === "lin" || sc === "log") return sc;
      } catch (e) {}
      return kind === "seen" ? "lin" : "log";
    }
    // The interval sets of the two page kinds are DISJOINT (the overview counts
    // in hours, a day page in minutes), so each remembers its own pick under a
    // key suffixed with its base — otherwise a visit to the overview would
    // silently reset the day pages, and back.
    var ivkey = IKEY + "-" + (hosts[0].getAttribute("data-base") || "0");
    try {
      var ss = sessionStorage.getItem(SKEY);
      if (ss === "line" || ss === "bar" || ss === "solid") style = ss;
      var si = sessionStorage.getItem(ivkey);
      if (si && /^\d+$/.test(si)) iv = si;
    } catch (e) {}

    var cards = [], h;
    for (var i = 0; i < hosts.length; i++) {
      h = hosts[i];
      h._kind = h.getAttribute("data-kind") || "count";
      h._spec = kindSpec(h._kind);
      h._link = h.getAttribute("data-link") || "";
      h._cid = h.getAttribute("data-cid") || ("ch" + i);
      h._title = h.getAttribute("data-title") || "Chart";
      h._base = h.getAttribute("data-base") || "";
      h._d = {};
      for (var a = 0; a < h.attributes.length; a++) {
        var an = h.attributes[a].name, m = /^data-iv(\d+)$/.exec(an);
        if (m) h._d[m[1]] = h.attributes[a].value;
      }
      h._slots = {};
      cards.push(h);
      bindTip(h);
    }
    // the EFFECTIVE interval of this page: the stored pick when this page kind
    // offers it (the overview counts in hours, a day page in minutes — the two
    // sets are disjoint), else the base. The stored value is left alone, so
    // stepping between the two page kinds restores each one own pick.
    if (!iv || !cards[0]._d[iv]) iv = cards[0]._base;
    // The AUTO interval (2026-08): a From/To change picks the slot size that
    // fits the span — 1 day: 1 hour · ≤3: 2 hours · ≤7: 4 hours · ≤15:
    // 6 hours · ≤30: 12 hours · more: 1 day — so narrowing zooms in and
    // widening (Reset included) zooms out. A manual interval click still
    // overrides, until the next range change. Only an interval this page
    // offers is picked (the day pages have no From/To, so they never enter).
    function autoIv(f, t) {
      if (!f || !t) return "";
      var days = Math.round((Date.parse(t) - Date.parse(f)) / 86400000) + 1;
      var v = days <= 1 ? "60" : days <= 3 ? "120" : days <= 7 ? "240" : days <= 15 ? "360" : days <= 30 ? "720" : "1440";
      return cards[0]._d[v] ? v : "";
    }
    // The From/To range (2026-08): report.js's date filter drives it via the
    // window hook below — each slot carries its date (s.dt), so narrowing is
    // a plain clip of the slot list; the axes, ticks and data table all
    // follow because draw() only ever sees the clipped slots. Charts whose
    // slots carry no date (none today) fall back to the full series.
    var RANGE = (window._slotRange && window._slotRange.narrowed) ? window._slotRange : null;
    // a range restored before this ran (the stash) auto-picks the interval too
    if (RANGE) { var _av0 = autoIv(RANGE.from, RANGE.to); if (_av0) iv = _av0; }
    function clip(sl) {
      if (!RANGE) return sl;
      var out = [], q, dated = false;
      for (q = 0; q < sl.length; q++) {
        if (sl[q].dt) dated = true;
        if (sl[q].dt && sl[q].dt >= RANGE.from && sl[q].dt <= RANGE.to) out.push(sl[q]);
      }
      // a DATED series whose range clips empty stays empty — silently showing
      // the full period under a narrowed title misreads as that range's data
      // (2026-08). Only a series with no dates at all keeps the fallback.
      return (out.length || dated) ? out : sl;
    }
    function render() {
      for (var c = 0; c < cards.length; c++) {
        // a card without the picked resolution (a different page kind, or the
        // day PeSIT card, whose sidecar is 30-minute) draws its own base
        var card = cards[c], use = (iv && card._d[iv]) ? iv : card._base;
        if (!card._slots[use]) card._slots[use] = parse(card._d[use], card._spec.ns);
        var scale = scaleFor(card._kind);
        card.innerHTML = draw(card._kind, style, clip(card._slots[use]), card._link, card._cid + style + use + scale + (RANGE ? RANGE.from + RANGE.to : ""), card._title, scale);
        // the card's OWN Linear/Log row (a sibling inside its chartbox) shows
        // the scale this card drew with — a per-kind choice, not a page-wide one
        var sbar = card.parentNode && card.parentNode.querySelector(".scalebtns");
        if (sbar) mark([sbar], "data-cscale", scale);
      }
      mark(document.querySelectorAll(".stylebtns"), "data-cstyle", style);
      mark(document.querySelectorAll(".ivbtns"), "data-civ", iv);
    }
    function mark(bars, attr, val) {
      for (var b = 0; b < bars.length; b++) {
        var tabs = bars[b].querySelectorAll("[" + attr + "]");
        for (var t = 0; t < tabs.length; t++)
          tabs[t].className = tabs[t].getAttribute(attr) === val ? "tab active" : "tab";
      }
    }
    function bindRow(sel, attr, key, set) {
      var bars = document.querySelectorAll(sel);
      for (var b = 0; b < bars.length; b++) bars[b].addEventListener("click", function (e) {
        var v = e.target && e.target.getAttribute && e.target.getAttribute(attr);
        if (!v) return;
        set(v);
        try { sessionStorage.setItem(key, v); } catch (e2) {}
        render();
      });
    }
    bindRow(".stylebtns", "data-cstyle", SKEY, function (v) { style = v; });
    bindRow(".ivbtns", "data-civ", ivkey, function (v) { iv = v; });
    // the Linear/Log row stores its pick under the CARD'S KIND (see scaleFor)
    var sbars = document.querySelectorAll(".scalebtns");
    for (var sb = 0; sb < sbars.length; sb++) sbars[sb].addEventListener("click", function (e) {
      var v = e.target && e.target.getAttribute && e.target.getAttribute("data-cscale");
      if (!v) return;
      var host = this.parentNode && this.parentNode.querySelector("div.slotchart");
      var k = host ? (host.getAttribute("data-kind") || "count") : "count";
      try { sessionStorage.setItem(scaleKey(k), v); } catch (e2) {}
      render();
    });
    window.slotchartSetRange = function (f, t, narrowed) {
      RANGE = narrowed && f && t ? { from: f, to: t, narrowed: true } : null;
      var av = autoIv(f, t);   // f/t carry the full-range dates on Reset too
      if (av) {
        iv = av;
        try { sessionStorage.setItem(ivkey, av); } catch (e) {}
      }
      render();
    };
    render();
  }

  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", init);
  else init();
})();
