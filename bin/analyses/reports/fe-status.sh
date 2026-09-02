#!/usr/bin/env bash
#
# fe-status.sh — "FE status information" (Analyses → Configuration, 2026-09-02,
# user request): one row per FE login — the partner-side credential the UC2 /
# UC4 flows are served through — with everything a status or migration check
# wants on one line:
#
#   Login          every configured login (base/_logins.tsv roster); a login
#                  that only input/<env>/logons_old.txt names is listed too —
#                  an old-gateway user with no configuration on this platform
#   Use cases      the use cases of its subscriptions: UC2 (the partner pulls),
#                  UC4 (the partner pushes) or UC2/UC4 (both — the mailbox
#                  pair). A subscription's use case is its name prefix, else
#                  the DERIVED one (xref/_subscriptions-ucderived.tsv, the
#                  hybrid production flows); any other use case shows as well
#   Cloud          the newest successful authentication on THIS platform, any
#                  protocol (bin/logons.sh — the detail pages' Logons figure),
#                  as date + hh:mm; empty when there is none
#   Last Gateway   the login's logon stamp on the OLD gateway, verbatim from
#                  input/<env>/logons_old.txt
#   Files in/out   the login's Files in the transfer window (_files.tsv col
#                  14) split by the FILE MOVEMENT (col 17): in = delivered to
#                  us (UC4), out = picked up from us (UC2) — the home page's
#                  In/Out split; a File with no movement counts in neither;
#                  a 0 renders empty
#   Waiting        those staged and not yet collected (outcome Waiting)
#   Oldest waiting how long the login's OLDEST staged, uncollected File has
#                  waited — "5 days", "12 hours", "45 minutes", "10 seconds"
#                  (one unit, truncated), aged against the NEWEST File in the
#                  whole cache (the data's "now", the Waiting report's anchor:
#                  a wall clock would make an unchanged export age between
#                  builds); @{sortval=<seconds>} keeps it numerically sortable
#
# Rows tint by the login's RESULT colour (restint, the base cache's third
# column); an old-gateway-only login has no result and stays untinted. Every
# figure is full-period (no date filter). Reads the config caches, the
# transfer files cache, the server logon summary and the input file; sources
# the ANALYSES lib, so the .rpt lands in data/<env>/analyses/reports/ and
# the page in docs/<env>/analyses/ (SUBS_GROUP_REPORTS, analyses:fe-status).
#
# input/<env>/logons_old.txt — one login per line, "<login> <stamp…>": the
# first token (up to the first run of spaces, TABs, commas or semicolons) is
# the login, matched case-insensitively; the rest of the line, trimmed, is
# the Last Gateway cell as written. Blank lines and lines starting with #
# are ignored; CRLF is tolerated. A missing file is not an error — the
# column simply stays empty.
#
# Usage:
#   ./fe-status.sh   # -> data/<env>/analyses/reports/fe-status.rpt
#
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib.sh"
source "$ROOT/bin/logons.sh"     # ensure_logons(): the per-login logon summary
OUT="$REPORTS_DIR/fe-status.rpt"
LBASE="$DATA/flow-manager/base/_logins.tsv"
LSUB="$DATA/flow-manager/xref/_logins-subscriptions.tsv"
UCDF="$DATA/flow-manager/xref/_subscriptions-ucderived.tsv"
TF="$DATA/transfer/cache/_files.tsv"
SCACHE="$DATA/server/cache"
OLD="$ROOT/input/$AXWAY_ENV/logons_old.txt"

if [ ! -f "$LBASE" ]; then
    echo "fe-status: no $LBASE (config not extracted) — page not published." >&2
    rm -f "$OUT"
    exit 0
fi
# the logon summary: the server reports build it first in bin/build.sh; a
# manual run builds it here (atomic, cmp-guarded). An env without a server
# parse cache gets an EMPTY summary — every Cloud stamp then stays empty.
ensure_logons "$SCACHE"
LOGONS="$SCACHE/_logons.tsv"
[ -f "$LSUB" ] || LSUB=/dev/null
[ -f "$UCDF" ] || UCDF=/dev/null
[ -f "$TF" ]   || TF=/dev/null
[ -f "$OLD" ]  || OLD=/dev/null
skip_if_fresh "$OUT" "${BASH_SOURCE[0]}" "$LBASE" "$LSUB" "$UCDF" "$TF" "$LOGONS" "$OLD"

GENDATE=$(date '+%Y-%m-%d %H:%M:%S')

