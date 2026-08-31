#!/usr/bin/env bash
#
# uc2-visits.sh — "UC2 pickup visits": what the partner's SSH visits to each
# UC2 (collect-from-us) flow actually DID. The logons of a pickup account
# group into VISITS (a gap > 30 min between logon minutes starts a new one —
# an SFTP client opens several connections per visit); every visit is
# classified by what its window shows in the transfer log:
#   Collected              took at least one staged file (and delivered none)
#   Collected + delivered  a two-way exchange visit: dropped its own files
#                          (the UC4 twin flow) AND took ours, in one visit
#   Delivered only         only handed files over — a UC4 delivery, NOT a
#                          pickup (excluded from every pickup figure)
# The visit classes are TIME windows; the "Same connection" column is the
# hard evidence beside them: distinct technical SSH connections (transfer-log
# Session IDs, sidecar col 18) in which the account both delivered and
# collected — the ONLY figure the detail pages' "Connection shared with UC4
# drop" row fires on (2026-08).
# The leading Pickups column is the account's pickup-LOGON count — the same
# figure the detail page's Pickup information table shows as Total pickups
# (sidecar col 5); empty-handed visits exist in the sidecar (col 15) but are
# not shown here.
#
# All figures come from the uc2-pickups.tsv sidecar uc2-status.sh computes
# (one line per (account, UC2 subscription); col 5 is the pickup-logon count,
# cols 11-15 the visit classification, col 18 the shared-session count) —
# this script only formats, so the two
# reports can never disagree. It must run AFTER uc2-status.sh (bin/server/reports.sh runs it
# past the pool barrier).
#
# A report whose PAGE sits in the Analyses menu (Configuration group, page
# docs/<env>/analyses/uc2-visits.html via SUBS_GROUP_REPORTS) but whose DATA
# is server-side — the uc2-status.sh arrangement.
#
# Usage:
#   ./uc2-visits.sh   # -> data/<env>/server/reports/uc2-visits.rpt
#
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../server/lib.sh"
mkdir -p "$REPORTS_DIR"
OUT="$REPORTS_DIR/uc2-visits.rpt"
PICKUPS="$REPORTS_DIR/uc2-pickups.tsv"

if [ ! -s "$PICKUPS" ]; then
    echo "uc2-visits: no $PICKUPS (no UC2 pickup activity in this env) — page not published." >&2
    rm -f "$OUT"   # env-split legitimate state: the analyses publish renders a placeholder
    exit 0
fi
skip_if_fresh "$OUT" "${BASH_SOURCE[0]}" "$PICKUPS"

