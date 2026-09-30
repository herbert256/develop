#!/usr/bin/env bash
#
# bin/build/linkcheck.sh — every link resolves, every page is reachable.
#
# A static check over the whole published tree: it resolves every internal
# href/src against the filesystem and then walks the link graph from the shared
# home to find pages nothing points at (one tree — one repo = one environment
# since 2026-09-11).
#
# THE TOP BAR IS RUNTIME, and that is the whole difficulty. Since 2026-07 the
# publishes bake only an empty `<div class="topbar" data-b=… data-help=…>`
# and assets/topbar.js renders the real bar
# from docs/assets/topbar-data.js. A naive href scan therefore finds almost no
# navigation at all and calls ~2,600 pages unreachable. This models what
# topbar.js emits, from the page's own attributes:
#   - the errors:"…" and overview:"…" links of topbar-data.js, data-b + the
#     path (the Reports pulldown and its menu hrefs went 2026-09-30)
#   - brand -> data-b + index.html
#   - data-b + dashboards/index.html, search/search.html,
#     search/all-files.html (the Files link, 2026-09-28),
#     transfer/entities/subscription-all.html (the site map icon went 2026-09-30),
#     transfer/duration.html + transfer/waiting-expired.html (the Duration and
#     Waiting/Expired links, 2026-09-30), analyses/partners-in.html (the
#     Partners link, 2026-09-30), transfer/security-params.html,
#     analyses/first-seen.html, analyses/subscriptions.html,
#     analyses/use-cases.html, transfer/file-journey-patterns.html and
#     transfer/activity-per-week.html (Security · Seen · Configuration · Use
#     cases · Patterns · Activity, 2026-09-30 — the pulldown's replacement)
#   - the help icon  -> data-b + help/<data-help>.html
# EVERY page carries the placeholder since 2026-09-30 — the help pages and the
# build report too (their baked bar, render_shared_topbar, went with the one
# topbar.js); a page whose topbar div is NOT empty would be scanned normally.
#
# Entity Search ships its rows as DATA, not markup (split_search_rows lifts them
# into docs/search/search-data.js — the search pages live under docs/search/ since
# 2026-09-12, so the payload links carry a leading ../), so its ~7,500 detail links live in the .js —
# they are read from there and counted as edges from search.html.
#
# EXPECTED-UNREACHABLE (not failures, listed for confirmation):
#   docs/404.html            what GitHub Pages serves for an unmatched URL;
#                            nothing should link it.
#   (the build report is back on the site since 2026-09-12 — docs/tools/build.html,
#   linked from help/general.html since 2026-09-30 — the sitemap Tools card before —
#   so it is REACHABLE, not expected-unreachable)
#
# Exit status: 1 when a link resolves to nothing, else 0. Unreachable pages
# beyond the expected set are reported and also fail the run — a page nothing
# links to is dead weight in the published site.
#
# Usage:  bin/build/linkcheck.sh          # ~1 s over ~3,000 pages
#         bin/build/linkcheck.sh -q       # summary only (no per-item detail)
#
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."

QUIET=0
[ "${1:-}" = "-q" ] && QUIET=1

DOCS="docs"
TB="$DOCS/assets/topbar-data.js"
[ -d "$DOCS" ] || { echo "linkcheck: no $DOCS/ — nothing to check" >&2; exit 1; }
[ -f "$TB" ]   || { echo "linkcheck: $TB missing — the runtime top bar cannot be modelled" >&2; exit 1; }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/axlink.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

# Every file in the tree (docs-relative) — the existence set. Sorted so the
# awk below loads it in a defined order and the report never depends on
# readdir order.
find "$DOCS" -type f | sed "s|^$DOCS/||" | LC_ALL=C sort > "$TMP/files"
find "$DOCS" -name '*.html' | LC_ALL=C sort > "$TMP/pages"
# the page list as an ARRAY — `$(cat …)` would word-split on any IFS character
# in a filename (impossible for today's slugified names, but this was the one
# place the repo expanded a file list that way)
PAGES=()
while IFS= read -r _pg; do PAGES+=("$_pg"); done < "$TMP/pages"

