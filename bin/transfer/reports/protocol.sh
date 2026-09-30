#!/usr/bin/env bash
#
# protocol.sh
# The OK transfer legs by DIRECTION x ACTION BY (formerly direction-action.sh)
# and the BINARY/ASCII mode split (formerly mode.sh), absorbed 2026-07 — both
# read the same per-leg columns, so ONE pass over the parse cache emits every
# table's aggregate as a tagged line. "Failed Subtransmission" is folded
# into "Failed". (The Protocol x direction table and its page
# protocol-protocol-direction.html went 2026-09-30, user request: "Delete
# report transfer/protocol-protocol-direction.html" — with the per-protocol,
# per-direction and per-action-by aggregates no table had read since the
# one-dimension tables went, 2026-09-29.)
#
# Usage:
#   ./protocol.sh    # reads input/*.csv (via the cache), writes data/protocol.rpt
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib.sh"
mkdir -p "$REPORTS_DIR"
OUT="$REPORTS_DIR/protocol.rpt"


shopt -s nullglob
files=("$INPUT_DIR"/*.csv)
shopt -u nullglob
if [ ${#files[@]} -eq 0 ]; then
    echo "No *.csv in $INPUT_DIR — building from the EMPTY caches (config-only estate)" >&2
fi
echo "Found ${#files[@]} file(s) in '$INPUT_DIR', processing..." >&2

# ONE pass over the shared parse cache for both tables — 2=direction,
# 3=status, 7=action_by, 9=size, 11=date, 20=mode. Every table gets its
# per-date buckets (the date filter).
#   X|     direction x action by        MODE|  BINARY/ASCII
agg=$(awk -F'\t' "$AWKLIB"'
    {
        status = $3; sub(/ Subtransmission$/, "", status); f = (status != "Processed")
        dir = $2; size = $9; d = $11; ab = $7; mode = $20
        if (dir == "") dir = "UNKNOWN"
        if (ab == "")  ab = "UNKNOWN"
        if (mode == "" || mode == "unknown") mode = "UNKNOWN"   # fold the cache lowercase "unknown" into one casing
        yk = dir SUBSEP ab          # direction x action by

        # VOLUME = the OK legs'"'"' bytes, the Transfers column'"'"'s own scope
        # (2026-09-29: every leg'"'"'s bytes beside an OK-only count)
        okb = f ? 0 : size
        yr[yk]++; yd[yk] = dir; ya[yk] = ab; if (f) yff[yk]++; else ypp[yk]++
        mr[mode]++; if (f) mf[mode]++; else mp[mode]++
        tr2++; tb += okb; if (f) tf++; else tp++
        if (d != "") {                                  # per-date metrics for the filter
            ydl[yk SUBSEP d]++;    ydf[yk SUBSEP d]  += f;   ydp[yk SUBSEP d]  += (!f)
            mdl[mode SUBSEP d]++;  mdf[mode SUBSEP d] += f;  mdp[mode SUBSEP d] += (!f)
        }
    }
    END {
        for (k in ydl) { split(k, a, SUBSEP); kk2 = a[1] SUBSEP a[2]; ybk[kk2] = ybk[kk2] (ybk[kk2] ? "," : "") a[3] ":" ydl[k] ":" (ydf[k]+0) ":" (ydp[k]+0) }
        for (k in mdl) { split(k, a, SUBSEP); mbk[a[1]] = mbk[a[1]] (mbk[a[1]] ? "," : "") a[2] ":" mdl[k] ":" (mdf[k]+0) ":" (mdp[k]+0) }
        for (k in yr) printf "X|%s|%s|%d|%d|%d|%s\n", yd[k], ya[k], yr[k], yff[k]+0, ypp[k]+0, ybk[k]
        for (k in mr) printf "MODE|%s|%d|%d|%d|%s\n", k, mr[k], mf[k]+0, mp[k]+0, mbk[k]
        printf "TOT|%d|%d|%d|%d|%s\n", tr2, tf+0, tp+0, tb, hbytes2(tb)
    }
' "$PARSED")

if [ -z "$agg" ]; then
    echo "No usable records found." >&2
    exit 1
fi

IFS='|' read -r _ tot_rec tot_failed tot_processed tot_bytes tot_human <<< "$(printf '%s\n' "$agg" | grep '^TOT|')"

# Every row block is formatted by awk straight into the .rpt (one fork per
# table, not one per row): grep picks the tag, sort orders it, awk shapes the
# ROW lines. `|| true` keeps a tag with no lines at all from tripping pipefail.
{
    printf 'TITLE\tProtocol, Direction & Mode\n'
    printf 'DESC\tTransfers (the OK legs) by direction × action by, and the BINARY/ASCII transfer mode split — the per-leg dimensions on one page.\n'

    # TRANSFERS = the OK legs in every table (2026-09-13, user request: one
    # Transfers column, no Error / OK pair, no green/red cells, no drills) —
    # headed "OK transfers" since 2026-09-30 (Security outreach, a sibling in
    # the group, counts EVERY leg under plain "Transfers"); the bucket
    # payloads keep all metrics, so the tokens read metric 2 (ok); rows sort by it

    # ---- Direction x Action By (formerly direction-action.sh, absorbed 2026-07)
    # (the By action by table went 2026-09-29: the subtotals of Direction x
    # action by)
    printf 'TABLE\tDirection x action by\n'
    printf 'HEAD\tDirection\tAction By\tOK transfers\n'
    printf 'KIND\ttext\ttext\tnum\n'
    printf 'RECALC\t-\t-\ts2\n'
    printf '%s\n' "$agg" | grep '^X|' | sort -t'|' -k6,6nr | awk -F'|' '
        $2 != "" && $6 + 0 > 0 { printf "ROW\t%s\t%s\t%s\t@data:buckets=%s\n", $2, $3, $6, $7 }' || true   # no OK leg: nothing this table counts
    printf 'TOTAL\t@{colspan=2}Total\t@{class=num}%s\n' "$tot_processed"


    # ---- Transfer mode BINARY/ASCII (formerly mode.sh, absorbed 2026-07) -----
    printf 'TABLE\t\n'
    printf 'HEAD\tMode\tOK transfers\n'
    printf 'KIND\ttext\tnum\n'
    printf 'RECALC\t-\ts2\n'
    printf '%s\n' "$agg" | grep '^MODE|' | sort -t'|' -k5,5nr | awk -F'|' '
        $2 != "" && $5 + 0 > 0 { printf "ROW\t%s\t%s\t@data:buckets=%s\n", $2, $5, $6 }' || true   # no OK leg: nothing this table counts
    printf 'TOTAL\tTotal\t@{class=num}%s\n' "$tot_processed"

    # the tables' own scope — the OK legs and their bytes (2026-09-29: the
    # summary counted EVERY leg beside the OK-only volume and tables)
    printf 'SUMMARY\tOK transfers: %s  |  OK volume: %s\n' "$tot_processed" "$tot_human"
    printf 'FOOT\n'
} > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"

echo "Data written to $OUT ($tot_rec record(s))." >&2
