#!/usr/bin/env bash
#
# fe-overview.sh — "FE overview" (Analyses → Configuration, 2026-09-02, user
# request; "Partners - Incoming" from 2026-09-03 to 2026-09-13, when the COMBINED
# page analyses/partners-in.html (partners-in.sh: this table + the Incoming
# logon funnel) took that name; this PAGE went 2026-09-29 — the .rpt stays as
# partners-in.sh's data source), one row per FE login (the partner-side
# credential the UC2 / UC4
# flows are served through) — the login's status columns plus its pickup
# figures. It replaced the "FE status information" page (folded in and
# removed 2026-09-02); the "UC2 pickup visits" page keeps the per-subscription
# visit breakdown.
#
#   Login          every configured login (base/_logins.tsv roster); a login
#                  that only input/logons_old.txt names is listed too —
#                  an old-gateway user with no configuration on this platform
#   Use cases      the use cases of its subscriptions: UC2 (the partner pulls),
#                  UC4 (the partner pushes) or UC2/UC4 (both — the mailbox
#                  pair). A subscription's use case is its name prefix, else
#                  the DERIVED one (xref/_subscriptions-ucderived.tsv, the
#                  hybrid production flows); any other use case shows as well
#   Cloud          the newest successful authentication on THIS platform, any
#                  protocol (bin/logons.sh — the detail pages' Logons figure),
#                  as date + hh:mm; empty when there is none
#   Gateway        the login's logon stamp on the OLD gateway, verbatim from
#                  input/logons_old.txt
#   Files in/out   the login's Files in the transfer window (_files.tsv col
#                  14) split by the FILE MOVEMENT (col 17): in = delivered to
#                  us (UC4), out = picked up from us (UC2) — the home page's
#                  In/Out split; a File with no movement counts in neither;
#                  a 0 renders empty
#   Retrieved      the out-side Files the partner actually collected (outcome
#                  Processed): Retrieved + Waiting + Expired = Files out, up to
#                  the rare out-side File whose pickup FAILED (in Files out only)
#   Error          the Files that FAILED, delivered or picked up (outcome
#                  Failed; Expired has its own column) — red when non-zero
#   Waiting        those staged and not yet collected (outcome Waiting)
#   Expired        those the retention sweep deleted before any pickup
#   Oldest waiting how long the login's OLDEST staged, uncollected File has
#                  waited — "5 days", "12 hours", "45 minutes", "10 seconds"
#                  (one unit, truncated), aged against the NEWEST File in the
#                  whole cache (the data's "now", the Waiting report's anchor:
#                  a wall clock would make an unchanged export age between
#                  builds); @{sortval=<seconds>} keeps it numerically sortable
#   Pickups, Pickup pattern — the pickup logons and the cadence of the VISITS
#                  they group into (a gap of more than 30 minutes starts a new
#                  one) — "Once" for a lone visit, the spacing of two, when
#                  there are too few for a cadence (2026-09-03)
# (The "Logon problems" column — logon.sh's _logon-problems.tsv sidecar
# summed, 2026-09-04 — went 2026-09-29: partners-in.sh never took it, the
# funnel's own Disallowed … Locked columns sit on that page.)
#
# The pickup figures (Pickups, Pickup pattern) come from the
# uc2-pickups.tsv sidecar bin/analyses/reports/uc2-status.sh writes into the
# SERVER reports dir (bin/build.sh runs the server reports before the
# analyses reports, so the sidecar is complete here; a missing one leaves
# those cells empty). The sidecar has one row per (account, UC2
# subscription) with the ACCOUNT's logon/visit figures repeated on each of
# the account's UC2 subscriptions — the login group's own on an account
# carrying several FE logins (uc2-status.sh's scoping). Joined here through
# subscription -> login and taken ONCE per (login, account): never the
# per-subscription repeat, never through the account -> login list (that
# would undo the multi-login scoping). A login serving two accounts sums its
# two onces (disjoint logon populations); the pattern is the busiest
# account's. The visit breakdown the sidecar also carries (two-way, delivery
# -only, same-connection) stays on the UC2 pickup visits page (dropped here
# 2026-09-02, user request, together with the Subscriptions column).
#
# Rows tint by the login's RESULT colour (restint, the base cache's third
# column); an old-gateway-only login has no result and stays untinted. Every
# figure is full-period (no date filter). Sources the ANALYSES lib, so the
# .rpt lands in data/analyses/reports/ and the page in
# docs/analyses/ (SUBS_GROUP_REPORTS, analyses:fe-overview).
#
# input/logons_old.txt — one login per line, "<login> <stamp…>": the
# first token (up to the first run of spaces, TABs, commas or semicolons) is
# the login, matched case-insensitively; the rest of the line, trimmed, is
# the Gateway cell as written. Blank lines and lines starting with # are
# ignored; CRLF is tolerated. A missing file is not an error — the column
# simply stays empty.
#
# Usage:
#   ./fe-overview.sh   # -> data/analyses/reports/fe-overview.rpt
#
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib.sh"
source "$ROOT/bin/logons.sh"     # ensure_logons(): the per-login logon summary
OUT="$REPORTS_DIR/fe-overview.rpt"
LBASE="$DATA/flow-manager/base/_logins.tsv"
LSUB="$DATA/flow-manager/xref/_logins-subscriptions.tsv"
UCDF="$DATA/flow-manager/xref/_subscriptions-ucderived.tsv"
TF="$DATA/transfer/cache/_files.tsv"
SCACHE="$DATA/server/cache"
OLD="$ROOT/input/logons_old.txt"
PICKUPS="$DATA/server/reports/uc2-pickups.tsv"   # uc2-status.sh's sidecar (server reports dir)