# One awk pass: the roster + joins in BEGIN (small files), the files cache
# streamed, then one "R" line per login and one "S" line of stat figures.
# The "-" sentinel keeps empty middle fields from collapsing (a TAB is IFS
# whitespace — the CLAUDE.md gotcha); the row writer swaps them back.
awk -F'\t' -v LBASE="$LBASE" -v LSUB="$LSUB" -v UCDF="$UCDF" -v LOGONS="$LOGONS" -v OLD="$OLD" '
    function ucof(s) { if (match(s, /^UC[0-9]+/)) return substr(s, 1, RLENGTH); if (toupper(s) in UCD) return UCD[toupper(s)]; return "" }
    function trim(s) { sub(/^[ \t\r]+/, "", s); sub(/[ \t\r]+$/, "", s); return s }
    function nz(s) { return (s == "" ? "-" : s) }
    function jdn(y,m,d,  a9){ a9=int((14-m)/12); y=y+4800-a9; m=m+12*a9-3; return d+int((153*m+2)/5)+365*y+int(y/4)-int(y/100)+int(y/400)-32045 }
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
        # the use cases per login, through its subscriptions (a set)
        while ((getline l < LSUB) > 0) { n = split(l, a, "\t"); if (n < 2 || a[1] == "" || a[2] == "") continue
            k = toupper(a[1]); if (!(k in IDX)) continue
            u = ucof(a[2]); if (u == "") continue
            if (!((k SUBSEP u) in HAS)) { HAS[k SUBSEP u] = 1; UCL[k] = UCL[k] (UCL[k] == "" ? "" : SUBSEP) u } } close(LSUB)
        # the last successful authentication, any protocol — sidecar field 3
        # ("-" = never), as date + hh:mm — the gateway stamp precision (2026-09-02, user request)
        while ((getline l < LOGONS) > 0) { n = split(l, a, "\t"); if (n >= 3 && a[1] != "" && a[3] != "-") LAST[toupper(a[1])] = substr(a[3], 1, 16) } close(LOGONS)
        # the old gateway file (format: see the header)
        while ((getline l < OLD) > 0) {
            l = trim(l); if (l == "" || substr(l, 1, 1) == "#") continue
            if (match(l, /[ \t,;]+/)) { u = substr(l, 1, RSTART - 1); s = trim(substr(l, RSTART + RLENGTH)) } else { u = l; s = "" }
            k = toupper(u); if (k == "") continue
            if (!(k in IDX)) { IDX[k] = ++nr; NAME[nr] = u; RES[nr] = ""; OLDONLY[nr] = 1 }
            GW[k] = s } close(OLD)
        NEWEST = 0
    }
    # the files cache on the command line: col 2 outcome, 4/5 date+time, 14
    # login, 17 the file movement (the home page rule: in / out, else neither).
    # The newest stamp of ALL Files anchors the waiting ages.
    { if ($4 != "") { t9 = tsec($4, $5); if (t9 > NEWEST) NEWEST = t9 } else t9 = 0
      k = toupper($14); if (k == "" || !(k in IDX)) next
      if ($17 == "in") FIN[k]++; else if ($17 == "out") FOUT[k]++
      if ($2 == "Waiting") { WCNT[k]++; if (t9 > 0 && (!(k in WOLD) || t9 < WOLD[k])) WOLD[k] = t9 }
      else if ($2 == "Expired") XCNT[k]++ }
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
            printf "R\t%s\t%s\t%s\t%s\t%s\t%d\t%d\t%d\t%s\t%d\n", NAME[i], nz(uc), ((k in LAST) ? LAST[k] : "-"), ((k in GW) ? nz(GW[k]) : "-"), nz(RES[i]), FIN[k] + 0, FOUT[k] + 0, WCNT[k] + 0, ow, XCNT[k] + 0
        }
        printf "S\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%s\n", nr, s_uc2 + 0, s_uc4 + 0, s_both + 0, s_here + 0, s_never + 0, s_gw + 0, s_old + 0, s_in + 0, s_out + 0, s_wait + 0, s_exp + 0, (gold >= 0 ? hage(gold) : "")
    }
' "$TF" > "$OUT.rows"

IFS=$'\t' read -r _ n_all n_uc2 n_uc4 n_both n_here n_never n_gw n_old n_in n_out n_wait n_exp t_old <<< "$(grep $'^S\t' "$OUT.rows")"

