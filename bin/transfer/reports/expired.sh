#!/usr/bin/env bash
#
# expired.sh
# Staged but never collected: a UC2 file waits STAGED until the partner fetches
# it, and the nightly File Maintenance retention sweep (03:00, ~11 days) deletes
# whatever nobody picked up — outcome Expired, never delivered. Four tables:
# how long a file survives, which accounts the losses belong to, what each sweep
# night removed, and whether the staging weekday matters.
#
# The deletion leaves NO transfer-log record — the evidence is only the server
# log's "File Maintenance … finished. Deleted files […]" lines, which
# bin/expire-files.sh joins onto the Waiting rows, setting _files.tsv col 2 to
# Expired and col 22 to the deletion timestamp. So this report reads only the
# transfer cache, but the answer exists because of the server log.
#
# Was an analyses insight page until 2026-07; it is a transfer report from then
# so its page and its script sit with the other subscription problems. The
# entity columns are KIND acct/ptn, so the renderer resolves their detail-page
# links through the slugmaps and the page needs no slugmap join of its own.
#
# A CURRENT-STATE audit: every table is `nofilter`, the date range never narrows
# it (the old page had no From/To either).
#
# Reads data/_files.tsv (2 outcome, 3 account, 4 date, 5 time, 8 size,
# 20 partner, 21 wait_ms, 22 expired-at). Writes data/expired.rpt.
#
# Usage:
#   ./expired.sh
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib.sh"
mkdir -p "$REPORTS_DIR"
OUT="$REPORTS_DIR/expired.rpt"

