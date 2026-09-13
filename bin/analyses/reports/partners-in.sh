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
#   Login … Pickup pattern   fe-overview.rpt columns 0-12, verbatim
#   Allowed … Session errors, First logon, Logons, Pattern, Re-screens
#                            the Incoming table's columns, verbatim (with
#                            their cell drills — the 5 newest log lines per
#                            count — re-keyed to the new column positions)
#   Dropped as duplicates:   fe-overview's "Logon problems" (the six funnel
#                            columns it summed are here) and the funnel's
#                            "Last logon" (= Cloud: the same logon summary,
#                            to the minute)
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
    BEGIN {
        E12 = "\t\t\t\t\t\t\t\t\t\t\t\t"; E13 = E12 "\t"
        # fe-overview.rpt ROW: 2 login, 3 use cases .. 14 pickup pattern, 15
        # logon problems (dropped), then @data:res=; TOTAL: 2 label, 3..14 the
        # same cells, 15 logon problems (dropped)
        while ((getline l < FE) > 0) { n = split(l, a, "\t")
            if (a[1] == "ROW") { k = toupper(a[2]); if (!(k in IDX)) { IDX[k] = ++nr; NAME[nr] = a[2] }
                s = ""; for (i = 3; i <= 14; i++) s = s "\t" a[i]; FEROW[k] = s
                for (i = 15; i <= n; i++) if (index(a[i], "@data:res=") == 1) FERES[k] = a[i]
                nfe++ }
            else if (a[1] == "TOTAL") { FETOT = ""; for (i = 3; i <= 14; i++) FETOT = FETOT "\t" a[i] }
        } close(FE)
        # logon.rpt, FIRST table (Incoming) ROW: 2 login, 3..11 Allowed ..
        # Session errors, 12 First logon, 13 Last logon (dropped), 14 Logons,
        # 15 Pattern, 16 Re-screens, then the @data: payloads; TOTAL likewise
        t = 0
        while ((getline l < LG) > 0) { n = split(l, a, "\t")
            if (a[1] == "TABLE") { t++; continue }
            if (t != 1) continue
            if (a[1] == "ROW") { nm = strip(a[2]); k = toupper(nm)
                if (!(k in IDX)) { IDX[k] = ++nr; NAME[nr] = nm; nonly++ }
                s = ""; for (i = 3; i <= 11; i++) s = s "\t" a[i]
                LGROW[k] = s "\t" a[12] "\t" a[14] "\t" a[15] "\t" a[16]
                # the cell drills, re-keyed: the funnel columns 1..9 sit at
                # 13..21 here, Re-screens (14) at 25
                d = ""
                for (i = 17; i <= n; i++) if (index(a[i], "@data:drill-cell-") == 1) { p = index(a[i], "="); if (p == 0) continue
                    ci = substr(a[i], 18, p - 18) + 0
                    nc = (ci >= 1 && ci <= 9) ? ci + 12 : (ci == 14 ? 25 : -1); if (nc < 0) continue
                    d = d "\t@data:drill-cell-" nc substr(a[i], p) }
                LGDR[k] = d }
            else if (a[1] == "TOTAL") { LGTOT = ""; for (i = 3; i <= 11; i++) LGTOT = LGTOT "\t" a[i]; LGTOT = LGTOT "\t" a[12] "\t" a[14] "\t" a[15] "\t" a[16] }
        } close(LG)
        if (FETOT == "") FETOT = E12
        if (LGTOT == "") LGTOT = E13
        print "TITLE\tPartners - Incoming"
        print "DESC\tEvery FE login on one line: its use cases, the last logon here and on the old gateway, its Files in and out with the retrieved, Waiting and Expired ones and the oldest wait, its pickups with their cadence, and the SSH screening funnel — Allowed, Disallowed, Authenticated, No account, Bad key, Key failures, Locked, Auth failed, Session errors, Re-screens — with the logon count and pattern."
        # the FE overview layout: default sort Waiting (column 8) descending;
        # group dividers before Cloud, Files in, Files out, Oldest waiting,
        # Pickups, then the funnel (Allowed), its logon summary (First logon)
        # and Re-screens; the funnel counts keep their log-line drills
        print "TABLE\tFE logins\twide\tnofilter\trestint\tsort=8:-1\tgsep=2,4,5,10,11,13,22,25\tdrill=log line"
        print "HEAD\tLogin\tUse cases\tCloud\tGateway\tFiles in\tFiles out\tError\tRetrieved\tWaiting\tExpired\tOldest waiting\tPickups\tPickup pattern\tAllowed\tDisallowed\tAuthenticated\tNo account\tBad key\tKey failures\tLocked\tAuth failed\tSession errors\tFirst logon\tLogons\tPattern\tRe-screens"
        print "KIND\tlogin\ttext\ttext\ttext\tnum\tnum\tnumfailed\tnumprocessed\tnumwarn\tnumfailed\ttext\tnum\ttext\tnumprocessed\tnumfailed\tnumprocessed\tnumfailed\tnumfailed\tnumwarn\tnumwarn\tnumfailed\tnumfailed\ttext\tnum\ttext\tnum"
        for (i = 1; i <= nr; i++) { k = toupper(NAME[i])
            fe = (k in FEROW) ? FEROW[k] : E12; lg = (k in LGROW) ? LGROW[k] : E13
            res = (k in FERES) ? "\t" FERES[k] : ""
            print "ROW\t" NAME[i] fe lg res ((k in LGDR) ? LGDR[k] : "") }
        print "TOTAL\tTotal (" nr " logins)" FETOT LGTOT
        print "KEYWORDS\tpartners,incoming,fe,login,overview,status,use case,uc2,uc4,mailbox,last logon,gateway,old gateway,migration,files,in,out,retrieved,collected,waiting,expired,oldest,age,pickup,visit,pattern,cadence,logon,logons,funnel,allowed,disallowed,authenticated,no account,bad key,key failures,locked,auth failed,session errors,re-screens,ssh"
        print "FOOT\tGenerated on " GEN
        printf "%d\t%d\t%d\n", nr, nfe + 0, nonly + 0 > "/dev/stderr"
    }
' /dev/null > "$OUT.tmp" 2> "$OUT.stat" && mv "$OUT.tmp" "$OUT"
IFS=$'\t' read -r n_all n_fe n_only < "$OUT.stat"; rm -f "$OUT.stat"
echo "Data written to $OUT ($n_all login(s): $n_fe from the FE overview, $n_only funnel-only)." >&2
