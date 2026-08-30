#!/usr/bin/env bash
#
# trend.sh — per-subscription GROWTH and DECLINE over the data window, plus
# the flows that went silent mid-window. The weekly report shows the site-wide
# trend; nothing else says WHICH subscription is behind a swing. The window is
# split in half at its midpoint and each subscription's Files/volume compared
# across the halves:
#   Went silent  active early (10+ Files in the first half), then NOTHING in
#                the window's final week. Stale Accounts covers accounts gone
#                quiet — subscriptions/flows fell through until now.
#   Growers      4x+ more Files in the second half (20+ Files there); a flow
#                with no first-half activity at all shows as "new".
#   Shrinkers    4x+ fewer Files in the second half (from 20+ in the first),
#                but still alive in the final week (else it is Went silent).
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
MIN_SILENT=10  # first-half Files an already-dead flow needs to be listed

shopt -s nullglob
files=("$INPUT_DIR"/*.csv)
shopt -u nullglob
if [ ${#files[@]} -eq 0 ]; then
    echo "No *.csv in $INPUT_DIR — building from the EMPTY caches (config-only estate)" >&2
fi
ensure_parsed
skip_if_fresh "$OUT" "${BASH_SOURCE[0]}"
echo "Found ${#files[@]} file(s) in '$INPUT_DIR', processing..." >&2

# One pass collecting per (site, day) Files/bytes; END splits the window at
# its midpoint. Emits pipe-separated:
#   S|f1|site|f2|lastd|dayssilent                      (went silent)
#   G|f2|site|f1|ratio|v1h|v2h                         (growers)
#   K|f1|site|f2|ratio|v1h|v2h                         (shrinkers)
#   TOT|nsil|ngrow|nshrink|from|mid1|mid2|to|nsites
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
        if (!(s in lastjd) || j > lastjd[s]) { lastjd[s] = j; lastd[s] = $4 }
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
            if (f1 >= MINSIL && lastjd[s] < silent) {
                nsil++
                printf "S|%08d|%s|%d|%s|%d\n", f1, s, f2, lastd[s], maxjd - lastjd[s]
            } else if (f2 >= MINBASE && f1 < f2 / RATIO) {
                ngrow++
                r = (f1 > 0) ? sprintf("%.1f x", f2 / f1) : "new"
                printf "G|%08d|%s|%d|%s|%s|%s\n", f2, s, f1, r, human(v1), human(v2)
            } else if (f1 >= MINBASE && f2 < f1 / RATIO) {
                nshr++
                r = (f2 > 0) ? sprintf("%.1f x", f1 / f2) : "-"
                printf "K|%08d|%s|%d|%s|%s|%s\n", f1, s, f2, r, human(v1), human(v2)
            }
        }
        printf "TOT|%d|%d|%d|%s|%s|%s|%s|%d\n", nsil+0, ngrow+0, nshr+0, fromjdn(minjd), fromjdn(mid), fromjdn(mid + 1), fromjdn(maxjd), nsites+0
    }
' "$FILES")

if [ -z "$agg" ]; then
    echo "No usable records found." >&2
    exit 1
fi

IFS='|' read -r _ n_sil n_grow n_shr d_from d_mid1 d_mid2 d_to n_sites <<< "$(printf '%s\n' "$agg" | grep '^TOT|')"

# The three row loops run INSIDE the report block below (a herestring keeps them
# in this shell). Their empty-state rows carry NO trailing newline — they never
# did (they came out of a $(printf …), which strips it) and the NOTE under each
# table runs onto that line. Kept verbatim so the rendered pages do not change.
n_sil_rows=0; n_grow_rows=0; n_shr_rows=0

{
    printf 'TITLE\tGrowers & Shrinkers\n'
    printf 'DESC\tPer-subscription growth and decline: the window split in half, each flow'\''s Files/volume compared across the halves — growers, shrinkers, and flows that went silent mid-window.\n'
    printf 'KEYWORDS\tgrowth, shrink, decline, silent, disappeared, delta, new flow, gone\n'
    printf 'INTRO\tWhich flows are changing: the window (**%s → %s**) split at its midpoint (first half to %s, second from %s), each of the **%s** subscription(s) compared across the halves. **%s** went **silent** (active early, nothing in the final week), **%s** grew **%sx+**, **%s** shrank **%sx+** while still alive. The Weekly report shows the site-wide trend; this names the flows behind it.\n' \
        "$d_from" "$d_to" "$d_mid1" "$d_mid2" "$n_sites" "$n_sil" "$n_grow" "$RATIO" "$n_shr" "$RATIO"

    printf 'TABLE\tWent silent\twide\tnofilter\n'
    printf 'HEAD\tSubscription\tFirst-half Files\tSecond-half Files\tLast seen\tDays silent\n'
    printf 'KIND\tsite\tnum\tnum\ttext\tnum\n'
    while IFS='|' read -r _ f1 site f2 lastd dsil; do
        [ -z "$site" ] && continue
        printf 'ROW\t%s\t%s\t%s\t%s\t@{class=failed}%s\n' "$site" $((10#$f1)) "$f2" "$lastd" "$dsil"
        n_sil_rows=$((n_sil_rows + 1))
    done <<< "$(printf '%s\n' "$agg" | grep '^S|' | LC_ALL=C sort -t'|' -k2,2r -k3,3)"
    if [ "$n_sil_rows" -eq 0 ]; then
        printf 'ROW\t@{colspan=5}No subscription with %s+ first-half Files fell silent.' "$MIN_SILENT"
    fi
    printf 'NOTE\tActive with %s+ Files in the first half, then NOTHING in the window'\''s final week. Days silent counts to the dataset'\''s last day, not today. Stale Accounts tracks the same signal per ACCOUNT (against its own cadence) — this catches the per-subscription cases.\n' "$MIN_SILENT"

    printf 'TABLE\tGrowers\twide\tnofilter\n'
    printf 'HEAD\tSubscription\tFirst-half Files\tSecond-half Files\tGrowth\tFirst-half volume\tSecond-half volume\n'
    printf 'KIND\tsite\tnum\tnum\ttext\tnum\tnum\n'
    while IFS='|' read -r _ f2 site f1 ratio v1 v2; do
        [ -z "$site" ] && continue
        printf 'ROW\t%s\t%s\t%s\t%s\t%s\t%s\n' "$site" "$f1" $((10#$f2)) "$ratio" "$v1" "$v2"
        n_grow_rows=$((n_grow_rows + 1))
    done <<< "$(printf '%s\n' "$agg" | grep '^G|' | LC_ALL=C sort -t'|' -k2,2r -k3,3)"
    if [ "$n_grow_rows" -eq 0 ]; then
        printf 'ROW\t@{colspan=6}No subscription grew %sx or more (with %s+ second-half Files).' "$RATIO" "$MIN_BASE"
    fi
    printf 'NOTE\t%sx+ more Files in the second half (%s+ Files there). "new" = no first-half activity at all — a flow that started mid-window (the First Seen analysis dates every flow'\''s absolute first appearance).\n' "$RATIO" "$MIN_BASE"

    printf 'TABLE\tShrinkers\twide\tnofilter\n'
    printf 'HEAD\tSubscription\tFirst-half Files\tSecond-half Files\tShrink\tFirst-half volume\tSecond-half volume\n'
    printf 'KIND\tsite\tnum\tnum\ttext\tnum\tnum\n'
    while IFS='|' read -r _ f1 site f2 ratio v1 v2; do
        [ -z "$site" ] && continue
        printf 'ROW\t%s\t%s\t%s\t%s\t%s\t%s\n' "$site" $((10#$f1)) "$f2" "$ratio" "$v1" "$v2"
        n_shr_rows=$((n_shr_rows + 1))
    done <<< "$(printf '%s\n' "$agg" | grep '^K|' | LC_ALL=C sort -t'|' -k2,2r -k3,3)"
    if [ "$n_shr_rows" -eq 0 ]; then
        printf 'ROW\t@{colspan=6}No still-active subscription shrank %sx or more (from %s+ first-half Files).' "$RATIO" "$MIN_BASE"
    fi
    printf 'NOTE\t%sx+ fewer Files in the second half (from %s+ in the first), but still alive in the final week — a fading flow, not a dead one (those are in Went silent).\n' "$RATIO" "$MIN_BASE"

    printf 'SUMMARY\tSubscriptions: %s  |  Went silent: %s  |  Growers (%sx+): %s  |  Shrinkers (%sx+): %s  |  Window: %s → %s\n' \
        "$n_sites" "$n_sil" "$RATIO" "$n_grow" "$RATIO" "$n_shr" "$d_from" "$d_to"
    printf 'FOOT\tGenerated on %s from %s file(s)\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${#files[@]}"
} > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"

echo "Data written to $OUT (silent $n_sil, growers $n_grow, shrinkers $n_shr)." >&2
