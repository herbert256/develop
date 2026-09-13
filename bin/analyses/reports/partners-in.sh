#!/usr/bin/env bash
#
# partners-in.sh — "Partners - Incoming" (analyses/partners-in.html,
# 2026-09-13, user request): ONE table combining the FE overview page
# (fe-overview.rpt — the login's use cases, its Cloud / Gateway stamps, its
# Files and its pickups) with the Incoming logon funnel (logon.rpt's Incoming
# table — Allowed … Session errors, First logon, Logons, Pattern, Re-screens),
# one row per login. A MERGED report (reads the two .rpt files, like
# activity.sh): every figure is the source page's own, so the three pages
# never disagree. The two source pages stay (user request: "do not yet
# remove those 2 reports").
#
#   Login … Pickups          fe-overview.rpt columns 0-11, verbatim
#   Allowed, Disallowed, Authenticated, Auth Failed, Locked, Pattern
#                            the Incoming table's columns, verbatim, with
#                            their cell drills (the 5 newest log lines per
#                            count) re-keyed to the new column positions;
#                            AUTH FAILED = the funnel's Bad key + Key
#                            failures + Auth failed folded into one count
#                            (2026-09-13, user request), its drill the 5
#                            newest lines of the three
#   Dropped (2026-09-13, user request): Re-screens, Pickup pattern, No
#                            account, Session errors, First logon, Logons;
#                            and as duplicates fe-overview's "Logon
#                            problems" (a sum of funnel columns) and the
#                            funnel's "Last logon" (= Cloud: the same logon
#                            summary, to the minute)
#
# Rows = the UNION: every fe-overview row in its baked order (the configured
# logins + the old-gateway-only ones), then the funnel-only logins (seen
# logging on, on no roster) with empty transfer cells and no tint. Tint = the
# fe-overview row tint (the login's RESULT); the funnel's own screening tint
# is not carried (its red cells are). Full-period, no date filter — the
# funnel's per-day buckets are dropped. Runs AFTER both sources: the server
# pool (logon.sh) and analyses wave 1 (fe-overview.sh).
#
# Usage:
#   ./partners-in.sh   # -> data/<env>/analyses/reports/partners-in.rpt
#
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib.sh"
OUT="$REPORTS_DIR/partners-in.rpt"
FE="$REPORTS_DIR/fe-overview.rpt"
LG="$DATA/server/reports/logon.rpt"

if [ ! -f "$FE" ]; then
    echo "partners-in: no $FE (fe-overview.sh wrote nothing) — page not published." >&2
    rm -f "$OUT"
    exit 0
fi
[ -f "$LG" ] || LG=/dev/null
skip_if_fresh "$OUT" "${BASH_SOURCE[0]}" "$FE" "$LG"

GENDATE=$(date '+%Y-%m-%d %H:%M:%S')

