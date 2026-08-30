#!/usr/bin/env bash
#
# attempts.sh — "Attempts to success": retry anatomy from each File's leg
# sequence. A File's FAILED LEGS (status != Processed) are its wasted
# attempts; the delivered outcome says whether trying eventually helped.
#   - delivered Files by failed-leg count (0 = clean first try)
#   - failed/expired Files by failed-leg count (how hard we tried before
#     giving up; an Expired file can show 0 — every leg processed, the
#     partner just never collected)
#   - the spacing between a failed leg and the NEXT attempt (the backoff
#     curve: instant hammering vs scheduled re-runs)
#   - which direction the failed legs sit on
#
# Usage:
#   ./attempts.sh   # reads input/*.csv (via the caches), writes data/attempts.rpt
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib.sh"
mkdir -p "$REPORTS_DIR"
OUT="$REPORTS_DIR/attempts.rpt"

shopt -s nullglob
files=("$INPUT_DIR"/*.csv)
shopt -u nullglob
if [ ${#files[@]} -eq 0 ]; then
    echo "No *.csv in $INPUT_DIR — building from the EMPTY caches (config-only estate)" >&2
fi
ensure_parsed
skip_if_fresh "$OUT" "${BASH_SOURCE[0]}"
echo "Found ${#files[@]} file(s) in '$INPUT_DIR', processing..." >&2

# Pass 1 = $FILES (outcome/date per CoreId), pass 2 = $PARSED sorted
# chronologically (coreid, sortkey). Failed leg = status != Processed
# ("Failed Subtransmission" folds in). Gap = failed leg start -> next leg
# start (jdn*86400 + time-of-day seconds; ms ignored).
agg=$( { cat "$FILES"; printf '###SPLIT###\n'; LC_ALL=C sort -t"$(printf '\t')" -k1,1 -k13,13 "$PARSED"; } | awk -F'\t' "$COREIDS_AWK"'
    function hsec(t,   a) { if (t == "") return 0; split(t, a, "[:.]"); return a[1]*3600 + a[2]*60 + a[3] }
    function nbucket(n) { if (n <= 5) return n; if (n <= 10) return 6; return 7 }
    function gbucket(s) {
        if (s < 10) return 1; if (s < 60) return 2; if (s < 600) return 3
        if (s < 3600) return 4; if (s < 86400) return 5; return 6
    }
    function flush(   ok, b, d) {
        if (cur == "") return
        if (!(cur in FOUT)) { reset(); return }
        ok = !(FOUT[cur] == "Failed" || FOUT[cur] == "Expired")
        b = nbucket(nf)
        d = FDT[cur]
        if (ok) { sr[b]++; ts++
                  if (d != "") sdb[b SUBSEP d]++
                  addtop("S" SUBSEP b, FSK[cur], FDT[cur] " " FTM[cur], cur) }
        else    { gr[b]++; tg++
                  if (d != "") gdb[b SUBSEP d]++
                  addtop("G" SUBSEP b, FSK[cur], FDT[cur] " " FTM[cur], cur) }
        reset()
    }
    function reset() { cur = ""; nf = 0; prevfail = 0; prevt = 0 }
    /^###SPLIT###$/ { mode = 1; next }
    mode == 0 { FOUT[$1] = $2; FDT[$1] = $4; FTM[$1] = $5; FSK[$1] = $6 ; next }
    {
        if ($1 != cur) { flush(); cur = $1 }
        t = ($14 + 0) * 86400 + hsec($12)
        if (prevfail) {   # gap from the failed leg to THIS attempt
            g = t - prevt; if (g < 0) g = 0
            gb = gbucket(g); gapc[gb]++; gapf[gb SUBSEP cur] = 1
            if (pfd != "") gapd[gb SUBSEP pfd]++
        }
        st = $3; sub(/ Subtransmission$/, "", st)
        if (st != "Processed") {
            nf++
            dir = ($2 == "") ? "?" : $2
            fdir[dir]++; fdirf[dir SUBSEP cur] = 1
            if ($11 != "") fdird[dir SUBSEP $11]++
            prevfail = 1; pfd = $11
        } else prevfail = 0
        prevt = t
    }
    END {
        flush()
        split("first try (0 failed legs)|1 failed leg|2 failed legs|3 failed legs|4 failed legs|5 failed legs|6 - 10 failed legs|> 10 failed legs", nlab, "|")
        for (k in sdb) { split(k, a, SUBSEP); sbk[a[1]] = sbk[a[1]] (sbk[a[1]] ? "," : "") a[2] ":" sdb[k] }
        for (k in gdb) { split(k, a, SUBSEP); gbk[a[1]] = gbk[a[1]] (gbk[a[1]] ? "," : "") a[2] ":" gdb[k] }
        for (b = 0; b <= 7; b++) {
            if (sr[b] + 0 > 0) printf "SUC|%d|%s|%d|%s|%s|%s\n", b, nlab[b+1], sr[b], (ts ? sprintf("%.1f", sr[b]*100/ts) : "0.0"), sbk[b], buildlist(top["S" SUBSEP b])
            if (gr[b] + 0 > 0) printf "GVE|%d|%s|%d|%s|%s|%s\n", b, nlab[b+1], gr[b], (tg ? sprintf("%.1f", gr[b]*100/tg) : "0.0"), gbk[b], buildlist(top["G" SUBSEP b])
        }
        split("< 10 s (hammering)|10 s - 1 min|1 - 10 min|10 min - 1 h|1 - 24 h|> 24 h", glab, "|")
        for (k in gapd) { split(k, a, SUBSEP); kbk[a[1]] = kbk[a[1]] (kbk[a[1]] ? "," : "") a[2] ":" gapd[k] }
        for (b = 1; b <= 6; b++) {
            if (gapc[b] + 0 == 0) continue
            nfl = 0; for (k in gapf) { split(k, a, SUBSEP); if (a[1] == b) nfl++ }
            printf "GAP|%d|%s|%d|%d|%s\n", b, glab[b], gapc[b], nfl, kbk[b]
        }
        for (dir in fdir) {
            nfl = 0; for (k in fdirf) { split(k, a, SUBSEP); if (a[1] == dir) nfl++ }
            dbk = ""
            for (k in fdird) { split(k, a, SUBSEP); if (a[1] == dir) dbk = dbk (dbk ? "," : "") a[2] ":" fdird[k] }
            printf "DIR|%s|%d|%d|%s\n", dir, fdir[dir], nfl, dbk
        }
        printf "TOT|%d|%d\n", ts+0, tg+0
    }
')

if [ -z "$agg" ]; then
    echo "No usable records found." >&2
    exit 1
fi

IFS='|' read -r _ tot_ok tot_gave <<< "$(printf '%s\n' "$agg" | grep '^TOT|')"

mkrows() {   # $1 = SUC|GVE — writes its ROW lines straight to stdout
    local tag=$1 b lab rec sh bk dr
    while IFS='|' read -r _ b lab rec sh bk dr; do
        [ -z "$lab" ] && continue
        printf 'ROW\t%s\t%s\t%s%%\t@data:buckets=%s\t@data:coreids=%s\t@data:ord=%s\n' "$lab" "$rec" "$sh" "$bk" "$dr" "$b"
    done <<< "$(printf '%s\n' "$agg" | grep "^$tag|" | sort -t'|' -k2,2n)"
}

# The two remaining row loops also carry a bash counter for their TOTAL line, so
# they run INSIDE the report block (a herestring keeps them in this shell) and
# the counter is ready by the time the TOTAL below it is printed.
tot_ret=0
tot_legs=0

{
    printf 'TITLE\tAttempts to Success\n'
    printf 'DESC\tRetry anatomy: how many failed legs before delivery (or before giving up), the retry spacing, and which side fails.\n'
    printf 'KEYWORDS\tretry, attempts, backoff, failed legs, gave up, hammering, retry spacing\n'
    printf 'INTRO\tEach File'\''s **failed legs** (status other than Processed) are its wasted attempts; the delivered outcome says whether trying helped. **%s** Files delivered, **%s** ended Error/Expired.\n' "$tot_ok" "$tot_gave"

    printf 'TABLE\tDelivered Files — failed legs before success\tdrill=File\n'
    printf 'HEAD\tAttempts\tFiles\t%% of delivered\n'
    printf 'KIND\ttext\tnum\tnum\n'
    printf 'RECALC\t-\ts0\t%%0\n'
    mkrows SUC
    printf 'TOTAL\tTotal\t@{class=num}%s\t@{class=num}100.0%%\n' "$tot_ok"
    printf 'NOTE\tOnly Files that DELIVERED (incl. Waiting). Click a row for that bucket'\''s 10 most recent Files. A big "first try" row is healthy; weight further down means the platform delivers by insisting.\n'

    printf 'TABLE\tGave up — failed legs on Error / Expired Files\tdrill=File\n'
    printf 'HEAD\tAttempts\tFiles\t%% of failed\n'
    printf 'KIND\ttext\tnum\tnum\n'
    printf 'RECALC\t-\ts0\t%%0\n'
    mkrows GVE
    printf 'TOTAL\tTotal\t@{class=num}%s\t@{class=num}100.0%%\n' "$tot_gave"
    printf 'NOTE\tFiles that ended **Error or Expired**. "first try (0 failed legs)" here is mostly the **Expired** population — every leg processed, the partner just never collected the staged file.\n'

    printf 'TABLE\tRetry spacing — failed leg to the next attempt\n'
    printf 'HEAD\tGap\tRetries\tFiles\n'
    printf 'KIND\ttext\tnum\tnum\n'
    printf 'RECALC\t-\ts0\t-\n'
    while IFS='|' read -r _ b lab cnt nfl bk; do
        [ -z "$lab" ] && continue
        printf 'ROW\t%s\t%s\t%s\t@data:buckets=%s\t@data:ord=%s\n' "$lab" "$cnt" "$nfl" "$bk" "$b"
        tot_ret=$((tot_ret + cnt))
    done <<< "$(printf '%s\n' "$agg" | grep '^GAP|' | sort -t'|' -k2,2n)"
    printf 'TOTAL\tTotal\t@{class=num}%s\t\n' "$tot_ret"
    printf 'NOTE\tThe time from a failed leg'\''s start to the NEXT leg of the same File. Under 10 seconds = automatic hammering; minutes/hours = scheduled re-runs; the Files column is full-period under a narrowed date range.\n'

    printf 'TABLE\tWhich side fails\n'
    printf 'HEAD\tDirection\tFailed legs\tFiles\n'
    printf 'KIND\ttext\tnum\tnum\n'
    printf 'RECALC\t-\ts0\t-\n'
    while IFS='|' read -r _ dir cnt nfl bk; do
        [ -z "$dir" ] && continue
        printf 'ROW\t%s\t%s\t%s\t@data:buckets=%s\n' "$dir" "$cnt" "$nfl" "$bk"
        tot_legs=$((tot_legs + cnt))
    done <<< "$(printf '%s\n' "$agg" | grep '^DIR|' | sort -t'|' -k1,1)"
    printf 'TOTAL\tTotal\t@{class=num}%s\t\n' "$tot_legs"
    printf 'NOTE\tInbound = the arrival side (partner/CFT delivering to ST); Outbound = the delivery side (ST pushing onward, or the partner collecting). The Files column is full-period under a narrowed date range.\n'

    printf 'SUMMARY\tDelivered: %s | Gave up: %s\n' "$tot_ok" "$tot_gave"
    printf 'FOOT\tGenerated on %s from %s file(s)\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${#files[@]}"
} > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"

echo "Data written to $OUT ($tot_ok + $tot_gave File(s))." >&2
