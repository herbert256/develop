#!/usr/bin/env bash
#
# partners-in.sh — "Partners in" (analyses/partners-in.html; "Partners -
# Incoming" 2026-09-13..09-30): ONE table combining the FE overview
# (fe-overview.rpt — the login's use cases, its Cloud / Gateway stamps, its
# Files) with the Incoming logon funnel (logon.rpt's Incoming table — the
# Logons › Incoming page until 2026-09-30, user request: "merge the two
# reports into one"), one row per login. A MERGED report (reads the two .rpt
# files, like activity.sh): every figure is the source report's own.
#
# THE LAYOUT (2026-09-30, the evening "few little things" batch and the late-night
# one, user request: "Move pattern to as first field in Screening; Remove the
# Logons column in the Logons sub table; Make Logons the second sub table; Rename
# Files In to Files in - UC4; Rename Files Out to Files out - UC2; Screening sub
# table, Remove column Bad Key (add the count of it to Auth failed)"), column
# groups under a GHEAD banner (0-based BUILT column index in brackets):
#   Login [0] · Use cases [1]
#   Logons           Cloud [2] · Gateway [3] (the FE overview stamps)
#   Files in - UC4   Count [4] · Errors [5]  fe-overview Files in / Error in
#   Files out - UC2  Count [6] · Errors [7] · Retrieved [8] · Waiting [9] ·
#                    Expired [10]  fe-overview Files out / Error out (Errors =
#                    the Failed Files; Expired has its column) + the pickup state
#   Screening        Pattern [11] · Allowed [12] · Disallowed [13] ·
#                    Authenticated [14] · Locked [15] · Auth failed [16] — the
#                    funnel, Pattern the logon rhythm; Auth failed = the funnel's
#                    Auth failed + Bad key (both a failed key / password check);
#                    the counts keep their cell drills (the 5 newest log lines)
#                    re-keyed to the new positions, Auth failed has none
# (The funnel's Logons count, No account, Key failures, Session errors, Re-screens, First
# logon and Last logon stay in logon.rpt — reason-boxes reads Key failures,
# verify.sh's twin check Session errors / Re-screens; the FE overview's Error,
# Oldest waiting and Pickups went 2026-09-30 with the audit: no reader.)
#
# Rows = the UNION: every fe-overview row in its baked order (the configured
# logins + the old-gateway-only ones), then the funnel-only logins (seen
# logging on, on no roster) with empty transfer cells and no tint. Tint = the
# fe-overview row tint (the login's RESULT); the red cells keep their red.
# Full period, no date filter (the fe-overview figures have no per-day
# dimension). logon.rpt's WARN (no "Allowed user" line in the whole window)
# is carried over. Runs AFTER both sources: the server pool (logon.sh) and
# analyses wave 1 (fe-overview.sh).
#
# Usage:
#   ./partners-in.sh   # -> data/analyses/reports/partners-in.rpt
#
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib.sh"
OUT="$REPORTS_DIR/partners-in.rpt"
FE="$REPORTS_DIR/fe-overview.rpt"
LG="$DATA/server/reports/logon.rpt"

if [ ! -f "$FE" ]; then
    echo "partners-in: no $FE (fe-overview.sh wrote nothing) — page not published." >&2
    rm -f "$OUT" "$REPORTS_DIR/partners-in-accounts.rpt" "$REPORTS_DIR/partners-in-partners.rpt"
    exit 0
fi
[ -f "$LG" ] || LG=/dev/null


