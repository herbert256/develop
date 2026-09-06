#!/usr/bin/env bash
#
# duration.sh
# Looks at transfer DURATION from several angles, over the LOGICAL transfers
# (data/_files.tsv, one row per CoreId). Duration is _files.tsv col 9 (dur_ms) —
# the transfer's WALL-CLOCK span in milliseconds (first row's start to the last
# row's end, gaps included), NOT the sum of the row durations.
#
# FOUR views along two selectors (each pair of buttons is a NAV group):
#   "OK transfers" / "All transfers" — the scope:
#     OK  = outcome Processed only (the default). Error transfers (mostly
#           instant 0-byte attempts) are excluded so they do not flatten
#           every statistic.
#     All = every outcome with a measured duration, so a failed transfer's
#           run time (e.g. a 2h timeout) counts too.
#   "Percentage" / "Min/Avg/Max" — the per-day table's columns:
#     Percentage  = p10 / p25 / p50 / p75 / p90 / p95 / p98 / p99 / p100
#                   (the default; p100 = the day's longest File, the Max of
#                   the other view — added 2026-09-06, user request).
#     Min/Avg/Max = Min / Avg / Median / Max per day.
#   - duration.rpt             OK  + Percentage
#   - duration-minmax.rpt      OK  + Min/Avg/Max
#   - duration-all.rpt         All + Percentage
#   - duration-all-minmax.rpt  All + Min/Avg/Max
#   The three siblings render beside duration.html, not as separate
#   menu/index entries.
#
# Table (per view): the per-day stats — the one table that differs between
# the two column views. (The Top 50 longest Files and the duration
# distribution moved to their own Performance pages 2026-09-03 —
# duration-longest.sh, duration-distribution.sh — and the slowest
# subscriptions by p95 on 2026-09-05: duration-slowest.sh.)
#
# The per-day stat columns are NOT additive across days, so they are marked
# `noagg`: each day keeps its own value but a narrowed date range blanks their
# total. The Files count IS additive and re-totals.
#
# Usage:
#   ./duration.sh    # reads input/*.csv (via the cache), writes data/duration{,-all}.rpt
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib.sh"
mkdir -p "$REPORTS_DIR"

# (TOP_N — the longest Files list — moved to duration-longest.sh 2026-09-03;
# TOP_SUB — the slowest subscriptions — to duration-slowest.sh 2026-09-05)

