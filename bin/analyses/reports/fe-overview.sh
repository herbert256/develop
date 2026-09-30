#!/usr/bin/env bash
#
# fe-overview.sh — "FE overview" (Analyses → Configuration, 2026-09-02, user
# request; "Partners - Incoming" from 2026-09-03 to 2026-09-13, when the COMBINED
# page analyses/partners-in.html (partners-in.sh: this table + the Incoming
# logon funnel) took that name; this PAGE went 2026-09-29 — the .rpt stays as
# partners-in.sh's data source), one row per FE login (the partner-side
# credential the UC2 / UC4 flows are served through). PAGELESS: it writes only
# the cells partners-in.sh takes (the Error / Oldest waiting / Pickups columns,
# the uc2-pickups.tsv join behind Pickups and the waiting-age anchor went
# 2026-09-30 with the audit — Partners in had dropped them that evening).
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
#                  the rare out-side File whose pickup FAILED
#   Waiting        those staged and not yet collected (outcome Waiting)
#   Expired        those the retention sweep deleted before any pickup
#   Error in/out   the Failed Files by movement (Expired has its own column) —
#                  the Partners in Files In / Files Out Errors (2026-09-30)
#
# Rows tint by the login's RESULT colour (the base cache's third column,
# @data:res); an old-gateway-only login has no result and stays untinted.
# Every figure is full-period (no date filter).
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


# One awk pass: the roster + joins in BEGIN (small files), the files cache
# streamed, then one "R" line per login and one "S" line of stat figures.
# The "-" sentinel keeps empty middle fields from collapsing (a TAB is IFS
# whitespace — the CLAUDE.md gotcha); the row writer swaps them back.
awk -F'\t' -v LBASE="$LBASE" -v LSUB="$LSUB" -v UCDF="$UCDF" -v LOGONS="$LOGONS" -v OLD="$OLD" '
    function ucof(s) { if (match(s, /^UC[0-9]+/)) return substr(s, 1, RLENGTH); if (toupper(s) in UCD) return UCD[toupper(s)]; return "" }
    function trim(s) { sub(/^[ \t\r]+/, "", s); sub(/[ \t\r]+$/, "", s); return s }
    function nz(s) { return (s == "" ? "-" : s) }
    BEGIN {
        while ((getline l < UCDF) > 0) { n = split(l, a, "\t"); if (n >= 2 && a[1] != "" && a[2] != "") UCD[toupper(a[1])] = a[2] } close(UCDF)
        # the roster: every configured login in FILE order (name-sorted), with
        # its result colour (third column, bin/build/result.sh)
        while ((getline l < LBASE) > 0) { n = split(l, a, "\t"); if (a[1] == "") continue
            k = toupper(a[1]); if (!(k in IDX)) { IDX[k] = ++nr; NAME[nr] = a[1]; RES[nr] = (n >= 3 ? a[3] : "") } } close(LBASE)
        # the login -> subscription pairs: the use-case set
        while ((getline l < LSUB) > 0) { n = split(l, a, "\t"); if (n < 2 || a[1] == "" || a[2] == "") continue
            k = toupper(a[1]); if (!(k in IDX)) continue
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
    }
    # the files cache on the command line: col 2 outcome, 14 login, 17 the
    # file movement (the home page rule: in / out, else neither)
    { k = toupper($14); if (k == "" || !(k in IDX)) next
      if ($17 == "in") FIN[k]++; else if ($17 == "out") { FOUT[k]++; if ($2 == "Processed") RET[k]++ }   # Retrieved = the collected out-side Files
      if ($2 == "Waiting") WCNT[k]++
      else if ($2 == "Expired") XCNT[k]++
      else if ($2 == "Failed") { if ($17 == "in") EIN[k]++; else if ($17 == "out") EOUT[k]++ } }   # Error = a failed File (2026-09-03, user request; Expired has its own column), split by movement for Partners in (2026-09-30)
    END {
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
            s_ret += RET[k] + 0; s_ein += EIN[k] + 0; s_eout += EOUT[k] + 0
            printf "R\t%s\t%s\t%s\t%s\t%s\t%d\t%d\t%d\t%d\t%d\t%d\t%d\n", \
                NAME[i], nz(uc), ((k in LAST) ? LAST[k] : "-"), ((k in GW) ? nz(GW[k]) : "-"), nz(RES[i]), \
                FIN[k] + 0, FOUT[k] + 0, WCNT[k] + 0, XCNT[k] + 0, RET[k] + 0, EIN[k] + 0, EOUT[k] + 0
        }
        printf "S\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\n", nr, s_uc2 + 0, s_uc4 + 0, s_both + 0, s_here + 0, s_never + 0, s_gw + 0, s_old + 0, \
            s_in + 0, s_out + 0, s_wait + 0, s_exp + 0, s_ret + 0, s_ein + 0, s_eout + 0
    }