awk -F'\t' -v FE="$FE" -v LG="$LG" '
    function strip(c) { while (index(c, "@{") == 1) sub(/^@\{[^}]*\}/, "", c); return c }
    # the cells in page order (key "" = the TOTAL): Use cases | Logons: Cloud,
    # Gateway | Files in - UC4: Count, Errors | Files out - UC2: Count, Errors,
    # Retrieved, Waiting, Expired | Screening: Pattern, Allowed, Disallowed,
    # Authenticated, Locked, Auth failed (F = fe-overview fields, G = logon.rpt
    # Incoming fields; Auth failed = G 10 + the Bad key count G 7)
    function cells(k) {
        return "\t" F[k, 3] "\t" F[k, 4] "\t" F[k, 5] \
               "\t" F[k, 6] "\t" F[k, 11] "\t" F[k, 7] "\t" F[k, 12] "\t" F[k, 8] "\t" F[k, 9] "\t" F[k, 10] \
               "\t" G[k, 15] "\t" G[k, 3] "\t" G[k, 4] "\t" G[k, 5] "\t" G[k, 9] "\t" addc(G[k, 10], G[k, 7])
    }
    # a + b of two count cells, the class prefix of the first kept (a TOTAL
    # cell carries one); both empty stays empty
    function addc(a, b,   p, x, y) {
        p = ""; if (match(a, /^@\{[^}]*\}/)) p = substr(a, 1, RLENGTH)
        x = strip(a); y = strip(b)
        if (x == "" && y == "") return p
        return p (x + y)
    }
    BEGIN {
        # fe-overview.rpt ROW: 2 login, 3 use cases, 4 Cloud, 5 Gateway, 6 Files
        # in, 7 Files out, 8 Retrieved, 9 Waiting, 10 Expired, 11 Error in, 12
        # Error out, then @data:res= (field 13); TOTAL: 2 label, 3..12 the same
        # cells
        while ((getline l < FE) > 0) { n = split(l, a, "\t")
            if (a[1] == "ROW") { k = toupper(a[2]); if (!(k in IDX)) { IDX[k] = ++nr; NAME[nr] = a[2] }
                for (i = 3; i <= 12; i++) F[k, i] = a[i]
                for (i = 13; i <= n; i++) if (index(a[i], "@data:res=") == 1) FERES[k] = a[i]
                nfe++ }
            else if (a[1] == "TOTAL") { for (i = 3; i <= 12; i++) F["", i] = a[i] }
        } close(FE)
        # logon.rpt (pageless): its WARN lines, then the FIRST table
        # (Incoming) ROW: 2 login, 3 Allowed, 4 Disallowed, 5 Authenticated,
        # 6 No account, 7 Bad key, 8 Key failures, 9 Locked, 10 Auth failed,
        # 11 Session errors, 12 First logon, 13 Last logon, 14 Logons, 15
        # Pattern, 16 Re-screens, then the @data: payloads; TOTAL likewise
        # (its cells carry @{class=…} prefixes)
        t = 0; nw = 0
        while ((getline l < LG) > 0) { n = split(l, a, "\t")
            if (a[1] == "TABLE") { t++; continue }
            if (a[1] == "WARN" && t == 0) { W[++nw] = l; continue }
            if (t != 1) continue
            if (a[1] == "ROW") { nm = strip(a[2]); k = toupper(nm)
                if (!(k in IDX)) { IDX[k] = ++nr; NAME[nr] = nm; nonly++ }
                for (i = 3; i <= 16; i++) G[k, i] = a[i]
                # the cell drills, re-keyed to this table (BUILT column index):
                # Allowed 1 -> 12, Disallowed 2 -> 13, Authenticated 3 -> 14,
                # Locked 7 -> 15 (Auth failed, 8, has none; Bad key, 5, folded
                # into Auth failed, and the dropped columns lose theirs)
                d = ""
                for (i = 17; i <= n; i++) if (index(a[i], "@data:drill-cell-") == 1) { p = index(a[i], "="); if (p == 0) continue
                    ci = substr(a[i], 18, p - 18) + 0
                    nc = (ci >= 1 && ci <= 3) ? ci + 11 : (ci == 7) ? 15 : -1
                    if (nc >= 0) d = d "\t@data:drill-cell-" nc "=" substr(a[i], p + 1) }
                LGDR[k] = d }
            else if (a[1] == "TOTAL") { for (i = 3; i <= 16; i++) G["", i] = a[i] }
        } close(LG)
        print "TITLE\tPartners in"
        for (i = 1; i <= nw; i++) print W[i]
        # the view row (2026-09-30, user request): this Endpoint view, then the
        # Accounts and Partners views bin/rpt-rollup.awk regroups it into
        print "NAV\t1|Endpoint|partners-in.html\t0|Accounts|partners-in-accounts.html\t0|Partners|partners-in-partners.html"
        # default sort Waiting (column 9) descending; the groups start at the
        # Logons, Files in - UC4, Files out - UC2 and Screening columns; the
        # funnel counts keep their log-line drills
        print "TABLE\tLogins\twide\tnofilter\trestint\tsort=9:-1\tgsep=2,4,6,11\tdrill=log line"
        print "GHEAD\t@{colspan=2}\t@{colspan=2,class=gband gsep}Logons\t@{colspan=2,class=gband gsep}Files in - UC4\t@{colspan=5,class=gband gsep}Files out - UC2\t@{colspan=6,class=gband gsep}Screening"
        print "HEAD\tLogin\tUse cases\tCloud\tGateway\tCount\tErrors\tCount\tErrors\tRetrieved\tWaiting\tExpired\tPattern\tAllowed\tDisallowed\tAuthenticated\tLocked\tAuth failed"
        print "KIND\tlogin\ttext\ttext\ttext\tnum\tnumfailed\tnum\tnumfailed\tnumprocessed\tnumwarn\tnumfailed\ttext\tnumprocessed\tnumfailed\tnumprocessed\tnumwarn\tnumfailed"
        for (i = 1; i <= nr; i++) { k = toupper(NAME[i])
            print "ROW\t" NAME[i] cells(k) ((k in FERES) ? "\t" FERES[k] : "") ((k in LGDR) ? LGDR[k] : "") }
        print "TOTAL\tTotal (" nr " logins)" cells("")
        print "FOOT"
        printf "%d\t%d\t%d\n", nr, nfe + 0, nonly + 0 > "/dev/stderr"
    }
