#!/usr/bin/env bash
#
# arrived-left.sh
# How each LOGICAL transfer arrived and how it left: the protocol of its earliest
# Inbound row (how the file was received) paired with the protocol of its latest
# Outbound row (how it was forwarded). One row per (Arrived, Left) combination,
# counting logical transfers (Files) split by the delivered outcome. Because
# every transfer has exactly one arrival protocol and one departure protocol, the
# rows reconcile to the total logical transfers (no per-row double counting).
#
# Usage:
#   ./arrived-left.sh    # reads input/*.csv (via the caches), writes data/arrived-left.rpt
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib.sh"
mkdir -p "$REPORTS_DIR"
OUT="$REPORTS_DIR/arrived-left.rpt"


shopt -s nullglob
files=("$INPUT_DIR"/*.csv)
shopt -u nullglob
if [ ${#files[@]} -eq 0 ]; then
    echo "No *.csv in $INPUT_DIR — building from the EMPTY caches (config-only estate)" >&2
fi
ensure_parsed
skip_if_fresh "$OUT" "${BASH_SOURCE[0]}"
echo "Found ${#files[@]} file(s) in '$INPUT_DIR', processing..." >&2

# Join both caches: pass 1 loads the delivered outcome + start date/time/sortkey
# per CoreId from _files.tsv (1=coreid, 2=outcome, 4=date_iso, 5=time,
# 6=sortkey); pass 2 walks _transfers.tsv (1=coreid, 2=direction, 10=protocol,
# 13=sortkey) tracking each CoreId's earliest Inbound protocol (Arrived) and
# latest Outbound protocol (Left). addtop() keeps, per (Arrived,Left) pair, the
# 10 most-recent transfers (by start sortkey) for the click-to-expand list.
agg=$(awk -F'\t' '
    BEGIN { US = sprintf("%c", 31) }
    function addtop(p, sk, disp, cid,   key, n, a2, i, pos, m, out) {
        key = sk SUBSEP disp SUBSEP cid
        n = (p in top) ? split(top[p], a2, US) : 0
        pos = n + 1
        for (i = 1; i <= n; i++) if (key > a2[i]) { pos = i; break }
        if (pos > 10) return
        for (i = (n < 10 ? n : 9); i >= pos; i--) a2[i+1] = a2[i]   # shift right, cap at 10
        a2[pos] = key
        m = (n < 10) ? n + 1 : 10
        out = a2[1]; for (i = 2; i <= m; i++) out = out US a2[i]
        top[p] = out
    }
    function buildlist(s,   cc, m, i, a3, f) {          # "date time  coreid,…" newest first
        cc = ""; m = (s == "") ? 0 : split(s, a3, US)
        for (i = 1; i <= m; i++) { split(a3[i], f, SUBSEP); cc = cc (cc ? "," : "") f[2] "  " f[3] }
        return cc
    }
    NR == FNR {
                oc[$1] = $2; dt[$1] = $4; tm[$1] = $5; skf[$1] = $6; next }
    {
        cid = $1; dir = $2; proto = $10; sk = $13
        if (proto == "") proto = "UNKNOWN"
        if (dir == "Inbound")       { if (!(cid in insk)  || sk < insk[cid])  { insk[cid]  = sk; arr[cid] = proto } }
        else if (dir == "Outbound") { if (!(cid in outsk) || sk > outsk[cid]) { outsk[cid] = sk; lft[cid] = proto } }
        seen[cid] = 1
    }
    END {
        for (cid in seen) {
            a = (cid in arr) ? arr[cid] : "(none)"       # no Inbound row -> (none)
            l = (cid in lft) ? lft[cid] : "(none)"       # no Outbound row -> (none)
            key = a SUBSEP l
            cnt[key]++; ka[key] = a; kl[key] = l
            proc = (oc[cid] != "Failed" && oc[cid] != "Expired")
            if (proc) pr[key]++; else fl[key]++
            d = dt[cid]
            if (d != "") { dl[key SUBSEP d]++; dfl[key SUBSEP d] += (!proc); dpr[key SUBSEP d] += proc }
            addtop(key SUBSEP (proc ? "P" : "F"), skf[cid], (d " " tm[cid]), cid)   # per-outcome recent-10 lists
            tcnt++; if (proc) tpr++; else tfl++
        }
        for (k in dl) { split(k, x, SUBSEP); kk = x[1] SUBSEP x[2]; bk[kk] = bk[kk] (bk[kk] ? "," : "") x[3] ":" dl[k] ":" (dfl[k]+0) ":" (dpr[k]+0) }
        # per pair: buckets, then the two recent-10 lists (Failed, Processed)
        for (k in cnt) printf "X|%s|%s|%d|%d|%d|%s|%s|%s\n", ka[k], kl[k], cnt[k], fl[k]+0, pr[k]+0, bk[k], buildlist(top[k SUBSEP "F"]), buildlist(top[k SUBSEP "P"])
        printf "TOT|%d|%d|%d\n", tcnt+0, tfl+0, tpr+0
    }
' "$FILES" "$PARSED")

if [ -z "$agg" ]; then
    echo "No usable records found." >&2
    exit 1
fi

IFS='|' read -r _ tot_rec tot_failed tot_processed <<< "$(printf '%s\n' "$agg" | grep '^TOT|')"

{
    printf 'TITLE\tArrived / Left\n'
    printf 'DESC\tHow each File arrived (first Inbound protocol) and how it left (last Outbound protocol), with the delivered outcome.\n'
    printf 'INTRO\tEach **File** is counted once by how its file **arrived** — the protocol of its earliest **Inbound** row — and how it **left** — the protocol of its latest **Outbound** row. **OK/Error** is the delivered (final-row) outcome. Every File has exactly one arrival and one departure protocol, so the rows reconcile to the total. **Click an Error or OK count** to see the 10 most recent Files of that outcome (by start time).\n'
    printf 'TABLE\t\n'
    printf 'HEAD\tArrived\tLeft\tFiles\tError\tOK\n'
    printf 'KIND\ttext\ttext\tnum\tnumfailed\tnumprocessed\n'
    printf 'RECALC\t-\t-\ts0\ts1\ts2\n'
    # Crosstab rows: Arrived | Left | Files | Error | OK | buckets, most common
    # first — printed straight into the report, no per-row command substitution.
    while IFS='|' read -r _ arrived left rec fa pr bk ccf ccp; do
        [ -z "$arrived" ] && continue
        printf 'ROW\t%s\t%s\t%s\t%s\t%s\t@data:buckets=%s\t@data:coreids-failed=%s\t@data:coreids-processed=%s\n' \
            "$arrived" "$left" "$rec" "$fa" "$pr" "$bk" "$ccf" "$ccp"
    done <<< "$(printf '%s\n' "$agg" | grep '^X|' | sort -t'|' -k4,4nr)"
    printf 'TOTAL\t@{colspan=2}Files\t@{class=num}%s\t@{class=num failed}%s\t@{class=num processed}%s\n' \
        "$tot_rec" "$tot_failed" "$tot_processed"
    printf 'NOTE\tArrived = the protocol of the earliest Inbound row; Left = the protocol of the latest Outbound row. "(none)" means the File had no Inbound (or no Outbound) row. Counts are Files, so the rows reconcile to the total; OK/Error follows the delivered (final-row) outcome.\n'
    printf 'FOOT\tGenerated on %s from %s file(s)\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${#files[@]}"
} > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"

echo "Data written to $OUT ($tot_rec logical transfer(s))." >&2
