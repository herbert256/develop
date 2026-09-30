#!/usr/bin/env bash
#
# protocol.sh
# Breaks Axway FlowManager transfers down by PROTOCOL (field 20: pesit, ssh,
# ftp, routing, ...) and by DIRECTION (field 8: Inbound/Outbound), showing
# record counts (the OK legs since 2026-09-13) and data volume, plus a protocol x
# direction crosstab. "Failed Subtransmission" is folded into "Failed".
# The page also carries the direction x action-by breakdown (formerly
# direction-action.sh) and the BINARY/ASCII mode split (formerly mode.sh),
# absorbed 2026-07 — all three read the same per-leg columns, so ONE pass over
# the parse cache emits every table's aggregate as a tagged line.
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

# ONE pass over the shared parse cache for all six tables — 2=direction,
# 3=status, 7=action_by, 9=size, 10=protocol, 11=date, 12=time, 13=sortkey,
# 20=mode. Every table gets its per-date buckets (the date filter). (The 10
# most-recent transfers per outcome — the drill payloads — went 2026-09-30:
# no table has shipped a drill since 2026-09-13, and six addtop calls per leg
# were the costliest part of the pass.)
#   PROTO|  by protocol          AB|    by action by
#   DIR|    by direction         X|     direction x action by
#   PXD|    protocol x direction MODE|  BINARY/ASCII
agg=$(awk -F'\t' '
    function human(b,   u, i, v) {
        split("B KB MB GB TB PB", u, " ")
        i = 1; v = b + 0
        while (v >= 1024 && i < 6) { v /= 1024; i++ }
        if (i == 1) return sprintf("%d %s", v, u[i])
        return sprintf("%.2f %s", v, u[i])
    }
    {
        status = $3; sub(/ Subtransmission$/, "", status); f = (status != "Processed")
        dir = $2; proto = $10; size = $9; d = $11; ab = $7; mode = $20
        if (proto == "") proto = "UNKNOWN"
        if (dir == "") dir = "UNKNOWN"
        if (ab == "")  ab = "UNKNOWN"
        if (mode == "" || mode == "unknown") mode = "UNKNOWN"   # fold the cache lowercase "unknown" into one casing
        xk = proto SUBSEP dir       # protocol x direction
        yk = dir SUBSEP ab          # direction x action by

        # VOLUME = the OK legs'"'"' bytes, the Transfers column'"'"'s own scope
        # (2026-09-29: every leg'"'"'s bytes beside an OK-only count)
        okb = f ? 0 : size
        pr[proto]++; pb[proto] += okb; if (f) pf[proto]++; else pp[proto]++
        dr[dir]++;   db[dir] += okb;   if (f) dff[dir]++;  else dpp[dir]++
        xr[xk]++; xb[xk] += okb; xp[xk] = proto; xd[xk] = dir; if (f) xff[xk]++; else xpp[xk]++
        ar[ab]++; if (f) afl[ab]++; else app[ab]++
        yr[yk]++; yd[yk] = dir; ya[yk] = ab; if (f) yff[yk]++; else ypp[yk]++
        mr[mode]++; if (f) mf[mode]++; else mp[mode]++
        tr2++; tb += okb; if (f) tf++; else tp++
        if (d != "") {                                  # per-date metrics for the filter
            pdl[proto SUBSEP d]++; pdf[proto SUBSEP d] += f; pdp[proto SUBSEP d] += (!f); pdb[proto SUBSEP d] += okb
            ddl[dir SUBSEP d]++;   ddf[dir SUBSEP d]  += f;  ddp[dir SUBSEP d]  += (!f); ddb[dir SUBSEP d]  += okb
            xdl[xk SUBSEP d]++;    xdf[xk SUBSEP d]  += f;   xdp[xk SUBSEP d]  += (!f);  xdb[xk SUBSEP d]   += okb
            adl[ab SUBSEP d]++;    adf[ab SUBSEP d]  += f;   adp[ab SUBSEP d]  += (!f)
            ydl[yk SUBSEP d]++;    ydf[yk SUBSEP d]  += f;   ydp[yk SUBSEP d]  += (!f)
            mdl[mode SUBSEP d]++;  mdf[mode SUBSEP d] += f;  mdp[mode SUBSEP d] += (!f)
        }
    }
    # the share is over the OK legs (2026-09-13, user request: the one
    # Transfers column of every table is the OK count — no Error / OK pair)
    function rshare(x) { return tp > 0 ? sprintf("%.1f", x * 100 / tp) : "0.0" }
    END {
        for (k in pdl) { split(k, a, SUBSEP); pbk[a[1]] = pbk[a[1]] (pbk[a[1]] ? "," : "") a[2] ":" pdl[k] ":" (pdf[k]+0) ":" (pdp[k]+0) ":" pdb[k] }
        for (k in ddl) { split(k, a, SUBSEP); dbk[a[1]] = dbk[a[1]] (dbk[a[1]] ? "," : "") a[2] ":" ddl[k] ":" (ddf[k]+0) ":" (ddp[k]+0) ":" ddb[k] }
        for (k in xdl) { split(k, a, SUBSEP); kk2 = a[1] SUBSEP a[2]; xbk[kk2] = xbk[kk2] (xbk[kk2] ? "," : "") a[3] ":" xdl[k] ":" (xdf[k]+0) ":" (xdp[k]+0) ":" xdb[k] }
        for (k in adl) { split(k, a, SUBSEP); abk[a[1]] = abk[a[1]] (abk[a[1]] ? "," : "") a[2] ":" adl[k] ":" (adf[k]+0) ":" (adp[k]+0) }
        for (k in ydl) { split(k, a, SUBSEP); kk2 = a[1] SUBSEP a[2]; ybk[kk2] = ybk[kk2] (ybk[kk2] ? "," : "") a[3] ":" ydl[k] ":" (ydf[k]+0) ":" (ydp[k]+0) }
        for (k in mdl) { split(k, a, SUBSEP); mbk[a[1]] = mbk[a[1]] (mbk[a[1]] ? "," : "") a[2] ":" mdl[k] ":" (mdf[k]+0) ":" (mdp[k]+0) }
        for (k in pr) printf "PROTO|%s|%d|%d|%d|%d|%s|%s|%s\n", k, pr[k], pf[k]+0, pp[k]+0, pb[k], human(pb[k]), rshare(pp[k]+0), pbk[k]
        for (k in dr) printf "DIR|%s|%d|%d|%d|%d|%s|%s|%s\n",   k, dr[k], dff[k]+0, dpp[k]+0, db[k], human(db[k]), rshare(dpp[k]+0), dbk[k]
        for (k in xr) printf "PXD|%s|%s|%d|%d|%d|%d|%s|%s|%s\n", xp[k], xd[k], xr[k], xff[k]+0, xpp[k]+0, xb[k], human(xb[k]), rshare(xpp[k]+0), xbk[k]
        for (k in ar) printf "AB|%s|%d|%d|%d|%s\n", k, ar[k], afl[k]+0, app[k]+0, abk[k]
        for (k in yr) printf "X|%s|%s|%d|%d|%d|%s\n", yd[k], ya[k], yr[k], yff[k]+0, ypp[k]+0, ybk[k]
        for (k in mr) printf "MODE|%s|%d|%d|%d|%s\n", k, mr[k], mf[k]+0, mp[k]+0, mbk[k]
        printf "TOT|%d|%d|%d|%d|%s\n", tr2, tf+0, tp+0, tb, human(tb)
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
    printf 'DESC\tTransfers (the OK legs) and volume by protocol × direction, the direction × action-by breakdown, and the BINARY/ASCII transfer mode split — the per-leg dimensions on one page.\n'

    # TRANSFERS = the OK legs in every table (2026-09-13, user request: one
    # Transfers column, no Error / OK pair, no green/red cells, no drills) —
    # headed "OK transfers" since 2026-09-30 (Security outreach, a sibling in
    # the group, counts EVERY leg under plain "Transfers");
    # the bucket payloads keep all metrics, so the tokens read metric 2 (ok)
    # for Transfers and the share, metric 3 for Volume; rows sort by it
    # (the By protocol and By direction tables went 2026-09-29: their rows are
    # the subtotals of Protocol × direction)
    printf 'TABLE\tProtocol × direction\n'
    printf 'HEAD\tProtocol\tDirection\tOK transfers\tVolume\t%% of OK transfers\n'
    printf 'KIND\ttext\ttext\tnum\tnum\tnum\n'
    printf 'RECALC\t-\t-\ts2\th3\t%%2\n'
    printf '%s\n' "$agg" | grep '^PXD|' | sort -t'|' -k6,6nr | awk -F'|' '
        $2 != "" && $6 + 0 > 0 { printf "ROW\t%s\t%s\t%s\t%s\t%s%%\t@data:buckets=%s\n", $2, $3, $6, $8, $9, $10 }' || true   # a pair with no OK leg: nothing this table counts (2026-09-29)
    printf 'TOTAL\t@{colspan=2}Total\t@{class=num}%s\t@{class=num}%s\t@{class=num}100.0%%\n' "$tot_processed" "$tot_human"


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
