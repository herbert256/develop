#!/usr/bin/env bash
#
# trend.sh — per-subscription GROWTH and DECLINE over the data window. The
# weekly report shows the site-wide trend; nothing else says WHICH
# subscription is behind a swing. The window is split in half at its midpoint
# and each subscription's Files/volume compared across the halves:
#   Growers      4x+ more Files in the second half (20+ Files there); a flow
#                with no first-half activity at all shows as "new".
#   Shrinkers    4x+ fewer Files in the second half (from 20+ in the first),
#                but still alive in the final week.
# A flow that went SILENT — active early (10+ Files in the first half), then
# NOTHING in the window's final week — is neither: the Went quiet report owns
# it (the Went silent table here went 2026-09-29).
#
# Full-period semantics (`nofilter`): the halves are fixed by the window, so
# the date filter never narrows this page.
#
# Reads data/_files.tsv (4=date_iso, 7=jdn, 8=size, 12=dest_site).
# Writes data/trend.rpt.
#
# Usage:
#   ./trend.sh    # reads input/*.csv (via the cache), writes data/trend.rpt
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib.sh"
mkdir -p "$REPORTS_DIR"
OUT="$REPORTS_DIR/trend.rpt"

RATIO=4        # growth/shrink factor at/above which a flow is listed
MIN_BASE=20    # Files the busy half needs before a ratio means anything
MIN_SILENT=10  # first-half Files that make a flow with no final-week File SILENT (left out)

