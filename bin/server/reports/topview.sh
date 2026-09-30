#!/usr/bin/env bash
#
# topview.sh — "Top view" for the SERVER log: a wide per-day health dashboard,
# the server area's landing report. One pass over the parse cache
# (data/_parse.tsv: 1=date, 2=time, 3=level I/W/E, 4=component T/P/S,
# 5=message) emits, per calendar day (calendar gaps filled with "0" rows):
#   records, a load bar, the Info / Warnings / Errors split and error rate, the
#   activity of each component (TM / PESITD / SSHD), and the
#   first and last record time. Warnings are tinted amber, Errors red. Click a
#   day to expand its 10 most recent Warning/Error lines.
#
# The total row is pinned to the top (TABLE modifier `totaltop`). Julian-day
# arithmetic is done in awk (portable), like the transfer day report.
#
# Usage:
#   ./topview.sh    # reads input/*.csv (via the cache), writes data/topview.rpt
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib.sh"
mkdir -p "$REPORTS_DIR"
OUT="$REPORTS_DIR/topview.rpt"

shopt -s nullglob
files=("$INPUT_DIR"/*.csv)
shopt -u nullglob
if [ ${#files[@]} -eq 0 ]; then
    echo "No files matching '*.csv' found in '$INPUT_DIR'" >&2
    rm -f "$OUT"   # no data for this ENV — page not published (an env-split legitimate state)
    exit 0
fi
echo "Found ${#files[@]} file(s) in '$INPUT_DIR', processing..." >&2

# The per-day records, level split (I/W/E), per-component counts (T/P/S) and
# first/last time come from the COUNTS table (bin/server/subsets.sh, one pass
# for every consumer — until 2026-09-30 this script read the whole cache for
# them), the per-day Warning/Error drill lines from the non-Info subset (the
# very lines the drill takes, in cache order). END walks the Julian-day range
# so calendar gaps become explicit "0" rows.
CNTF=$(srv_counts)
agg=$(awk -F'\t' -v CNTF="$CNTF" "$LOGLINES_AWK$AWKLIB"'
    function zb(v) { return (v + 0 == 0) ? "" : v + 0 }   # a 0 count shows blank
    FILENAME == CNTF {   # C date hour level component count  |  T date first last
        if ($1 == "T") { first[$2] = $3; last[$2] = $4; next }
        d = $2; if (d == "") next                  # an undated line: no Top view day
        n = $6 + 0; lv = $4; cp = $5
        rec[d] += n; trec += n; allday[d] = 1
        if (lv == "I") { inf[d] += n; tinf += n } else if (lv == "W") { warn[d] += n; twarn += n } else if (lv == "E") { err[d] += n; terr += n }
        if (cp == "T") { cT[d] += n; tT += n } else if (cp == "P") { cP[d] += n; tP += n } else if (cp == "S") { cS[d] += n; tS += n }
        next
    }
    {   # the non-Info lines, in cache order: the Warning/Error drill lines
        d = substr($1, 1, 10); if (d !~ /^[0-9][0-9][0-9][0-9]-/) next
        addline(d, $1 " " $2, lvlname($3) " " compname($4) "  " substr($5, 1, 200))
    }
    END {
        maxr = 1; for (d in rec) if (rec[d] > maxr) maxr = rec[d]
        mn = 0; mx = 0
        for (d in allday) { split(d, pp, "-"); j = jdn(pp[1]+0, pp[2]+0, pp[3]+0); if (mn == 0 || j < mn) mn = j; if (j > mx) mx = j }
        if (mn == 0) exit   # empty parse: emit nothing — the shell empty-guard below handles it (the walk would otherwise print one bogus fromjdn(0) year -4713 row)
        busyd = ""; busyc = 0; for (d in rec) if (rec[d] > busyc || (rec[d] == busyc && d < busyd)) { busyc = rec[d]; busyd = d }   # earliest date breaks a tie
        worstd = ""; worste = -1; for (d in rec) if ((err[d]+0) > worste || ((err[d]+0) == worste && d < worstd)) { worste = err[d]+0; worstd = d }
        ndays = 0
        for (j = mn; j <= mx; j++) {
            d = fromjdn(j)
            if (d in rec) {
                ndays++
                ep = rec[d] > 0 ? sprintf("%.1f", (err[d]+0) * 100 / rec[d]) : "0.0"
                w = int(rec[d] * 100 / maxr)
                fi = first[d]; sub(/\.[0-9]+$/, "", fi); if (fi == "") fi = "-"
                la = last[d];  sub(/\.[0-9]+$/, "", la); if (la == "") la = "-"
                # the component counts blank a 0 (2026-09-30 audit A5-06 — the
                # transfer Top view rule; every reader adds +0)
                printf "ROW\t@{href=../day/%s.html}%s\t%d\t%d\t%d\t%d\t%d\t%s%%\t%s\t%s\t%s\t%s\t%s\t@data:loglines=%s\n", \
                    d, d, rec[d], w, inf[d]+0, warn[d]+0, err[d]+0, ep, zb(cT[d]), zb(cP[d]), zb(cS[d]), fi, la, lastlines(d)
            } else {
                printf "ROW\t%s\t0\t0\t0\t0\t0\t0.0%%\t\t\t\t-\t-\t@data:loglines=\n", d
            }
        }
        # noisiest component overall
        split("TM PESITD SSHD", cn, " "); ct[1]=tT; ct[2]=tP; ct[3]=tS
        noisy = cn[1]; noisyc = tT+0; for (i = 2; i <= 3; i++) if ((ct[i]+0) > noisyc) { noisyc = ct[i]+0; noisy = cn[i] }
        tep = trec > 0 ? sprintf("%.1f", terr * 100 / trec) : "0.0"
        printf "TOT|%d|%d|%d|%d|%s|%d|%d|%d\n", trec, tinf+0, twarn+0, terr+0, tep, tT+0, tP+0, tS+0
        printf "KPI|%d|%s|%d|%s|%d|%s|%d|%s|%s\n", ndays, busyd, busyc, worstd, worste, noisy, noisyc, fromjdn(mn), fromjdn(mx)
    }
' "$CNTF" "$(srv_subset noninfo)")

if [ -z "$agg" ]; then echo "No usable records found." >&2; rm -f "$OUT"; exit 0; fi

rows=$(printf '%s\n' "$agg" | grep '^ROW')
IFS='|' read -r _ trec tinf twarn terr tep tT tP tS <<< "$(printf '%s\n' "$agg" | grep '^TOT|')"
IFS='|' read -r _ ndays busyd busyc worstd worste noisy noisyc kfrom kto <<< "$(printf '%s\n' "$agg" | grep '^KPI|')"
[ "$ndays" -eq 1 ] && total_label="Totals for 1 day" || total_label="Totals for $ndays days"

{
    printf 'TITLE\tServer top view\n'   # = its Reports menu label (2026-09-29)
    printf 'TABLE\t\twide\ttotaltop\tdatereset\tpct=6:5:1\n'
    printf 'HEAD\tDate\tRecords\tLoad\tInfo\tWarnings\tErrors\tError %%\tTM\tPESITD\tSSHD\tFirst\tLast\n'
    printf 'KIND\ttext\tnum\tbar\tnum\tnumwarn\tnumfailed\tnum\tnum\tnum\tnum\ttext\ttext\n'
    zb() { [ "${1:-0}" != 0 ] && printf '%s' "$1" || true; }   # a 0 component total shows blank (A5-06)
    printf 'TOTAL\t%s\t@{class=num}%s\t\t@{class=num}%s\t@{class=num warn}%s\t@{class=num failed}%s\t@{class=num}%s%%\t@{class=num}%s\t@{class=num}%s\t@{class=num}%s\t\t\n' \
        "$total_label" "$trec" "$tinf" "$twarn" "$terr" "$tep" "$(zb "$tT")" "$(zb "$tP")" "$(zb "$tS")"
    printf '%s\n' "$rows"
    printf 'SUMMARY\tDays: %s  |  Records: %s  |  Errors: %s (%s%%)  |  Warnings: %s  |  Noisiest: %s\n' "$ndays" "$trec" "$terr" "$tep" "$twarn" "$noisy"
    printf 'FOOT\n'
} > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"

echo "Data written to $OUT ($ndays day(s), $trec record(s))." >&2
