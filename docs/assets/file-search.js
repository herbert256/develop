/* file-search.js — the dedicated engine of the six FILE SEARCH pages
   (file-search-<window>.html — ONE page per window since 2026-08, the
   Errors/OK pair is gone; every result row tints green (OK) or red (Error)).
   ------------------------------------------------------------------------
   Deliberately NOT report.js's shared esearch: these pages search ONLY on
   the Search button (or Enter) — no per-keystroke filtering — over their own
   per-page COMPACT payload (file-search-<key>-data.js, v5, written by
   bin/analyses/reports/file-search.sh):

     window.AXWAY_FSEARCH_D  the date dictionary, one date per line
     window.AXWAY_FSEARCH_S  the subscription dictionary, "NAME \t slug"
                             per line (slug empty = no detail link)
     window.AXWAY_FSEARCH_R  one File per line, dictionary indices for the
                             date and subscription, tm = HH:MM:SS shown
                             beside the date:
         name \t di \t si \t tm \t bytes \t coreid \t flag
     (flag: "" = OK, "e" = Error, "E" = Error with its own error page)

   The engine renders ONLY the matches (DOM-built, auto-escaped), at most
   500, newest first (the payload order). Only the six pages load this
   script; report.js still runs for the chrome but keeps its hands off the
   table (restint + nosort + nosearch + nofilter, and the table ships empty
   — each rendered row carries data-res=green|red, the restint tint).

   Behaviour:
   - builds the controls row (input + Search button + count) above the table;
   - matching is on the FILE NAME and the CoreId, case-insensitive; `*` = any run,
     `?` = one character, several space-separated words must ALL match;
   - an ERROR row with its own error page (flag E): every cell and the whole
     row open errors/<coreid>.html; every other row follows its
     Subscription cell's detail-page link;
   - after every search the NAV row's sibling links (file-search-*.html) get
     ?q=<query> appended and the page's own URL is kept in sync
     (history.replaceState), so switching windows re-runs the search there
     and a reload repeats it;
   - on load a ?q=… parameter fills the box and searches immediately. */