if [ ! -f "$LBASE" ]; then
    echo "fe-overview: no $LBASE (config not extracted) — page not published." >&2
    rm -f "$OUT"
    exit 0
fi
# the logon summary: the server reports build it first in bin/build.sh; a
# manual run builds it here (atomic). An env without a server
# parse cache gets an EMPTY summary — every Cloud stamp then stays empty.
ensure_logons "$SCACHE"
LOGONS="$SCACHE/_logons.tsv"
[ -f "$LSUB" ]    || LSUB=/dev/null
[ -f "$UCDF" ]    || UCDF=/dev/null
[ -f "$TF" ]      || TF=/dev/null
[ -f "$OLD" ]     || OLD=/dev/null
[ -f "$PICKUPS" ] || PICKUPS=/dev/null   # -f, not -s: an EMPTY sidecar is the valid no-pickup state


# One awk pass: the roster + joins in BEGIN (small files), the files cache
# streamed, then one "R" line per login and one "S" line of stat figures.
# The "-" sentinel keeps empty middle fields from collapsing (a TAB is IFS
# whitespace — the CLAUDE.md gotcha); the row writer swaps them back.
awk -F'\t' -v LBASE="$LBASE" -v LSUB="$LSUB" -v UCDF="$UCDF" -v LOGONS="$LOGONS" -v OLD="$OLD" -v PICKUPS="$PICKUPS" "$AWKLIB"'
    function ucof(s) { if (match(s, /^UC[0-9]+/)) return substr(s, 1, RLENGTH); if (toupper(s) in UCD) return UCD[toupper(s)]; return "" }
    function trim(s) { sub(/^[ \t\r]+/, "", s); sub(/[ \t\r]+$/, "", s); return s }
    function nz(s) { return (s == "" ? "-" : s) }
    function tsec(d,t,   p9){ split(d,p9,"-"); return jdn(p9[1]+0,p9[2]+0,p9[3]+0)*86400 + substr(t,1,2)*3600 + substr(t,4,2)*60 + substr(t,7,2) }
    # one unit, truncated, singular/plural: "5 days", "12 hours", "45 minutes", "10 seconds"
    function hage(s,   n9, u9) {
        s = int(s); if (s < 0) s = 0
        if (s >= 86400)     { n9 = int(s / 86400); u9 = "day" }
        else if (s >= 3600) { n9 = int(s / 3600); u9 = "hour" }
        else if (s >= 60)   { n9 = int(s / 60); u9 = "minute" }
        else                { n9 = s; u9 = "second" }
        return n9 " " u9 (n9 == 1 ? "" : "s")
    }
    BEGIN {
        while ((getline l < UCDF) > 0) { n = split(l, a, "\t"); if (n >= 2 && a[1] != "" && a[2] != "") UCD[toupper(a[1])] = a[2] } close(UCDF)
        # the roster: every configured login in FILE order (name-sorted), with
        # its result colour (third column, bin/build/result.sh)
        while ((getline l < LBASE) > 0) { n = split(l, a, "\t"); if (a[1] == "") continue
            k = toupper(a[1]); if (!(k in IDX)) { IDX[k] = ++nr; NAME[nr] = a[1]; RES[nr] = (n >= 3 ? a[3] : "") } } close(LBASE)
        # the login -> subscription pairs: the use-case set and the INVERSE map
        # subscription -> logins (a SUBSEP-led list) the pickup sidecar joins through
        while ((getline l < LSUB) > 0) { n = split(l, a, "\t"); if (n < 2 || a[1] == "" || a[2] == "") continue
            k = toupper(a[1]); if (!(k in IDX)) continue
            su = toupper(a[2])
            if (!((k SUBSEP "S" SUBSEP su) in HAS)) { HAS[k SUBSEP "S" SUBSEP su] = 1; SL[su] = SL[su] SUBSEP k }
            u = ucof(a[2]); if (u == "") continue
            if (!((k SUBSEP u) in HAS)) { HAS[k SUBSEP u] = 1; UCL[k] = UCL[k] (UCL[k] == "" ? "" : SUBSEP) u } } close(LSUB)
        # the last successful authentication, any protocol — sidecar field 3
        # ("-" = never), as date + hh:mm — the gateway stamp precision
        while ((getline l < LOGONS) > 0) { n = split(l, a, "\t"); if (n >= 3 && a[1] != "" && a[3] != "-") LAST[toupper(a[1])] = substr(a[3], 1, 16) } close(LOGONS)
        # the old gateway file (format: see the header)
        while ((getline l < OLD) > 0) {
            l = trim(l); if (l == "" || substr(l, 1, 1) == "#") continue
            if (match(l, /[ \t,;]+/)) { u = substr(l, 1, RSTART - 1); s = trim(substr(l, RSTART + RLENGTH)) } else { u = l; s = "" }
            k = toupper(u); if (k == "") continue
            if (!(k in IDX)) { IDX[k] = ++nr; NAME[nr] = u; RES[nr] = ""; OLDONLY[nr] = 1 }
            GW[k] = s } close(OLD)
        # the UC2 pickup sidecar (see the header): cols 1 subscription, 2
        # account, 5 pickups, 8 pattern — ONCE per
        # (login, account)
        while ((getline l < PICKUPS) > 0) { n = split(l, a, "\t"); if (n < 16 || a[1] == "") continue
            su = toupper(a[1]); if (!(su in SL)) continue
            m = split(substr(SL[su], 2), LG9, SUBSEP)
            for (j = 1; j <= m; j++) { k = LG9[j]; key = k SUBSEP a[2]
                if (key in PKSEEN) continue
                PKSEEN[key] = 1
                PK[k] += a[5]
                if (!(k in PKBEST) || a[5] + 0 > PKBEST[k]) { PKBEST[k] = a[5] + 0; PAT[k] = a[8] } } } close(PICKUPS)
        NEWEST = 0
    }
    # the files cache on the command line: col 2 outcome, 4/5 date+time, 14
    # login, 17 the file movement (the home page rule: in / out, else neither).
    # The newest stamp of ALL Files anchors the waiting ages.
    { if ($4 != "") { t9 = tsec($4, $5); if (t9 > NEWEST) NEWEST = t9 } else t9 = 0
      k = toupper($14); if (k == "" || !(k in IDX)) next
      if ($17 == "in") FIN[k]++; else if ($17 == "out") { FOUT[k]++; if ($2 == "Processed") RET[k]++ }   # Retrieved = the collected out-side Files
      if ($2 == "Waiting") { WCNT[k]++; if (t9 > 0 && (!(k in WOLD) || t9 < WOLD[k])) WOLD[k] = t9 }
      else if ($2 == "Expired") XCNT[k]++
      if ($2 == "Failed") ECNT[k]++ }   # Error = a failed File, delivered or picked up (2026-09-03, user request; Expired has its own column)
    END {
        gold = -1
        for (i = 1; i <= nr; i++) { k = toupper(NAME[i])
            # the use-case cell: UC1..UC4 in order, any other use case after
            uc = ""
            m = split(UCL[k], U, SUBSEP)
            for (j = 1; j <= 4; j++) if ((k SUBSEP "UC" j) in HAS) uc = uc (uc == "" ? "" : "/") "UC" j
            for (j = 1; j <= m; j++) if (U[j] !~ /^UC[1-4]$/) uc = uc (uc == "" ? "" : "/") U[j]
            if (uc == "UC2") s_uc2++; else if (uc == "UC4") s_uc4++; else if (uc == "UC2/UC4") s_both++
            if (k in LAST) s_here++; else if (!(i in OLDONLY)) s_never++
            if (k in GW) s_gw++
            if (i in OLDONLY) s_old++
            s_in += FIN[k] + 0; s_out += FOUT[k] + 0; s_wait += WCNT[k] + 0; s_exp += XCNT[k] + 0
            # the Oldest waiting cell with its sort key; "-" when nothing waits
            ow = "-"
            if (k in WOLD) { ag = NEWEST - WOLD[k]; if (ag < 0) ag = 0; ow = "@{sortval=" int(ag) "}" hage(ag); if (ag > gold) gold = ag }
            # the pickup figures (0 when the login has no sidecar row) and the
            # retrieved count; the pattern only where pickups exist (drops the sidecar placeholder)
            pk = (k in PK) ? PK[k] + 0 : 0; ret = (k in RET) ? RET[k] + 0 : 0; err = (k in ECNT) ? ECNT[k] + 0 : 0
            pat = (pk > 0 && (k in PAT)) ? PAT[k] : ""
            s_pk += pk; s_ret += ret; s_err += err
            printf "R\t%s\t%s\t%s\t%s\t%s\t%d\t%d\t%d\t%s\t%d\t%d\t%d\t%s\t%d\n", \
                NAME[i], nz(uc), ((k in LAST) ? LAST[k] : "-"), ((k in GW) ? nz(GW[k]) : "-"), nz(RES[i]), \
                FIN[k] + 0, FOUT[k] + 0, WCNT[k] + 0, ow, XCNT[k] + 0, pk, ret, nz(pat), err
        }
        printf "S\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%s\t%d\t%d\t%d\n", nr, s_uc2 + 0, s_uc4 + 0, s_both + 0, s_here + 0, s_never + 0, s_gw + 0, s_old + 0, \
            s_in + 0, s_out + 0, s_wait + 0, s_exp + 0, (gold >= 0 ? hage(gold) : "-"), s_pk + 0, s_ret + 0, s_err + 0
    }