{
    printf 'TITLE\tFE status information\n'
    printf 'DESC\tEvery FE login on one line: its use cases (UC2, UC4 or the UC2/UC4 mailbox pair), the last logon on this platform, the last logon on the old gateway, its Files in and out, the Waiting ones and how long the oldest has waited.\n'
    printf 'INTRO\tOne row per **FE login** — the credential a partner connects with. **Use cases** are those of the login'\''s subscriptions: **UC2** (the partner picks up), **UC4** (the partner delivers) or **UC2/UC4** (both — the mailbox pair). **Cloud** is the newest successful authentication on THIS platform, over any protocol (the detail pages'\'' Logons figure; empty = no logon in the log window). **Last Gateway** is the login'\''s last logon on the OLD gateway, as recorded in input/<env>/logons_old.txt — a login listed there but not configured here still gets a row (untinted), so a partner not yet moved over stands out. **Files in** counts the login'\''s Files delivered to us (UC4) and **Files out** those picked up from us (UC2), over the transfer window; **Waiting** are the staged Files not yet collected, **Expired** those the retention sweep deleted before any pickup, and **Oldest waiting** is how long the oldest of them has waited — aged against the newest transfer in the log, so an unchanged export does not age between builds. Rows are tinted by the login'\''s result colour — green delivering, red failing, orange configured but never seen. Every figure is full-period; a 0 renders empty.\n'
    printf 'STAT\twhite\t%s\tLogins\n' "$n_all"
    printf 'STAT\twhite\t%s\tUC2\n' "$n_uc2"
    printf 'STAT\twhite\t%s\tUC4\n' "$n_uc4"
    printf 'STAT\twhite\t%s\tUC2/UC4\n' "$n_both"
    printf 'STAT\tgreen\t%s\tLogged on here\n' "$n_here"
    printf 'STAT\torange\t%s\tNever logged on here\n' "$n_never"
    printf 'STAT\twhite\t%s\tLast Gateway known\n' "$n_gw"
    printf 'STAT\t%s\t%s\tOld gateway only\n' "$([ "$n_old" -gt 0 ] && echo orange || echo white)" "$n_old"
    printf 'TABLE\tFE logins\twide\tnofilter\trestint\n'
    printf 'HEAD\tLogin\tUse cases\tCloud\tLast Gateway\tFiles in\tFiles out\tWaiting\tExpired\tOldest waiting\n'
    printf 'KIND\tlogin\ttext\ttext\ttext\tnum\tnum\tnumwarn\tnumfailed\ttext\n'
    # sorted by login name; the sentinels swap back here, the result colour
    # becomes the row tint, an old-gateway-only login carries no tint
    grep $'^R\t' "$OUT.rows" | LC_ALL=C sort -t$'\t' -k2,2f | awk -F'\t' '
        { uc = ($3 == "-" ? "" : $3); last = ($4 == "-" ? "" : $4); gw = ($5 == "-" ? "" : $5)
          fin = ($7 + 0 == 0 ? "" : $7); fout = ($8 + 0 == 0 ? "" : $8)   # a 0 shows empty (2026-09-02, user request), like the z-blanked outcome cells
          ow = ($10 == "-" ? "" : $10)
          res = ($6 == "-" ? "" : "\t@data:res=" $6)
          printf "ROW\t%s\t%s\t%s\t%s\t%s\t%s\t%d\t%d\t%s%s\n", $2, uc, last, gw, fin, fout, $9, $11, ow, res }'
    printf 'TOTAL\tTotal (%s logins)\t\t\t\t@{class=num}%s\t@{class=num}%s\t@{class=num warn}%s\t@{class=num failed}%s\t%s\n' "$n_all" "$n_in" "$n_out" "$n_wait" "$n_exp" "$t_old"
    printf 'NOTE\t**input/<env>/logons_old.txt** carries the old gateway'\''s logons, one login per line: the login, then its stamp ("FE000123  2026-09-02 14:35") — the first token is the login (case-insensitive), the rest of the line is shown as written; blank lines and # comments are ignored. The file is per environment and hand-maintained (like BL.txt); when it is missing the column stays empty. A subscription'\''s use case is its name prefix, or the use case DERIVED from the configuration for a flow without one (the hybrid production flows). Files in / Files out count Files (one per CoreId) attributed to the login by their movement direction — the home page'\''s In/Out split — over the whole transfer window. **Oldest waiting** shows one unit, truncated ("5 days", "12 hours", "45 minutes", "10 seconds"), sorts by the exact age, and the Total row carries the oldest of all.\n'
    printf 'KEYWORDS\tfe,login,status,use case,uc2,uc4,mailbox,last logon,gateway,old gateway,migration,files,in,out,waiting,oldest,age,pickup\n'
    printf 'FOOT\tGenerated on %s\n' "$GENDATE"
} > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"
rm -f "$OUT.rows"

echo "Data written to $OUT ($n_all login(s): $n_uc2 UC2, $n_uc4 UC4, $n_both UC2/UC4; $n_here logged on here, $n_gw with a gateway logon, $n_old old-gateway only; $n_in in, $n_out out, $n_wait waiting, oldest ${t_old:-none})." >&2
