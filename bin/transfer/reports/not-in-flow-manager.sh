#!/usr/bin/env bash
#
# not-in-flow-manager.sh — "Not in Flow Manager" (Failures & Retries group):
# one row for every entity VALUE that appears in the transfer log but is NOT in
# the current FlowManager configuration — all TEN entity lists checked, by the
# shared classifier bin/transfer/nifm-lib.sh (the types and their columns are
# listed there; bin/transfer/filepages.sh uses the same one). All matching is
# case-insensitive. Counts are Files (one logical transfer per CoreId). A
# missing base cache degrades to an empty configured list (everything logged
# shows), like showseen.
#
# THE PER-ROW PAGES (2026-10-02, user request: "the complete row must link to a
# new page docs/not-in-fm/<type>_<name>.html with all entries for that row …
# the first 10 rows must link to an entry in /files/"): every row of the table
# opens (rowlink + @data:href) its page, rendered by bin/transfer/publish.sh
# from data/transfer/reports/not-in-fm/<type>_<slug>.rpt — <type> the lowercase
# type word (account … bl), <slug> the site-wide slugof of the value, bumped
# "-2", "-3" on a clash within one type. The page lists EVERY File of the row —
# Date/time · Subscription · File · CoreId · State, newest first (sortkey
# descending, CoreId ascending on a tie), tinted by the File colour (col 25),
# a TOTAL row and a NAV row back; date-aware like the row it opens from. A row
# whose File has a published page (_filepages.tsv — kind N covers the first 10
# of every such page) opens it with the whole row; any other row carries
# @data:norowlink.
#
# Usage:
#   ./not-in-flow-manager.sh   # reads the caches, writes data/transfer/reports/not-in-flow-manager.rpt
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib.sh"
source "$ROOT/bin/pda-union.sh"   # SP_AWK: the File attribution UNION (bl_union — the BL set)
mkdir -p "$REPORTS_DIR"
OUT="$REPORTS_DIR/not-in-flow-manager.rpt"