' "$TF" > "$OUT.rows"

IFS=$'\t' read -r _ n_all n_uc2 n_uc4 n_both n_here n_never n_gw n_old n_in n_out n_wait n_exp t_old n_pk n_ret n_err <<< "$(command grep $'^S\t' "$OUT.rows")"
[ "$t_old" = "-" ] && t_old=""   # the sentinel (a middle field — an empty one would shift the read)
# a 0 total renders empty like the 0 cells (the outcome-kind totals z-blank themselves)
nz() { if [ "${1:-0}" -eq 0 ] 2>/dev/null; then printf ''; else printf '%s' "$1"; fi; }

{
    printf 'TITLE\tFE overview\n'
    # PAGELESS: partners-in.sh reads the ROWs (in this baked order), their
    # @data:res and the TOTAL, and emits its OWN TABLE / HEAD / KIND (the
    # default sort, the column groups) — the modifiers went here with the
    # second 2026-09-29 audit; the HEAD stays as the column legend
    printf 'TABLE\tFE logins\n'
    printf 'HEAD\tLogin\tUse cases\tCloud\tGateway\tFiles in\tFiles out\tError\tRetrieved\tWaiting\tExpired\tOldest waiting\tPickups\n'
    # baked Files out DESC, then Files in DESC, then Pickups DESC, then Cloud DESC, then Gateway DESC (no stamp last), then login name (the secondary sort keys — see the
    # TABLE line); the sentinels swap back here, the result colour
    # becomes the row tint, an old-gateway-only login carries no tint. R
    # fields: 2 login 3 uc 4 cloud 5 gw 6 res 7 in 8 out 9 waiting 10 oldest
    # 11 expired 12 pickups 13 retrieved 14 pattern (not written — its one
    # reader, partners-in.sh, dropped it; 2026-09-29) 15 error. The ROW
    # carries @data:res right after Pickups (field 14): partners-in.sh takes
    # cells 3-13 and looks for the tint from field 14 on. The processed-kind count
    # passes its 0 through: the renderer z-blanks it (an empty non-z
    # processed cell would show the base green on an untinted row).
    command grep $'^R\t' "$OUT.rows" | LC_ALL=C sort -t$'\t' -k8,8nr -k7,7nr -k12,12nr -k4,4r -k5,5r -k2,2f | awk -F'\t' '
        function z(v) { return (v + 0 == 0) ? "" : v }   # a 0 shows empty, like the z-blanked outcome cells
        { uc = ($3 == "-" ? "" : $3); last = ($4 == "-" ? "" : $4); gw = ($5 == "-" ? "" : $5)
          ow = ($10 == "-" ? "" : $10)
          res = ($6 == "-" ? "" : "\t@data:res=" $6)
          printf "ROW\t%s\t%s\t%s\t%s\t%s\t%s\t%d\t%d\t%d\t%d\t%s\t%s%s\n", \
              $2, uc, last, gw, z($7), z($8), $15, $13, $9, $11, ow, z($12), res }'
    printf 'TOTAL\tTotal (%s rows)\t\t\t\t@{class=num}%s\t@{class=num}%s\t@{class=num failed}%s\t@{class=num processed}%s\t@{class=num warn}%s\t@{class=num failed}%s\t%s\t@{class=num}%s\n' \
        "$n_all" "$(nz "$n_in")" "$(nz "$n_out")" "$n_err" "$n_ret" "$n_wait" "$n_exp" "$t_old" "$(nz "$n_pk")"
    printf 'FOOT\n'
} > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"
rm -f "$OUT.rows"

echo "Data written to $OUT ($n_all login(s): $n_uc2 UC2, $n_uc4 UC4, $n_both UC2/UC4; $n_here logged on here, $n_gw with a gateway logon, $n_old old-gateway only; $n_in in, $n_out out, $n_wait waiting, oldest ${t_old:-none}; $n_pk pickup(s), $n_ret retrieved)." >&2
