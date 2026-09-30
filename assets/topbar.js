/* topbar.js — THE top bar of every page (2026-09-30, the lean round: the ONE
 * implementation — report.js buildTopbar + publish_lib.sh render_topbar, the
 * baked twin the help pages and the build report carried, and the inline
 * AXWAY_ENVLINKS / fit scripts are gone).
 * Every page bakes only a placeholder `<div class="topbar" data-b=…
 * [data-help=…]></div>` and loads, in this order, assets/topbar-data.js
 * (window.AXWAY_TB — the data: the Errors / Overview hrefs (the Reports
 * menu string went 2026-09-30 with the pulldown), the CoreId URL
 * template, the environment label + key and the four site URLs of the
 * environment switch (the data period went 2026-09-30, user request); written by publish_lib ensure_assets) and
 * this file, before report.js — so the bar exists before report.js runs.
 * data-b = the page's prefix back to the docs root, data-help = its help
 * slug. No framework, ES5. */
(function () {
  "use strict";

  function esc(s) { return String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;"); }

  // THE ENVIRONMENT SWITCH (2026-09-12, user request): on a RUNTIME checkout
  // (envkey acceptance|production) the other environment's link is the SAME
  // PAGE on the other site, whose host differs per viewer — computed here,
  // never baked: on localhost the local checkouts, anywhere else the GitHub
  // Pages sites (M.sites = publish_lib ENV_SITES_JS). The other site answers
  // a missing page with its own 404. FROM THE FILE SYSTEM (file:, 2026-09-14,
  // user request) there is no other site: the other link and the separator
  // are REMOVED, leaving the active home link alone.
  function envLinks(M) {
    var i, a, b, r, p, F, A, S, L, h;
    if (location.protocol === "file:") {
      F = document.querySelectorAll(".envpair a[data-envto],.envpair .envsep");
      for (i = 0; i < F.length; i++) F[i].parentNode.removeChild(F[i]);
      return;
    }
    S = M.sites || {}; h = location.hostname;
    L = (h === "localhost" || h === "127.0.0.1") ? (S.local || {}) : (S.remote || {});
    A = document.querySelectorAll("a[data-envto]");
    for (i = 0; i < A.length; i++) {
      a = A[i]; b = L[a.getAttribute("data-envto")];
      if (!b) continue;
      r = new URL(a.getAttribute("data-root") || "./", location.href).pathname;
      p = location.pathname.indexOf(r) === 0 ? location.pathname.slice(r.length) : "";
      a.href = b + p + location.search + location.hash;
    }
  }

  // The bar, evenly-spaced parts (style.css: justify-content space-between):
  // 1 the brand — its TEXT is the environment label (input/environment.txt;
  // "Axway ST" without one), or on a runtime checkout the pair "Acceptance /
  // Production", the active one bold and yellow (.envcur) linking the home
  // page · 2 Overview · Errors · Duration · Partners · Waiting/Expired ·
  // Security · Seen · Configuration · Use cases · Patterns · Activity ·
  // Entities · Files + the search icon (ONE cluster, 2026-09-29; since
  // 2026-09-30, user request, Errors right after Overview, Duration ->
  // transfer/duration.html and Waiting/Expired -> transfer/waiting-expired.html
  // added, the data period between the brand and the cluster gone; later that
  // day the pair "Partners: In / Out", since the evening just "Partners" ->
  // analyses/partners-in.html (Partners Out through its group row), fixed paths
  // like Duration, right after Duration since the night; the six links after
  // Waiting/Expired replaced the Reports pulldown the same night) · 3 the
  // Dashboard link · 4 the help icon (the site map icon went 2026-09-30 with
  // the site map; Logons, after Partners, went again with its reports).
  function buildTopbar() {
    var tb = document.querySelector("div.topbar");
    if (!tb || tb.firstChild) return;
    var M = window.AXWAY_TB || {};
    var b = tb.getAttribute("data-b") || "";
    var help = tb.getAttribute("data-help") || "";
    var brand = (typeof M.env === "string" && M.env) ? M.env : "Axway ST";
    var brandHtml, keys = ["acceptance", "production"], ki, kk, pair = "";
    if (M.envkey === "acceptance" || M.envkey === "production") {
      for (ki = 0; ki < keys.length; ki++) {
        kk = keys[ki];
        if (pair) pair += '<span class="envsep">/</span>';
        pair += (kk === M.envkey)
          ? '<a class="envlink envcur" href="' + b + 'index.html">' + kk.charAt(0).toUpperCase() + kk.slice(1) + "</a>"
          : '<a class="envlink" data-envto="' + kk + '" data-root="' + esc(b) + '" href="#">' + kk.charAt(0).toUpperCase() + kk.slice(1) + "</a>";
      }
      brandHtml = '<span class="brand envpair">' + pair + "</span>";
    } else brandHtml = '<a class="brand" href="' + b + 'index.html">' + esc(brand) + "</a>";
    tb.innerHTML =
      brandHtml +
      '<span class="entgroup">' +
      (M.overview ? '<a class="entlabel" href="' + b + esc(M.overview) + '">Overview</a>' : "") +
      (M.errors ? '<a class="entlabel" href="' + b + esc(M.errors) + '">Errors</a>' : "") +
      '<a class="entlabel" href="' + b + 'transfer/duration.html">Duration</a>' +
      '<a class="entlabel" href="' + b + 'analyses/partners-in.html">Partners</a>' +
      '<a class="entlabel" href="' + b + 'transfer/waiting-expired.html">Waiting/Expired</a>' +
      // (2026-09-30, user request, with the Reports pulldown gone: the
      // groups it opened, as fixed paths right after Waiting/Expired)
      '<a class="entlabel" href="' + b + 'transfer/security-params.html">Security</a>' +
      '<a class="entlabel" href="' + b + 'analyses/first-seen.html">Seen</a>' +
      '<a class="entlabel" href="' + b + 'analyses/subscriptions.html">Configuration</a>' +
      '<a class="entlabel" href="' + b + 'analyses/use-cases.html">Use cases</a>' +
      '<a class="entlabel" href="' + b + 'transfer/file-journey-patterns.html">Patterns</a>' +
      '<a class="entlabel" href="' + b + 'transfer/activity-per-week.html">Activity</a>' +
      '<a class="entlabel" href="' + b + 'transfer/entities/subscription-all.html">Entities</a>' +
      '<a class="entlabel" href="' + b + 'search/all-files.html">Files</a>' +
      '<a class="searchbtn" href="' + b + 'search/search.html" title="Search" aria-label="Search">🔍</a></span>' +
      '<a class="dashlink" href="' + b + 'dashboards/index.html">Dashboard</a>' +
      '<span class="tr-group">' +
      (help ? '<a class="helpbtn" href="' + b + "help/" + help + '.html" title="Help" aria-label="Help">?</a>' : "") +
      "</span>";
    envLinks(M);
  }

  // A narrow window WRAPS the fixed bar onto a second line, and the body's
  // fixed top padding (one line) then hid the page title behind it
  // (2026-09-29): the padding follows the bar's real height instead.
  function fitTopbar() {
    var bar = document.querySelector(".topbar"); if (!bar || !document.body) return;
    var h = bar.offsetHeight;
    document.body.style.paddingTop = h > 48 ? (h + 12) + "px" : "";
  }
  var fitPending = false;
  window.addEventListener("resize", function () {
    if (fitPending) return; fitPending = true;
    (window.requestAnimationFrame || setTimeout)(function () { fitPending = false; fitTopbar(); });
  });

  function run() { buildTopbar(); fitTopbar(); }
  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", run);
  else run();
}());
