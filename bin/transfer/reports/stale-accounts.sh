#!/usr/bin/env bash
#
# stale-accounts.sh
# Accounts ranked by how long they have been IDLE — the gap between their last
# record and the end of the data window. Surfaces accounts that have "gone quiet"
# (possibly decommissioned or broken upstream) that a per-account summary sorted
# by name would bury. Shows first/last activity, days idle and record count;
# accounts idle for a week or more are tinted. Dates use Julian day numbers
# (portable — no non-POSIX `date`).
#
# Usage:
#   ./stale-accounts.sh    # reads input/*.csv, writes data/stale-accounts.rpt
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib.sh"
mkdir -p "$REPORTS_DIR"
OUT="$REPORTS_DIR/stale-accounts.rpt"

STALE_DAYS=7   # idle threshold (days) at/above which an account is flagged


shopt -s nullglob
files=("$INPUT_DIR"/*.csv)
shopt -u nullglob
if [ ${#files[@]} -eq 0 ]; then
    echo "No *.csv in $INPUT_DIR — building from the EMPTY caches (config-only estate)" >&2
fi
ensure_parsed
skip_if_fresh "$OUT" "${BASH_SOURCE[0]}"
echo "Found ${#files[@]} file(s) in '$INPUT_DIR', processing..." >&2

# Read the logical-transfer cache (data/_files.tsv): one row per transfer,
# 3=account, 4=date_iso, 6=sortkey, 7=jdn. Counts logical transfers per account
# (transfers with no valid date are skipped). Besides the absolute "days idle",
# compute each account's own cadence — the MEDIAN gap between its active days —
# and the idle/gap ratio: a daily account idle 3 days (ratio 3) is more alarming
# than a weekly one idle 5 (ratio < 1), which a flat threshold gets backwards.
#
# Each ACC line carries its finished ROW line — tints included — as its LAST
# pipe-field, so the ranking below is one sort and one cut instead of a fork per
# account. The pipe-fields ahead of it are unchanged, so the sort keys (and the
# whole-line tie-break, decided at the unique account name in field 4) are too.
agg=$(awk -F'\t' -v stale="$STALE_DAYS" '
    $4 == "" { next }
    $3 == "" { next }   # blacklist-blanked account: no cadence to report
    {
        account = $3; iso = $4; sk = $6; jd = $7 + 0
        cnt[account]++; trec++
        adays[account SUBSEP jd] = 1
        if (jd > maxjd) maxjd = jd
        if (!(account in havemin) || sk < minkey[account]) { minkey[account] = sk; firstdisp[account] = iso; havemin[account] = 1 }
        if (!(account in havemax) || sk > maxkey[account]) { maxkey[account] = sk; lastdisp[account] = iso; lastjd[account] = jd; havemax[account] = 1 }
    }
    END {
        # Gather each account'\''s active-day jdns ("d1 d2 ...", unsorted).
        for (k in adays) { split(k, a, SUBSEP); dl[a[1]] = dl[a[1]] " " a[2] }
        for (acct in cnt) {
            nd = split(dl[acct], D, " ")
            # insertion-sort the handful of active days, then collect the gaps
            for (i = 2; i <= nd; i++) { v = D[i]; j = i - 1; while (j >= 1 && D[j] > v) { D[j+1] = D[j]; j-- } D[j+1] = v }
            ng = 0
            for (i = 2; i <= nd; i++) { ng++; G[ng] = D[i] - D[i-1] }
            for (i = 2; i <= ng; i++) { v = G[i]; j = i - 1; while (j >= 1 && G[j] > v) { G[j+1] = G[j]; j-- } G[j+1] = v }
            if (ng == 0) med = 0
            else if (ng % 2) med = G[(ng + 1) / 2]
            else med = (G[ng / 2] + G[ng / 2 + 1]) / 2
            idle = maxjd - lastjd[acct]
            if (med > 0) { ratio = idle / med; rs = sprintf("%.1f", ratio); rsort = sprintf("%012.1f", ratio) }
            else         { ratio = -1;        rs = "-";                    rsort = "-0000000001." }
            gapcell = (med > 0 ? sprintf("%.1f", med) : "-")
            # Tint the cells here: idle at/above the threshold, and a ratio of 2 or
            # more as DISPLAYED (rs, rounded to one decimal — "-" reads as 0, so a
            # cadence-less account is never tinted).
            idlecell  = (idle >= stale) ? sprintf("@{class=failed}%d", idle) : sprintf("%d", idle)
            ratiocell = (rs + 0 >= 2)   ? "@{class=failed}" rs : rs
            printf "ACC|%s|%d|%s|%s|%s|%d|%s|%s|%d|ROW\t%s\t%s\t%s\t%d\t%s\t%s\t%s\t%d\n", \
                rsort, idle, acct, firstdisp[acct], lastdisp[acct], nd, gapcell, rs, cnt[acct], \
                acct, firstdisp[acct], lastdisp[acct], nd, gapcell, idlecell, ratiocell, cnt[acct]
            if (idle >= stale) stalecount++
            if (ratio >= 2) quietcount++
            acctcount++
        }
        printf "TOT|%d|%d|%d|%d\n", acctcount+0, stalecount+0, quietcount+0, trec+0
    }
' "$FILES")

# No emptiness guard on $agg: the awk END always emits the TOT| line, so it is
# never empty — a zero-account dataset still renders a page with zero counts.

IFS='|' read -r _ acct_count stale_count quiet_count tot_records <<< "$(printf '%s\n' "$agg" | grep '^TOT|')"

# Ranked by how overdue the account is relative to its OWN cadence (idle ÷
# median gap), then by absolute idle days; single-active-day accounts (no
# cadence) sort last. The ROW lines ride along as field 11, so cut is all the
# ranking needs (-f11- keeps any pipe inside the row text intact).
# `|| true`: a zero-account dataset yields no ACC| rows, and a zero-match grep
# exits 1 under set -euo pipefail; empty $rows prints nothing below.
rows=$(printf '%s\n' "$agg" | grep '^ACC|' | LC_ALL=C sort -t'|' -k2,2r -k3,3nr | cut -d'|' -f11- || true)
[ -n "$rows" ] && rows+=$'\n'

{
    printf 'TITLE\tStale Accounts\n'
    printf 'DESC\tAccounts gone quiet: idle time compared against each account'\''s own transfer cadence.\n'
    printf 'INTRO\t**%s** accounts total; **%s** idle for **%s+ days**, **%s** overdue by at least **2×** their own cadence. "Median gap" is the account'\''s typical spacing between active days; "Idle ÷ gap" says how many of its own cycles it has missed — a daily account idle 3 days (ratio 3.0) is more alarming than a weekly one idle 5 days (ratio 0.7).\n' \
        "$acct_count" "$stale_count" "$STALE_DAYS" "$quiet_count"
    printf 'TABLE\tAccounts by idle time vs own cadence\twide\tnofilter\n'
    printf 'HEAD\tAccount\tFirst activity\tLast activity\tActive days\tMedian gap\tDays idle\tIdle ÷ gap\tFiles\n'
    printf 'KIND\tacct\ttext\ttext\tnum\tnum\tnum\tnum\tnum\n'
    printf '%s' "$rows"
    printf 'TOTAL\tTotal (%s accounts)\t\t\t\t\t@{class=num failed}%s stale\t@{class=num failed}%s overdue\t@{class=num}%s\n' "$acct_count" "$stale_count" "$quiet_count" "$tot_records"
    printf 'NOTE\tOne File = all the transfers (rows) that make up one logical transfer. Days idle is relative to the most recent File across all accounts, not today. Idle %s+ days is tinted; so is an Idle ÷ gap ratio of 2 or more (two missed cycles). Accounts seen on a single day have no cadence ("-") and sort last. Files without an account attribution (platform-internal, blanked at parse time) are excluded. **This table always shows the full period** — staleness is measured against the dataset'\''s end, so narrowing the From/To range would hide exactly the stalest accounts.\n' "$STALE_DAYS"
    printf 'SUMMARY\tAccounts: %s  |  Idle %s+ days: %s  |  Overdue vs own cadence (2x+): %s\n' "$acct_count" "$STALE_DAYS" "$stale_count" "$quiet_count"
    printf 'FOOT\tGenerated on %s from %s file(s)\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${#files[@]}"
} > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"

echo "Data written to $OUT ($acct_count account(s), $stale_count stale)." >&2
