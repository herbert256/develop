#!/usr/bin/env bash
#
# pickups.sh — "Pickups": every UC2 (partner collects from us) flow's Pickup
# information in ONE table — the rows of the detail pages' "Pickup
# information" table turned into columns, one row per UC2 subscription.
#
# All figures come verbatim from the uc2-pickups.tsv sidecar uc2-status.sh
# computes (see the column list there), so this page, the UC2 status page,
# the UC2 pickup visits page and the detail-page tables can never disagree.
# Must run AFTER uc2-status.sh (bin/server/reports.sh runs it past the pool
# barrier).
#
# Usage:
#   ./pickups.sh   # -> data/<env>/server/reports/pickups.rpt
#
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib.sh"
mkdir -p "$REPORTS_DIR"
OUT="$REPORTS_DIR/pickups.rpt"
PICKUPS="$REPORTS_DIR/uc2-pickups.tsv"

if [ ! -s "$PICKUPS" ]; then
    echo "pickups: no $PICKUPS (no UC2 flows in this env) — page not published." >&2
    rm -f "$OUT"   # env-split legitimate state: the publish renders a placeholder
    exit 0
fi
skip_if_fresh "$OUT" "${BASH_SOURCE[0]}" "$PICKUPS"

# One row per UC2 subscription, name order (the report is the per-page tables
# collated — a lookup table, not a ranking; the columns sort client-side).
rows=$(LC_ALL=C sort -t$'\t' -k1,1f "$PICKUPS" | awk -F'\t' '
    function sublink(s) { return (s != "") ? "@{alink=subscriptions/" s "}" : "" }
    function stamp(s) { return (s == "" || s == "-") ? "\342\200\224" : substr(s, 1, 19) }
    {
        # UC4 drop = same-connection PROOF only (sidecar col 18): sessions in
        # which the account both delivered and collected — never the
        # time-window visit classes (2026-08)
        shared = ($18 + 0 > 0) ? "yes" : ""
        printf "ROW\t%s%s\t%s\t%s\t%d\t%d\t%d\t%d\t%d\t%s\t%d\t%s\n", \
            sublink($1), $1, stamp($3), stamp($4), $5, $6, $7, $16, $17, $8, $9, shared
        tp += $5; tw += $6; tf += $7; twt += $16; txp += $17; td += $9; nr++
    }
    END { printf "TOTFOOT\t%d\t%d\t%d\t%d\t%d\t%d\t%d\n", nr+0, tp+0, tw+0, tf+0, twt+0, txp+0, td+0 }
')
tot=$(printf '%s\n' "$rows" | grep $'^TOTFOOT\t')
rows=$(printf '%s\n' "$rows" | grep -v $'^TOTFOOT\t' || true)
IFS=$'\t' read -r _ n_rows t_pk t_wf t_f t_wt t_xp t_dl <<< "$tot"

{
    printf 'TITLE\tPickups\n'
    printf 'DESC\tEvery UC2 (partner collects from us) flow'\''s pickup figures side by side: first/last pickup, pickup logons, collected files, waiting and expired files, the pickup cadence and the UC4 shared-connection flag.\n'
    printf 'INTRO\tOne row per **UC2** (partner collects from us) subscription — the detail pages'\'' **Pickup information** tables collated. A **pickup** is a successful SSH logon by the flow'\''s pickup account (shared across that account'\''s UC2 subscriptions); a visit that only **delivered** files (the UC4 twin flow) is not a pickup — its logons count in the **Delivered-only logons** column. **With files** counts the pickups that collected at least one file of the subscription (each collected file credits the logon that took it); **Files picked up** matches the flow'\''s OK figure; **Waiting**/**Expired** are its staged files by outcome. **UC4 drop** = proven same-connection two-way traffic: at least one technical SSH connection (transfer-log Session ID) both delivered and collected a file (see the UC2 pickup visits analysis). A partner collecting over CFT/PESIT logs no SSH pickup, so its logon columns stay empty while files still move.\n'
    printf 'TABLE\tPickups per UC2 subscription\twide\tnofilter\n'
    printf 'HEAD\tSubscription\tFirst pickup\tLast pickup\tPickups\tWith files\tFiles picked up\tWaiting\tExpired\tPattern\tDelivered-only logons\tUC4 drop\n'
    printf 'KIND\tmono\ttext\ttext\tnum\tnum\tnumprocessed\tnum\tnumfailed\ttext\tnum\ttext\n'
    printf '%s\n' "$rows"
    printf 'TOTAL\tTotal (%s subscription(s))\t\t\t@{class=num}%s\t@{class=num}%s\t@{class=num processed}%s\t@{class=num}%s\t@{class=num failed}%s\t\t@{class=num}%s\t\n' \
        "$n_rows" "$t_pk" "$t_wf" "$t_f" "$t_wt" "$t_xp" "$t_dl"
    printf 'NOTE\tThe logon figures (Pickups, Delivered-only logons, Pattern, UC4 drop) are the pickup ACCOUNT'\''s and repeat on each of its UC2 subscriptions; With files, Files picked up, Waiting and Expired are each subscription'\''s own. The **UC4 drop** flag needs same-connection proof — one SSH session (transfer-log Session ID) that both delivered and collected; a partner that delivers and collects over separate connections, even in the same visit, does not raise it. The per-flow story — the visit classification and the shared-connection evidence — is on each subscription'\''s detail page and the UC2 pickup visits analysis.\n'
    printf 'SUMMARY\tFlows: %s  |  Pickups: %s  |  Files picked up: %s  |  Waiting: %s  |  Expired: %s\n' \
        "$n_rows" "$t_pk" "$t_f" "$t_wt" "$t_xp"
    printf 'KEYWORDS\tuc2,pickup,pickups,collect,sftp,logon,waiting,expired,pattern,cadence,uc4,shared connection\n'
    printf 'FOOT\tGenerated on %s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
} > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"

echo "Data written to $OUT ($n_rows UC2 flow(s), $t_pk pickup logon(s), $t_f file(s) picked up)." >&2