shopt -s nullglob
files=("$INPUT_DIR"/*.csv)
shopt -u nullglob
if [ ${#files[@]} -eq 0 ]; then
    echo "No *.csv in $INPUT_DIR — building from the EMPTY caches (config-only estate)" >&2
fi
echo "Found ${#files[@]} file(s) in '$INPUT_DIR', processing..." >&2

source "$SCRIPT_DIR/../nifm-lib.sh"   # nifm_prepare / NIFM_AWK — the classifier, shared with bin/transfer/filepages.sh
nifm_prepare
TMPD=$(mktemp -d "${TMPDIR:-/tmp}/axnifm2.XXXXXX")
trap 'rm -rf "$TMPD" ${NIFM_TMP:+"$NIFM_TMP"}' EXIT
NSUB="$REPORTS_DIR/not-in-fm"
# the CoreIds with a PUBLISHED File page (bin/transfer/filepages.sh)
: > "$TMPD/pages"
[ -f "$CACHE_DIR/_filepages.tsv" ] && cut -f1 "$CACHE_DIR/_filepages.tsv" > "$TMPD/pages"

# Pass 1: aggregate the unconfigured (type, value) pairs from $FILES —
# TAB lines "tidx  files  name  failed  processed  bytes  first  last  buckets"
# — then sort by type order / Files desc / name and format the .rpt. Each
# entry also goes to $TMPD/entries — "tidx TAB VALUE (upper) TAB sortkey TAB
# CoreId TAB date time TAB subscription TAB colour TAB state TAB value as
# logged TAB file" — for the per-row pages.
awk -F'\t' "${NIFM_V[@]}" -v BLMAP="$BL_MAP" -v ENT="$TMPD/entries" "$SP_AWK$NIFM_AWK"'
    BEGIN { nifm_load() }
    function nifm_hit(t, v,   k) {
        k = t SUBSEP toupper(v)
        if (!(k in n)) { disp[k] = v; ord[++nk] = k }
        n[k]++; vol[k] += size; if (pr) p[k]++; else fl[k]++
        if (first[k] == "" || sk < firstk[k]) { firstk[k] = sk; first[k] = dt " " tm }
        if (last[k] == ""  || sk > lastk[k])  { lastk[k]  = sk; last[k]  = dt " " tm }
        db = k SUBSEP date
        if (!(db in bn)) { bord[k] = bord[k] SUBSEP date }
        bn[db]++; bv[db] += size; if (pr) bp[db]++; else bf[db]++
        printf "%s\t%s\t%s\t%s\t%s %s\t%s\t%s\t%s\t%s\t%s\n", t, toupper(v), sk, $1, dt, substr(tm, 1, 8), $12, $25, st, v, $11 > ENT
    }
    {
        date = $4; if (date == "") next
        dt = $4; tm = $5; sk = $6; size = $8 + 0; pr = ($2 != "Failed" && $2 != "Expired")
        st = ($2 == "Processed") ? "OK" : ($2 == "Failed") ? "Error" : $2
        nifm_row()
    }
    END {
        close(ENT)
        for (i = 1; i <= nk; i++) { k = ord[i]
            split(k, K, SUBSEP)
            bk = ""
            m = split(substr(bord[k], 2), D, SUBSEP)
            for (j = 1; j <= m; j++) { db = k SUBSEP D[j]
                bk = bk (bk == "" ? "" : ",") D[j] ":" bn[db] ":" (bf[db]+0) ":" (bp[db]+0) ":" (bv[db]+0) }
            printf "%s\t%d\t%s\t%d\t%d\t%d\t%s\t%s\t%s\n", K[1], n[k], disp[k], fl[k]+0, p[k]+0, vol[k], first[k], last[k], bk
        }
    }
' "$FILES" > "$TMPD/agg"
: >> "$TMPD/entries"

# ---- the page names: <type>_<slug>, slugof over the C-sorted values of a
# type, a numeric bump on a clash (the site-wide slug rule) -> tidx TAB VALUE
# (upper) TAB page name
LC_ALL=C sort -t$'\t' -k1,1n -k3,3 "$TMPD/agg" | awk -F'\t' "$AWKLIB$NIFM_TWORD_AWK"'
    { b = nifm_tword($1 + 0) "_" slugof($3); if (b ~ /_$/) b = b "value"
      s = b; n = 1; while (s in used) { n++; s = b "-" n }; used[s] = 1
      printf "%s\t%s\t%s\n", $1, toupper($3), s }' > "$TMPD/names"

# ---- the per-row pages (see the header), staged in not-in-fm.new/ ----
rm -rf "$NSUB.new"; mkdir -p "$NSUB.new"
LC_ALL=C sort -t$'\t' -k1,1n -k2,2 -k3,3r -k4,4 "$TMPD/entries" | awk -F'\t' \
    -v names="$TMPD/names" -v pages="$TMPD/pages" -v dir="$NSUB.new" "$AWKLIB"'
    BEGIN { split("Account|Subscription|Login|Host|Whitelist|Logical|Partner|Application|Domain|BL", TL, "|")
            while ((getline l < names) > 0) { split(l, a, "\t"); PN[a[1] SUBSEP a[2]] = a[3] } close(names)
            while ((getline l < pages) > 0) if (l != "") PG[l] = 1
            close(pages) }
    function clean(s) { gsub(/[\t\r]/, " ", s); return s }
    function finish() { if (out == "") return; printf "TOTAL\tTotal (%d Files)\t\t\t\t\n", nr > out; printf "FOOT\n" > out; close(out) }
    ($1 SUBSEP $2) != cur {
        finish(); cur = $1 SUBSEP $2; nr = 0; out = ""
        if (!(cur in PN)) next
        out = dir "/" PN[cur] ".rpt"; seen1 = 0
    }
    out == "" { next }
    {
        fn = $10; for (j = 11; j <= NF; j++) fn = fn " " $j   # (a TAB never reaches a file name; folded anyway)
        if (nr == 0) {
            # the TITLE names the value as LOGGED on the newest entry
            printf "TITLE\tNot in Flow Manager: %s %s\n", TL[$1 + 0], clean($9) > out
            printf "NAV\t0|Not in Flow Manager|../transfer/not-in-flow-manager.html\n" > out
            printf "TABLE\t%s Files\twide\tsort=0:-1\tpager=25\trestint\trowlink\n", TL[$1 + 0] > out
            printf "HEAD\tDate/time\tSubscription\tFile\tCoreId\tState\n" > out
            printf "KIND\ttext\tsite\tmono\tmono\ttext\n" > out
        }
        res = ($7 == "green" || $7 == "orange" || $7 == "red") ? "\t@data:res=" $7 : ""
        res = res (($4 in PG) ? "\t@data:href=../files/" $4 ".html" : "\t@data:norowlink=1")
        printf "ROW\t%s\t%s\t%s\t%s\t%s%s\n", $5, clean($6), lit(clean(fn)), $4, $8, res > out
        nr++
    }
    END { finish() }'
rm -rf "$NSUB"; mv "$NSUB.new" "$NSUB"

LC_ALL=C sort -t$'\t' -k1,1n -k2,2nr -k3,3 "$TMPD/agg" \
| awk -F'\t' -v names="$TMPD/names" "$AWKLIB"'
    BEGIN {
        split("Account|Subscription|Login|Host|Whitelist|Logical|Partner|Application|Domain|BL", TL, "|")
        split("accounts|subscriptions|logins|hosts||logicals|partners|applications|domains|bl", SD, "|")
        while ((getline l < names) > 0) { split(l, a, "\t"); PN[a[1] SUBSEP a[2]] = a[3] } close(names)
        printf "TITLE\tNot in Flow Manager\n"
        # the WHOLE row opens the per-row page (2026-10-02 — see the header)
        printf "TABLE\tLogged but not configured\twide\tgroup\trowlink\n"
        printf "HEAD\tType\tName\tFiles\tError\tOK\tVolume\tFirst seen\tLast seen\n"
        printf "KIND\ttext\ttext\tnum\tnumfailed\tnumprocessed\tnum\ttext\ttext\n"
        printf "RECALC\t-\t-\ts0\ts1\ts2\th3\t-\t-\n"
    }
    {
        t = $1 + 0
        nm = $3
        cell = (SD[t] != "") ? "@{alink=" SD[t] "/" nm "}" nm : nm
        pk = t SUBSEP toupper(nm)
        printf "ROW\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t@data:buckets=%s%s\n", TL[t], cell, $2, $4, $5, hbytes2($6), $7, $8, $9, ((pk in PN) ? "\t@data:href=../not-in-fm/" PN[pk] ".html" : "")
        rows++; tf += $2; te += $4; to += $5; tb += $6
    }
    END {
        # an EMPTY table totals blank, not "0" / "0 B" (2026-09-30 audit A5-06; the
        # failed / processed zeros z-blank in the renderer)
        printf "TOTAL\tTotal (%d rows)\t\t@{class=num}%s\t@{class=num failed}%d\t@{class=num processed}%d\t@{class=num}%s\t\t\n", rows+0, (tf + 0 > 0 ? tf + 0 : ""), te+0, to+0, (tb + 0 > 0 ? hbytes2(tb+0) : "")
        printf "SUMMARY\tUnconfigured values: %d  |  Files touched: %d  |  Volume: %s\n", rows+0, tf+0, hbytes2(tb+0)
        printf "FOOT\n"
    }
' > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"

echo "Data written to $OUT (+ $(ls "$NSUB" | grep -c '\.rpt$' || true) per-row page(s))." >&2