# ARGV order matters: 1 = the file set, 2 = topbar-data.js, 3.. = the pages.
# (ARGIND is a gawk extension — the file index is counted on FNR==1 instead.)
# (bin/date.awk in front: jdn / fromjdn for the chart slot dates, section 2c)
awk -v DOCS="$DOCS" "$(cat bin/date.awk)"'
    function resolve(page, t,   base, full, n, parts, i, sp, stack, out) {
        sub(/[#?].*/, "", t)
        if (t == "") return ""
        if (t ~ /^[a-zA-Z][a-zA-Z0-9+.-]*:/ || t ~ /^\/\//) return ""   # http:, mailto:, //host
        if (t ~ /^\//) return "\001ROOT"                                # site-root link (the 404 fallback)
        base = page
        if (!sub(/\/[^\/]*$/, "", base)) base = ""
        full = (base == "" ? t : base "/" t)
        n = split(full, parts, "/"); sp = 0
        for (i = 1; i <= n; i++) {
            if (parts[i] == "" || parts[i] == ".") continue
            # a ".." that climbs ABOVE docs/ is a broken link on the served site
            # even when the path happens to exist on disk (2026-09-12: the
            # file-search pages loaded ../assets/file-search.js from the site
            # root — the repo-root assets/ made it pass here while the browser
            # got a 404)
            if (parts[i] == "..") { if (sp > 0) sp--; else return "\001ESCAPE"; continue }
            stack[++sp] = parts[i]
        }
        out = ""
        for (i = 1; i <= sp; i++) out = out (i == 1 ? "" : "/") stack[i]
        return out
    }
    function edge(page, raw,   t) {
        t = resolve(page, raw)
        if (t == "") { next_ext++; return }
        if (t == "\001ROOT") { rootlink[page]++; return }
        if (t == "\001ESCAPE") { t = "(above the site root) " raw }   # counted as broken below
        if (t in FILE) { E[page, ++EN[page]] = t }
        else           { if (!(t in BRKN)) BRKEX[t] = page "\t" raw   # keep the FIRST sighting as the example
                         BRKN[t]++ }
    }

    FNR == 1 { nfile++ }
    nfile == 1 { FILE[$0] = 1; next }
    nfile == 2 {                                   # topbar-data.js: the data links
        # the top-bar LINKS kept as data (2026-09-29): errors:"…" and
        # overview:"…", docs-root-relative — "@" + the path
        s = $0
        while (match(s, /(errors|overview):"[^"]+"/)) {
            h = substr(s, RSTART, RLENGTH); sub(/^[a-z]+:"/, "", h); sub(/"$/, "", h)
            MENU[++MENUN] = "@" h
            s = substr(s, RSTART + RLENGTH)
        }
        next
    }
    {                                              # a page: accumulate its text
        page = FILENAME; sub("^" DOCS "/", "", page)
        PG[page] = PG[page] $0 "\n"
    }
    END {
        for (page in PG) {
            txt = PG[page]
            # 1. the static href/src links
            s = txt
            while (match(s, /(href|src)="[^"]*"/)) {
                h = substr(s, RSTART, RLENGTH); sub(/^[a-z]+="/, "", h); sub(/"$/, "", h)
                edge(page, h)
                s = substr(s, RSTART + RLENGTH)
            }
            # 2. the RUNTIME top bar, only when the div is an empty placeholder
            if (match(txt, /<div class="topbar"[^>]*>/)) {
                d = substr(txt, RSTART, RLENGTH)
                rest = substr(txt, RSTART + RLENGTH)
                sub(/^[ \t\r\n]+/, "", rest)
                if (index(rest, "</div>") == 1) {
                    b = attr(d, "data-b"); hlp = attr(d, "data-help")
                    for (i = 1; i <= MENUN; i++) { h = MENU[i]; gsub(/@/, b, h); edge(page, h) }
                    edge(page, b "index.html")
                    edge(page, b "dashboards/index.html")
                    edge(page, b "search/search.html")
                    edge(page, b "search/all-files.html")   # the Files link (2026-09-28)
                    edge(page, b "transfer/entities/subscription-all.html")
                    edge(page, b "transfer/duration.html")          # the Duration link (2026-09-30)
                    edge(page, b "transfer/waiting-expired.html")   # the Waiting/Expired link (2026-09-30)
                    edge(page, b "analyses/partners-in.html")      # the Partners link (2026-09-30)
                    # the six links that replaced the Reports pulldown (2026-09-30)
                    edge(page, b "transfer/security-params.html")
                    edge(page, b "analyses/first-seen.html")
                    edge(page, b "analyses/subscriptions.html")
                    edge(page, b "analyses/use-cases.html")
                    edge(page, b "transfer/file-journey-patterns.html")
                    edge(page, b "transfer/activity-per-week.html")
                    if (hlp != "") edge(page, b "help/" hlp ".html")
                }
            }
            # 2b. THE DRILL LINKS: report.js bindDrill links every drill entry
            # whose File the row names in data-fp to files/<coreid>.html
            # (data-b + the path; render_rpt lists the Files of the ROW
            # shipped File lists that are in the published set,
            # bin/transfer/filepages.sh), so every data-fp CoreId is a STRICT
            # edge: a missing page is a broken link.
            if (index(txt, "data-fp=\"") > 0) {
                b9 = match(txt, /<div class="topbar"[^>]*>/) ? attr(substr(txt, RSTART, RLENGTH), "data-b") : ""
                s = txt
                while (match(s, /data-fp="[^"]*"/)) {
                    a9 = substr(s, RSTART + 9, RLENGTH - 10); s = substr(s, RSTART + RLENGTH)
                    n9 = split(a9, F9, " ")
                    for (i9 = 1; i9 <= n9; i9++) if (F9[i9] != "") edge(page, b9 "files/" F9[i9] ".html")
                }
            }
            # 2c. THE CHART LINKS (2026-09-30 audit A6-08): assets/slotchart.js
            # links EVERY slot of a chart to its data-link, "{}" = the slot
            # DATE — data or not — so every slot date of every series
            # (data-iv<N>) is a STRICT edge: a date with no day page is a
            # broken link. A data-link without "{}" is a plain edge.
            if (index(txt, "data-link=\"") > 0) {
                s = txt
                while (match(s, /<div class="slotchart"[^>]*>/)) {
                    tag = substr(s, RSTART, RLENGTH); s = substr(s, RSTART + RLENGTH)
                    lp = attr(tag, "data-link"); if (lp == "") continue
                    if (index(lp, "{}") == 0) { edge(page, lp); continue }
                    split("", CD); ncd = 0; t2 = tag
                    while (match(t2, /data-iv[0-9]+="[^"]*"/)) {
                        a9 = substr(t2, RSTART, RLENGTH); t2 = substr(t2, RSTART + RLENGTH)
                        iv9 = substr(a9, 8); sub(/=.*/, "", iv9)
                        v9 = a9; sub(/^[^"]*"/, "", v9); sub(/"$/, "", v9)
                        chart_dates(v9, iv9 + 0)
                    }
                    # in date order (the first-sighting example never rests on
                    # awk hash order)
                    for (i9 = 2; i9 <= ncd; i9++) { v = CDL[i9]; j9 = i9 - 1; while (j9 >= 1 && CDL[j9] > v) { CDL[j9 + 1] = CDL[j9]; j9-- } CDL[j9 + 1] = v }
                    for (i9 = 1; i9 <= ncd; i9++) { h9 = lp; sub(/\{\}/, CDL[i9], h9); edge(page, h9) }
                }
            }
        }
        # 3. Entity Search: its rows live in search/search-data.js, not in the
        # page (the payload maps to search/search.html; its links carry ../,
        # one level up)
        for (f in FILE) if (f ~ /^[a-z]+\/search-data\.js$/) {
            src = f; sub(/-data\.js$/, ".html", src)
            while ((getline l < (DOCS "/" f)) > 0) {
                s = l
                while (match(s, /href="[^"]*"/)) {
                    h = substr(s, RSTART + 6, RLENGTH - 7)
                    edge(src, h)
                    s = substr(s, RSTART + RLENGTH)
                }
            }
            close(DOCS "/" f)
        }
        # 3a. THE ENTITIES ROW PAYLOAD (2026-09-30): the Entities views ship
        # the data-fp lists of their rows in transfer/entities/<entity>-data.js
        # (report.js attachEntityPayload puts them back on the rows, and
        # bindDrill links them like 2b) — strict edges of the entity All
        # view, whose data-b is ../../
        for (f in FILE) if (f ~ /^transfer\/entities\/[a-z-]+-data\.js$/) {
            src = f; sub(/-data\.js$/, "-all.html", src)
            while ((getline l < (DOCS "/" f)) > 0) {
                s = l
                while (match(s, /data-fp="[^"]*"/)) {
                    a9 = substr(s, RSTART + 9, RLENGTH - 10); s = substr(s, RSTART + RLENGTH)
                    n9 = split(a9, F9, " ")
                    for (i9 = 1; i9 <= n9; i9++) if (F9[i9] != "") edge(src, "../../files/" F9[i9] ".html")
                }
            }
            close(DOCS "/" f)
        }
        # 3b. THE ALL FILES SEARCH (2026-09-27): search/all/index.js (the
        # subscription -> detail slug dictionary) and the day shards
        # search/all/d-<date>.js, whose links assets/all-files-search.js
        # DERIVES — a row with an UPPERCASE flag (its 6th field) opens
        # files/<coreid>.html (the 32-hex 5th field, dashes re-inserted), any
        # other row its subscription page. All are edges of the page.
        # (A shard line may carry the template-literal quote marks around it;
        # the flag test reads only its first character.)
        if ("search/all/index.js" in FILE) {
            src = "search/all-files.html"; sect = ""; hd = "window.AXWAY_AFX={v:1,subs:`"
            while ((getline l < (DOCS "/search/all/index.js")) > 0) {
                if (index(l, hd) == 1) { sect = "S"; l = substr(l, length(hd) + 1) }
                if (sect != "S") continue
                e9 = index(l, "`,days:`"); if (e9 > 0) { l = substr(l, 1, e9 - 1); sect = "" }
                n2 = split(l, a2, "\t")
                if (n2 >= 2 && a2[2] != "") edge(src, "../details/subscriptions/" a2[2] ".html")
            }
            close(DOCS "/search/all/index.js")
            for (f in FILE) if (f ~ /^search\/all\/d-[0-9-]+\.js$/) {
                while ((getline l < (DOCS "/" f)) > 0) {
                    n2 = split(l, a2, "\t")
                    if (n2 >= 6 && a2[6] ~ /^[DOEWX]/ && a2[5] ~ /^[0-9a-f]+$/ && length(a2[5]) == 32)
                        edge(src, "../files/" substr(a2[5], 1, 8) "-" substr(a2[5], 9, 4) "-" substr(a2[5], 13, 4) "-" substr(a2[5], 17, 4) "-" substr(a2[5], 21, 12) ".html")
                }
                close(DOCS "/" f)
            }
        }
        # 4. reachability: breadth-first from the shared home
        q[1] = "index.html"; SEEN["index.html"] = 1; head = 1; tail = 1
        while (head <= tail) {
            p = q[head++]
            for (k = 1; k <= EN[p]; k++) { t = E[p, k]; if (!(t in SEEN)) { SEEN[t] = 1; q[++tail] = t } }
        }
        nedge = 0; for (p in EN) nedge += EN[p]
        npage = 0; for (f in FILE) if (f ~ /\.html$/) { npage++; if (!(f in SEEN)) print "UNREACH\t" f }
        for (t in BRKN) print "BROKEN\t" t "\t" BRKN[t] "\t" BRKEX[t]
        print "STAT\tpages\t" npage
        print "STAT\tedges\t" nedge
        nrl = 0; for (rl in rootlink) nrl++   # POSIX awk: length(array) is a gawk/mawk extension
        print "STAT\troot\t" nrl
    }
    # the slot dates of ONE chart series into CD / CDL (ncd), the rule of
    # assets/slotchart.js expandSeries + parse: a compact series
    # "=S<YYYY-MM-DD>T<HHMM>~<o|d|m>|v|v…" steps iv minutes per slot from its
    # start; the plain form "label:v…:date|…" names each slot date last
    function chart_dates(v, iv,   n, seg, i, h, j0, m0, mm, p, P, dd) {
        n = split(v, seg, "|")
        h = seg[1]
        if (substr(h, 1, 2) == "=S") {
            if (iv <= 0 || h !~ /^=S[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9][0-9][0-9]~[odm]$/) return
            j0 = jdn(substr(h, 3, 4) + 0, substr(h, 8, 2) + 0, substr(h, 11, 2) + 0)
            m0 = substr(h, 14, 2) * 60 + substr(h, 16, 2)
            for (i = 2; i <= n; i++) { mm = m0 + (i - 2) * iv; dd = fromjdn(j0 + int(mm / 1440))
                if (!(dd in CD)) { CD[dd] = 1; CDL[++ncd] = dd } }
            return
        }
        for (i = 1; i <= n; i++) { p = split(seg[i], P, ":"); dd = P[p]
            if (dd ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$/ && !(dd in CD)) { CD[dd] = 1; CDL[++ncd] = dd } }
    }
    function attr(d, name,   m, v) {
        if (!match(d, name "=\"[^\"]*\"")) return ""
        v = substr(d, RSTART, RLENGTH)
        sub("^" name "=\"", "", v); sub(/"$/, "", v)
        return v
    }
' "$TMP/files" "$TB" ${PAGES[@]+"${PAGES[@]}"} > "$TMP/out"

LC_ALL=C sort "$TMP/out" > "$TMP/sorted"
pages=$(awk -F'\t' '$1=="STAT" && $2=="pages"{print $3}' "$TMP/sorted")
edges=$(awk -F'\t' '$1=="STAT" && $2=="edges"{print $3}' "$TMP/sorted")
nroot=$(awk -F'\t' '$1=="STAT" && $2=="root"{print $3}' "$TMP/sorted")
nbroken=$(awk -F'\t' '$1=="BROKEN"' "$TMP/sorted" | wc -l | tr -d ' ')

# The expected-unreachable set (see the header): the root 404 and
# hand-authored help/ pages — a help page is
# linked only from its report family's pages, so a family with no pages
# this build (a config-only estate: no day pages, no incoming-connection
# details) legitimately orphans its docs. The dangerous direction — a help
# SLUG with no file — is still a broken link and still fails the run; the
# orphan direction is listed informationally below. Anything else is a
# finding.
awk -F'\t' '$1=="UNREACH"{print $2}' "$TMP/sorted" \
  | grep -vxE '404\.html|help/[A-Za-z0-9_.-]+\.html' > "$TMP/orphans" || :
norph=$(wc -l < "$TMP/orphans" | tr -d ' ')
nexp=$(awk -F'\t' '$1=="UNREACH"' "$TMP/sorted" | wc -l | tr -d ' ')

printf 'linkcheck: %s pages, %s internal links, %s broken, %s unreachable (%s expected)\n' \
       "$pages" "$edges" "$nbroken" "$norph" "$((nexp - norph))"
[ "$nroot" -gt 0 ] && printf 'linkcheck: %s site-root href="/" link(s) — the 404 fallback, rewritten by its inline script\n' "$nroot"

if [ "$QUIET" = 0 ] && [ "$nbroken" -gt 0 ]; then
    echo "--- broken links ---"
    awk -F'\t' '$1=="BROKEN"{ printf "  %-56s %s link(s), e.g. %s -> %s\n", $2, $3, $4, $5 }' "$TMP/sorted"
fi
if [ "$QUIET" = 0 ] && [ "$norph" -gt 0 ]; then
    echo "--- unreachable pages ---"
    sed 's|^|  |' "$TMP/orphans"
fi
nhelp=$(awk -F'\t' '$1=="UNREACH" && $2 ~ /^help\//' "$TMP/sorted" | wc -l | tr -d ' ')
if [ "$QUIET" = 0 ] && [ "$nhelp" -gt 0 ]; then
    echo "--- unreachable help pages (informational: their report family has no pages this build) ---"
    awk -F'\t' '$1=="UNREACH" && $2 ~ /^help\// { print "  " $2 }' "$TMP/sorted"
fi

[ "$nbroken" -eq 0 ] && [ "$norph" -eq 0 ]