' "$TF" > "$OUT.rows"

IFS=$'\t' read -r _ n_all n_uc2 n_uc4 n_both n_here n_never n_gw n_old n_in n_out n_wait n_exp n_ret n_ein n_eout <<< "$(command grep $'^S\t' "$OUT.rows")"
# a 0 total renders empty like the 0 cells (the outcome-kind totals z-blank themselves)
nz() { if [ "${1:-0}" -eq 0 ] 2>/dev/null; then printf ''; else printf '%s' "$1"; fi; }

{
    printf 'TITLE\tFE overview\n'
    # PAGELESS: partners-in.sh reads the ROWs (in this baked order), their
    # @data:res and the TOTAL, and emits its OWN TABLE / HEAD / KIND; the
    # HEAD stays as the column legend
    printf 'TABLE\tFE logins\n'
    printf 'HEAD\tLogin\tUse cases\tCloud\tGateway\tFiles in\tFiles out\tRetrieved\tWaiting\tExpired\tError in\tError out\n'
    # baked Files out DESC, then Files in DESC, then Cloud DESC, then Gateway
    # DESC (no stamp last), then login name (the Pickups key between Files in
    # and Cloud went with the column, 2026-09-30); the sentinels swap back
    # here, the result colour becomes the row tint, an old-gateway-only login
    # carries no tint. R fields: 2 login 3 uc 4 cloud 5 gw 6 res 7 in 8 out
    # 9 waiting 10 expired 11 retrieved 12 / 13 the Failed Files by movement
    # in / out. The ROW: 2 login, 3 uc, 4 cloud, 5 gw, 6 in, 7 out, 8
    # retrieved, 9 waiting, 10 expired, 11 error in, 12 error out, then
    # @data:res (field 13) — partners-in.sh takes the cells by position. The
    # processed-kind count passes its 0 through: the renderer z-blanks it (an
    # empty non-z processed cell would show the base green on an untinted row).
    command grep $'^R\t' "$OUT.rows" | LC_ALL=C sort -t$'\t' -k8,8nr -k7,7nr -k4,4r -k5,5r -k2,2f | awk -F'\t' '
        function z(v) { return (v + 0 == 0) ? "" : v }   # a 0 shows empty, like the z-blanked outcome cells
        { uc = ($3 == "-" ? "" : $3); last = ($4 == "-" ? "" : $4); gw = ($5 == "-" ? "" : $5)
          res = ($6 == "-" ? "" : "\t@data:res=" $6)
          printf "ROW\t%s\t%s\t%s\t%s\t%s\t%s\t%d\t%d\t%d\t%d\t%d%s\n", \
              $2, uc, last, gw, z($7), z($8), $11, $9, $10, $12, $13, res }'
    printf 'TOTAL\tTotal (%s rows)\t\t\t\t@{class=num}%s\t@{class=num}%s\t@{class=num processed}%s\t@{class=num warn}%s\t@{class=num failed}%s\t@{class=num failed}%s\t@{class=num failed}%s\n' \
        "$n_all" "$(nz "$n_in")" "$(nz "$n_out")" "$n_ret" "$n_wait" "$n_exp" "$n_ein" "$n_eout"
    printf 'FOOT\n'
} > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"
rm -f "$OUT.rows"

echo "Data written to $OUT ($n_all login(s): $n_uc2 UC2, $n_uc4 UC4, $n_both UC2/UC4; $n_here logged on here, $n_gw with a gateway logon, $n_old old-gateway only; $n_in in, $n_out out, $n_wait waiting, $n_ret retrieved)." >&2
