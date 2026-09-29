#!/usr/bin/env bash
#
# punctuality.sh — arrival-time regularity per subscription: does the daily
# file arrive ON TIME, and did any expected day get skipped? For every
# subscription active on 8+ days, the day's FIRST File defines its arrival
# time; the median of those defines its typical slot and the spread its
# regularity class:
#   Clockwork  ± 15 min or tighter   (cron-driven flows land here, many at ±0)
#   Regular    ± 1 hour
#   Loose      ± 3 hours
#   Irregular  wider (event-driven; late/missed have no meaning there)
# For Clockwork/Regular flows it then flags LATE arrivals (over an hour past
# the typical slot) and MISSED DAYS: a weekday the flow served on 75%+ of its
# calendar occurrences that passed without any File.
#
# Complements: stale-accounts measures idle DAYS vs an account's own cadence
# (day granularity, accounts); this is time-OF-DAY granularity per
# subscription. The UC status / UC3 tab (Configured cronjobs) shows the CONFIGURED schedules —
# a Clockwork row here is the observed side of one of those cron lines.
# Full-period semantics (`nofilter`): the regularity model needs the whole
# window, so the date filter never narrows this page.
#
# Reads data/_files.tsv (4=date_iso, 5=time, 7=jdn, 12=dest_site).
# Writes data/punctuality-src.rpt — a PAGELESS data producer since 2026-09-29
# (user request: the Punctuality pages were removed): its rows are the
# file-arrival fallback slot of the Polling pages (polling.sh / uc3-polling.sh
# via bin/cron-observed.awk: site, active days, typical, window, class).
#
# Usage:
#   ./punctuality.sh    # reads input/*.csv (via the cache), writes data/transfer/reports/punctuality-src.rpt
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib.sh"
mkdir -p "$REPORTS_DIR"
OUT="$REPORTS_DIR/punctuality-src.rpt"   # pageless since 2026-09-29; polling.sh / uc3-polling.sh read THIS file

MIN_DAYS=8   # active days a subscription needs before a rhythm is claimed

