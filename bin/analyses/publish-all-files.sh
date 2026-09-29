#!/usr/bin/env bash
#
# publish-all-files.sh — the ALL FILES SEARCH (2026-09-27, user request):
# search/all-files.html over EVERY File of the transfer cache (the File search
# window pages and the Latest files pages it once sat beside went 2026-09-29).
# Its data also feeds every subscription page's Files table (the per-
# subscription day lists s/<slug>.js below, 2026-09-29).
#
# THE BALANCE between the end user's wait and the size of docs/:
#   - ONE SHARD PER DATA DAY, docs/search/all/d-<yyyy-mm-dd>.js — the day's
#     Files newest first, ~95 B each: name ⇥ HHMMSS ⇥ local subscription
#     index ⇥ bytes ⇥ CoreId (32 hex, no dashes) ⇥ flag ("" / d OK, o OK after
#     a retry or resubmit — orange, e Error, w Waiting, x Expired; UPPERCASE =
#     the File has a page). Each shard carries
#     its OWN subscription dictionary, so an old day's shard is byte-identical
#     from build to build (git and the outbox archive store it once).
#   - A SMALL MANIFEST, docs/search/all/index.js (window.AXWAY_AFX): per day
#     its File count, the subscriptions present, the shard's cksum (?v=) and a
#     BLOOM FILTER of the day's file-name trigrams + CoreId tokens. The engine
#     (assets/all-files-search.js) loads only the days that CAN hold a match —
#     the filter never rules out a day that has one — newest first, a few at a
#     time, and stops once it has the newest 500 matches. The shared From/To
#     selection narrows the days before anything loads.
#
# THE FILTER (keep in step with the engine — the same normalisation and hash):
#   text   = the file name, lowercased, every run of non-ASCII bytes -> "?"
#   items  = its trigrams that contain a character outside [0-9a-f-] (an
#            all-hex trigram can come from a CoreId anywhere, so the engine
#            never prunes on one), plus "#" + the 8 hex of every
#            /[0-9a-f]{8}-/ occurrence in the name AND in the dashed CoreId
#            (a CoreId pasted from an error mail finds its day at once)
#   bits   = m = the smallest power of two >= max(1024, 8 x items); three
#            hashes, h = (h * B + code) mod 2147483647 over the item's
#            characters with B = 131, 257 and 521, bit = h mod m (about 3 %
#            false positives per item: a pasted CoreId loads ~its own day)
#   encode = 6 bits per character of the base64 alphabet, bit b of
#            character j = bit 6j+b
#
# The File pages: a row whose CoreId has a page in docs/files/ (the failed.sh
# rosters: data/transfer/reports/errors/ + files/) carries an UPPERCASE flag
# and the engine links that page. Runs as its own build step AFTER the
# failed.sh catch-ups and the transfer publish catch-up (their rosters are
# final by then); a manual re-publish must run it too (it is outside the
# per-area publishes, like publish-partner-groups.sh).
#
# Usage: bin/analyses/publish-all-files.sh
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../publish_lib.sh"   # cd's to the repo root; render_rpt, …
source "$SCRIPT_DIR/../ranges.sh"        # grp_par: PASS 2 per day-aligned slice (2026-09-28)
ensure_assets

FCACHE="$DATA/transfer/cache/_files.tsv"
ERRD="$DATA/transfer/reports/errors"
FPGD="$DATA/transfer/reports/files"
SLUGMAP="$DATA/transfer/reports/details/subscriptions/_slugmap.tsv"
OUTD="$DOCS/search/all"
PAGE="$DOCS/search/all-files.html"

mkdir -p "$DOCS/search"
rm -rf "$OUTD"
mkdir -p "$OUTD"
TMPD=$(mktemp -d "${TMPDIR:-/tmp}/axallf.XXXXXX")
trap 'rm -rf "$TMPD"' EXIT

# the CoreIds that have a File page (every roster .rpt renders to docs/files/)
{
    [ -d "$ERRD" ] && find "$ERRD" -name '*.rpt' -type f 2>/dev/null
    [ -d "$FPGD" ] && find "$FPGD" -name '*.rpt' -type f 2>/dev/null
} | awk '{ sub(/.*\//, ""); sub(/\.rpt$/, ""); print }' > "$TMPD/pages"
[ -f "$SLUGMAP" ] || SLUGMAP=/dev/null

