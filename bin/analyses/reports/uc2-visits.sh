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
# Session IDs, sidecar col 16) in which the account both delivered and
# collected — the ONLY figure the detail pages' "Connection shared with UC4
# drop" row fires on (2026-08).
# The leading Pickups column is the account's pickup-LOGON count — the same
# figure the detail page's Pickup information table shows as Pickup logons (SSH)
# (sidecar col 5); empty-handed visits are in the visit total (col 10) but
# not shown as a class here.
#
# All figures come from the uc2-pickups.tsv sidecar uc2-status.sh computes
# (one line per (account, UC2 subscription); col 5 is the pickup-logon count,
# cols 10-13 the visit classification, col 16 the shared-session count) —
# this script only formats, so the two
# reports can never disagree. It must run AFTER uc2-status.sh (bin/server/reports.sh runs it
# past the pool barrier).
#
# A report whose table rides the UC2 tab of UC status (tab=uc2, 2026-09-29 —
# no page of its own) but whose DATA is server-side — the uc2-status.sh
# arrangement.
#
# Usage:
#   ./uc2-visits.sh   # -> data/server/reports/uc2-visits.rpt
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

# Rows: one per UC2 subscription whose account logged at least one visit,
# session-proven shared connections first, then two-way exchangers, then the
# most pickups; name breaks ties so the order never depends on input order.
# The account's pickup/visit figures repeat on each of its UC2 subscriptions
# (the logon evidence is account-level).
rows=$(LC_ALL=C sort -t$'\t' -k16,16nr -k12,12nr -k5,5nr -k1,1f "$PICKUPS" | awk -F'\t' '
    function sublink(s) { return (s != "") ? "@{alink=subscriptions/" s "}" : "" }
    function nz(x) { return (x + 0 == 0) ? "" : x + 0 }   # a 0 count is BLANK, as on the sibling tabs (2026-09-29 audit)
    $10 + 0 > 0 {
        printf "ROW\t%s%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", \
            sublink($1), $1, nz($5), nz($11), nz($12), nz($13), nz($16), nz($7), $8
        tf += $7; nr++
        # the logon/visit figures belong to the ACCOUNT (or, on an account with
        # several FE logins, to the flow login), repeated on each of its UC2
        # subscriptions: the totals count every such group ONCE (2026-09-28
        # fix: an account with eight UC2 flows counted its pickups eight
        # times). The sidecar carries no login, so a group is the account plus
        # its logon figures (first / last pickup, pickups) — THE key
        # pickups.sh uses too (2026-09-29: the two keys had drifted apart)
        g = $2 SUBSEP $3 SUBSEP $4 SUBSEP $5
        if (!(g in grp)) { grp[g] = 1; tp += $5; tc += $11; tb += $12; td += $13; ts += $16 }
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
    printf 'STAT\twhite\t%s\tUC2 flows with visits\n' "$n_rows"
    printf 'STAT\twhite\t%s\tPickups\n' "$t_p"
    printf 'STAT\tgreen\t%s\tCollected\n' "$t_c"
    printf 'STAT\tgreen\t%s\tCollected + delivered\n' "$t_b"
    printf 'STAT\twhite\t%s\tDelivered only\n' "$t_d"
    printf 'STAT\twhite\t%s\tSame connection\n' "$t_s"
    # noagg: the account-level columns cannot be re-summed over a searched subset
    # tab=uc2 (2026-09-29): rides the UC2 tab of UC status
    printf 'TABLE\tVisits per UC2 subscription\twide\tnofilter\tnoagg=1,2,3,4,5\ttab=uc2\n'
    printf 'HEAD\tSubscription\tPickups\tCollected\tCollected + delivered\tDelivered only\tSame connection\tFiles picked up\tPickup pattern\n'
    printf 'KIND\tmono\tnum\tnumprocessed\tnumprocessed\tnum\tnum\tnum\ttext\n'
    printf '%s\n' "$rows"
    nzs() { [ "${1:-0}" = 0 ] || printf '%s' "$1"; }
    printf 'TOTAL\tTotal (%s subscription(s))\t@{class=num}%s\t@{class=num processed}%s\t@{class=num processed}%s\t@{class=num}%s\t@{class=num}%s\t@{class=num}%s\t\n' \
        "$n_rows" "$(nzs "$t_p")" "$(nzs "$t_c")" "$(nzs "$t_b")" "$(nzs "$t_d")" "$(nzs "$t_s")" "$(nzs "$t_f")"
    printf 'FOOT\n'
} > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"

echo "Data written to $OUT ($n_rows flow(s), $t_p pickup(s): $t_c collected, $t_b two-way, $t_d delivered-only visit(s))." >&2
