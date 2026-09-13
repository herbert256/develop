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
ensure_parsed
skip_if_fresh "$OUT" "${BASH_SOURCE[0]}"
echo "Found ${#files[@]} file(s) in '$INPUT_DIR', processing..." >&2

# ONE pass over the shared parse cache for all six tables — 2=direction,
# 3=status, 7=action_by, 9=size, 10=protocol, 11=date, 12=time, 13=sortkey,
# 20=mode, 23=transfer_id. Every table gets its per-date buckets (the date
# filter) and its 10 most-recent transfers per outcome (the drill-down).
#   PROTO|  by protocol          AB|    by action by
#   DIR|    by direction         X|     direction x action by
#   PXD|    protocol x direction MODE|  BINARY/ASCII
agg=$(awk -F'\t' "$COREIDS_AWK"'
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
        oc = f ? "F" : "P"

        pr[proto]++; pb[proto] += size; if (f) pf[proto]++; else pp[proto]++
        dr[dir]++;   db[dir] += size;   if (f) dff[dir]++;  else dpp[dir]++
        xr[xk]++; xb[xk] += size; xp[xk] = proto; xd[xk] = dir; if (f) xff[xk]++; else xpp[xk]++
        ar[ab]++; if (f) afl[ab]++; else app[ab]++
        yr[yk]++; yd[yk] = dir; ya[yk] = ab; if (f) yff[yk]++; else ypp[yk]++
        mr[mode]++; if (f) mf[mode]++; else mp[mode]++
        tr2++; tb += size; if (f) tf++; else tp++
        addtop("PRO" SUBSEP proto SUBSEP oc, $13, $11 " " $12, $23)
        addtop("DIR" SUBSEP dir   SUBSEP oc, $13, $11 " " $12, $23)
        addtop("PXD" SUBSEP xk    SUBSEP oc, $13, $11 " " $12, $23)
        addtop("AB"  SUBSEP ab    SUBSEP oc, $13, $11 " " $12, $23)
        addtop("X"   SUBSEP yk    SUBSEP oc, $13, $11 " " $12, $23)
        addtop("M"   SUBSEP mode  SUBSEP oc, $13, $11 " " $12, $23)
        if (d != "") {                                  # per-date metrics for the filter
            pdl[proto SUBSEP d]++; pdf[proto SUBSEP d] += f; pdp[proto SUBSEP d] += (!f); pdb[proto SUBSEP d] += size
            ddl[dir SUBSEP d]++;   ddf[dir SUBSEP d]  += f;  ddp[dir SUBSEP d]  += (!f); ddb[dir SUBSEP d]  += size
            xdl[xk SUBSEP d]++;    xdf[xk SUBSEP d]  += f;   xdp[xk SUBSEP d]  += (!f);  xdb[xk SUBSEP d]   += size
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
        for (k in pr) printf "PROTO|%s|%d|%d|%d|%d|%s|%s|%s|%s|%s\n", k, pr[k], pf[k]+0, pp[k]+0, pb[k], human(pb[k]), rshare(pp[k]+0), pbk[k], buildlist(top["PRO" SUBSEP k SUBSEP "F"]), buildlist(top["PRO" SUBSEP k SUBSEP "P"])
        for (k in dr) printf "DIR|%s|%d|%d|%d|%d|%s|%s|%s|%s|%s\n",   k, dr[k], dff[k]+0, dpp[k]+0, db[k], human(db[k]), rshare(dpp[k]+0), dbk[k], buildlist(top["DIR" SUBSEP k SUBSEP "F"]), buildlist(top["DIR" SUBSEP k SUBSEP "P"])
        for (k in xr) printf "PXD|%s|%s|%d|%d|%d|%d|%s|%s|%s|%s|%s\n", xp[k], xd[k], xr[k], xff[k]+0, xpp[k]+0, xb[k], human(xb[k]), rshare(xpp[k]+0), xbk[k], buildlist(top["PXD" SUBSEP k SUBSEP "F"]), buildlist(top["PXD" SUBSEP k SUBSEP "P"])
        for (k in ar) printf "AB|%s|%d|%d|%d|%s|%s|%s\n", k, ar[k], afl[k]+0, app[k]+0, abk[k], buildlist(top["AB" SUBSEP k SUBSEP "F"]), buildlist(top["AB" SUBSEP k SUBSEP "P"])
        for (k in yr) printf "X|%s|%s|%d|%d|%d|%s|%s|%s\n", yd[k], ya[k], yr[k], yff[k]+0, ypp[k]+0, ybk[k], buildlist(top["X" SUBSEP k SUBSEP "F"]), buildlist(top["X" SUBSEP k SUBSEP "P"])
        for (k in mr) printf "MODE|%s|%d|%d|%d|%s|%s|%s\n", k, mr[k], mf[k]+0, mp[k]+0, mbk[k], buildlist(top["M" SUBSEP k SUBSEP "F"]), buildlist(top["M" SUBSEP k SUBSEP "P"])
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
    printf 'DESC\tTransfers (the OK legs) and volume by protocol and direction, the direction x action-by breakdown, and the BINARY/ASCII transfer mode split — the per-leg dimensions on one page.\n'
    printf 'INTRO\t%s total volume across all protocols.\n' "$tot_human"

    # TRANSFERS = the OK legs in every table (2026-09-13, user request: one
    # Transfers column, no Error / OK pair, no green/red cells, no drills);
    # the bucket payloads keep all metrics, so the tokens read metric 2 (ok)
    # for Transfers and the share, metric 3 for Volume; rows sort by it
    printf 'TABLE\tBy protocol\tdrill=transfer\n'
    printf 'HEAD\tProtocol\tTransfers\tVolume\t%% of transfers\n'
    printf 'KIND\ttext\tnum\tnum\tnum\n'
    printf 'RECALC\t-\ts2\th3\t%%2\n'
    # key | records | failed | processed | bytes | human | share | buckets | drills
    printf '%s\n' "$agg" | grep '^PROTO|' | sort -t'|' -k5,5nr | awk -F'|' '
        $2 != "" { printf "ROW\t%s\t%s\t%s\t%s%%\t@data:buckets=%s\n", $2, $5, $7, $8, $9 }' || true
    printf 'TOTAL\tTotal\t@{class=num}%s\t@{class=num}%s\t@{class=num}100.0%%\n' "$tot_processed" "$tot_human"

    printf 'TABLE\tBy direction\tdrill=transfer\n'
    printf 'HEAD\tDirection\tTransfers\tVolume\t%% of transfers\n'
    printf 'KIND\ttext\tnum\tnum\tnum\n'
    printf 'RECALC\t-\ts2\th3\t%%2\n'
    printf '%s\n' "$agg" | grep '^DIR|' | sort -t'|' -k5,5nr | awk -F'|' '
        $2 != "" { printf "ROW\t%s\t%s\t%s\t%s%%\t@data:buckets=%s\n", $2, $5, $7, $8, $9 }' || true
    printf 'TOTAL\tTotal\t@{class=num}%s\t@{class=num}%s\t@{class=num}100.0%%\n' "$tot_processed" "$tot_human"

    printf 'TABLE\tProtocol × direction\tdrill=transfer\n'
    printf 'HEAD\tProtocol\tDirection\tTransfers\tVolume\t%% of transfers\n'
    printf 'KIND\ttext\ttext\tnum\tnum\tnum\n'
    printf 'RECALC\t-\t-\ts2\th3\t%%2\n'
    printf '%s\n' "$agg" | grep '^PXD|' | sort -t'|' -k6,6nr | awk -F'|' '
        $2 != "" { printf "ROW\t%s\t%s\t%s\t%s\t%s%%\t@data:buckets=%s\n", $2, $3, $6, $8, $9, $10 }' || true
    printf 'TOTAL\t@{colspan=2}Total\t@{class=num}%s\t@{class=num}%s\t@{class=num}100.0%%\n' "$tot_processed" "$tot_human"

    printf 'NOTE\tCounts individual transfers (legs), not Files: one File has an Inbound row (e.g. ssh) and an Outbound row (e.g. pesit), so protocol/direction are per leg.\n'

    # ---- Direction x Action By (formerly direction-action.sh, absorbed 2026-07)
    printf 'INTRO\tTransfer legs by **Direction** (Inbound/Outbound), by **Action By**, and their crosstab — the OK legs. Counts physical **Transfers** — one per log row — so one File'\''s inbound and outbound legs count once each.\n'

    printf 'TABLE\tBy action by\tdrill=transfer\n'
    printf 'HEAD\tAction By\tTransfers\n'
    printf 'KIND\ttext\tnum\n'
    printf 'RECALC\t-\ts2\n'
    printf '%s\n' "$agg" | grep '^AB|' | sort -t'|' -k5,5nr | awk -F'|' '
        $2 != "" { printf "ROW\t%s\t%s\t@data:buckets=%s\n", $2, $5, $6 }' || true
    printf 'TOTAL\tTotal\t@{class=num}%s\n' "$tot_processed"

    printf 'TABLE\tDirection x action by\tdrill=transfer\n'
    printf 'HEAD\tDirection\tAction By\tTransfers\n'
    printf 'KIND\ttext\ttext\tnum\n'
    printf 'RECALC\t-\t-\ts2\n'
    printf '%s\n' "$agg" | grep '^X|' | sort -t'|' -k6,6nr | awk -F'|' '
        $2 != "" { printf "ROW\t%s\t%s\t%s\t@data:buckets=%s\n", $2, $3, $6, $7 }' || true
    printf 'TOTAL\t@{colspan=2}Total\t@{class=num}%s\n' "$tot_processed"

    printf 'NOTE\tCounts individual transfers (legs), not Files: direction and action-by are per leg (a File has an Inbound and an Outbound row).\n'

    # ---- Transfer mode BINARY/ASCII (formerly mode.sh, absorbed 2026-07) -----
    printf 'INTRO\tHow transfers moved their files, from the log **Mode** column: **BINARY** vs **ASCII**. Counts are per transfer.\n'
    printf 'TABLE\t\tdrill=transfer\n'
    printf 'HEAD\tMode\tTransfers\n'
    printf 'KIND\ttext\tnum\n'
    printf 'RECALC\t-\ts2\n'
    printf '%s\n' "$agg" | grep '^MODE|' | sort -t'|' -k5,5nr | awk -F'|' '
        $2 != "" { printf "ROW\t%s\t%s\t@data:buckets=%s\n", $2, $5, $6 }' || true
    printf 'TOTAL\tTotal\t@{class=num}%s\n' "$tot_processed"
    printf 'NOTE\tCounts individual transfers (legs), not Files: Mode is a per-leg attribute.\n'

    printf 'SUMMARY\tTotal transfers: %s  |  Total volume: %s\n' "$tot_rec" "$tot_human"
    printf 'FOOT\tGenerated on %s from %s file(s)\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${#files[@]}"
} > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"

echo "Data written to $OUT ($tot_rec record(s))." >&2
