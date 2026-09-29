#!/usr/bin/env bash
#
# uc3-polling.sh — the UC3 tab's POLLING tables (2026-09-05, user request: "one
# report about us polling partners"): the former Remote polls report and the
# former analyses Cronjobs page, folded onto uc-status-uc3.html. Writes
# data/server/reports/uc3-polling.rpt, the component
# bin/analyses/reports/uc-status.sh merges right behind uc3-status.rpt; every
# TABLE carries tab=uc3, so publish_lib's segment_rpt keeps them on the UC3 tab
# page, stacked under the status table, instead of opening tab pages of their
# own. (This script lives in bin/analyses/reports/ because its tables ride an
# analyses/ page; it sources the SERVER lib because its DATA is server data.)
#
#   Polls by subscription             } copied from remote-poll.rpt's TABLE blocks
#   Remote directory listing failures } (bin/server/reports/remote-poll.sh, an
#                                       unpublished intermediate since 2026-09-05;
#                                       its first table is also entity-coverage's
#                                       Out proof) — RECALC/@data:buckets/drills
#                                       come along verbatim
#   Configured cronjobs               } the former bin/analyses/publish.sh
#   Schedules that never complete     } write_cronjobs_page (hand-written HTML),
#   a poll                            } re-emitted as .rpt tables
#
# Runs AFTER the server report pool (bin/server/reports.sh): it reads
# remote-poll.rpt and its two sidecars poll-times.tsv / poll-failures.tsv, the
# transfer punctuality-src.rpt (the file-arrival fallback slot), the config export
# (the cron expressions, via jq + bin/cron2human.awk) and the subscription ->
# host xref (the host-keyed authentication failures); the schedule-vs-observed
# classification is bin/cron-observed.awk, shared with polling.sh.
#
# Usage:
#   ./uc3-polling.sh   # -> data/server/reports/uc3-polling.rpt
#
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../server/lib.sh"
mkdir -p "$REPORTS_DIR"
OUT="$REPORTS_DIR/uc3-polling.rpt"
RP="$REPORTS_DIR/remote-poll.rpt"
PT="$REPORTS_DIR/poll-times.tsv"
PF="$REPORTS_DIR/poll-failures.tsv"
PUNCT="$TRANSFER_REPORTS/punctuality-src.rpt"   # the component (2026-09-29: punctuality.rpt is the merged page)
SUBJSON="$FM_INPUT_DIR/subscriptions.json"   # the SKIP-filtered copy when present (server/lib.sh)
XSH="$CONFIG_XREF/_subscriptions-hosts.tsv"
CRON_AWK="$ROOT/bin/cron2human.awk"

if [ ! -f "$RP" ] && [ ! -f "$SUBJSON" ]; then
    rm -f "$OUT"; echo "uc3-polling: neither remote-poll.rpt nor a config export — nothing to add to the UC3 tab." >&2; exit 0
fi
echo "uc3-polling: building the UC3 tab's polling tables ..." >&2

