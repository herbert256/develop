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
ensure_parsed
skip_if_fresh "$OUT" "${BASH_SOURCE[0]}"
echo "Found ${#files[@]} file(s) in '$INPUT_DIR', processing..." >&2

# One pass: per-day records, level split (I/W/E), per-component counts
# (T/P/S), first/last time, and the per-day Warning/Error drill lines. END
# walks the Julian-day range so calendar gaps become explicit "0" rows.
agg=$(awk -F'\t' "$LOGLINES_AWK"'
    function jdn(y,m,d,  a){ a=int((14-m)/12); y=y+4800-a; m=m+12*a-3; return d+int((153*m+2)/5)+365*y+int(y/4)-int(y/100)+int(y/400)-32045 }
    function fromjdn(j,  a,b,c,dd,e,mm,day,mon,yr){ a=j+32044; b=int((4*a+3)/146097); c=a-int(146097*b/4); dd=int((4*c+3)/1461); e=c-int(1461*dd/4); mm=int((5*e+2)/153); day=e-int((153*mm+2)/5)+1; mon=mm+3-12*int(mm/10); yr=100*b+dd-4800+int(mm/10); return sprintf("%04d-%02d-%02d",yr,mon,day) }
    {
        d = substr($1, 1, 10); if (d !~ /^[0-9][0-9][0-9][0-9]-/) next
        lv = $3; cp = $4; t = $2
        rec[d]++; trec++; allday[d] = 1
        if (lv == "I") { inf[d]++; tinf++ } else if (lv == "W") { warn[d]++; twarn++ } else if (lv == "E") { err[d]++; terr++ }
        if (cp == "T") { cT[d]++; tT++ } else if (cp == "P") { cP[d]++; tP++ } else if (cp == "S") { cS[d]++; tS++ }
        if (t != "") { if (!(d in first) || t < first[d]) first[d] = t; if (!(d in last) || t > last[d]) last[d] = t }
        if (lv != "I") addline(d, $1 " " $2, lvlname(lv) " " compname(cp) "  " substr($5, 1, 200))   # Warning/Error drill lines
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
                printf "ROW\t@{href=../day/%s.html}%s\t%d\t%d\t%d\t%d\t%d\t%s%%\t%d\t%d\t%d\t%s\t%s\t@data:loglines=%s\n", \
                    d, d, rec[d], w, inf[d]+0, warn[d]+0, err[d]+0, ep, cT[d]+0, cP[d]+0, cS[d]+0, fi, la, lastlines(d)
            } else {
                printf "ROW\t%s\t0\t0\t0\t0\t0\t0.0%%\t0\t0\t0\t-\t-\t@data:loglines=\n", d
            }
        }
        # noisiest component overall
        split("TM PESITD SSHD", cn, " "); ct[1]=tT; ct[2]=tP; ct[3]=tS
        noisy = cn[1]; noisyc = tT+0; for (i = 2; i <= 3; i++) if ((ct[i]+0) > noisyc) { noisyc = ct[i]+0; noisy = cn[i] }
        tep = trec > 0 ? sprintf("%.1f", terr * 100 / trec) : "0.0"
        printf "TOT|%d|%d|%d|%d|%s|%d|%d|%d\n", trec, tinf+0, twarn+0, terr+0, tep, tT+0, tP+0, tS+0
        printf "KPI|%d|%s|%d|%s|%d|%s|%d|%s|%s\n", ndays, busyd, busyc, worstd, worste, noisy, noisyc, fromjdn(mn), fromjdn(mx)
    }
' "$PARSED")

if [ -z "$agg" ]; then echo "No usable records found." >&2; rm -f "$OUT"; exit 0; fi

rows=$(printf '%s\n' "$agg" | grep '^ROW')
IFS='|' read -r _ trec tinf twarn terr tep tT tP tS <<< "$(printf '%s\n' "$agg" | grep '^TOT|')"
IFS='|' read -r _ ndays busyd busyc worstd worste noisy noisyc kfrom kto <<< "$(printf '%s\n' "$agg" | grep '^KPI|')"
[ "$ndays" -eq 1 ] && total_label="Totals for 1 day" || total_label="Totals for $ndays days"

{
    printf 'TITLE\tTop view\n'
    printf 'DESC\tThe whole server log at a glance: per day, the records, the Info/Warning/Error split and error rate, and how busy each component (TM, PESITD, SSHD) was.\n'
    printf 'INTRO\tThe server log at a glance. Over **%s** day(s) (%s → %s): **%s** records — **%s** errors (**%s%%**) and **%s** warnings. Busiest day **%s** (**%s** records); most errors on **%s** (**%s**). The noisiest component is **%s** (**%s** records). Click a day for its 10 most recent Warning/Error lines.\n' \
        "$ndays" "$kfrom" "$kto" "$trec" "$terr" "$tep" "$twarn" "$busyd" "$busyc" "$worstd" "$worste" "$noisy" "$noisyc"
    printf 'TABLE\t\twide\ttotaltop\tdatereset\tpct=6:5:1\n'
    printf 'HEAD\tDate\tRecords\tLoad\tInfo\tWarnings\tErrors\tError %%\tTM\tPESITD\tSSHD\tFirst\tLast\n'
    printf 'KIND\ttext\tnum\tbar\tnum\tnumwarn\tnumfailed\tnum\tnum\tnum\tnum\ttext\ttext\n'
    printf 'TOTAL\t%s\t@{class=num}%s\t\t@{class=num}%s\t@{class=num warn}%s\t@{class=num failed}%s\t@{class=num}%s%%\t@{class=num}%s\t@{class=num}%s\t@{class=num}%s\t\t\n' \
        "$total_label" "$trec" "$tinf" "$twarn" "$terr" "$tep" "$tT" "$tP" "$tS"
    printf '%s\n' "$rows"
    printf 'NOTE\tOne row = one calendar day. Records and the Info/Warning/Error and per-component (TM/PESITD/SSHD) columns are additive — a date-filtered range re-totals them. Error %% is that day'\''s Errors ÷ Records. Warnings are tinted amber, Errors red. Click a day to expand its 10 most recent Warning/Error lines (newest first); days with none are not clickable. To see what caused a spike day, open **Error Reasons** or **Top Messages** (tabs above) and narrow their From/To to that day — this page always loads at the full range, so set the range on those tabs.\n'
    printf 'SUMMARY\tDays: %s  |  Records: %s  |  Errors: %s (%s%%)  |  Warnings: %s  |  Noisiest: %s\n' "$ndays" "$trec" "$terr" "$tep" "$twarn" "$noisy"
    printf 'FOOT\tGenerated on %s from %s file(s)\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${#files[@]}"
} > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"

echo "Data written to $OUT ($ndays day(s), $trec record(s))." >&2