shopt -s nullglob
files=("$INPUT_DIR"/*.csv)
shopt -u nullglob
if [ ${#files[@]} -eq 0 ]; then
    echo "No *.csv in $INPUT_DIR — building from the EMPTY caches (config-only estate)" >&2
fi
echo "Found ${#files[@]} file(s) in '$INPUT_DIR', processing..." >&2

# One pass collecting per (site, day) Files/bytes; END splits the window at
# its midpoint. Emits pipe-separated:
#   G|f2|site|f1|ratio|v1h|v2h                         (growers)
#   K|f1|site|f2|ratio|v1h|v2h                         (shrinkers)
#   TOT|ngrow|nshrink|from|mid1|mid2|to|nsites
agg=$(awk -F'\t' -v RATIO="$RATIO" -v MINBASE="$MIN_BASE" -v MINSIL="$MIN_SILENT" '
    function fromjdn(j,  a,b,c,dd,e,mm,day,mon,yr){ a=j+32044; b=int((4*a+3)/146097); c=a-int(146097*b/4); dd=int((4*c+3)/1461); e=c-int(1461*dd/4); mm=int((5*e+2)/153); day=e-int((153*mm+2)/5)+1; mon=mm+3-12*int(mm/10); yr=100*b+dd-4800+int(mm/10); return sprintf("%04d-%02d-%02d",yr,mon,day) }
    function human(b,   u, i, v) {
        split("B KB MB GB TB PB", u, " ")
        i = 1; v = b + 0
        while (v >= 1024 && i < 6) { v /= 1024; i++ }
        if (i == 1) return sprintf("%d %s", v, u[i])
        return sprintf("%.2f %s", v, u[i])
    }
    $12 == "" || $4 == "" { next }
    {
        s = $12; j = $7 + 0
        k = s SUBSEP j
        sf[k]++; sb[k] += $8
        if (!(k in seenk)) { seenk[k] = 1; dl[s] = dl[s] " " j }
        if (minjd == 0 || j < minjd) minjd = j
        if (j > maxjd) maxjd = j
        if (!(s in lastjd) || j > lastjd[s]) lastjd[s] = j
        sites[s] = 1
    }
    END {
        mid = minjd + int((maxjd - minjd) / 2)
        silent = maxjd - 6                     # alive = a File in the final week
        for (s in sites) { nsites++
            f1 = 0; f2 = 0; v1 = 0; v2 = 0
            nd = split(dl[s], D, " ")
            for (i = 1; i <= nd; i++) { j = D[i] + 0; k = s SUBSEP j
                if (j <= mid) { f1 += sf[k]; v1 += sb[k] } else { f2 += sf[k]; v2 += sb[k] } }
            # a SILENT flow (see the header) is neither grower nor shrinker
            if (f1 >= MINSIL && lastjd[s] < silent) continue
            if (f2 >= MINBASE && f1 < f2 / RATIO) {
                ngrow++
                r = (f1 > 0) ? sprintf("%.1f x", f2 / f1) : "new"
                printf "G|%08d|%s|%d|%s|%s|%s\n", f2, s, f1, r, human(v1), human(v2)
            } else if (f1 >= MINBASE && f2 < f1 / RATIO) {
                nshr++
                r = (f2 > 0) ? sprintf("%.1f x", f1 / f2) : "-"
                printf "K|%08d|%s|%d|%s|%s|%s\n", f1, s, f2, r, human(v1), human(v2)
            }
        }
        printf "TOT|%d|%d|%s|%s|%s|%s|%d\n", ngrow+0, nshr+0, fromjdn(minjd), fromjdn(mid), fromjdn(mid + 1), fromjdn(maxjd), nsites+0
    }
' "$FILES")

if [ -z "$agg" ]; then
    echo "No usable records found." >&2
    exit 1
fi

IFS='|' read -r _ n_grow n_shr d_from d_mid1 d_mid2 d_to n_sites <<< "$(printf '%s\n' "$agg" | grep '^TOT|')"

# The two row loops run INSIDE the report block below (a herestring keeps them
# in this shell). Their empty-state rows end their line like every other
# (2026-09-28 fix: they ran into the NOTE under each table, rendering it as a
# cell).
n_grow_rows=0; n_shr_rows=0

{
    printf 'TITLE\tGrowers & Shrinkers\n'
    printf 'KEYWORDS\tgrowth, shrink, decline, delta, new flow, grower, shrinker\n'

    # (the Went silent table went 2026-09-29: Expected arrival's Overdue
    # verdict and the Went quiet report list the same flows)
    printf 'TABLE\tGrowers\twide\tnofilter\n'
    printf 'HEAD\tSubscription\tFirst-half Files\tSecond-half Files\tGrowth\tFirst-half volume\tSecond-half volume\n'
    printf 'KIND\tsite\tnum\tnum\ttext\tnum\tnum\n'
    while IFS='|' read -r _ f2 site f1 ratio v1 v2; do
        [ -z "$site" ] && continue
        printf 'ROW\t%s\t%s\t%s\t%s\t%s\t%s\n' "$site" "$f1" $((10#$f2)) "$ratio" "$v1" "$v2"
        n_grow_rows=$((n_grow_rows + 1))
    done <<< "$(printf '%s\n' "$agg" | grep '^G|' | LC_ALL=C sort -t'|' -k2,2r -k3,3)"
    if [ "$n_grow_rows" -eq 0 ]; then
        printf 'ROW\t@{colspan=6}No subscription grew %sx or more (with %s+ second-half Files).\n' "$RATIO" "$MIN_BASE"
    fi

    printf 'TABLE\tShrinkers\twide\tnofilter\n'
    printf 'HEAD\tSubscription\tFirst-half Files\tSecond-half Files\tShrink\tFirst-half volume\tSecond-half volume\n'
    printf 'KIND\tsite\tnum\tnum\ttext\tnum\tnum\n'
    while IFS='|' read -r _ f1 site f2 ratio v1 v2; do
        [ -z "$site" ] && continue
        printf 'ROW\t%s\t%s\t%s\t%s\t%s\t%s\n' "$site" $((10#$f1)) "$f2" "$ratio" "$v1" "$v2"
        n_shr_rows=$((n_shr_rows + 1))
    done <<< "$(printf '%s\n' "$agg" | grep '^K|' | LC_ALL=C sort -t'|' -k2,2r -k3,3)"
    if [ "$n_shr_rows" -eq 0 ]; then
        printf 'ROW\t@{colspan=6}No still-active subscription shrank %sx or more (from %s+ first-half Files).\n' "$RATIO" "$MIN_BASE"
    fi

    printf 'FOOT\n'
} > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"

echo "Data written to $OUT (growers $n_grow, shrinkers $n_shr)." >&2