shopt -s nullglob
files=("$INPUT_DIR"/*.csv)
shopt -u nullglob
if [ ${#files[@]} -eq 0 ]; then
    echo "No *.csv in $INPUT_DIR — building from the EMPTY caches (config-only estate)" >&2
fi
ensure_parsed
# one script, FOUR outputs — skip
# only when BOTH rpts are fresh and the top dir exists (pda-entities pattern)
_dur_fresh=1
for _f in "$REPORTS_DIR/duration.rpt" "$REPORTS_DIR/duration-minmax.rpt" \
          "$REPORTS_DIR/duration-all.rpt" "$REPORTS_DIR/duration-all-minmax.rpt"; do
    if ! { [ -f "$_f" ] && ! [ "$PARSED" -nt "$_f" ] && ! [ "$FILES" -nt "$_f" ] && ! [ "${BASH_SOURCE[0]}" -nt "$_f" ]; }; then
        _dur_fresh=0; break
    fi
done
if [ "$_dur_fresh" = 1 ]; then
    echo "  the four duration .rpt files are up to date; skipping." >&2
    exit 0
fi
unset _dur_fresh _f
echo "Found ${#files[@]} file(s) in '$INPUT_DIR', processing..." >&2

# Every duration/size cell is spelled out by the awk that computes it —
# humandur() and hd() in the main pass, humandur()/humanbytes() in the top-N pass —
# and travels to bash as an extra field on the O, S and top-N lines. There are no
# bash formatting helpers: they forked an awk per cell, ~350 execs per view.
# humandur() is the site-wide spelling (report.js humanDur matches it exactly);
# hd() is the per-day table's WHOLE-UNIT spelling, deliberately coarser.

# ---- build one scope (two outputs) --------------------------------------------
# Parameters via the calls below: OKONLY (1 = Processed only), OUT_MM/OUT_PP
# (the Min/Avg/Max and Percentage .rpt of this scope), NAV_MM/NAV_PP (the two
# button rows: OK/All then
# Min-Avg-Max/Percentage), and the scope words for the DESC/INTRO/NOTE.
build_view() {
    local OKONLY=$1 OUT_MM=$2 OUT_PP=$3 NAV_MM=$4 NAV_PP=$5 SCOPE_DESC=$6 SCOPE_INTRO=$7 SCOPE_NOTE=$8

    # main pass: per-day + distribution stats. Tagged col 1:
    # 1=per-day min/avg/max, 2=per-day percentiles, D=distribution,
    # O=overall. (S=subscription left with duration-slowest.sh, 2026-09-05.) OKONLY drops non-Processed Files (the "OK transfers" view).
    local agg; agg=$(awk -F'\t' -v okonly="$OKONLY" '
        function humandur(ms) {
            if (ms < 1000)    return sprintf("%d ms", ms)
            if (ms < 60000)   return sprintf("%.2f s", ms/1000)
            if (ms < 3600000) return sprintf("%.1f min", ms/60000)
            return sprintf("%.2f h", ms/3600000)
        }
        # The per-day table spells its durations in WHOLE units — no milliseconds
        # and no decimals, so a 12-column wide table stays scannable. Sub-second
        # values render "<1 s" rather than "0 s", which would read as no duration
        # at all (the Min column is sub-second on most days).
        function hd(ms) {
            ms = ms + 0
            if (ms < 0)       return "-"
            if (ms < 1000)    return "<1 s"
            if (ms < 60000)   return sprintf("%d s", int(ms/1000 + 0.5))
            if (ms < 3600000) return sprintf("%d m", int(ms/60000 + 0.5))
            return sprintf("%d h", int(ms/3600000 + 0.5))
        }
        # hdc() is hd() plus the cell class: the UNIT carries the tint, so a
        # column reads at a glance — seconds green, minutes orange, hours (and
        # days, should a tier ever be added) red. "<1 s" ends in "s", so it
        # tints green like every other sub-minute cell. Deliberately NOT "num
        # dur-x": the renderer adds num itself for a numeric KIND — on a ROW
        # unconditionally — so spelling it here yields class="num num dur-s".
        function hdc(ms,   v, u) {
            v = hd(ms)
            if (v == "-") return v
            u = substr(v, length(v))
            return "@{class=dur-" (u == "s" || u == "m" ? u : "h") "}" v
        }
        function qsort(A, lo, hi,   i, j, p, t) {
            while (lo < hi) {
                i = lo; j = hi; p = A[int((lo + hi) / 2)]
                while (i <= j) {
                    while (A[i] < p) i++
                    while (A[j] > p) j--
                    if (i <= j) { t = A[i]; A[i] = A[j]; A[j] = t; i++; j-- }
                }
                if (j - lo < hi - i) { if (lo < j) qsort(A, lo, j); lo = i }
                else                 { if (i < hi) qsort(A, i, hi); hi = j }
            }
        }
        function pctl(P) { return T[int((TN - 1) * P / 100 + 0.5) + 1] }
        function nrank(p, nn) { return int((nn - 1) * p / 100 + 0.5) + 1 }
        function dentry(t,   f) { split(t, f, "|"); return f[2] "  " f[3] "  (" humandur(f[1] + 0) ")" }
        function celllist(r, desc, nn,   start, end, i, out) {
            start = r - 2; if (start < 1) start = 1
            if (start > nn - 4) start = (nn - 4 < 1) ? 1 : nn - 4
            end = start + 4; if (end > nn) end = nn
            out = ""
            if (desc) { for (i = end; i >= start; i--) out = out (out == "" ? "" : "\037") dentry(PD[i]) }
            else      { for (i = start; i <= end; i++) out = out (out == "" ? "" : "\037") dentry(PD[i]) }
            return out
        }
        function bkt(ms) {
            if (ms <=     100) return 0
            if (ms <=    1000) return 1
            if (ms <=   10000) return 2
            if (ms <=   60000) return 3
            if (ms <=  300000) return 4
            if (ms <= 1800000) return 5
            return 6
        }
        okonly && ($2 == "Failed" || $2 == "Expired") { next }
        {
            d = substr($4, 1, 10); if (d !~ /^[0-9][0-9][0-9][0-9]-/) next
            ms = $9 + 0; if (ms <= 0) next
            G[++GN] = ms; gsum += ms; if (GN == 1 || ms < gmin) gmin = ms; if (ms > gmax) gmax = ms
            dc[d]++; dsum[d] += ms; if (dc[d] == 1 || ms < dmin[d]) dmin[d] = ms; if (ms > dmax[d]) dmax[d] = ms
            DV[d SUBSEP dc[d]] = ms
            DVc[d SUBSEP dc[d]] = $1; DVt[d SUBSEP dc[d]] = $4 " " $5
            b = bkt(ms); bkc[b]++; bkd[b SUBSEP d]++
        }
        END {
            nd = 0; for (d in dc) days[++nd] = d
            for (i = 2; i <= nd; i++) { v = days[i]; j = i - 1; while (j >= 1 && days[j] > v) { days[j+1] = days[j]; j-- } days[j+1] = v }
            for (i = 1; i <= nd; i++) {
                d = days[i]; n = dc[d]
                for (k = 1; k <= n; k++) T[k] = DV[d SUBSEP k]; TN = n; qsort(T, 1, n)
                for (k = 1; k <= n; k++) PD[k] = sprintf("%012d", DV[d SUBSEP k]) "|" DVt[d SUBSEP k] "|" DVc[d SUBSEP k]
                qsort(PD, 1, n)
                L = celllist(n, 1, n)
                # the Avg drill list centres on the first value >= the mean
                av = int(dsum[d]/n + 0.5)
                for (ak = 1; ak < n && T[ak] < av; ak++) ;
                # 12 stat cells (min avg median max p10 p25 p50 p75 p90 p95
                # p98 p99), then their 13 drill lists (L first, for the
                # Date and Files cells); the Max drill reuses L.
                printf "1\t%s\t%d\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s", \
                    d, n, hdc(dmin[d]), hdc(av), hdc(pctl(50)), hdc(dmax[d]), hdc(pctl(10)), hdc(pctl(25)), hdc(pctl(50)), hdc(pctl(75)), hdc(pctl(90)), hdc(pctl(95)), hdc(pctl(98)), hdc(pctl(99))
                printf "\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", \
                    L, celllist(1, 0, n), celllist(ak, 0, n), celllist(nrank(50, n), 0, n), L, celllist(nrank(10, n), 0, n), celllist(nrank(25, n), 0, n), celllist(nrank(50, n), 0, n), celllist(nrank(75, n), 0, n), celllist(nrank(90, n), 0, n), celllist(nrank(95, n), 0, n), celllist(nrank(98, n), 0, n), celllist(nrank(99, n), 0, n)
            }
            if (GN == 0) exit
            TN = GN; for (k = 1; k <= GN; k++) T[k] = G[k]; qsort(T, 1, GN)
            # cols 2-13 the raw figures, then the spellings the INTRO (humandur)
            # and the per-day TOTAL row (hd) need, in the order they are printed.
            # The TOTAL row must use hd() like the rows above it, so the column
            # reads in one unit from top to bottom.
            printf "O\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", \
                GN, gmin, int(gsum/GN + 0.5), gmax, pctl(10), pctl(25), pctl(50), pctl(75), pctl(90), pctl(95), pctl(99), nd, \
                humandur(gmin), humandur(pctl(50)), humandur(pctl(95)), humandur(pctl(99)), humandur(gmax), \
                hdc(gmin), hdc(pctl(50)), hdc(gmax), hdc(pctl(10)), hdc(pctl(25)), hdc(pctl(75)), hdc(pctl(90)), hdc(pctl(95)), hdc(pctl(99)), \
                hdc(int(gsum/GN + 0.5)), hdc(pctl(98))
            split("<= 100 ms|100 ms - 1 s|1 s - 10 s|10 s - 1 min|1 - 5 min|5 - 30 min|> 30 min", BL, "|")
            for (b = 0; b <= 6; b++) {
                bs = ""; for (i = 1; i <= nd; i++) { d = days[i]; c = bkd[b SUBSEP d] + 0; if (c > 0) bs = bs (bs ? "," : "") d ":" c }
                printf "D\t%s\t%d\t%.1f%%\t@data:buckets=%s\n", BL[b+1], bkc[b] + 0, (GN > 0 ? 100 * bkc[b] / GN : 0), bs
            }
        }
    ' "$FILES")

    if [ -z "$agg" ]; then
        local _eo _en
        for _eo in "$OUT_MM" "$OUT_PP"; do
            _en=$NAV_MM; [ "$_eo" = "$OUT_PP" ] && _en=$NAV_PP
            {
                printf 'TITLE\tTransfer Duration\n'
                printf 'DESC\tHow long transfers take — per-day min/avg/median/max and percentiles, (the longest Files, the duration distribution and the slowest subscriptions have their own pages). %s\n' "$SCOPE_DESC"
                printf 'INTRO\tNo Files with a measured duration in this view.\n'
                printf '%s\n' "$_en"
                printf 'TABLE\tTransfer duration\n'
                printf 'HEAD\tDuration\n'
                printf 'KIND\ttext\n'
                printf 'ROW\tNo transfers with a measured duration in this view.\n'
                printf 'FOOT\tGenerated on %s from %s file(s)\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${#files[@]}"
            } > "$_eo.tmp" && mv "$_eo.tmp" "$_eo"
            echo "No transfers with a duration found for $_eo — wrote empty-state." >&2
        done
        return 0
    fi


    local _ g_n g_min g_avg g_max g_p10 g_p25 g_p50 g_p75 g_p90 g_p95 g_p99 g_days
    local u_min u_p50 u_p95 u_p99 u_max h_min h_p50 h_max h_p10 h_p25 h_p75 h_p90 h_p95 h_p99 h_avg h_p98
    IFS=$'\t' read -r _ g_n g_min g_avg g_max g_p10 g_p25 g_p50 g_p75 g_p90 g_p95 g_p99 g_days \
        u_min u_p50 u_p95 u_p99 u_max h_min h_p50 h_max h_p10 h_p25 h_p75 h_p90 h_p95 h_p99 h_avg h_p98 \
        <<< "$(printf '%s\n' "$agg" | grep '^O'$'\t')"

    # the per-day "1" lines: $2 date, $3 files, $4-$15 the 12 stat cells
    # (min avg median max p10 p25 p50 p75 p90 p95 p98 p99), $16-$28
    # their drill lists (L first, shared by the Date and Files cells).
    # Each view picks its columns; drill-cell-N is the view's own cell index.
    local perday_mm; perday_mm=$(printf '%s\n' "$agg" | awk -F'\t' 'BEGIN{OFS="\t"} $1=="1"{
        print "ROW", $2, $3, $4, $5, $6, $7, \
            "@data:drill-cell-0=" $16, "@data:drill-cell-1=" $16, "@data:drill-cell-2=" $17, \
            "@data:drill-cell-3=" $18, "@data:drill-cell-4=" $19, "@data:drill-cell-5=" $20
    }')
    # p100 (2026-09-06, user request) is the day's longest File — the Max cell
    # ($7) and its drill list ($20) reused, so the two views agree to the ms.
    # LAST column: the home per-day table reads p50/p75/p90/p99 from this
    # table by POSITION (bin/build/publish.sh, cols 6/7/8/11).
    local perday_pp; perday_pp=$(printf '%s\n' "$agg" | awk -F'\t' 'BEGIN{OFS="\t"} $1=="1"{
        row="ROW" OFS $2 OFS $3
        for(i=8;i<=15;i++) row=row OFS $i
        row=row OFS $7
        row=row OFS "@data:drill-cell-0=" $16 OFS "@data:drill-cell-1=" $16
        for(i=2;i<=9;i++) row=row OFS "@data:drill-cell-" i "=" $(i+19)
        row=row OFS "@data:drill-cell-10=" $20
        print row
    }')



    emit_view() {   # $1 the .rpt to write  $2 its NAV line  $3 the view (mm|pp)
        local OUT=$1 NAVLINE=$2 VIEW=$3
    {
        printf 'TITLE\tTransfer Duration\n'
        printf 'DESC\tHow long transfers take — per-day min/avg/median/max and percentiles, (the longest Files, the duration distribution and the slowest subscriptions have their own pages). %s\n' "$SCOPE_DESC"
        printf 'INTRO\tDuration of the **%s** Files over **%s** day(s). Overall **min %s**, **median (p50) %s**, **p95 %s**, **p99 %s**, **max %s**. %s The **Percentage** and **Min/Avg/Max** buttons switch the per-day columns; the stats are shown in **whole seconds, minutes or hours**, and a narrowed date range keeps each day but blanks the non-additive totals.\n' \
            "$g_n" "$g_days" "$u_min" "$u_p50" "$u_p95" "$u_p99" "$u_max" "$SCOPE_INTRO"
        printf '%s\n' "$NAVLINE"

        # Files keeps an explicit @{class=num}; the duration cells arrive
        # from hdc() carrying their own dur-<unit> class, and the renderer adds
        # the num alignment to those itself.
        if [ "$VIEW" = mm ]; then
            printf 'TABLE\tDuration per day\twide\ttotaltop\tnoagg=2,3,4,5\n'
            printf 'HEAD\tDate\tFiles\tMin\tAvg\tMedian\tMax\n'
            printf 'KIND\ttext\tnum\tnum\tnum\tnum\tnum\n'
            printf 'TOTAL\tOverall (%s days)\t@{class=num}%s\t%s\t%s\t%s\t%s\n' \
                "$g_days" "$g_n" "$h_min" "$h_avg" "$h_p50" "$h_max"
            printf '%s\n' "$perday_mm"
        else
            printf 'TABLE\tDuration per day\twide\ttotaltop\tnoagg=2,3,4,5,6,7,8,9,10\n'
            printf 'HEAD\tDate\tFiles\tp10\tp25\tp50\tp75\tp90\tp95\tp98\tp99\tp100\n'
            printf 'KIND\ttext\tnum\tnum\tnum\tnum\tnum\tnum\tnum\tnum\tnum\tnum\n'
            printf 'TOTAL\tOverall (%s days)\t@{class=num}%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
                "$g_days" "$g_n" "$h_p10" "$h_p25" "$h_p50" "$h_p75" "$h_p90" "$h_p95" "$h_p98" "$h_p99" "$h_max"
            printf '%s\n' "$perday_pp"
        fi


        printf 'NOTE\tOne "File" = one logical transfer (all records sharing a CoreId); duration = its **wall-clock span** — from the first record start to the last record end, in milliseconds (so it includes the store-and-forward gap between the inbound and outbound legs, and the idle time between retries), NOT the sum of the record durations. %sPer-day min/median/max and percentiles are **not additive**: a narrowed date range keeps each day row but blanks the total. Percentiles use the nearest-rank method; **p100** is the day'\''s longest File — the Max of the other view — so the gap between p99 and p100 says how far the worst case sits from the rest.\n' "$SCOPE_NOTE"
        printf 'SUMMARY\tFiles: %s  |  Median: %s  |  p95: %s  |  p99: %s  |  Max: %s\n' \
            "$g_n" "$u_p50" "$u_p95" "$u_p99" "$u_max"
        printf 'FOOT\tGenerated on %s from %s file(s)\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${#files[@]}"
    } > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"

    echo "Data written to $OUT ($g_n Files over $g_days days)." >&2
    }
    emit_view "$OUT_MM" "$NAV_MM" mm
    emit_view "$OUT_PP" "$NAV_PP" pp
}

# The two button groups on one NAV row (@sep = the gap): OK/All transfers,
# then Percentage vs Min/Avg/Max (Percentage first — it is the default and
# lives at duration.html). Each button links the SAME view along the other
# axis, so the two selections compose.
NAV_OK_PP=$'NAV\t1|OK transfers|duration.html\t0|All transfers|duration-all.html\t@sep\t1|Percentage|duration.html\t0|Min/Avg/Max|duration-minmax.html'
NAV_OK_MM=$'NAV\t1|OK transfers|duration-minmax.html\t0|All transfers|duration-all-minmax.html\t@sep\t0|Percentage|duration.html\t1|Min/Avg/Max|duration-minmax.html'
NAV_ALL_PP=$'NAV\t0|OK transfers|duration.html\t1|All transfers|duration-all.html\t@sep\t1|Percentage|duration-all.html\t0|Min/Avg/Max|duration-all-minmax.html'
NAV_ALL_MM=$'NAV\t0|OK transfers|duration-minmax.html\t1|All transfers|duration-all-minmax.html\t@sep\t0|Percentage|duration-all.html\t1|Min/Avg/Max|duration-all-minmax.html'

build_view 1 "$REPORTS_DIR/duration-minmax.rpt" "$REPORTS_DIR/duration.rpt" \
    "$NAV_OK_MM" "$NAV_OK_PP" \
    "Delivered (Processed) Files only — the default; use the All transfers button to include failures." \
    "Only **Processed** Files count; Error transfers (mostly instant 0-byte attempts) are excluded so they do not flatten the statistics — switch to **All transfers** to include them." \
    "**Only Processed (OK) Files are counted** here (use the All transfers button to include failures). "

build_view 0 "$REPORTS_DIR/duration-all-minmax.rpt" "$REPORTS_DIR/duration-all.rpt" \
    "$NAV_ALL_MM" "$NAV_ALL_PP" \
    "ALL Files, including failed (Error) transfers." \
    "**All** Files count, including Error transfers — a failed transfer's duration is how long it ran before failing (e.g. a timeout), so long-hanging failures show up here (switch to **OK transfers** for delivered-only statistics)." \
    "**All Files are counted, including failed (Error) ones** — a failure's duration is how long it ran before giving up (use the OK transfers button for delivered-only). "
