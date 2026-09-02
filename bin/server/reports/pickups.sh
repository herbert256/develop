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
# barrier). Plus ONE joined column (2026-09-02, user request): Last Gateway
# — the flow's login(s)' last logon on the OLD gateway, from the
# hand-maintained input/<env>/logons_old.txt (the FE status information
# page's Last Gateway; same file, same tolerant format: first token = the
# login, the rest of the line = the stamp as written) through the
# subscription -> login xref; several logins join ", "-separated. The
# stamps on this page show date + hh:mm.
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
SL="$CONFIG_XREF/_subscriptions-logins.tsv"
OLD="$(cd "$SCRIPT_DIR/../../.." && pwd)/input/$AXWAY_ENV/logons_old.txt"

if [ ! -s "$PICKUPS" ]; then
    echo "pickups: no $PICKUPS (no UC2 flows in this env) — page not published." >&2
    rm -f "$OUT"   # env-split legitimate state: the publish renders a placeholder
    exit 0
fi
[ -f "$SL" ]  || SL=/dev/null
[ -f "$OLD" ] || OLD=/dev/null
skip_if_fresh "$OUT" "${BASH_SOURCE[0]}" "$PICKUPS" "$SL" "$OLD"

# One row per UC2 subscription. The rows are BAKED in Pickups-descending
# order (sidecar col 5, name as the last tiebreak) because that is the
# SECOND sort key the page opens on (2026-09-01, user request: Waiting desc,
# then Pickups desc). report.js applies the table's own data-sort-init
# (Waiting desc) with Array.prototype.sort, which is STABLE — "ties keep DOM
# order" — so equal Waiting values stay in the order baked here. Change this
# order and you silently change the page's secondary sort.
rows=$(LC_ALL=C sort -t$'\t' -k5,5nr -k1,1f "$PICKUPS" | awk -F'\t' -v SL="$SL" -v OLD="$OLD" '
    function sublink(s) { return (s != "") ? "@{alink=subscriptions/" s "}" : "" }
    # date + hh:mm (2026-09-02, user request — the gateway stamp precision)
    function stamp(s) { return (s == "" || s == "-") ? "\342\200\224" : substr(s, 1, 16) }
    function trim(s) { sub(/^[ \t\r]+/, "", s); sub(/[ \t\r]+$/, "", s); return s }
    function z(v) { return (v + 0 == 0) ? "" : v }   # a 0 count shows empty (2026-09-02, user request); the outcome columns z-blank themselves
    # the Last Gateway cell: the stamps of the subscription'"'"'s logins, in
    # xref order, deduplicated; an em dash when none is known
    function gateway(s,   n, L, i, k, o) {
        n = split(SLOG[toupper(s)], L, SUBSEP); o = ""
        for (i = 1; i <= n; i++) { k = toupper(L[i]); if (!(k in GW) || GW[k] == "") continue
            if (index("\037" o "\037", "\037" GW[k] "\037") == 0) o = o (o == "" ? "" : "\037") GW[k] }
        if (o == "") return "\342\200\224"
        gsub(/\037/, ", ", o); return o
    }
    BEGIN {
        while ((getline l < SL) > 0) { n = split(l, a, "\t"); if (n < 2 || a[1] == "" || a[2] == "") continue
            k = toupper(a[1]); SLOG[k] = SLOG[k] (SLOG[k] == "" ? "" : SUBSEP) a[2] } close(SL)
        while ((getline l < OLD) > 0) {
            l = trim(l); if (l == "" || substr(l, 1, 1) == "#") continue
            if (match(l, /[ \t,;]+/)) { u = substr(l, 1, RSTART - 1); v = trim(substr(l, RSTART + RLENGTH)) } else { u = l; v = "" }
            if (u != "") GW[toupper(u)] = v } close(OLD)
    }
    {
        # UC4 drop = same-connection PROOF only (sidecar col 18): sessions in
        # which the account both delivered and collected — never the
        # time-window visit classes (2026-08)
        shared = ($18 + 0 > 0) ? "yes" : ""
        printf "ROW\t%s%s\t%s\t%s\t%s\t%s\t%s\t%d\t%s\t%d\t%s\t%s\t%s\n", \
            sublink($1), $1, stamp($3), stamp($4), gateway($1), z($5), z($6), $7, z($16), $17, $8, z($9), shared
        tp += $5; tw += $6; tf += $7; twt += $16; txp += $17; td += $9; nr++
    }
    END { printf "TOTFOOT\t%d\t%d\t%d\t%d\t%d\t%d\t%d\n", nr+0, tp+0, tw+0, tf+0, twt+0, txp+0, td+0 }
')
tot=$(printf '%s\n' "$rows" | grep $'^TOTFOOT\t')
rows=$(printf '%s\n' "$rows" | grep -v $'^TOTFOOT\t' || true)
IFS=$'\t' read -r _ n_rows t_pk t_wf t_f t_wt t_xp t_dl <<< "$tot"
# a 0 total renders empty like the 0 cells above (2026-09-02, user request);
# the outcome-kind totals z-blank themselves in the renderer
nz() { if [ "${1:-0}" -eq 0 ] 2>/dev/null; then printf ''; else printf '%s' "$1"; fi; }

{
    printf 'TITLE\tPickups\n'
    printf 'DESC\tEvery UC2 (partner collects from us) flow'\''s pickup figures side by side: first/last pickup, the last logon on the old gateway, pickup logons, collected files, waiting and expired files, the pickup cadence and the UC4 shared-connection flag.\n'
    printf 'INTRO\tOne row per **UC2** (partner collects from us) subscription — the detail pages'\'' **Pickup information** tables collated. A **pickup** is a successful SSH logon by the flow'\''s pickup account (shared across that account'\''s UC2 subscriptions); a visit that only **delivered** files (the UC4 twin flow) is not a pickup — its logons count in the **Delivered-only logons** column. **Last Gateway** is the flow'\''s login'\''s last logon on the OLD gateway, from input/<env>/logons_old.txt (the FE status information page'\''s Last Gateway column). **With files** counts the pickups that collected at least one file of the subscription (each collected file credits the logon that took it); **Files picked up** matches the flow'\''s OK figure; **Waiting**/**Expired** are its staged files by outcome. **UC4 drop** = proven same-connection two-way traffic: at least one technical SSH connection (transfer-log Session ID) both delivered and collected a file (see the UC2 pickup visits analysis). A partner collecting over CFT/PESIT logs no SSH pickup, so its logon columns stay empty while files still move. Stamps show date and hh:mm.\n'
    # default sort: Waiting (column 7, 0-based — Last Gateway sits before it
    # since 2026-09-02) descending, then Pickups (column 4) descending —
    # 2026-09-01, user request. The primary key is this modifier; the
    # secondary is the BAKED row order (see the sort feeding the awk above)
    # preserved by report.js'\''s stable sort. sort=, never nosort, so the
    # header clicks keep working.
    printf 'TABLE\tPickups per UC2 subscription\twide\tnofilter\tsort=7:-1\n'
    printf 'HEAD\tSubscription\tFirst pickup\tLast pickup\tLast Gateway\tPickups\tWith files\tFiles picked up\tWaiting\tExpired\tPattern\tDelivered-only logons\tUC4 drop\n'
    printf 'KIND\tmono\ttext\ttext\ttext\tnum\tnum\tnumprocessed\tnum\tnumfailed\ttext\tnum\ttext\n'
    printf '%s\n' "$rows"
    printf 'TOTAL\tTotal (%s subscription(s))\t\t\t\t@{class=num}%s\t@{class=num}%s\t@{class=num processed}%s\t@{class=num}%s\t@{class=num failed}%s\t\t@{class=num}%s\t\n' \
        "$n_rows" "$(nz "$t_pk")" "$(nz "$t_wf")" "$t_f" "$(nz "$t_wt")" "$t_xp" "$(nz "$t_dl")"
    printf 'NOTE\tThe logon figures (Pickups, Delivered-only logons, Pattern) are the pickup ACCOUNT'\''s and repeat on each of its UC2 subscriptions — except on an account carrying **several FE logins** (production), where they are the flow'\''s own **login'\''s**: each login is a different partner credential. UC4 drop stays account-level; With files, Files picked up, Waiting and Expired are each subscription'\''s own. The **UC4 drop** flag needs same-connection proof — one SSH session (transfer-log Session ID) that both delivered and collected; a partner that delivers and collects over separate connections, even in the same visit, does not raise it. **Last Gateway** joins the hand-maintained input/<env>/logons_old.txt ("<login> <stamp>" per line, shown as written) through the subscription'\''s configured login(s); a flow whose login the file does not name shows an em dash. The per-flow story — the visit classification and the shared-connection evidence — is on each subscription'\''s detail page and the UC2 pickup visits analysis.\n'
    printf 'SUMMARY\tFlows: %s  |  Pickups: %s  |  Files picked up: %s  |  Waiting: %s  |  Expired: %s\n' \
        "$n_rows" "$t_pk" "$t_f" "$t_wt" "$t_xp"
    printf 'KEYWORDS\tuc2,pickup,pickups,collect,sftp,logon,waiting,expired,pattern,cadence,uc4,shared connection,gateway,old gateway\n'
    printf 'FOOT\tGenerated on %s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
} > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"

echo "Data written to $OUT ($n_rows UC2 flow(s), $t_pk pickup logon(s), $t_f file(s) picked up)." >&2