if [ -s "$FCACHE" ]; then
    # PASS 1 — one line per dated File: day ⇥ sortkey ⇥ the shard row fields
    LC_ALL=C awk -F'\t' -v OFS='\t' -v PG="$TMPD/pages" '
        BEGIN { while ((getline l < PG) > 0) PAGE[l] = 1; close(PG) }
        $4 !~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$/ { next }
        {
            tm = substr($5, 1, 8); gsub(/:/, "", tm)
            # "o" = an OK File the colour column (col 25) calls orange: it
            # got through after a retry or a resubmit (2026-09-29)
            f = ($2 == "Failed") ? "e" : ($2 == "Waiting") ? "w" : ($2 == "Expired") ? "x" : ($25 == "orange") ? "o" : "d"
            if ($1 in PAGE) f = toupper(f); else if (f == "d") f = ""
            cid = $1; gsub(/-/, "", cid)
            nm = $11; gsub(/[\t\r\n]/, " ", nm)
            print $4, $6, nm, tm, $12, $8 + 0, cid, f
        }' "$FCACHE" | LC_ALL=C sort -t"$(printf '\t')" -k1,1r -k2,2r -k7,7 > "$TMPD/rows"
else
    : > "$TMPD/rows"
fi

# The GLOBAL subscription dictionary first (2026-09-28, speed round 23): its
# index = the order of first appearance in the rows (newest day first), name
# ⇥ detail slug — the manifest dictionary, and the index the per-day lists
# use. Computed up front so PASS 2 can run per day-aligned slice.
LC_ALL=C awk -F'\t' -v SLUGMAP="$SLUGMAP" -v GSIF="$TMPD/gsi" '
    BEGIN { while ((getline l < SLUGMAP) > 0) { n = split(l, a, "\t"); if (n >= 2 && a[1] != "") SLUG[a[1]] = a[2] }
            close(SLUGMAP) }
    !($5 in GSI) { GSI[$5] = ngs++; printf "%s\t%d\n", $5, GSI[$5] > GSIF; printf "%s\t%s\n", $5, (($5 in SLUG) ? SLUG[$5] : "") }
    END { close(GSIF) }' "$TMPD/rows" > "$TMPD/subs"
: >> "$TMPD/gsi"
_pj=$( (command -v nproc >/dev/null 2>&1 && nproc) || sysctl -n hw.ncpu 2>/dev/null || echo 2 )
case $_pj in ""|*[!0-9]*) _pj=2 ;; esac

