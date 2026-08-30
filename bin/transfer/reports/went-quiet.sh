#!/usr/bin/env bash
#
# went-quiet.sh
# Subscriptions that HAVE carried traffic and then stopped: every subscription
# with at least one File in data/_files.tsv whose LAST File is more than
# QUIET_DAYS (7) days before the end of the data window.
#
# The outcome does not matter — Processed, Failed, Waiting and Expired all count
# as traffic. The question here is not "did it work" but "is anything still
# happening at all", so a flow failing every day is NOT quiet, while one that
# delivered perfectly and then stopped IS. The health verdicts live elsewhere
# (Only red, From green to red, the UCx status reports).
#
# A subscription that has NEVER carried a File is out of scope by construction:
# it cannot have gone quiet, and the Entities "Not seen" view already lists it.
#
# "Days ago" is measured against the LAST DAY IN THE DATA, not today: the site
# reports on an export, so counting from the wall clock would make every figure
# drift with how old the export is. Same convention as stale-accounts.sh.
# Dates use the cache's Julian day number (col 7) — no `date` command.
#
# Reads data/_files.tsv (12 = subscription, 4 = date, 7 = jdn). Writes
# data/went-quiet.rpt.
#
# Usage:
#   ./went-quiet.sh    # reads input/*.csv (via the cache), writes data/went-quiet.rpt
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib.sh"
mkdir -p "$REPORTS_DIR"
OUT="$REPORTS_DIR/went-quiet-src.rpt"

QUIET_DAYS=7   # a subscription unseen for MORE than this many days has gone quiet

shopt -s nullglob
files=("$INPUT_DIR"/*.csv)
shopt -u nullglob
if [ ${#files[@]} -eq 0 ]; then
    echo "No *.csv in $INPUT_DIR — building from the EMPTY caches (config-only estate)" >&2
fi
ensure_parsed
skip_if_fresh "$OUT" "${BASH_SOURCE[0]}"
echo "Found ${#files[@]} file(s) in '$INPUT_DIR', processing..." >&2

# One pass over the logical-transfer cache: per subscription the last day it
# carried a File (any outcome) and how many it carried in all; the window end is
# the largest jdn seen. Emits (unordered — the sort below puts them in order):
#   ROW <TAB> subscription <TAB> days ago
#   TOT <TAB> quiet <TAB> total <TAB> window-end date <TAB> files-in-quiet
agg=$(awk -F'\t' -v QD="$QUIET_DAYS" '
    $12 == "" || $4 == "" || $7 == "" { next }
    {
        n[$12]++
        if ($7 + 0 > last[$12] + 0) { last[$12] = $7 + 0; lastd[$12] = $4 }
        if ($7 + 0 > endj) { endj = $7 + 0; endd = $4 }
    }
    END {
        for (s in n) {
            tot++
            ago = endj - last[s]
            if (ago <= QD) continue
            quiet++; qf += n[s]
            printf "ROW\t%s\t%d\t%s\t%d\n", s, ago, lastd[s], n[s]
        }
        printf "TOT\t%d\t%d\t%s\t%d\n", quiet + 0, tot + 0, endd, qf + 0
    }' "$FILES")

IFS=$'\t' read -r _ n_quiet n_tot end_date n_files <<< "$(printf '%s\n' "$agg" | grep $'^TOT\t')"

# LONGEST-quiet first (most days ago), then by name — the baked order matches
# the table's own default sort (sort=1:-1), so a no-JS reader and the sorted
# view agree and there is no re-sort flash on load.
# `|| true`: zero ROW lines = nothing went quiet — the healthy state the
# report block below renders deliberately; a zero-match grep exiting 1 under
# set -euo pipefail must not abort the script before it gets there.
rows=$(printf '%s\n' "$agg" | grep $'^ROW\t' \
       | LC_ALL=C sort -t"$(printf '\t')" -k3,3nr -k2,2 \
       | awk -F'\t' '{ printf "ROW\t%s\t%s\n", $2, $3 }' || true)

{
    printf 'TITLE\tWent quiet\n'
    printf 'DESC\tSubscriptions that carried Files and then stopped: no traffic at all in the last %s days of the window, whatever the outcome was.\n' "$QUIET_DAYS"
    if [ "${n_quiet:-0}" -eq 0 ]; then
        printf 'INTRO\tEvery one of the **%s** subscriptions that carried a File was still active within the last **%s** days of the window (which ends **%s**). Nothing has gone quiet.\n' \
            "${n_tot:-0}" "$QUIET_DAYS" "${end_date:-?}"
    else
        printf 'INTRO\t**%s** of the **%s** subscriptions that have ever carried a File went **quiet**: their last File is more than **%s days** before the end of the window (**%s**), so nothing at all has happened on them since. The outcome does not matter — Processed, Failed, Waiting and Expired all count as traffic — so this asks whether **anything is still happening**, not whether it is **working**. Between them they carried **%s** Files before stopping. Longest-quiet first; sort the column the other way for the flows that stopped most recently.\n' \
            "$n_quiet" "$n_tot" "$QUIET_DAYS" "$end_date" "$n_files"
    fi

    # total first, then the flagged count — the order every status report uses
    printf 'STAT\twhite\t%s\tSubscriptions with Files\n' "${n_tot:-0}"
    printf 'STAT\tred\t%s\tWent quiet\n' "${n_quiet:-0}"

    printf 'TABLE\tSubscriptions with no recent traffic\tnofilter\tsort=1:-1\n'
    printf 'HEAD\tSubscription\tDays ago last traffic\n'
    printf 'KIND\tsite\tnum\n'
    if [ "${n_quiet:-0}" -eq 0 ]; then
        printf 'ROW\t@{colspan=2}No subscription has been quiet for more than %s days.\n' "$QUIET_DAYS"
    else
        printf '%s\n' "$rows"
    fi
    printf 'NOTE\tA subscription is **quiet** when its most recent File is more than **%s days** before the last day in the data (**%s**) — counted against the WINDOW END, not against today, so the figures do not drift with the age of the export. Every outcome counts as traffic, so a flow that fails daily is not quiet; **Only red** and **From green to red** are where health is judged. A subscription that has never carried a File cannot have gone quiet and is not listed — the Entities **Not seen** view has those. The per-account equivalent, weighed against each account'"'"'s own cadence, is **Stale accounts**.\n' \
        "$QUIET_DAYS" "${end_date:-?}"
    printf 'KEYWORDS\tquiet, silent, stopped, dormant, idle, inactive, no traffic, last seen, days ago, decommissioned, went quiet\n'
    printf 'SUMMARY\tWent quiet: %s of %s subscription(s)  |  Window ends: %s  |  Threshold: %s days\n' \
        "${n_quiet:-0}" "${n_tot:-0}" "${end_date:-?}" "$QUIET_DAYS"
    printf 'FOOT\tGenerated on %s from %s file(s)\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${#files[@]}"
} > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"

echo "Data written to $OUT (${n_quiet:-0} of ${n_tot:-0} subscription(s) quiet for more than $QUIET_DAYS days)." >&2
