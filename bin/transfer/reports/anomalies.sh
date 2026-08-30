#!/usr/bin/env bash
#
# anomalies.sh
# Detect UNUSUAL activity in the transfer log, at two granularities rendered
# as the two tables of ONE page, anomalies.html (they were a tab pair,
# anomalies-{hourly,daily}.html, until 2026-08):
#
#   HOURLY — for every (day, hour) bucket the five signals — Error rate,
#   Duration (avg per OK File), Files spike, Files silence, Volume — are
#   compared against that hour-of-day TYPICAL value (the median across the
#   window days, weekdays and weekends baselined separately so a quiet Sunday
#   is not "silent" against a Tuesday median). Hours that exceed the
#   thresholds are merged into consecutive EPISODES (one unflagged gap hour
#   allowed), e.g. "Duration high 08:00-14:59".
#
#   DAILY — the same idea per whole calendar day vs the typical day (same
#   weekday/weekend median baselines): Error rate and Duration at >=4x
#   typical, Files spike and Volume at >=2x (day totals swing less than
#   hours), plus Files drop (<=1/4 of typical) and Silence (a calendar day
#   with NO transfers where the baseline expects >=20 — absent days are
#   walked via the jdn calendar, so a fully-dead day still shows).
#
# Each row links its Date to the per-day page opened in the matching
# hero-chart view (?axway_hero=).
#
# Usage:
#   ./anomalies.sh    # reads data/transfer/cache/_files.tsv, writes data/transfer/reports/anomalies.rpt
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib.sh"
mkdir -p "$REPORTS_DIR"
OUT="$REPORTS_DIR/anomalies.rpt"