shopt -s nullglob
files=("$INPUT_DIR"/*.csv)
shopt -u nullglob
if [ ${#files[@]} -eq 0 ]; then
    echo "No *.csv in $INPUT_DIR — building from the EMPTY caches (config-only estate)" >&2
fi
ensure_parsed
skip_if_fresh "$OUT" "${BASH_SOURCE[0]}"
echo "Found ${#files[@]} file(s) in '$INPUT_DIR', processing..." >&2

TMPD=$(mktemp -d "${TMPDIR:-/tmp}/axexp.XXXXXX")
trap 'rm -rf "$TMPD"' EXIT

# ONE pass over _files.tsv -> the four section extracts + one stats line.
# Expired = col 2; Collected = a staged file that WAS picked up (col 21 set);
# Waiting = still staged. Ages are calendar days, staging date -> deletion date.
awk -F'\t' -v D="$TMPD" '
    function jdn(y,m,d,  a){ a=int((14-m)/12); y=y+4800-a; m=m+12*a-3; return d+int((153*m+2)/5)+365*y+int(y/4)-int(y/100)+int(y/400)-32045 }
    function j(ds,  p){ split(ds,p,"-"); return jdn(p[1]+0,p[2]+0,p[3]+0) }
    $2 == "Expired" {
        n++; b += $8
        split($22, dp, " "); age = j(dp[1]) - j($4); agesum += age
        ages[age]++
        ea[$3]++; eb[$3] += $8; eage[$3] += age
        if (fs[$3] == "" || $4 " " $5 < fs[$3]) fs[$3] = $4 " " substr($5, 1, 8)
        if ($4 " " $5 > lsx[$3]) lsx[$3] = $4 " " substr($5, 1, 8)
        if ($22 > ld[$3]) ld[$3] = $22
        night[dp[1]]++; nightb[dp[1]] += $8
        if (!((dp[1] SUBSEP $3) in na)) { na[dp[1] SUBSEP $3] = 1; nacct[dp[1]]++ }
        ewd[j($4) % 7]++
        if (pt[$3] == "" && $20 != "") pt[$3] = $20
        next
    }
    $21 != "" { cn++; ca[$3]++; cwd[j($4) % 7]++; next }
    $2 == "Waiting" { wn++; wa[$3]++ }
    END {
        printf "%d\t%d\t%d\t%d\t%d\n", n+0, b+0, agesum+0, cn+0, wn+0 > (D "/x_stats")
        for (a in ea) printf "%s\t%d\t%d\t%d\t%d\t%d\t%s\t%s\t%s\t%s\n", \
            a, ea[a], ca[a]+0, wa[a]+0, eb[a], eage[a], fs[a], lsx[a], ld[a], pt[a] > (D "/x_acct")
        for (d in night) printf "%s\t%d\t%d\t%d\n", d, night[d], nightb[d], nacct[d]+0 > (D "/x_night")
        for (g in ages) printf "%d\t%d\n", g, ages[g] > (D "/x_age")
        for (w = 0; w < 7; w++) printf "%d\t%d\t%d\n", w, ewd[w]+0, cwd[w]+0 > (D "/x_wd")
    }
' "$FILES"
[ -f "$TMPD/x_stats" ] || printf '0\t0\t0\t0\t0\n' > "$TMPD/x_stats"
IFS=$'\t' read -r nexp bexp agesum ncoll nwait < "$TMPD/x_stats"

hsz() { awk -v b="$1" 'BEGIN{ if (b>=1073741824) printf "%.1f GB", b/1073741824
    else if (b>=1048576) printf "%.1f MB", b/1048576
    else if (b>=1024)    printf "%.1f KB", b/1024
    else                 printf "%d B", b }'; }
hb=$(hsz "$bexp")
avgage=$(awk -v s="$agesum" -v n="$nexp" 'BEGIN{ printf "%.1f", n ? s/n : 0 }')
share=$(awk -v e="$nexp" -v c="$ncoll" 'BEGIN{ printf "%.1f", (e+c) ? e*100/(e+c) : 0 }')

{
    printf 'TITLE\tExpired\n'
    printf 'DESC\tStaged UC2 files the retention sweep deleted before any pickup: how long until expiry, which accounts never collect, what each sweep night removed, and the never-delivered volume.\n'
    printf 'INTRO\tA **UC2** file waits **staged** until the partner collects it — and the nightly File Maintenance retention sweep (03:00, ~11 days) deletes whatever nobody picked up: outcome **Expired**, never delivered. **%s** File(s) went that way, **%s%%** of every staged file whose fate is already decided, worth **%s** that never reached a partner. The per-subscription view is on **Waiting**.\n' \
        "$nexp" "$share" "$hb"

    printf 'STAT\tred\t%s\tExpired Files\n' "$nexp"
    printf 'STAT\twhite\t%s%%\tof resolved staged Files\n' "$share"
    printf 'STAT\twhite\t%s\tNever-delivered volume\n' "$hb"
    printf 'STAT\twhite\t%s d\tAverage staged to deleted\n' "$avgage"
    printf 'STAT\torange\t%s\tStill waiting (in window)\n' "$nwait"

    # ---- 1. the retention curve --------------------------------------------
    printf 'TABLE\tHow long until a staged file expires\tnofilter\tnosearch\n'
    printf 'HEAD\tStaged to deleted\tFiles\tShare\n'
    printf 'KIND\ttext\tnum\tnum\n'
    if [ -s "$TMPD/x_age" ]; then
        LC_ALL=C sort -t"$(printf '\t')" -k1,1n "$TMPD/x_age" | awk -F'\t' -v t="$nexp" \
            '{ printf "ROW\t%d day(s)\t%d\t%.1f%%\n", $1, $2, t ? $2*100/t : 0 }
             END { printf "TOTAL\tTotal (%d row(s))\t@{class=num}%d\t@{class=num}100.0%%\n", NR, t }'
    else
        printf 'ROW\t@{colspan=3}No expired Files in this data window.\n'
        printf 'TOTAL\tTotal (0 rows)\t\t\n'
    fi
    printf 'NOTE\tCalendar days between the staging start and the deletion: ONE global retention (~11 days) — the sweep runs at 03:00, so a file staged before 03:00 expires on calendar day 11, a later one on day 10-11. No account deviates (see the per-account average below), so retention is **not** configured per partner.\n'

    # ---- 2. the accounts ----------------------------------------------------
    printf 'TABLE\tAccounts the expired files belong to\twide\tnofilter\trestint\n'
    printf 'HEAD\tAccount\tPartner\tExpired\tCollected\tWaiting\tPickup rate\tAvg age\tVolume\tFirst staged\tLast staged\tLast deletion\n'
    printf 'KIND\tacct\tptn\tnumfailed\tnumprocessed\tnumwarn\tnum\tnum\tnum\ttext\ttext\ttext\n'
    if [ -s "$TMPD/x_acct" ]; then
        LC_ALL=C sort -t"$(printf '\t')" -k2,2nr -k1,1 "$TMPD/x_acct" | awk -F'\t' '
            function hsz(b) { if (b >= 1073741824) return sprintf("%.1f GB", b/1073741824)
                if (b >= 1048576) return sprintf("%.1f MB", b/1048576)
                if (b >= 1024)    return sprintf("%.1f KB", b/1024)
                return b " B" }
            {
                rate = ($2 + $3) ? $3 * 100 / ($2 + $3) : 0
                # never collected once = a dead pickup flow (red); collects some
                # and lets the rest expire = orange
                printf "ROW\t%s\t%s\t%d\t%d\t%d\t%.0f%%\t%.1f d\t%s\t%s\t%s\t%s\t@data:res=%s\n", \
                    $1, $10, $2, $3, $4, rate, $6 / $2, hsz($5), $7, $8, substr($9, 1, 19), \
                    ($3 == 0 ? "red" : "orange")
                te += $2; tc += $3; tw += $4; tv += $5
            }
            END { trate = (te + tc) ? tc * 100 / (te + tc) : 0
                  printf "TOTAL\tTotal (%d account(s))\t\t@{class=num failed}%d\t@{class=num processed}%d\t@{class=num warn}%d\t@{class=num}%.0f%%\t\t@{class=num}%s\t\t\t\n", \
                      NR, te, tc, tw, trate, hsz(tv) }'
    else
        printf 'ROW\t@{colspan=11}No expired Files in this data window.\n'
        printf 'TOTAL\tTotal (0 accounts)\t\t\t\t\t\t\t\t\t\t\n'
    fi
    printf 'NOTE\tPickup rate = Collected / (Collected + Expired) for the same account — how often this partner actually fetches what is staged for it. **Red** rows never collected a single file (a dead pickup flow: everything staged for them expires); **orange** rows collect some and let the rest expire. Waiting = staged within the last ~11 days, still collectable.\n'

    # ---- 3. the sweep nights ------------------------------------------------
    printf 'TABLE\tExpiries per sweep night\tnofilter\n'
    printf 'HEAD\tDeletion night\tFiles expired\tVolume\tAccounts\n'
    printf 'KIND\ttext\tnum\tnum\tnum\n'
    if [ -s "$TMPD/x_night" ]; then
        LC_ALL=C sort -t"$(printf '\t')" -k1,1 "$TMPD/x_night" | awk -F'\t' '
            function hsz(b) { if (b >= 1048576) return sprintf("%.1f MB", b/1048576)
                if (b >= 1024) return sprintf("%.1f KB", b/1024)
                return b " B" }
            { printf "ROW\t%s\t%d\t%s\t%d\n", $1, $2, hsz($3), $4
              tn += $2; tv += $3 }
            END { printf "TOTAL\tTotal (%d night(s))\t@{class=num failed}%d\t@{class=num}%s\t\n", NR, tn, hsz(tv) }'
    else
        printf 'ROW\t@{colspan=4}No expired Files in this data window.\n'
        printf 'TOTAL\tTotal (0 nights)\t\t\t\n'
    fi
    printf 'NOTE\tEach row is one 03:00 File Maintenance run and what it removed unclaimed. A missing night means that sweep deleted nothing — nothing staged ~11 days earlier went uncollected. The Accounts column is per night and not additive (one account expires files on many nights), so the Total leaves it blank.\n'

    # ---- 4. the staging weekday --------------------------------------------
    printf 'TABLE\tStaged on which weekday - expired vs collected\tnofilter\tnosearch\n'
    printf 'HEAD\tStaged on\tExpired\tCollected\tExpired share\n'
    printf 'KIND\ttext\tnumfailed\tnumprocessed\tnum\n'
    if [ -s "$TMPD/x_wd" ] && [ "$nexp" -gt 0 ]; then
        awk -F'\t' 'BEGIN{ split("Monday Tuesday Wednesday Thursday Friday Saturday Sunday", W, " ") }
            { e = $2; c = $3
              if (e + c > 0) { printf "ROW\t%s\t%d\t%d\t%.0f%%\n", W[$1 + 1], e, c, e * 100 / (e + c); nr++; te += e; tc += c } }
            END { printf "TOTAL\tTotal (%d weekday(s))\t@{class=num failed}%d\t@{class=num processed}%d\t@{class=num}%.0f%%\n", nr+0, te+0, tc+0, (te+tc) ? te*100/(te+tc) : 0 }' "$TMPD/x_wd"
    else
        printf 'ROW\t@{colspan=4}No staged UC2 Files in this data window.\n'
        printf 'TOTAL\tTotal (0 weekdays)\t\t\t\n'
    fi
    printf 'NOTE\tThe weekday the file was **STAGED** (not deleted). NOTE one account can dominate this split — check the per-account table before reading a weekday pattern as partner behaviour.\n'

    printf 'NOTE\tSource: the transfer parse cache (_files.tsv) — outcome **Expired** and the col-22 deletion timestamp set by **bin/expire-files.sh** from the server log'"'"'s "File Maintenance … finished. Deleted files […]" lines (the deletion leaves NO transfer-log record). Collected = staged files with a pickup (col 21); the sweep also removes already-collected staged copies — routine cleanup, not counted here. Expired files count as **Error** on every report; Waiting files count as **OK**.\n'
    printf 'KEYWORDS\texpired, retention, file maintenance, sweep, deleted, never delivered, uncollected, pickup, staged, uc2, waiting\n'
    printf 'SUMMARY\tExpired: %s Files (%s%% of resolved staged)  |  Volume: %s  |  Average staged to deleted: %s d  |  Still waiting: %s\n' \
        "$nexp" "$share" "$hb" "$avgage" "$nwait"
    printf 'FOOT\tGenerated on %s from %s file(s)\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${#files[@]}"
} > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"

echo "Data written to $OUT ($nexp expired, $ncoll collected, $nwait waiting)." >&2
