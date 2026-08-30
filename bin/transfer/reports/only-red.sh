#!/usr/bin/env bash
#
# only-red.sh — "Only red" (Failures & Retries group): subscriptions whose
# EVERY File in _files.tsv is an Error — Failed or Expired, the site-wide
# Error rule — i.e. flows that have NEVER delivered a single OK File in this
# log window. The complement of "From green to red" (which lists the flows
# that USED to work): these never worked at all.
#
# Per qualifying subscription: its Files (all errors), the Failed/Expired
# split, when the failures started and when the last one happened, and how
# long it has been failing — with the standard Error drill-down (there are
# no OK Files to drill).
#
# Outcome policy (site-wide, 2026-07): Error = Failed OR Expired; Processed
# AND Waiting count as OK — so one Waiting (staged, not yet collected) File
# disqualifies a subscription from this list. Full-period semantics
# (`nofilter`, like episodes/from-green-to-red): "never delivered" is a
# whole-window property, so narrowing the date range would fabricate
# entries.
#
# Reads data/_files.tsv (1=coreid, 2=outcome, 4=date_iso, 5=time, 6=sortkey,
# 7=jdn, 8=size, 11=file, 12=dest_site). Writes
# data/transfer/reports/only-red.rpt.
#
# Usage:
#   ./only-red.sh   # reads input/*.csv (via the cache), writes the .rpt
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# TRANSFER lib, not the analyses one: this is a transfer-DATA report (it reads
# the transfer caches and writes data/<env>/transfer/reports/). It lives HERE
# because its page sits in the ANALYSES menu, in the Subscriptions group — the
# same arrangement as cross-reference.sh. bin/transfer/reports.sh still runs it.
source "$SCRIPT_DIR/../lib.sh"
mkdir -p "$REPORTS_DIR"
OUT="$REPORTS_DIR/only-red.rpt"