# PASS 2 — the day shards + the manifest lines + the bloom filters, per
# DAY-ALIGNED slice of the rows in parallel (grp_par: the rows are sorted on
# the day, a day is never split, the manifest parts join in slice order)
grp_par "$TMPD/rows" "$TMPD/pass2" "$_pj" env LC_ALL=C awk -F'\t' -v OUTD="$OUTD" -v MAN="$TMPD/days" -v SUBSF="$TMPD/subdays" -v GSIF="$TMPD/gsi" '
    function tl(s) { gsub(/\\/, "\\\\", s); gsub(/`/, "\\`", s); gsub(/\$\{/, "\\${", s); return s }   # template-literal escape
    function hsh(s, b,   i, h) { h = 0; for (i = 1; i <= length(s); i++) h = (h * b + ORD[substr(s, i, 1)]) % 2147483647; return h }
    function item(s) { if (!(s in IT)) { IT[s] = 1; nit++ } }
    # The engine matches the UNICODE-lowercased name, where two non-ASCII
    # capitals fold INTO ASCII: KELVIN SIGN U+212A -> "k", I WITH DOT ABOVE
    # U+0130 -> "i" + U+0307. A name holding one files the trigrams of that
    # form too, or "kpi" pruned the day of a Kelvin-sign KPI.csv the matcher
    # finds (audit 2026-09-29 F11); the engine keeps asking the RAW words
    function items(txt,   u) {
        if (index(txt, "\342\204\252") || index(txt, "\304\260")) {
            u = txt; gsub("\342\204\252", "k", u); gsub("\304\260", "i\314\207", u); items1(u) }
        items1(txt)
    }
    function items1(txt,   t, i, g, r) {
        t = tolower(txt); gsub(/[\200-\377]+/, "?", t)
        for (i = 1; i + 2 <= length(t); i++) { g = substr(t, i, 3); if (g ~ /[^0-9a-f-]/) item(g) }
        r = t
        while (match(r, /[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]-/)) {
            item("#" substr(r, RSTART, 8)); r = substr(r, RSTART + RLENGTH) }
    }
    # the day shard STREAMS: its rows go to the file as they come (a string
    # grown row by row re-copies itself on every append — quadratic in the
    # rows of the day), and the subscription dictionary, complete only at the
    # end of the day, follows them: AXWAY_AFD(day, rows, subscriptions)
    function flush(   f, s, m, nb, i, it, B, j, v, b, enc, sl, k, nd, DL) {
        if (day == "") return
        f = OUTD "/d-" day ".js"
        s = ""; for (i = 1; i <= nls; i++) s = s (i > 1 ? "\n" : "") tl(LSN[i])
        printf "`,`%s`);\n", s > f
        close(f)
        m = 1024; while (m < 8 * nit) m *= 2
        split("", B)
        for (it in IT) { B[hsh(it, 131) % m] = 1; B[hsh(it, 257) % m] = 1; B[hsh(it, 521) % m] = 1 }
        nb = int((m + 5) / 6); enc = ""
        for (j = 0; j < nb; j++) {
            v = 0; for (b = 0; b < 6; b++) if ((6 * j + b) in B) v += P2[b]
            enc = enc substr(A64, v + 1, 1)
        }
        # the subscription indices of the day, ascending (never hash order)
        nd = 0; for (k in DS) DL[++nd] = k + 0
        for (i = 2; i <= nd; i++) { v = DL[i]; j = i - 1; while (j >= 1 && DL[j] > v) { DL[j + 1] = DL[j]; j-- } DL[j + 1] = v }
        sl = ""; for (i = 1; i <= nd; i++) sl = sl (i > 1 ? "," : "") DL[i]
        split("", DL)
        printf "%s\t%d\t%s\t%d\t%s\n", day, nrow, sl, m, enc > MAN
        # the subscription pages\047 day lists: name, local index, Files
        for (i = 1; i <= nls; i++) printf "%s\t%s\t%d\t%d\n", day, LSN[i], i - 1, LC[i - 1] > SUBSF
        day = ""; nrow = 0; nls = 0; nit = 0
        split("", LSI); split("", LSN); split("", IT); split("", DS); split("", LC)
    }
    BEGIN {
        for (i = 1; i < 256; i++) ORD[sprintf("%c", i)] = i
        A64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
        P2[0] = 1; for (i = 1; i < 6; i++) P2[i] = P2[i - 1] * 2
        while ((getline l < GSIF) > 0) { n = split(l, a, "\t"); GSI[a[1]] = a[2] + 0 }
        close(GSIF)
        MAN = MAN "." ENVIRON["GRP_PART"]; printf "" > MAN
        SUBSF = SUBSF "." ENVIRON["GRP_PART"]; printf "" > SUBSF
    }
    {
        if ($1 != day) { flush(); day = $1; sf = OUTD "/d-" day ".js"; printf "AXWAY_AFD(\"%s\",`", day > sf }
        sb = $5
        if (!(sb in LSI)) { LSI[sb] = nls++; LSN[nls] = sb }
        DS[GSI[sb]] = 1
        LC[LSI[sb]]++
        printf "%s%s\t%s\t%s\t%s\t%s\t%s", (nrow ? "\n" : ""), tl($3), $4, LSI[sb], $6, $7, $8 > sf
        nrow++
        items($3)
        c = $7; items(substr(c, 1, 8) "-")          # the dashed CoreId starts with its only /[0-9a-f]{8}-/ run
    }
    END {
        flush()
        close(MAN); close(SUBSF)
    }' -
: > "$TMPD/days"; : > "$TMPD/subdays"
for ((_i = 1; _i <= GRP_N; _i++)); do cat "$TMPD/days.$_i" >> "$TMPD/days"; cat "$TMPD/subdays.$_i" >> "$TMPD/subdays"; done
: >> "$TMPD/subs"

# the manifest: the global subscription dictionary (name ⇥ detail slug; the
# per-day lists index it) + one line per day, newest first, with the shard's
# cksum appended for its ?v= cache-buster
{
    printf 'window.AXWAY_AFX={v:1,subs:`'
    awk '{ gsub(/\\/, "\\\\"); gsub(/`/, "\\`"); gsub(/\$\{/, "\\${"); print }' "$TMPD/subs" | awk 'NR > 1 { printf "\n" } { printf "%s", $0 }'
    printf '`,days:`'
    first=1
    while IFS=$'\t' read -r d n sl m enc; do
        v=$(cksum < "$OUTD/d-$d.js" | awk '{print $1}')
        [ "$first" = 1 ] || printf '\n'
        printf '%s\t%s\t%s\t%s\t%s\t%s' "$d" "$n" "$sl" "$m" "$enc" "$v"
        printf '%s\t%s\n' "$d" "$v" >> "$TMPD/dayv"
        first=0
    done < "$TMPD/days"
    printf '`};\n'
} > "$OUTD/index.js"

# THE SUBSCRIPTION DAY LISTS (2026-09-29, user request): docs/search/all/
# s/<slug>.js per subscription detail page — the Files table of
# details/subscriptions/<slug>.html (assets/sub-files.js) reads it to page
# through the subscription's Files, 25 at a time, loading only the day
# shards a page needs:
#   AXWAY_AFS("<slug>", `day \t Files \t shard cksum \t local index(es)`)
# one line per day that holds a File of it, NEWEST FIRST; the local indices
# (",") are the shard dictionary entries of its name(s) — several names can
# share one detail page (the slug map), a name without a page has no list.
mkdir -p "$OUTD/s"
LC_ALL=C awk -F'\t' -v OFS='\t' -v SUBS="$TMPD/subs" -v DV="$TMPD/dayv" '
    BEGIN {
        while ((getline l < SUBS) > 0) { n = split(l, a, "\t"); if (n >= 2 && a[2] != "") SL[a[1]] = a[2] }
        close(SUBS)
        while ((getline l < DV) > 0) { split(l, a, "\t"); V[a[1]] = a[2] }
        close(DV)
    }
    ($2 in SL) && $4 > 0 {
        k = SL[$2] SUBSEP $1
        if (!(k in C)) { K[++nk] = k; I[k] = $3 } else I[k] = I[k] "," $3
        C[k] += $4
    }
    END { for (i = 1; i <= nk; i++) { split(K[i], a, SUBSEP); print a[1], a[2], C[K[i]], V[a[2]], I[K[i]] } }
' "$TMPD/subdays" | LC_ALL=C sort -t"$(printf '\t')" -k1,1 -k2,2r | LC_ALL=C awk -F'\t' -v OUTD="$OUTD/s" '
    function js(x) { gsub(/\\/, "\\\\", x); gsub(/"/, "\\\"", x); return x }
    function close1() { if (cur != "") { printf "`);\n" > f; close(f) } }
    $1 != cur { close1(); cur = $1; f = OUTD "/" cur ".js"; printf "AXWAY_AFS(\"%s\",`", js(cur) > f; nl = 0 }
    { printf "%s%s\t%s\t%s\t%s", (nl++ ? "\n" : ""), $2, $3, $4, $5 > f }
    END { close1() }'
nsubl=$(find "$OUTD/s" -name '*.js' -type f | wc -l | tr -d ' ')
ndays=$(wc -l < "$TMPD/days" | tr -d ' '); nrows=$(wc -l < "$TMPD/rows" | tr -d ' ')

# the page: an EMPTY table the engine fills (rangehook: the shared From/To)
_rpt="$TMPD/page.rpt"
printf 'TITLE\tAll files search\nTABLE\t\twide\trestint\tnosort\tnosearch\tnofilter\trangehook\nHEAD\tStart\tSubscription\tState\tSize\tFile\tCoreId\nKIND\ttext\ttext\ttext\tnum\tmono\tmono\n' > "$_rpt"
CUR_DATES=$TRANSFER_DATES
RPT_NOPROSE=1 render_rpt "$_rpt" "$PAGE" "../assets/style.css" "../index.html" "ANALYSES - All files search" 1 "all-files-search" "all-files-search"
_mv=$(cksum < "$OUTD/index.js" | awk '{print $1}')
_ev=$(cksum < "$DOCS/assets/all-files-search.js" 2>/dev/null | awk '{print $1}')
awk -v a="<script src=\"all/index.js?v=$_mv\" defer></script>" -v b="<script src=\"../assets/all-files-search.js?v=$_ev\" defer></script>" \
    '/<script src=[^>]*report\.js/ && !done { print a; print b; done = 1 } { print }' "$PAGE" > "$PAGE.tmp.$$" \
    && mv "$PAGE.tmp.$$" "$PAGE"
echo "Wrote search/all-files.html + search/all/ ($ndays day shard(s), $nrows File(s), $nsubl subscription day list(s))." >&2