(function () {
  "use strict";

  var SHOW = 500;   // matches rendered at most; the count line says the truth

  function splitLines(s) {
    if (typeof s !== "string") return [];
    var a = s.split("\n"), out = [], i;
    for (i = 0; i < a.length; i++) if (a[i] !== "") out.push(a[i]);
    return out;
  }

  function humanBytes(b) {                      // the site's humanbytes format
    b = +b;
    if (b < 1024) return b + " B";
    if (b < 1048576) return (b / 1024).toFixed(2) + " KB";
    if (b < 1073741824) return (b / 1048576).toFixed(2) + " MB";
    return (b / 1073741824).toFixed(2) + " GB";
  }

  function init() {
    var R = window.AXWAY_FSEARCH_R;
    if (typeof R !== "string") return;                             // not a file-search page
    var page = location.pathname.split("/").pop();
    var m9 = /^file-search-([a-z0-9-]+)\.html$/.exec(page);
    if (!m9) return;
    var table = document.querySelector(".tablewrap table");
    if (!table || !table.rows.length) return;

    var dates = splitLines(window.AXWAY_FSEARCH_D);
    var subsRaw = splitLines(window.AXWAY_FSEARCH_S), subs = [], i, p;
    for (i = 0; i < subsRaw.length; i++) {
      p = subsRaw[i].indexOf("\t");
      subs.push(p < 0 ? [subsRaw[i], ""] : [subsRaw[i].slice(0, p), subsRaw[i].slice(p + 1)]);
    }
    var rows = splitLines(R);
    var keys = new Array(rows.length);          // the lower-cased name per row
    var kcore = new Array(rows.length);         // the lower-cased CoreId per row
    for (i = 0; i < rows.length; i++) {
      p = rows[i].indexOf("\t");
      keys[i] = (p < 0 ? rows[i] : rows[i].slice(0, p)).toLowerCase();
      // the CoreId is the second-to-last field (the trailing flag may be "")
      p = rows[i].lastIndexOf("\t");
      kcore[i] = p < 0 ? "" : rows[i].slice(rows[i].lastIndexOf("\t", p - 1) + 1, p).toLowerCase();
    }

    // ---- the controls row, above the table wrap -------------------------
    var wrap = table.closest ? table.closest(".tablewrap") : table.parentNode;
    var bar = document.createElement("div");
    bar.className = "controls";
    var box = document.createElement("input");
    box.type = "text"; box.className = "search";
    box.placeholder = "Search by file name or CoreId…";
    box.title = "Wildcards: ? = one character, * = any run; several space-separated words must all match";
    var btn = document.createElement("button");
    btn.type = "button"; btn.className = "daterange"; btn.textContent = "Search";
    var count = document.createElement("span");
    count.className = "searchhint";
    var idle = rows.length + " files searchable — type a file name or CoreId and press Search";
    count.textContent = idle;
    bar.appendChild(box); bar.appendChild(btn); bar.appendChild(count);
    wrap.parentNode.insertBefore(bar, wrap);

    // with NO data rows (no search yet, or no matches) the empty table
    // header and the explanatory note(s) under it stay hidden — the intro
    // and the count line say everything there is to say (2026-08)
    var notes = document.querySelectorAll("p.note");   // direct body children on these pages
    function showData(on) {
      wrap.style.display = on ? "" : "none";
      for (var n = 0; n < notes.length; n++) notes[n].style.display = on ? "" : "none";
    }
    showData(false);

    // ---- one row line -> a <tr>, per page kind --------------------------
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
    function render(line) {
      // name di si tm bytes coreid flag  (flag "" OK, "e" Error, "E" Error + page)
      var f = line.split("\t"), tr = document.createElement("tr");
      var nm = f[0], dt = dates[+f[1]] || "", sb = subs[+f[2]] || ["", ""];
      if (f[3]) dt = dt + " " + f[3];   // the row's own time beside the date
      var dlink = sb[1] ? "details/subscriptions/" + sb[1] + ".html" : "";
      var err = f[6] === "e" || f[6] === "E";
      tr.setAttribute("data-res", err ? "red" : "green");   // the restint tint
      if (f[6] === "E") {               // error WITH its own page: the whole row opens it
        var eh = "errors/" + f[5] + ".html";
        tr.setAttribute("data-href", eh);
        cell(tr, "file cl", nm, eh);
        cell(tr, "cl", dt, eh);
        cell(tr, "cl", sb[0], eh);
        cell(tr, "num cl", humanBytes(f[4]), eh);
        cell(tr, "mono cl", f[5], eh, true);
      } else {                          // OK, or an error without a page: follow the subscription
        cell(tr, "file", nm, "");
        cell(tr, "", dt, "");
        cell(tr, dlink ? "cl" : "", sb[0], dlink);
        cell(tr, "num", humanBytes(f[4]), "");
        cell(tr, "mono", f[5], "", true);
      }
      return tr;
    }

    // ---- one term -> a matcher (substring, or a glob when * / ? appear) --
    function matcher(term) {
      if (!/[*?]/.test(term)) return function (k) { return k.indexOf(term) !== -1; };
      var re = new RegExp(term.replace(/[.+^${}()|[\]\\]/g, "\\$&")
                              .replace(/\*/g, "[\\s\\S]*").replace(/\?/g, "[\\s\\S]"));
      return function (k) { return re.test(k); };
    }

    var navs = [];   // the sibling window links
    var all = document.querySelectorAll("p.tabs a.tab");
    for (i = 0; i < all.length; i++)
      if (/file-search-[a-z0-9-]+\.html/.test(all[i].getAttribute("href") || "")) navs.push(all[i]);

    function carry(q) {
      var tail = q === "" ? "" : "?q=" + encodeURIComponent(q);
      for (var n = 0; n < navs.length; n++) {
        var base = (navs[n].getAttribute("href") || "").replace(/[?#].*$/, "");
        navs[n].setAttribute("href", base + tail);
      }
      try {
        history.replaceState(null, "", location.pathname + tail);
      } catch (e) {}
    }

    function run() {
      var q = box.value.trim().toLowerCase();
      carry(box.value.trim());
      // keep the header row, drop the rest
      while (table.rows.length > 1) table.deleteRow(1);
      if (q === "") { count.textContent = idle; showData(false); return; }
      var terms = q.split(/\s+/), ms = [], t;
      for (t = 0; t < terms.length; t++) ms.push(matcher(terms[t]));
      var frag = document.createDocumentFragment(), shown = 0, total = 0, r, ok;
      for (r = 0; r < rows.length; r++) {
        ok = true;
        // a term matches on the file NAME or the CoreId; all terms must match
        for (t = 0; t < ms.length && ok; t++) ok = ms[t](keys[r]) || ms[t](kcore[r]);
        if (!ok) continue;
        total++;
        if (shown < SHOW) {
          var tr = render(rows[r]);
          if (tr.getAttribute("data-href") || tr.getElementsByTagName("a").length)
            tr.className = "rowlink";
          frag.appendChild(tr); shown++;
        }
      }
      table.tBodies[0].appendChild(frag);
      showData(shown > 0);
      count.textContent = total === 0 ? "no matches"
        : total > shown ? total + " matches — showing the newest " + shown
        : total + (total === 1 ? " match" : " matches");
    }

    btn.addEventListener("click", run);
    box.addEventListener("keydown", function (e) { if (e.key === "Enter") run(); });

    // WHOLE-ROW links. An error row with its own page carries data-href; every
    // other row follows its FIRST link — the Subscription cell's detail-page
    // anchor (a subscription the slugmap does not know has no link and its
    // row stays inert). The click is DELEGATED (rows are inserted after
    // load); a real link still wins.
    table.addEventListener("click", function (e) {
      var el = e.target, tr = null;
      while (el && el !== table) {
        if (el.tagName === "A") return;
        if (el.tagName === "TR") { tr = el; break; }
        el = el.parentNode;
      }
      if (!tr) return;
      var h = tr.getAttribute("data-href");
      if (!h) {
        var a0 = tr.getElementsByTagName("a")[0];
        if (a0) h = a0.getAttribute("href");
      }
      if (h) location.href = h;
    });

    // ?q=… (a sibling page's carry, or a reload): fill and search now
    var qm = /[?&]q=([^&]*)/.exec(location.search), q0 = "";
    if (qm) { try { q0 = decodeURIComponent(qm[1].replace(/\+/g, " ")); } catch (e) { q0 = qm[1]; } }
    if (q0 !== "") { box.value = q0; run(); }
    box.focus();
  }

  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", init);
  else init();
}());
