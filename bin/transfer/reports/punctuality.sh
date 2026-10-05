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
#   Irregular  wider (event-driven)
# (The LATE arrivals and MISSED DAYS of the removed Punctuality page — and the
# Last seen column — went 2026-09-29: the one reader takes the five columns
# below.)
#
# Time-OF-DAY granularity per subscription (the day-granularity account
# idleness of stale-accounts.sh went 2026-10-05). The UC status / UC3 tab (Configured cronjobs) shows the CONFIGURED schedules —
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
# 8+-day site. Emits
# pipe-separated (the late / missed drill went with the page, 2026-09-29):
#   P|clsord|spread|site|days|typical|window|class
#   TOT|sites|clock|reg|loose|irreg
agg=$(awk -F'\t' -v MINDAYS="$MIN_DAYS" "$AWKLIB"'
    BEGIN { PI2 = 8 * atan2(1, 1) }
    function hhmm(m) { m = int(m) % 1440; if (m < 0) m += 1440; return sprintf("%02d:%02d", int(m / 60), m % 60) }
    # the minute m moved by whole days to within 12 hours of the centre c
    function unwrap(m, c) { while (m - c > 720) m -= 1440; while (c - m >= 720) m += 1440; return m }
    $12 == "" || $12 == "Unknown" || $4 == "" || $5 == "" { next }   # "Unknown" = no subscription (2026-09-29)
    {
        s = $12; d = $4; j = $7 + 0
        m = substr($5, 1, 2) * 60 + substr($5, 4, 2)
        k = s SUBSEP d
        if (!(k in fm) || m < fm[k]) fm[k] = m
        if (!(k in seenk)) { seenk[k] = 1; days[s]++; dl[s] = dl[s] " " j }
    }
    END {
        for (s in days) {
            if (days[s] < MINDAYS) continue
            nd = split(dl[s], D, " ")
            # per-day arrival minutes, insertion-sorted for the median. The
            # clock is a CIRCLE (2026-09-29 audit F15: arrivals at 23:58 and
            # 00:02 read as a linear 12:00 +-718 min, Irregular, so the
            # late / missed checks skipped a tight midnight flow): the circular
            # mean of the minutes is the centre, every minute is unwrapped to
            # within 12 hours of it, and median, spread and the late test work
            # on those unwrapped minutes. A daytime cluster is unchanged.
            n = 0; cs = 0; sn = 0
            for (i = 1; i <= nd; i++) { m0 = fm[s SUBSEP fromjdn(D[i])] + 0; cs += cos(m0 * PI2 / 1440); sn += sin(m0 * PI2 / 1440) }
            ctr = atan2(sn, cs) * 1440 / PI2
            for (i = 1; i <= nd; i++) { n++; M[n] = unwrap(fm[s SUBSEP fromjdn(D[i])] + 0, ctr) }
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

            printf "P|%d|%09d|%s|%d|%s|%d|%s\n", co, spread, s, days[s], hhmm(med), spread, cls
            nsites++
        }
        printf "TOT|%d|%d|%d|%d|%d\n", nsites+0, nclock+0, nreg+0, nloose+0, nirr+0
    }
' "$FILES")

if [ -z "$agg" ]; then
    echo "No usable records found." >&2
    exit 1
fi

IFS='|' read -r _ n_sites n_clock n_reg n_loose n_irr <<< "$(printf '%s\n' "$agg" | grep '^TOT|')"

n_rows=0

{
    printf 'TITLE\tPunctuality\n'

    printf 'TABLE\tArrival regularity per subscription\twide\tnofilter\n'
    printf 'HEAD\tSubscription\tActive days\tTypical arrival\tWindow\tClass\n'
    while IFS='|' read -r _ co _spd site adays typ spread cls; do
        [ -z "$site" ] && continue
        printf 'ROW\t%s\t%s\t%s\t± %s min\t%s\n' \
            "$site" "$adays" "$typ" "$spread" "$cls"
        n_rows=$((n_rows + 1))
    done <<< "$(printf '%s\n' "$agg" | grep '^P|' | LC_ALL=C sort -t'|' -k2,2n -k3,3 -k4,4)"
    # the empty-state row ends its line like every other (2026-09-28 fix: it
    # used to run into the next NOTE/TOTAL line, rendering that text as a cell)
    if [ "$n_rows" -eq 0 ]; then
        printf 'ROW\t@{colspan=5}No subscription reaches %s active days in this data window.\n' "$MIN_DAYS"
    fi

    printf 'FOOT\n'
} > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"

echo "Data written to $OUT ($n_sites subscription(s): $n_clock clockwork, $n_reg regular, $n_loose loose, $n_irr irregular)." >&2
