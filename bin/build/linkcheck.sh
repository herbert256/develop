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
# and report.js's buildTopbar renders the real bar
# from docs/assets/topbar-data.js. A naive href scan therefore finds almost no
# navigation at all and calls ~2,600 pages unreachable. This models what
# buildTopbar emits, from the page's own attributes:
#   - every menu href in topbar-data.js, its "@" placeholder replaced by data-b
#   - brand -> data-b + index.html
#   - data-b + dashboards/index.html, tools/report-finder.html, search/search.html,
#     search/all-files.html (the Files link, 2026-09-28),
#     tools/sitemap.html, transfer/entities/subscription-all.html
#   - the help icon  -> data-b + help/<data-help>.html
# A page whose topbar div is NOT empty has a baked bar (help pages, the build
# report — render_shared_topbar) and is scanned normally.
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
#   linked from the sitemap Tools card, so it is REACHABLE, not expected-unreachable)
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
awk -v DOCS="$DOCS" '
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
    nfile == 2 {                                   # topbar-data.js: the menu hrefs
        s = $0
        while (match(s, /href=\\"[^"\\]+\\"/)) {
            h = substr(s, RSTART + 7, RLENGTH - 9)
            MENU[++MENUN] = h
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
                    edge(page, b "tools/report-finder.html")
                    edge(page, b "search/search.html")
                    edge(page, b "search/all-files.html")   # the Files link (2026-09-28)
                    edge(page, b "tools/sitemap.html")
                    edge(page, b "transfer/entities/subscription-all.html")
                    if (hlp != "") edge(page, b "help/" hlp ".html")
                }
            }
            # 2b. THE DRILL LINKS (2026-09-21): report.js bindDrill links the
            # FIRST File of a red / orange drill cell to files/<coreid>.html
            # (data-b + the path). The Error / Retry / Resubmit lists always
            # open under such a cell — a STRICT edge, a missing page is a
            # broken link. The per-column lists (drillcols keys, the Duration
            # drill-cell-N) are red / orange only per cell, which the markup
            # scan here cannot tell — those get the edge when the page exists
            # (reachability), and the list check after this pass holds every
            # File bin/build/drill-files.sh listed against the tree. Scanned PER
            # TABLE: a table whose data-drill-unit is not the File (the
            # drill=transfer leg tables) lists TRANSFER ids — no links there.
            if (index(txt, "data-coreids-") > 0 || index(txt, "data-drill-cell-") > 0) {
                b9 = match(txt, /<div class="topbar"[^>]*>/) ? attr(substr(txt, RSTART, RLENGTH), "data-b") : ""
                nt9 = split(txt, T9, "<table")
                for (ti9 = 2; ti9 <= nt9; ti9++) {
                s = T9[ti9]; tg9 = substr(s, 1, index(s, ">"))
                u9 = attr(tg9, "data-drill-unit"); if (u9 != "" && u9 != "File") continue
                while (match(s, /data-(coreids-[a-z0-9]+|drill-cell-[0-9]+)="[^"]*"/)) {
                    a9 = substr(s, RSTART, RLENGTH); s = substr(s, RSTART + RLENGTH)
                    k9 = a9; sub(/=.*/, "", k9)
                    if (k9 == "data-coreids-processed") continue
                    if (!match(a9, /[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]-[0-9a-f][0-9a-f][0-9a-f][0-9a-f]-[0-9a-f][0-9a-f][0-9a-f][0-9a-f]-[0-9a-f][0-9a-f][0-9a-f][0-9a-f]-[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]/)) continue
                    h9 = b9 "files/" substr(a9, RSTART, RLENGTH) ".html"
                    if (k9 == "data-coreids-failed" || k9 == "data-coreids-retry" || k9 == "data-coreids-resubmit") edge(page, h9)
                    else if (resolve(page, h9) in FILE) edge(page, h9)
                }
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
                    if (n2 >= 6 && a2[6] ~ /^[DEWX]/ && a2[5] ~ /^[0-9a-f]+$/ && length(a2[5]) == 32)
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

# THE DRILL-CELL FILES (2026-09-21): every File bin/build/drill-files.sh listed —
# the first File of a red / orange drill cell, which report.js links — has its
# page under files/ (failed.sh pages the list); a missing one is a broken link
# the markup scan above cannot see (the link is made in the browser)
DRILLF="data/transfer/reports/_drill-files.tsv"; ndrill=0; ndmiss=0
if [ -f "$DRILLF" ]; then
    ndrill=$(wc -l < "$DRILLF" | tr -d ' ')
    awk -v D="$DOCS/files/" '$1 != "" { f = D $1 ".html"; if ((getline l < f) < 0) print $1; else close(f) }' "$DRILLF" > "$TMP/drillmiss"
    ndmiss=$(wc -l < "$TMP/drillmiss" | tr -d ' ')
fi

printf 'linkcheck: %s pages, %s internal links, %s broken, %s unreachable (%s expected)\n' \
       "$pages" "$edges" "$nbroken" "$norph" "$((nexp - norph))"
[ "$nroot" -gt 0 ] && printf 'linkcheck: %s site-root href="/" link(s) — the 404 fallback, rewritten by its inline script\n' "$nroot"
[ "$ndrill" -gt 0 ] && printf 'linkcheck: %s drill-cell File(s) listed, %s without a files/ page\n' "$ndrill" "$ndmiss"

if [ "$QUIET" = 0 ] && [ "$nbroken" -gt 0 ]; then
    echo "--- broken links ---"
    awk -F'\t' '$1=="BROKEN"{ printf "  %-56s %s link(s), e.g. %s -> %s\n", $2, $3, $4, $5 }' "$TMP/sorted"
fi
if [ "$QUIET" = 0 ] && [ "$ndmiss" -gt 0 ]; then
    echo "--- drill-cell Files without a page (first 10) ---"
    awk 'NR <= 10 { print "  files/" $1 ".html" }' "$TMP/drillmiss"
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

[ "$nbroken" -eq 0 ] && [ "$norph" -eq 0 ] && [ "$ndmiss" -eq 0 ]
