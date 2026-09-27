#!/usr/bin/env bash
#
# publish-all-files.sh — the ALL FILES SEARCH, "Implementation 3, all files"
# (2026-09-27, user request): search/all-files.html over EVERY File of the
# transfer cache, where Implementation 1 covers the newest 30 data days and
# Implementation 2 the newest 1000 Files per subscription.
#
# THE BALANCE between the end user's wait and the size of docs/:
#   - ONE SHARD PER DATA DAY, docs/search/all/d-<yyyy-mm-dd>.js — the day's
#     Files newest first, ~95 B each: name ⇥ HHMMSS ⇥ local subscription
#     index ⇥ bytes ⇥ CoreId (32 hex, no dashes) ⇥ flag. Each shard carries
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
source "$SCRIPT_DIR/../publish_lib.sh"   # cd's to the repo root; render_rpt, file_search_impl_row, …
ensure_assets

FCACHE="$DATA/transfer/cache/_files.tsv"
ERRD="$DATA/transfer/reports/errors"
FPGD="$DATA/transfer/reports/files"
SLUGMAP="$DATA/transfer/reports/details/subscriptions/_slugmap.tsv"
OUTD="$DOCS/search/all"
PAGE="$DOCS/search/all-files.html"
STAMP="$PUBLISH_STAMP_DIR/all-files.stamp"
if publish_is_fresh "$STAMP" "$OUTD" "${BASH_SOURCE[0]}" "$FCACHE" "$ERRD" "$FPGD" "$SLUGMAP" \
       "$DOCS/assets/all-files-search.js" && [ -f "$PAGE" ]; then
    echo "docs/search/all-files.html is up to date; skipping." >&2
    exit 0
fi

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
            f = ($2 == "Failed") ? "e" : ($2 == "Waiting") ? "w" : ($2 == "Expired") ? "x" : "d"
            if ($1 in PAGE) f = toupper(f); else if (f == "d") f = ""
            cid = $1; gsub(/-/, "", cid)
            nm = $11; gsub(/[\t\r\n]/, " ", nm)
            print $4, $6, nm, tm, $12, $8 + 0, cid, f
        }' "$FCACHE" | LC_ALL=C sort -t"$(printf '\t')" -k1,1r -k2,2r -k7,7 > "$TMPD/rows"
else
    : > "$TMPD/rows"
fi

# PASS 2 — the day shards + the manifest lines + the bloom filters
LC_ALL=C awk -F'\t' -v OUTD="$OUTD" -v MAN="$TMPD/days" -v SUBF="$TMPD/subs" -v SLUGMAP="$SLUGMAP" '
    function tl(s) { gsub(/\\/, "\\\\", s); gsub(/`/, "\\`", s); gsub(/\$\{/, "\\${", s); return s }   # template-literal escape
    function hsh(s, b,   i, h) { h = 0; for (i = 1; i <= length(s); i++) h = (h * b + ORD[substr(s, i, 1)]) % 2147483647; return h }
    function item(s) { if (!(s in IT)) { IT[s] = 1; nit++ } }
    function items(txt,   t, i, g, r) {
        t = tolower(txt); gsub(/[\200-\377]+/, "?", t)
        for (i = 1; i + 2 <= length(t); i++) { g = substr(t, i, 3); if (g ~ /[^0-9a-f-]/) item(g) }
        r = t
        while (match(r, /[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]-/)) {
            item("#" substr(r, RSTART, 8)); r = substr(r, RSTART + RLENGTH) }
    }
    function flush(   f, s, m, nb, i, it, B, j, v, b, enc, sl, k, nd, DL) {
        if (day == "") return
        f = OUTD "/d-" day ".js"
        s = ""; for (i = 1; i <= nls; i++) s = s (i > 1 ? "\n" : "") tl(LSN[i])
        printf "AXWAY_AFD(\"%s\",`%s`,`%s`);\n", day, s, rows > f
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
        day = ""; rows = ""; nrow = 0; nls = 0; nit = 0
        split("", LSI); split("", LSN); split("", IT); split("", DS)
    }
    BEGIN {
        for (i = 1; i < 256; i++) ORD[sprintf("%c", i)] = i
        A64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
        P2[0] = 1; for (i = 1; i < 6; i++) P2[i] = P2[i - 1] * 2
        while ((getline l < SLUGMAP) > 0) { n = split(l, a, "\t"); if (n >= 2 && a[1] != "") SLUG[a[1]] = a[2] }
        close(SLUGMAP)
    }
    {
        if ($1 != day) { flush(); day = $1 }
        sb = $5
        if (!(sb in LSI)) { LSI[sb] = nls++; LSN[nls] = sb }
        if (!(sb in GSI)) { GSI[sb] = ngs++; GSN[ngs] = sb }
        DS[GSI[sb]] = 1
        rows = rows (nrow ? "\n" : "") tl($3) "\t" $4 "\t" LSI[sb] "\t" $6 "\t" $7 "\t" $8
        nrow++
        items($3)
        c = $7; items(substr(c, 1, 8) "-")          # the dashed CoreId starts with its only /[0-9a-f]{8}-/ run
    }
    END {
        flush()
        for (i = 1; i <= ngs; i++) printf "%s\t%s\n", GSN[i], ((GSN[i] in SLUG) ? SLUG[GSN[i]] : "") > SUBF
        close(MAN); close(SUBF)
    }' "$TMPD/rows"
: >> "$TMPD/days"; : >> "$TMPD/subs"

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
        first=0
    done < "$TMPD/days"
    printf '`};\n'
} > "$OUTD/index.js"
ndays=$(wc -l < "$TMPD/days" | tr -d ' '); nrows=$(wc -l < "$TMPD/rows" | tr -d ' ')

# the page: an EMPTY table the engine fills (rangehook: the shared From/To)
_rpt="$TMPD/page.rpt"
printf 'TITLE\tAll files search\nDESC\tFind a File among ALL the Files of the transfer logs by file name or CoreId and subscription, the results following each keystroke; the index loads only the days that can hold a match.\nKEYWORDS\tall files,file,files,search,find,filename,file name,coreid,subscription,history,archive\nTABLE\t\twide\trestint\tnosort\tnosearch\tnofilter\trangehook\nHEAD\tStart\tSubscription\tState\tSize\tFile\tCoreId\nKIND\ttext\ttext\ttext\tnum\tmono\tmono\n' > "$_rpt"
CUR_DATES=$TRANSFER_DATES
RPT_NOPROSE=1 render_rpt "$_rpt" "$PAGE" "../assets/style.css" "../index.html" "ANALYSES - All files search" 1 "all-files-search" "all-files-search"
_mv=$(cksum < "$OUTD/index.js" | awk '{print $1}')
_ev=$(cksum < "$DOCS/assets/all-files-search.js" 2>/dev/null | awk '{print $1}')
awk -v a="<script src=\"all/index.js?v=$_mv\" defer></script>" -v b="<script src=\"../assets/all-files-search.js?v=$_ev\" defer></script>" \
    '/<script src=[^>]*report\.js/ && !done { print a; print b; done = 1 } { print }' "$PAGE" > "$PAGE.tmp.$$" \
    && mv "$PAGE.tmp.$$" "$PAGE"
_inject_after_h1 "$PAGE" "$(file_search_impl_row 3)"

publish_stamp "$STAMP"
echo "Wrote search/all-files.html + search/all/ ($ndays day shard(s), $nrows File(s))." >&2