shopt -s nullglob
files=("$INPUT_DIR"/*.csv)
shopt -u nullglob
if [ ${#files[@]} -eq 0 ]; then
    echo "No *.csv in $INPUT_DIR — building from the EMPTY caches (config-only estate)" >&2
fi
ensure_parsed
skip_if_fresh "$OUT" "${BASH_SOURCE[0]}"
echo "Found ${#files[@]} file(s) in '$INPUT_DIR', processing..." >&2

# One pass over _files.tsv per subscription. A single OK File (Processed or
# Waiting) disqualifies the subscription. Emits pipe-separated lines (the
# drill lists carry no pipes):
#   S|site|files|failed|expired|first|firstjd|last|lastjd|bytes|faildrill
#   TOT|sites|onlyred|maxdate|maxjd
agg=$(awk -F'\t' "$COREIDS_AWK"'
    function human(b,   u, i, v) { split("B KB MB GB TB PB", u, " "); i = 1; v = b + 0
        while (v >= 1024 && i < 6) { v /= 1024; i++ }
        return (i == 1) ? sprintf("%d %s", v, u[i]) : sprintf("%.2f %s", v, u[i]) }
    $12 == "" || $4 == "" { next }
    {
        s = $12
        if (!(s in cnt)) { ord[++ns] = s }
        cnt[s]++
        if ($7 + 0 > maxjd) { maxjd = $7 + 0; maxdate = $4 }
        if ($2 == "Failed" || $2 == "Expired") {
            if ($2 == "Failed") nf[s]++; else nx[s]++
            by[s] += $8
            if (fk[s] == "" || $6 < fk[s]) { fk[s] = $6; fd[s] = $4 " " substr($5, 1, 8); fj[s] = $7 + 0 }
            if ($6 > lk[s])                { lk[s] = $6; ld[s] = $4 " " substr($5, 1, 8); lj[s] = $7 + 0 }
            addtop("F" SUBSEP s, $6, $4 " " $5, $1)
        } else {
            okc[s]++
        }
    }
    END {
        for (i = 1; i <= ns; i++) { s = ord[i]
            if (okc[s] + 0 > 0) continue
            nor++
            printf "S|%s|%d|%d|%d|%s|%d|%s|%d|%s|%s\n", s, cnt[s], nf[s] + 0, nx[s] + 0, \
                fd[s], fj[s], ld[s], lj[s], human(by[s] + 0), buildlist(top["F" SUBSEP s])
        }
        printf "TOT|%d|%d|%s|%d\n", ns + 0, nor + 0, maxdate, maxjd
    }
' "$FILES")

if [ -z "$agg" ]; then
    echo "No usable records found." >&2
    exit 1
fi

IFS='|' read -r _ n_sites n_onlyred last_date max_jd <<< "$(printf '%s\n' "$agg" | grep '^TOT|')"

n_rows=0

{
    printf 'TITLE\tOnly red\n'
    printf 'DESC\tSubscriptions whose every File is an Error (Failed or Expired) — flows that never delivered a single OK File in this log window.\n'
    printf 'KEYWORDS\tonly red, never worked, never green, all failed, no success, dead flow, never delivered, broken\n'
    printf 'INTRO\tThe NEVER-WORKED list: of the **%s** subscription(s) with Files, **%s** have **only Error Files** — Failed or Expired, not one OK delivery in the whole window. The regressions (flows that USED to work and broke later) are on **From green to red** instead. Newest failure first; click an Error count for that subscription'\''s 10 most recent failed Files.\n' \
        "$n_sites" "$n_onlyred"
    printf 'TABLE\tSubscriptions with only Error Files\twide\tnofilter\n'
    printf 'HEAD\tSubscription\tFiles\tFailed\tExpired\tFirst failure\tLast failure\tDays failing\tVolume\n'
    printf 'KIND\tsite\tnumfailed\tnum\tnum\ttext\ttext\tnum\tnum\n'
    # Most recent failure first — the still-actively-failing flows top the list.
    # Printed straight into the report, no per-row command substitution.
    while IFS='|' read -r _ site fcnt nfail nexp first firstjd last lastjd vol fdrill; do
        [ -z "$site" ] && continue
        days=$(( max_jd - firstjd + 1 ))
        printf 'ROW\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t@data:coreids-failed=%s\n' \
            "$site" "$fcnt" "$nfail" "$nexp" "$first" "$last" "$days" "$vol" "$fdrill"
        n_rows=$((n_rows + 1))
    done <<< "$(printf '%s\n' "$agg" | grep '^S|' | LC_ALL=C sort -t'|' -k9,9nr -k2,2)"
    # No trailing newline on the empty-state row — it never had one (it came out
    # of a $(printf …), which strips it), so the NOTE below runs onto its line.
    if [ "$n_rows" -eq 0 ]; then
        printf 'ROW\t@{colspan=8}No subscription is only-red — every subscription with Files delivered at least one OK File in this window.'
    fi
    if [ "$n_onlyred" -gt 0 ]; then
        printf 'TOTAL\tTotal (%s subscriptions)\t\t\t\t\t\t\t\n' "$n_onlyred"
    fi
    printf 'NOTE\tEvery File of these subscriptions is an **Error** — outcome Failed, or Expired (a staged UC2 file the retention sweep deleted before pickup). One Processed or **Waiting** File disqualifies a subscription (Waiting counts as OK site-wide: staged and still collectable). Days failing counts from the first failure to the dataset'\''s last day (%s). Volume is the bytes of the failed attempts. **This table always shows the full period** — "never delivered" is a whole-window property, so a narrowed From/To range would fabricate entries.\n' "$last_date"
    printf 'SUMMARY\tSubscriptions: %s  |  Only red: %s\n' "$n_sites" "$n_onlyred"
    printf 'FOOT\tGenerated on %s from %s file(s)\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${#files[@]}"
} > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"

echo "Data written to $OUT ($n_onlyred of $n_sites subscription(s) only-red)." >&2