# Rows: one per UC2 subscription whose account logged at least one visit,
# session-proven shared connections first, then two-way exchangers, then the
# most pickups; name breaks ties so the order never depends on input order.
# The account's pickup/visit figures repeat on each of its UC2 subscriptions
# (the logon evidence is account-level).
rows=$(LC_ALL=C sort -t$'\t' -k18,18nr -k13,13nr -k5,5nr -k1,1f "$PICKUPS" | awk -F'\t' '
    function sublink(s) { return (s != "") ? "@{alink=subscriptions/" s "}" : "" }
    $11 + 0 > 0 {
        printf "ROW\t%s%s\t%d\t%d\t%d\t%d\t%d\t%d\t%s\n", \
            sublink($1), $1, $5, $12, $13, $14, $18, $7, $8
        tp += $5; tc += $12; tb += $13; td += $14; ts += $18; tf += $7; nr++
    }
    END { printf "TOTFOOT\t%d\t%d\t%d\t%d\t%d\t%d\t%d\n", nr+0, tp+0, tc+0, tb+0, td+0, ts+0, tf+0 }
')
tot=$(printf '%s\n' "$rows" | grep $'^TOTFOOT\t')
rows=$(printf '%s\n' "$rows" | grep -v $'^TOTFOOT\t' || true)
IFS=$'\t' read -r _ n_rows t_p t_c t_b t_d t_s t_f <<< "$tot"

if [ "${n_rows:-0}" -eq 0 ]; then
    echo "uc2-visits: no account with SSH visits — page not published." >&2
    rm -f "$OUT"
    exit 0
fi

{
    printf 'TITLE\tUC2 pickup visits\n'
    printf 'DESC\tWhat each UC2 partner actually does when it connects: total pickups, visits that collected, two-way exchange visits (delivered and collected in one visit), delivery-only visits (the UC4 twin) and the same-connection proof — SSH sessions that both delivered and collected.\n'
    printf 'INTRO\tA pickup account'\''s SSH logons group into **visits** (a gap of more than 30 minutes starts a new one); every visit is classified by what its window shows in the transfer log. **Pickups** counts the account'\''s pickup logons — the figure the detail page'\''s Pickup information table shows as Total pickups. **Collected** took at least one staged file; **Collected + delivered** is a two-way exchange — the partner dropped its own files (the UC4 twin flow) AND took ours in one visit; **Delivered only** is a UC4 delivery, not a pickup, and is excluded from every pickup figure. **Same connection** is the hard evidence beside those time windows: distinct technical SSH connections (transfer-log Session IDs) in which the account **both delivered and collected** a file — the only figure the detail pages'\'' "Connection shared with UC4 drop" row fires on. The pickup and visit figures are the ACCOUNT'\''s, so they repeat on each of its UC2 subscriptions — except on an account carrying **several FE logins** (production), where they are the flow'\''s own **login'\''s**; each subscription links to its detail page, whose Pickup information table carries that flow'\''s own figures.\n'
    printf 'STAT\twhite\t%s\tUC2 flows with visits\n' "$n_rows"
    printf 'STAT\twhite\t%s\tPickups\n' "$t_p"
    printf 'STAT\tgreen\t%s\tCollected\n' "$t_c"
    printf 'STAT\tgreen\t%s\tCollected + delivered\n' "$t_b"
    printf 'STAT\twhite\t%s\tDelivered only\n' "$t_d"
    printf 'STAT\twhite\t%s\tSame connection\n' "$t_s"
    printf 'TABLE\tVisits per UC2 subscription\twide\tnofilter\n'
    printf 'HEAD\tSubscription\tPickups\tCollected\tCollected + delivered\tDelivered only\tSame connection\tFiles picked up\tPickup pattern\n'
    printf 'KIND\tmono\tnum\tnumprocessed\tnumprocessed\tnum\tnum\tnum\ttext\n'
    printf '%s\n' "$rows"
    printf 'TOTAL\tTotal (%s subscription(s))\t@{class=num}%s\t@{class=num processed}%s\t@{class=num processed}%s\t@{class=num}%s\t@{class=num}%s\t@{class=num}%s\t\n' \
        "$n_rows" "$t_p" "$t_c" "$t_b" "$t_d" "$t_s" "$t_f"
    printf 'NOTE\tThe classification is per **visit**, not per logon: an SFTP client typically opens several connections per visit, and they all inherit the visit'\''s class. **Pickups** counts the LOGONS (as on the detail pages), so it runs higher than the visit columns. A visit that collected counts as a pickup **even when it also delivered** — only delivery-only visits are excluded. **Same connection** counts SESSIONS, not visits: a two-way exchange visit whose deliveries and pickups travelled in separate connections (an SFTP client typically opens a fresh connection per operation) shows here as 0 — only a session that provably carried both directions counts, and only that figure raises the detail pages'\'' "Connection shared with UC4 drop" row. A partner collecting over **CFT/PESIT** logs no SSH visit at all, so a flow can pick files up while absent here (its Files picked up still shows on its detail page). **Files picked up** is per subscription; the pickup, visit and session columns are per ACCOUNT and repeat on each of its UC2 subscriptions.\n'
    printf 'SUMMARY\tFlows: %s  |  Pickups: %s  |  Collected: %s  |  Two-way: %s  |  Delivered only: %s  |  Same connection: %s\n' \
        "$n_rows" "$t_p" "$t_c" "$t_b" "$t_d" "$t_s"
    printf 'KEYWORDS\tuc2,pickup,visit,logon,collect,deliver,exchange,two-way,uc4 twin,sftp,session,same connection\n'
    printf 'FOOT\tGenerated on %s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
} > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"

echo "Data written to $OUT ($n_rows flow(s), $t_p pickup(s): $t_c collected, $t_b two-way, $t_d delivered-only visit(s))." >&2