' /dev/null > "$OUT.tmp" 2> "$OUT.stat" && mv "$OUT.tmp" "$OUT"
IFS=$'\t' read -r n_all n_fe n_only < "$OUT.stat"; rm -f "$OUT.stat"
echo "Data written to $OUT ($n_all login(s): $n_fe from the FE overview, $n_only funnel-only)." >&2

# THE ACCOUNTS AND PARTNERS VIEWS (2026-09-30, user request: "Accounts &
# Partners must give the same reports, but now with the Entities Accounts &
# Partners"): partners-in-<view>.rpt = this table regrouped per entity through
# the configured login pairs (xref/_logins-accounts.tsv / _logins-partners.tsv)
# by bin/rpt-rollup.awk (its header: the union rule, the cell rules). Rules per
# cell: Use cases union · Cloud / Gateway the newest · the counts summed ·
# Pattern the busiest login's (most Authenticated logons, ROW field 16 — the
# Logons column went, the SSH authentications stand in for it).
PI_RULES="uc max max sum sum sum sum sum sum sum best:16 sum sum sum sum sum"
for v in accounts:acct:Account:Accounts partners:ptn:Partner:Partners; do
    IFS=: read -r vk kind headl tname <<< "$v"
    m="$DATA/flow-manager/xref/_logins-$vk.tsv"; [ -f "$m" ] || m=/dev/null
    b="$DATA/flow-manager/base/_$vk.tsv"; [ -f "$b" ] || b=/dev/null
    vout="$REPORTS_DIR/partners-in-$vk.rpt"
    awk -F'\t' -v MAP="$m" -v BASE="$b" -v KIND="$kind" -v HEADL="$headl" -v TNAME="$tname" -v NOUN="$vk" \
        -v ACTIVE="$tname" -v RULES="$PI_RULES" -v ORDER="" -v DCAP=5 -v LCAP=10 \
        -f "$ROOT/bin/rpt-rollup.awk" "$OUT" > "$vout.tmp" 2> "$vout.stat" && mv "$vout.tmp" "$vout"
    IFS=$'\t' read -r n_v n_drop < "$vout.stat"; rm -f "$vout.stat"
    echo "Data written to $vout ($n_v $vk; $n_drop login row(s) in no $vk view)." >&2
done