shopt -s nullglob
files=("$INPUT_DIR"/*.csv)
shopt -u nullglob
if [ ${#files[@]} -eq 0 ]; then
    echo "No *.csv in $INPUT_DIR — building from the EMPTY caches (config-only estate)" >&2
fi
echo "Found ${#files[@]} file(s) in '$INPUT_DIR', processing..." >&2

# One pass. Per (site, day): the first arrival minute. END classifies each
# 8+-day site and walks the calendar for expected-weekday misses. Emits
# pipe-separated (the late / missed drill went with the page, 2026-09-29):
#   P|clsord|spread|site|days|typical|window|class|late|missed|lastd
#   TOT|sites|clock|reg|loose|irreg|late|missed
agg=$(awk -F'\t' -v MINDAYS="$MIN_DAYS" '
    function fromjdn(j,  a,b,c,dd,e,mm,day,mon,yr){ a=j+32044; b=int((4*a+3)/146097); c=a-int(146097*b/4); dd=int((4*c+3)/1461); e=c-int(1461*dd/4); mm=int((5*e+2)/153); day=e-int((153*mm+2)/5)+1; mon=mm+3-12*int(mm/10); yr=100*b+dd-4800+int(mm/10); return sprintf("%04d-%02d-%02d",yr,mon,day) }
    function hhmm(m) { return sprintf("%02d:%02d", int(m / 60), m % 60) }
    $12 == "" || $12 == "Unknown" || $4 == "" || $5 == "" { next }   # "Unknown" = no subscription (2026-09-29)
    {
        s = $12; d = $4; j = $7 + 0
        m = substr($5, 1, 2) * 60 + substr($5, 4, 2)
        k = s SUBSEP d
        if (!(k in fm) || m < fm[k]) fm[k] = m
        if (!(k in seenk)) { seenk[k] = 1; days[s]++; dl[s] = dl[s] " " j }
        if (j < minjd || minjd == 0) minjd = j
        if (j > maxjd) { maxjd = j; lastm = -1 }
        if (j == maxjd && m > lastm) lastm = m                 # the newest minute of the window
        if (!(s in lastd) || d > lastd[s]) lastd[s] = d
        if (!(s in firstj) || j < firstj[s]) firstj[s] = j
        jd2d[j] = d
    }
    END {
        for (s in days) {
            if (days[s] < MINDAYS) continue
            nd = split(dl[s], D, " ")
            # per-day arrival minutes, insertion-sorted for the median
            n = 0
            for (i = 1; i <= nd; i++) { n++; M[n] = fm[s SUBSEP fromjdn(D[i])] + 0 }
            for (i = 2; i <= n; i++) { v = M[i]; j2 = i - 1; while (j2 >= 1 && M[j2] > v) { M[j2+1] = M[j2]; j2-- } M[j2+1] = v }
            med = (n % 2) ? M[(n + 1) / 2] : int((M[n / 2] + M[n / 2 + 1]) / 2)
            sum = 0; ss = 0
            for (i = 1; i <= n; i++) { sum += M[i]; ss += M[i] * M[i] }
            mean = sum / n; var2 = ss / n - mean * mean; if (var2 < 0) var2 = 0
            spread = int(sqrt(var2) + 0.5)
            if      (spread <= 15)  { cls = "Clockwork"; co = 0; nclock++ }
            else if (spread <= 60)  { cls = "Regular";   co = 1; nreg++ }
            else if (spread <= 180) { cls = "Loose";     co = 2; nloose++ }
            else                    { cls = "Irregular"; co = 3; nirr++ }

            late = 0; missed = 0
            if (co <= 1) {
                # active-day set + per-weekday activity counts
                delete act; delete wact
                for (i = 1; i <= nd; i++) { act[D[i]] = 1; wact[D[i] % 7]++ }
                # calendar occurrences per weekday from the first day OF THE FLOW
                # (2026-09-28 fix: the walk started at the first day of the window,
                # so a flow that began mid-window "missed" every day before it
                # existed) to the last day of the window
                delete wcal
                for (j2 = firstj[s]; j2 <= maxjd; j2++) wcal[j2 % 7]++
                for (j2 = firstj[s]; j2 <= maxjd; j2++) {
                    w = j2 % 7; d2 = jd2d[j2]; if (d2 == "") d2 = fromjdn(j2)
                    if (j2 in act) {
                        am = fm[s SUBSEP d2] + 0
                        if (am > med + 60) late++
                    } else if (j2 == maxjd && lastm < med + 60) {
                        # the window ends before this flow is even late on its
                        # last day: the export cut, not a missed day
                    } else if (wcal[w] >= 2 && wact[w] >= 0.75 * wcal[w]) {
                        missed++
                    }
                }
                tlate += late; tmissed += missed
            }
            printf "P|%d|%09d|%s|%d|%s|%d|%s|%s|%s|%s\n", co, spread, s, days[s], hhmm(med), spread, cls, (co <= 1 ? late : "-"), (co <= 1 ? missed : "-"), lastd[s]
            nsites++
        }
        printf "TOT|%d|%d|%d|%d|%d|%d|%d\n", nsites+0, nclock+0, nreg+0, nloose+0, nirr+0, tlate+0, tmissed+0
    }
' "$FILES")

if [ -z "$agg" ]; then
    echo "No usable records found." >&2
    exit 1
fi

IFS='|' read -r _ n_sites n_clock n_reg n_loose n_irr t_late t_missed <<< "$(printf '%s\n' "$agg" | grep '^TOT|')"

n_rows=0

{
    printf 'TITLE\tPunctuality\n'

    printf 'TABLE\tArrival regularity per subscription\twide\tnofilter\n'
    printf 'HEAD\tSubscription\tActive days\tTypical arrival\tWindow\tClass\tLate\tMissed days\tLast seen\n'
    printf 'KIND\tsite\tnum\ttext\ttext\ttext\tnum\tnum\ttext\n'
    while IFS='|' read -r _ co _spd site adays typ spread cls late missed lastd; do
        [ -z "$site" ] && continue
        late_cell=$late; missed_cell=$missed
        [ "$late" != "-" ] && [ "$late" -gt 0 ] && late_cell="@{class=warn}$late"
        [ "$missed" != "-" ] && [ "$missed" -gt 0 ] && missed_cell="@{class=failed}$missed"
        printf 'ROW\t%s\t%s\t%s\t± %s min\t%s\t%s\t%s\t%s\n' \
            "$site" "$adays" "$typ" "$spread" "$cls" "$late_cell" "$missed_cell" "$lastd"
        n_rows=$((n_rows + 1))
    done <<< "$(printf '%s\n' "$agg" | grep '^P|' | LC_ALL=C sort -t'|' -k2,2n -k3,3 -k4,4)"
    # the empty-state row ends its line like every other (2026-09-28 fix: it
    # used to run into the next NOTE/TOTAL line, rendering that text as a cell)
    if [ "$n_rows" -eq 0 ]; then
        printf 'ROW\t@{colspan=8}No subscription reaches %s active days in this data window.\n' "$MIN_DAYS"
    fi

    printf 'FOOT\n'
} > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"

echo "Data written to $OUT ($n_sites subscription(s), $t_late late, $t_missed missed)." >&2
