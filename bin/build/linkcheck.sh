#!/usr/bin/env bash
#
# bin/build/linkcheck.sh — every link resolves, every page is reachable.
#
# A static check over the whole published tree: it resolves every internal
# href/src against the filesystem and then walks the link graph from the shared
# home to find pages nothing points at. Both environments at once (like
# crosslink.sh) — the env switch and the shared root pages are cross-env links,
# so one env in isolation cannot be checked.
#
# THE TOP BAR IS RUNTIME, and that is the whole difficulty. Since 2026-07 the
# publishes bake only an empty `<div class="topbar" data-eb=… data-b=…
# data-help=… data-twin=…>` and report.js's buildTopbar renders the real bar
# from docs/assets/topbar-data.js. A naive href scan therefore finds almost no
# navigation at all and calls ~2,600 pages unreachable. This models what
# buildTopbar emits, from the page's own attributes:
#   - every menu href in topbar-data.js, its "@" placeholder replaced by data-eb
#   - brand -> data-b + index.html
#   - data-eb + dashboards/index.html, report-finder.html, search.html,
#     sitemap.html, transfer/entities/subscription-all.html
#   - the help icon  -> data-b + help/<data-help>.html
#   - the env switch -> data-twin  (on the shared root pages it is a
#     data-target JS toggle with no href, so there is nothing to check)
# A page whose topbar div is NOT empty has a baked bar (help pages, the build
# report — render_shared_topbar) and is scanned normally.
#
# Entity Search ships its rows as DATA, not markup (split_search_rows lifts them
# into docs/<env>/search-data.js), so its ~7,500 detail links live in the .js —
# they are read from there and counted as edges from search.html.
#
# EXPECTED-UNREACHABLE (not failures, listed for confirmation):
#   docs/404.html            what GitHub Pages serves for an unmatched URL;
#                            nothing should link it. The per-env 404s ARE
#                            linked — crosslink.sh points a twin-less page at
#                            docs/<other>/404.html.
#   (the build report left docs/ entirely 2026-08-29 — build/index.html is
#   local only, so no build.html expectation remains)
#
# Exit status: 1 when a link resolves to nothing, else 0. Unreachable pages
# beyond the expected set are reported and also fail the run — a page nothing
# links to is dead weight in the published site.
#
# Usage:  bin/build/linkcheck.sh          # both envs, ~1 s over 2,900 pages
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
            if (parts[i] == "..") { if (sp > 0) sp--; continue }
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
                    eb = attr(d, "data-eb"); b = attr(d, "data-b")
                    hlp = attr(d, "data-help"); twin = attr(d, "data-twin")
                    for (i = 1; i <= MENUN; i++) { h = MENU[i]; gsub(/@/, eb, h); edge(page, h) }
                    edge(page, b "index.html")
                    edge(page, eb "dashboards/index.html")
                    edge(page, eb "report-finder.html")
                    edge(page, eb "search.html")
                    edge(page, eb "sitemap.html")
                    edge(page, eb "transfer/entities/subscription-all.html")
                    if (hlp  != "") edge(page, b "help/" hlp ".html")
                    if (twin != "") edge(page, twin)
                }
            }
        }
        # 3. Entity Search + File search: their rows live in *search-data.js,
        # not in the page (search-data.js maps to search.html; each of the six
        # file-search-<key>-data.js maps to its file-search-<key>.html)
        for (f in FILE) if (f ~ /^[a-z]+\/(file-search-[a-z0-9-]+-|search-)data\.js$/) {
            src = f; sub(/-data\.js$/, ".html", src)
            if (f ~ /file-search-/) {
                # the COMPACT v2 payload (bin/analyses/reports/file-search.sh,
                # 2026-08): no markup — the links are DERIVED the way the
                # engine derives them. In the _S section the second field is a
                # detail slug (non-empty = a detail-page link); an _R row
                # whose LAST field is "E" (an Error with its own page, the v5
                # flag) links errors/<coreid>.html — the coreid is its
                # 36-char field.
                sect = ""
                while ((getline l < (DOCS "/" f)) > 0) {
                    if (index(l, "window.AXWAY_FSEARCH_S=") == 1) { sect = "S"; continue }
                    if (index(l, "window.AXWAY_FSEARCH_R=") == 1) { sect = "R"; continue }
                    if (index(l, "window.AXWAY_FSEARCH_") == 1) { sect = ""; continue }
                    if (l == "`;" || l == "") continue
                    if (sect == "S") {
                        n2 = split(l, a2, "\t")
                        if (n2 >= 2 && a2[2] != "") edge(src, "details/subscriptions/" a2[2] ".html")
                    } else if (sect == "R") {
                        n2 = split(l, a2, "\t")
                        if (a2[n2] == "E")
                            for (i2 = 1; i2 <= n2; i2++)
                                if (length(a2[i2]) == 36 && a2[i2] ~ /^[0-9a-f-]+$/) { edge(src, "errors/" a2[i2] ".html"); break }
                    }
                }
                close(DOCS "/" f)
                continue
            }
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