awk -F'\t' -v FE="$FE" -v LG="$LG" -v GEN="$GENDATE" '
    function strip(c) { while (index(c, "@{") == 1) sub(/^@\{[^}]*\}/, "", c); return c }
    function num(c) { c = strip(c); return (c ~ /^[0-9]+$/) ? c + 0 : 0 }
    # the Auth Failed drill: the three source lists (each newest first,
    # \x1f-joined) merged, the 5 newest kept (the lines lead with their
    # timestamp, so a string sort orders them)
    function mergedrill(p1, p2, p3,   n1, L, i, j, v, out) {
        n1 = 0
        if (p1 != "") n1 += split(p1, A1, "\037"); for (i = 1; i <= n1; i++) L[i] = A1[i]
        if (p2 != "") { m2 = split(p2, A2, "\037"); for (i = 1; i <= m2; i++) L[++n1] = A2[i] }
        if (p3 != "") { m3 = split(p3, A3, "\037"); for (i = 1; i <= m3; i++) L[++n1] = A3[i] }
        for (i = 2; i <= n1; i++) { v = L[i]; for (j = i - 1; j >= 1 && L[j] < v; j--) L[j + 1] = L[j]; L[j + 1] = v }
        out = ""; for (i = 1; i <= n1 && i <= 5; i++) out = out (i > 1 ? "\037" : "") L[i]
        return out
    }
    BEGIN {
        E11 = "\t\t\t\t\t\t\t\t\t\t\t"; E6 = "\t\t\t\t\t\t"
        # fe-overview.rpt ROW: 2 login, 3 use cases .. 13 pickups, 14 pickup
        # pattern (dropped), 15 logon problems (dropped), then @data:res=;
        # TOTAL: 2 label, 3..13 the same cells
        while ((getline l < FE) > 0) { n = split(l, a, "\t")
            if (a[1] == "ROW") { k = toupper(a[2]); if (!(k in IDX)) { IDX[k] = ++nr; NAME[nr] = a[2] }
                s = ""; for (i = 3; i <= 13; i++) s = s "\t" a[i]; FEROW[k] = s
                for (i = 15; i <= n; i++) if (index(a[i], "@data:res=") == 1) FERES[k] = a[i]
                nfe++ }
            else if (a[1] == "TOTAL") { FETOT = ""; for (i = 3; i <= 13; i++) FETOT = FETOT "\t" a[i] }
        } close(FE)
        # logon.rpt, FIRST table (Incoming) ROW: 2 login, 3 Allowed, 4
        # Disallowed, 5 Authenticated, 6 No account (dropped), 7 Bad key, 8 Key
        # failures, 9 Locked, 10 Auth failed, 11 Session errors (dropped), 12
        # First logon (dropped), 13 Last logon (dropped), 14 Logons (dropped),
        # 15 Pattern, 16 Re-screens (dropped), then the @data: payloads;
        # TOTAL likewise (its cells carry @{class=…} prefixes)
        t = 0
        while ((getline l < LG) > 0) { n = split(l, a, "\t")
            if (a[1] == "TABLE") { t++; continue }
            if (t != 1) continue
            if (a[1] == "ROW") { nm = strip(a[2]); k = toupper(nm)
                if (!(k in IDX)) { IDX[k] = ++nr; NAME[nr] = nm; nonly++ }
                af = num(a[7]) + num(a[8]) + num(a[10])
                LGROW[k] = "\t" a[3] "\t" a[4] "\t" a[5] "\t" (af > 0 ? af : "") "\t" a[9] "\t" a[15]
                # the cell drills, re-keyed: Allowed 1 -> 12, Disallowed 2 ->
                # 13, Authenticated 3 -> 14, Locked 7 -> 16; Bad key 5 + Key
                # failures 6 + Auth failed 8 -> the merged Auth Failed 15
                d = ""; d5 = ""; d6 = ""; d8 = ""
                for (i = 17; i <= n; i++) if (index(a[i], "@data:drill-cell-") == 1) { p = index(a[i], "="); if (p == 0) continue
                    ci = substr(a[i], 18, p - 18) + 0; pl = substr(a[i], p + 1)
                    if (ci == 5) d5 = pl; else if (ci == 6) d6 = pl; else if (ci == 8) d8 = pl
                    else { nc = (ci == 1) ? 12 : (ci == 2) ? 13 : (ci == 3) ? 14 : (ci == 7) ? 16 : -1
                           if (nc >= 0) d = d "\t@data:drill-cell-" nc "=" pl } }
                md = mergedrill(d5, d6, d8); if (md != "") d = d "\t@data:drill-cell-15=" md
                LGDR[k] = d }
            else if (a[1] == "TOTAL") { af = num(a[7]) + num(a[8]) + num(a[10])
                LGTOT = "\t" a[3] "\t" a[4] "\t" a[5] "\t@{class=num failed}" (af > 0 ? af : "") "\t" a[9] "\t" a[15] }
        } close(LG)
        if (FETOT == "") FETOT = E11
        if (LGTOT == "") LGTOT = E6
        print "TITLE\tPartners - Incoming"
        print "DESC\tEvery FE login on one line: its use cases, the last logon here and on the old gateway, its Files in and out with the retrieved, Waiting and Expired ones and the oldest wait, its pickups, and the SSH screening funnel — Allowed, Disallowed, Authenticated, Auth Failed (bad key, key failures and failed authentications), Locked — with the logon pattern."
        # the FE overview layout: default sort Waiting (column 8) descending;
        # group dividers before Cloud, Files in, Files out, Oldest waiting,
        # Pickups, the funnel (Allowed) and Pattern; the funnel counts keep
        # their log-line drills
        print "TABLE\tFE logins\twide\tnofilter\trestint\tsort=8:-1\tgsep=2,4,5,10,11,12,17\tdrill=log line"
        print "HEAD\tLogin\tUse cases\tCloud\tGateway\tFiles in\tFiles out\tError\tRetrieved\tWaiting\tExpired\tOldest waiting\tPickups\tAllowed\tDisallowed\tAuthenticated\tAuth Failed\tLocked\tPattern"
        print "KIND\tlogin\ttext\ttext\ttext\tnum\tnum\tnumfailed\tnumprocessed\tnumwarn\tnumfailed\ttext\tnum\tnumprocessed\tnumfailed\tnumprocessed\tnumfailed\tnumwarn\ttext"
        for (i = 1; i <= nr; i++) { k = toupper(NAME[i])
            fe = (k in FEROW) ? FEROW[k] : E11; lg = (k in LGROW) ? LGROW[k] : E6
            res = (k in FERES) ? "\t" FERES[k] : ""
            print "ROW\t" NAME[i] fe lg res ((k in LGDR) ? LGDR[k] : "") }
        print "TOTAL\tTotal (" nr " logins)" FETOT LGTOT
        print "KEYWORDS\tpartners,incoming,fe,login,overview,status,use case,uc2,uc4,mailbox,last logon,gateway,old gateway,migration,files,in,out,retrieved,collected,waiting,expired,oldest,age,pickup,visit,pattern,cadence,logon,funnel,allowed,disallowed,authenticated,bad key,key failures,locked,auth failed,ssh"
        print "FOOT\tGenerated on " GEN
        printf "%d\t%d\t%d\n", nr, nfe + 0, nonly + 0 > "/dev/stderr"
    }
' /dev/null > "$OUT.tmp" 2> "$OUT.stat" && mv "$OUT.tmp" "$OUT"
IFS=$'\t' read -r n_all n_fe n_only < "$OUT.stat"; rm -f "$OUT.stat"
echo "Data written to $OUT ($n_all login(s): $n_fe from the FE overview, $n_only funnel-only)." >&2