shopt -s nullglob
files=("$INPUT_DIR"/*.csv)
shopt -u nullglob
if [ ${#files[@]} -eq 0 ]; then
    echo "No *.csv in $INPUT_DIR — building from the EMPTY caches (config-only estate)" >&2
fi
ensure_parsed
skip_if_fresh "$OUT" "${BASH_SOURCE[0]}"
echo "Found ${#files[@]} file(s) in '$INPUT_DIR', processing..." >&2

# Pass 1: aggregate per (day, hour) AND per day, build the per-(class, hour)
# and per-class daily baselines, flag + merge episodes, emit one sortable line
# per finding: tbl(1 hourly/2 daily), date, start hh, what, window, level,
# typical, ratio, files, err, hero view, tint. Pass 2 (after the sort: table
# DESCENDING so the DAILY findings lead, then newest-first) formats the .rpt.
#
# ONE page, two tables (2026-08 — the report used to split into an Hourly and a
# Daily page): Daily first because it is the coarse read ("which days were
# odd", ~40 rows), the hourly episodes below it paged, since they run into the
# hundreds and would otherwise bury the daily table under a screen of scrolling.
# _files.tsv: 2=outcome, 4=date, 5=time, 8=size, 9=dur_ms.
awk -F'\t' '
    function jdn(y,m,d,  a){ a=int((14-m)/12); y=y+4800-a; m=m+12*a-3; return d+int((153*m+2)/5)+365*y+int(y/4)-int(y/100)+int(y/400)-32045 }
    function fromjdn(j,   a,b,c,dd,e,mm,day,mon,yr) { a=j+32044; b=int((4*a+3)/146097); c=a-int(146097*b/4); dd=int((4*c+3)/1461); e=c-int(1461*dd/4); mm=int((5*e+2)/153); day=e-int((153*mm+2)/5)+1; mon=mm+3-12*int(mm/10); yr=100*b+dd-4800+int(mm/10); return sprintf("%04d-%02d-%02d", yr, mon, day) }
    function jofd(d,   dp) { split(d, dp, "-"); return jdn(dp[1]+0, dp[2]+0, dp[3]+0) }
    function median(A, key, n,   i, j, t, v, m) {
        if (n == 0) return 0
        for (i = 1; i <= n; i++) { v = A[key, i]; j = i - 1; while (j > 0 && t[j] > v) { t[j+1] = t[j]; j-- } t[j+1] = v }
        m = int(n / 2)
        return (n % 2) ? t[m + 1] : (t[m] + t[m + 1]) / 2
    }
    function mx(a, b) { return a > b ? a : b }
    {
        d = $4; if (d == "") next
        if (!(d in DSEEN)) { DSEEN[d] = 1; DL[++ND] = d }
        DFC[d]++; DVB[d] += $8
        if ($2 != "Failed" && $2 != "Expired") { if ($9 + 0 > 0) { DDS[d] += $9; DDN[d]++ } }
        else DFF[d]++
        h = substr($5, 1, 2); if (h !~ /^[0-9][0-9]$/) next
        FC[d, h]++; VB[d, h] += $8
        if ($2 != "Failed" && $2 != "Expired") { if ($9 + 0 > 0) { DS[d, h] += $9; DN[d, h]++ } }
        else FF[d, h]++
    }
    END {
        # day -> weekday/weekend class
        for (x = 1; x <= ND; x++) { d = DL[x]
            CL[d] = (jofd(d) % 7 >= 5) ? "we" : "wd" }
        # ---- hourly: per (class, hour) samples — files + volume over EVERY
        # day (a missing bucket is a real 0), duration/rate only where defined
        for (x = 1; x <= ND; x++) { d = DL[x]; c = CL[d]
            for (h = 0; h < 24; h++) { hh = sprintf("%02d", h); k = c SUBSEP hh
                FS_[k, ++FN[k]] = FC[d, hh] + 0
                VS_[k, ++VN[k]] = VB[d, hh] + 0
                if (DN[d, hh] + 0 > 0)  { DS_[k, ++DNN[k]] = DS[d, hh] / DN[d, hh] }
                if (FC[d, hh] + 0 > 0)  { RS_[k, ++RN[k]] = FF[d, hh] * 100 / FC[d, hh] }
            } }
        for (c = 1; c <= 2; c++) { cl = (c == 1) ? "wd" : "we"
            for (h = 0; h < 24; h++) { hh = sprintf("%02d", h); k = cl SUBSEP hh
                FB[k] = median(FS_, k, FN[k] + 0)
                VBASE[k] = median(VS_, k, VN[k] + 0)
                DB[k] = median(DS_, k, DNN[k] + 0)
                RB[k] = median(RS_, k, RN[k] + 0)
            } }
        # flag each (day, hour) per signal, then merge runs (one-hour gaps
        # bridged) into episodes. FLG values: ratio (silence: -1).
        for (x = 1; x <= ND; x++) { d = DL[x]; c = CL[d]
            for (m = 1; m <= 5; m++) for (h = 0; h < 24; h++) FLG[m, h] = 0
            for (h = 0; h < 24; h++) { hh = sprintf("%02d", h); k = c SUBSEP hh
                f = FC[d, hh] + 0; v = VB[d, hh] + 0; ff = FF[d, hh] + 0
                rate = f > 0 ? ff * 100 / f : 0
                avg = DN[d, hh] + 0 > 0 ? DS[d, hh] / DN[d, hh] : 0
                if (f >= 5 && rate >= 25 && rate >= 4 * mx(RB[k], 2))            FLG[1, h] = rate / mx(RB[k], 2)
                if (DN[d, hh] + 0 >= 5 && avg >= 300000 && avg >= 4 * mx(DB[k], 30000)) FLG[2, h] = avg / mx(DB[k], 30000)
                if (f >= 30 && f >= 4 * mx(FB[k], 5))                            FLG[3, h] = f / mx(FB[k], 5)
                if (f == 0 && FB[k] >= 20)                                       FLG[4, h] = -1
                if (v >= 100000000 && v >= 4 * mx(VBASE[k], 10000000))           FLG[5, h] = v / mx(VBASE[k], 10000000)
            }
            for (m = 1; m <= 5; m++) {
                h = 0
                while (h < 24) {
                    if (!FLG[m, h]) { h++; continue }
                    hs = h; he = h; h++
                    while (h < 24 && (FLG[m, h] || (h + 1 < 24 && FLG[m, h + 1]))) { if (FLG[m, h]) he = h; h++ }
                    # episode stats over the flagged hours hs..he
                    pk = 0; pkr = 0; wf = 0; wff = 0
                    for (i = hs; i <= he; i++) {
                        if (!FLG[m, i]) continue
                        hh = sprintf("%02d", i)
                        wf += FC[d, hh] + 0; wff += FF[d, hh] + 0
                        if (m == 1) val = (FC[d, hh] ? FF[d, hh] * 100 / FC[d, hh] : 0)
                        else if (m == 2) val = (DN[d, hh] ? DS[d, hh] / DN[d, hh] : 0)
                        else if (m == 3) val = FC[d, hh] + 0
                        else if (m == 5) val = VB[d, hh] + 0
                        else val = 0
                        if (val >= pk) pk = val
                        if (FLG[m, i] > pkr) pkr = FLG[m, i]
                    }
                    k = CL[d] SUBSEP sprintf("%02d", hs)
                    win = sprintf("%02d:00-%02d:59", hs, he)
                    if (m == 1)      printf "1\t%s\t%02d\tError rate\t%s\t%d%%\t%.1f%%\t%.1f\t%d\t%d\tError%%20%%25%%20Files\t%s\n",  d, hs, win, pk + 0.5, RB[k], pkr, wf, wff, (pkr >= 10 ? "red" : "orange")
                    else if (m == 2) printf "1\t%s\t%02d\tDuration\t%s\t%s\t%s\t%.1f\t%d\t%d\tDuration\t%s\n",               d, hs, win, hdur(pk), hdur(DB[k]), pkr, wf, wff, (pkr >= 10 ? "red" : "orange")
                    else if (m == 3) printf "1\t%s\t%02d\tFiles spike\t%s\t%d Files\t%d\t%.1f\t%d\t%d\tFiles%%20processed\t%s\n", d, hs, win, pk, FB[k] + 0.5, pkr, wf, wff, (pkr >= 10 ? "red" : "orange")
                    else if (m == 4) printf "1\t%s\t%02d\tSilence\t%s\t0 Files\t%d\t\t0\t0\tFiles%%20processed\tred\n",           d, hs, win, FB[k] + 0.5
                    else             printf "1\t%s\t%02d\tVolume\t%s\t%s\t%s\t%.1f\t%d\t%d\tVolume\t%s\n",                   d, hs, win, hbytes(pk), hbytes(VBASE[k]), pkr, wf, wff, (pkr >= 10 ? "red" : "orange")
                }
            }
        }
        # ---- daily: per-class baselines over the data days, then a CALENDAR
        # walk (jdn min..max) so a day with no transfers at all still shows as
        # Silence — it has no _files.tsv rows to be seen by.
        for (x = 1; x <= ND; x++) { d = DL[x]; c = CL[d]
            FDS[c, ++FDN[c]] = DFC[d] + 0
            VDS[c, ++VDN[c]] = DVB[d] + 0
            if (DDN[d] + 0 > 0) DDSA[c, ++DDNC[c]] = DDS[d] / DDN[d]
            if (DFC[d] + 0 > 0) RDS[c, ++RDN[c]] = DFF[d] * 100 / DFC[d]
        }
        for (c = 1; c <= 2; c++) { cl = (c == 1) ? "wd" : "we"
            FDB[cl] = median(FDS, cl, FDN[cl] + 0)
            VDB[cl] = median(VDS, cl, VDN[cl] + 0)
            DDB[cl] = median(DDSA, cl, DDNC[cl] + 0)
            RDB[cl] = median(RDS, cl, RDN[cl] + 0)
        }
        jmin = 0; jmax = 0
        for (x = 1; x <= ND; x++) { j = jofd(DL[x]); if (jmin == 0 || j < jmin) jmin = j; if (j > jmax) jmax = j }
        for (j = jmin; j <= jmax; j++) {
            d = fromjdn(j); cl = (j % 7 >= 5) ? "we" : "wd"
            f = DFC[d] + 0; v = DVB[d] + 0; ff = DFF[d] + 0
            rate = f > 0 ? ff * 100 / f : 0
            avg = DDN[d] + 0 > 0 ? DDS[d] / DDN[d] : 0
            if (f == 0) {
                # an absent day has no day page — hero "-" makes pass 2 leave the Date unlinked
                if (FDB[cl] >= 20) printf "2\t%s\t00\tSilence\t\t0 Files\t%d\t\t0\t0\t-\tred\n", d, FDB[cl] + 0.5
                continue
            }
            if (f >= 20 && rate >= 10 && rate >= 4 * mx(RDB[cl], 1)) { r = rate / mx(RDB[cl], 1)
                printf "2\t%s\t00\tError rate\t\t%d%%\t%.1f%%\t%.1f\t%d\t%d\tError%%20%%25%%20Files\t%s\n", d, rate + 0.5, RDB[cl], r, f, ff, (r >= 10 ? "red" : "orange") }
            if (DDN[d] + 0 >= 20 && avg >= 300000 && avg >= 4 * mx(DDB[cl], 60000)) { r = avg / mx(DDB[cl], 60000)
                printf "2\t%s\t00\tDuration\t\t%s\t%s\t%.1f\t%d\t%d\tDuration\t%s\n", d, hdur(avg), hdur(DDB[cl]), r, f, ff, (r >= 10 ? "red" : "orange") }
            if (f >= 100 && f >= 2 * mx(FDB[cl], 50)) { r = f / mx(FDB[cl], 50)
                printf "2\t%s\t00\tFiles spike\t\t%d Files\t%d\t%.1f\t%d\t%d\tFiles%%20processed\t%s\n", d, f, FDB[cl] + 0.5, r, f, ff, (r >= 10 ? "red" : "orange") }
            else if (FDB[cl] >= 100 && f <= FDB[cl] / 4)
                printf "2\t%s\t00\tFiles drop\t\t%d Files\t%d\t%.2f\t%d\t%d\tFiles%%20processed\t%s\n", d, f, FDB[cl] + 0.5, f / FDB[cl], f, ff, (f <= FDB[cl] / 10 ? "red" : "orange")
            if (v >= 200000000 && v >= 2 * mx(VDB[cl], 50000000)) { r = v / mx(VDB[cl], 50000000)
                printf "2\t%s\t00\tVolume\t\t%s\t%s\t%.1f\t%d\t%d\tVolume\t%s\n", d, hbytes(v), hbytes(VDB[cl]), r, f, ff, (r >= 10 ? "red" : "orange") }
        }
    }
    function hdur(ms) {
        if (ms <= 0)      return "-"
        if (ms < 1000)    return sprintf("%d ms", ms)
        if (ms < 60000)   return sprintf("%.1f s", ms/1000)
        if (ms < 3600000) return sprintf("%.1f min", ms/60000)
        return sprintf("%.2f h", ms/3600000)
    }
    function hbytes(b,   u, i, v) {
        split("B KB MB GB TB PB", u, " ")
        i = 1; v = b + 0
        while (v >= 1024 && i < 6) { v /= 1024; i++ }
        if (i == 1) return sprintf("%d %s", v, u[i])
        return sprintf("%.2f %s", v, u[i])
    }
' "$FILES" \
| LC_ALL=C sort -t$'\t' -k1,1r -k2,2r -k3,3 -k4,4 \
| awk -F'\t' -v nfiles="${#files[@]}" -v now="$(date '+%Y-%m-%d %H:%M:%S')" '
    function open_daily() {
        printf "TABLE\tDaily — unusual days\twide\tkeephead\tanchor=daily\n"
        printf "HEAD\tDate\tWhat\tValue\tTypical\t× typical\tFiles\tError\n"
        printf "KIND\ttext\ttext\tnum\tnum\tnum\tnum\tnumfailed\n"
    }
    function close_daily() {
        printf "TOTAL\tTotal (%d rows)\t\t\t\t\t\t\n", n2
        printf "NOTE\tSignals per calendar day vs the typical day: **Error rate** (≥10%%, ≥20 Files, ≥4× typical), **Duration** (avg per OK File ≥5 min, ≥20 OK Files, ≥4×), **Files spike** (≥100 Files, ≥2×), **Files drop** (≤¼ of a ≥100-Files typical), **Silence** (a calendar day with NO transfers where ≥20 are typical — missing days are walked via the calendar), **Volume** (≥200 MB, ≥2×).\n"
    }
    function open_hourly() {
        printf "TABLE\tHourly — unusual hours\twide\tanchor=hourly\tpager=50\n"
        printf "HEAD\tDate\tHours\tWhat\tPeak\tTypical\t× typical\tFiles\tError\n"
        printf "KIND\ttext\tmono\ttext\tnum\tnum\tnum\tnum\tnumfailed\n"
    }
    function close_hourly() {
        printf "TOTAL\tTotal (%d rows)\t\t\t\t\t\t\t\n", n1
        printf "NOTE\tSignals per start hour: **Error rate** (≥25%% and ≥5 Files), **Duration** (avg per OK File ≥5 min, ≥5 OK Files), **Files spike** (≥30 Files), **Silence** (0 Files in an hour that typically moves ≥20), **Volume** (≥100 MB) — each also ≥4× its typical. Consecutive flagged hours merge into one episode.\n"
        printf "NOTE\tEnd-of-window caution: on the newest day the outbound legs of just-arrived files may not be exported yet, which can flag late hours or the whole day as Error rate — recheck after the next log export.\n"
        printf "FOOT\tGenerated on %s from %s file(s)\n", now, nfiles
    }
    BEGIN {
        printf "TITLE\tAnomalies\n"
        printf "DESC\tDetected unusual hours and days: error-rate spikes, duration surges, file-count spikes, drops and silences, and volume bursts — each compared to its typical value across the window.\n"
        printf "INTRO\tEvery calendar day (the **Daily** table) and every hour (the **Hourly** table below it) is compared against its TYPICAL value — the median across the window days, weekdays and weekends baselined separately. A finding must beat a multiple of its typical (4× for hours; 4× for daily Error rate and Duration, 2× for daily Files and Volume) plus an absolute floor per signal, so quiet-window noise never flags. **Value/Peak** is the flagged figure, **× typical** the figure vs the baseline; **red** rows are ≥10× typical (or a silence), **orange** the rest. The Date links open the day page with the matching chart view selected — and each day page links back here only when that day has findings of its own.\n"
        open_daily()
    }
    $1 == "2" {
        if ($11 == "-") printf "ROW\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t@data:res=%s\n", $2, $4, $6, $7, $8, $9, $10, $12
        else printf "ROW\t@{href=../day/%s.html?axway_hero=%s}%s\t%s\t%s\t%s\t%s\t%s\t%s\t@data:res=%s\n", $2, $11, $2, $4, $6, $7, $8, $9, $10, $12
        n2++
    }
    $1 == "1" {
        if (!t1) { close_daily(); open_hourly(); t1 = 1 }
        printf "ROW\t@{href=../day/%s.html?axway_hero=%s}%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t@data:res=%s\n", $2, $11, $2, $5, $4, $6, $7, $8, $9, $10, $12
        n1++
    }
    END {
        if (!t1) { close_daily(); open_hourly() }
        close_hourly()
    }
' > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"

echo "Data written to $OUT." >&2