# ---- (c)+(d): the cron tables, computed first (the emit block below prints in page order)
crows=""; xrows=""; total=0; sftp=0; ftp=0; distinct=0; sumpolls=0
if [ -f "$SUBJSON" ] && command -v jq >/dev/null 2>&1; then
    # name ⇥ PROTO ⇥ cron ⇥ human — cron2human.awk (shared with details.sh)
    # appends the plain-English column
    rows=$(jq -r '
        .[] | . as $s
        | (["sftp","ftp"][] as $p
           | ($s.parameters["hybrid_partner_\($p)_relay0_receive_scheduler_cron_expression"]) as $c
           | select($c != null and $c != "")
           | [ $s.name, ($p|ascii_upcase), $c ] | @tsv)
      ' "$SUBJSON" | awk -F'\t' -v CF=3 -f "$CRON_AWK" | LC_ALL=C sort -f)
    # `grep -c .` exits 1 on zero matches — an env with NO cron-scheduled
    # subscriptions must not abort under set -e
    total=$(printf '%s\n' "$rows" | grep -c . || true)
    sftp=$(printf '%s\n' "$rows" | awk -F'\t' '$2=="SFTP"' | grep -c . || true)
    ftp=$(printf '%s\n' "$rows"  | awk -F'\t' '$2=="FTP"'  | grep -c . || true)
    distinct=$(printf '%s\n' "$rows" | cut -f3 | LC_ALL=C sort -u | grep -c . || true)
    _pu="$PUNCT"; [ -f "$_pu" ] || _pu=/dev/null
    _pt="$PT";    [ -f "$_pt" ] || _pt=/dev/null
    _pf="$PF";    [ -f "$_pf" ] || _pf=/dev/null
    _xs="$XSH";   [ -f "$_xs" ] || _xs=/dev/null
    # bin/cron-observed.awk classifies each schedule (shared with the flat
    # Polling page); the second awk shapes two row kinds: "C ⇥ ROW ⇥ …"
    # (Configured cronjobs) and "X ⇥ failures ⇥ starts ⇥ ROW ⇥ …" (the
    # never-completes table, sorted by the shell on its two leading numbers)
    body=$(printf '%s\n' "$rows" | awk -F'\t' -v PUNCT="$_pu" -v POLLT="$_pt" -v PF="$_pf" -v XSH="$_xs" -f "$ROOT/bin/cron-observed.awk" \
        | awk -F'\t' '
            # name ⇥ cron ⇥ schedule ⇥ observed ⇥ bad ⇥ polls ⇥ days ⇥ never ⇥ starts ⇥ failures ⇥ why
            # (a zero count cell is BLANK, like its TOTAL — 2026-09-29; the
            # "-" of the Observed column keeps its meaning: never fires)
            { nm = "@{alink=subscriptions/" $1 "}" $1
              printf "C\tROW\t%s\t%s\t%s\t%s%s\t%s\t%s\n", nm, $2, $3, ($5 ? "@{class=obsbad}" : ""), $4, ($6 ? $6 : ""), ($7 ? $7 : "")
              if ($8 && !(toupper($1) in NEV)) { NEV[toupper($1)] = 1
                  printf "X\t%d\t%d\tROW\t%s\t%s\t%s\t%s\n", $10, $9, nm, ($9 ? $9 : ""), ($10 ? $10 : ""), ($11 != "" ? $11 : "no failure line names this flow in the loaded logs") }
            }')
    crows=$(printf '%s\n' "$body" | command grep $'^C\t' | cut -f2- || true)
    xrows=$(printf '%s\n' "$body" | command grep $'^X\t' | LC_ALL=C sort -t"$(printf '\t')" -k2,2nr -k3,3nr -k5,5 || true)
    sumpolls=$(printf '%s\n' "$crows" | awk -F'\t' '$6 ~ /^[0-9]+$/ { s += $6 } END { print s+0 }')
fi

{
    printf 'TITLE\tUC3 polling\n'
    # ---- (a)+(b): remote-poll.rpt's TABLE blocks, verbatim (+ tab=uc3) ------
    if [ -f "$RP" ]; then
        awk -F'\t' '
            $1 == "TABLE" { t++; print $0 "\ttab=uc3"; next }   # (the anchor= ids went 2026-09-29: nothing links them)
            t && ($1 == "HEAD" || $1 == "GHEAD" || $1 == "KIND" || $1 == "RECALC" || $1 == "ROW" || $1 == "TOTAL") { print; next }
            { next }   # TITLE/DESC/INTRO/NOTE/SUMMARY/FOOT: the merged page has its own (a report page renders no prose)
        ' "$RP"
    else
        printf 'TABLE\tPolls by subscription\ttab=uc3\n'
    fi
    # ---- (c) Configured cronjobs ------------------------------------------
    if [ -f "$SUBJSON" ]; then
        printf 'TABLE\tConfigured cronjobs\twide\tnofilter\ttab=uc3\n'
        printf 'STAT\twhite\t%s\tpolling schedules\n' "$total"
        printf 'STAT\twhite\t%s\tSFTP\n' "$sftp"
        printf 'STAT\twhite\t%s\tFTP\n' "$ftp"
        printf 'STAT\twhite\t%s\tdistinct cron expressions\n' "$distinct"
        printf 'HEAD\tSubscription\tCron expression\tSchedule\tObserved\tPolls\tActive days\n'
        printf 'KIND\tmono\tmono\ttext\ttext\tnum\tnum\n'
        [ -n "$crows" ] && printf '%s\n' "$crows"
        printf 'TOTAL\tTotal (%s cronjobs)\t\t\t\t@{class=num}%s\t\n' "$total" "$([ "${sumpolls:-0}" = 0 ] || printf '%s' "$sumpolls")"
        printf 'LINK\thttps://www.quartz-scheduler.org/documentation/quartz-2.3.0/tutorials/crontrigger.html\tQuartz cron trigger reference\n'
        # ---- (d) Schedules that never complete a poll ----------------------
        if [ -n "$xrows" ]; then
            read -r x_n x_st x_fail <<< "$(printf '%s\n' "$xrows" | awk -F'\t' '{ n++; f += $2; s += $3 } END { printf "%d %d %d", n+0, s+0, f+0 }')"
            printf 'TABLE\tSchedules that never complete a poll\twide\tnofilter\ttab=uc3\n'
            printf 'HEAD\tSubscription\tPoll starts\tFailure lines\tWhat goes wrong\n'
            printf 'KIND\tmono\tnum\tnum\ttext\n'
            printf '%s\n' "$xrows" | cut -f4-
            printf 'TOTAL\tTotal (%s subscription(s))\t@{class=num}%s\t@{class=num}%s\t\n' "$x_n" "$([ "$x_st" = 0 ] || printf '%s' "$x_st")" "$([ "$x_fail" = 0 ] || printf '%s' "$x_fail")"
        fi
    fi
    printf 'FOOT\n'
} > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"

echo "Data written to $OUT ($(command grep -c '^TABLE' "$OUT") table(s): polls $( [ -f "$RP" ] && echo copied || echo absent ), $total cronjob(s))." >&2
