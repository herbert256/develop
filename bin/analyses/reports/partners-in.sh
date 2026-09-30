#!/usr/bin/env bash
#
# partners-in.sh — "Partners in" (analyses/partners-in.html; "Partners -
# Incoming" 2026-09-13..09-30): ONE table combining the FE overview
# (fe-overview.rpt — the login's use cases, its Cloud / Gateway stamps, its
# Files and its pickups) with the WHOLE Incoming logon funnel (logon.rpt's
# Incoming table — the Logons › Incoming page until 2026-09-30, user request:
# "merge the two reports into one"), one row per login. A MERGED report
# (reads the two .rpt files, like activity.sh): every figure is the source
# report's own, so it equals the two former pages cell for cell.
#
#   Login … Pickups          fe-overview.rpt columns 0-11, verbatim
#   Allowed … Session errors, Re-screens, First logon, Logons, Pattern
#                            the Incoming table's columns, verbatim, with
#                            their cell drills (the 5 newest log lines per
#                            count) re-keyed to the new column positions
#   Dropped as the SAME figure shown twice: the funnel's "Last logon" (= Cloud,
#                            the same logon-summary stamp, to the minute) and
#                            the old "Auth Failed" (Bad key + Key failures +
#                            Auth failed folded into one count — the three
#                            columns themselves are here now)
#
# Rows = the UNION: every fe-overview row in its baked order (the configured
# logins + the old-gateway-only ones), then the funnel-only logins (seen
# logging on, on no roster) with empty transfer cells and no tint. Tint = the
# fe-overview row tint (the login's RESULT); the funnel's red cells keep
# their red. Full period, no date filter (the fe-overview figures have no
# per-day dimension) — the funnel's per-day buckets stay in logon.rpt for
# reason-boxes. logon.rpt's WARN (no "Allowed user" line in the whole
# window) is carried over. Runs AFTER both sources: the server pool
# (logon.sh) and analyses wave 1 (fe-overview.sh).
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
    BEGIN {
        E11 = "\t\t\t\t\t\t\t\t\t\t\t"; E13 = "\t\t\t\t\t\t\t\t\t\t\t\t\t"
        # fe-overview.rpt ROW: 2 login, 3 use cases .. 13 pickups, then
        # @data:res= (field 14 — fe-overview writes no Pickup pattern since
        # 2026-09-29); TOTAL: 2 label, 3..13 the same cells
        while ((getline l < FE) > 0) { n = split(l, a, "\t")
            if (a[1] == "ROW") { k = toupper(a[2]); if (!(k in IDX)) { IDX[k] = ++nr; NAME[nr] = a[2] }
                s = ""; for (i = 3; i <= 13; i++) s = s "\t" a[i]; FEROW[k] = s
                for (i = 14; i <= n; i++) if (index(a[i], "@data:res=") == 1) FERES[k] = a[i]
                nfe++ }
            else if (a[1] == "TOTAL") { FETOT = ""; for (i = 3; i <= 13; i++) FETOT = FETOT "\t" a[i] }
        } close(FE)
        # logon.rpt (pageless): its WARN lines, then the FIRST table
        # (Incoming) ROW: 2 login, 3 Allowed, 4 Disallowed, 5 Authenticated,
        # 6 No account, 7 Bad key, 8 Key failures, 9 Locked, 10 Auth failed,
        # 11 Session errors, 12 First logon, 13 Last logon (dropped: = Cloud),
        # 14 Logons, 15 Pattern, 16 Re-screens, then the @data: payloads;
        # TOTAL likewise (its cells carry @{class=…} prefixes)
        t = 0; nw = 0
        while ((getline l < LG) > 0) { n = split(l, a, "\t")
            if (a[1] == "TABLE") { t++; continue }
            if (a[1] == "WARN" && t == 0) { W[++nw] = l; continue }
            if (t != 1) continue
            if (a[1] == "ROW") { nm = strip(a[2]); k = toupper(nm)
                if (!(k in IDX)) { IDX[k] = ++nr; NAME[nr] = nm; nonly++ }
                s = ""; for (i = 3; i <= 11; i++) s = s "\t" a[i]
                LGROW[k] = s "\t" a[16] "\t" a[12] "\t" a[14] "\t" a[15]
                # the cell drills, re-keyed to this table: Allowed 1 -> 12 …
                # Locked 7 -> 18 (+11), Session errors 9 -> 20, Re-screens
                # 14 -> 21 (Auth failed, 8, has none)
                d = ""
                for (i = 17; i <= n; i++) if (index(a[i], "@data:drill-cell-") == 1) { p = index(a[i], "="); if (p == 0) continue
                    ci = substr(a[i], 18, p - 18) + 0
                    nc = (ci >= 1 && ci <= 7) ? ci + 11 : (ci == 9) ? 20 : (ci == 14) ? 21 : -1
                    if (nc >= 0) d = d "\t@data:drill-cell-" nc "=" substr(a[i], p + 1) }
                LGDR[k] = d }
            else if (a[1] == "TOTAL") { s = ""; for (i = 3; i <= 11; i++) s = s "\t" a[i]
                LGTOT = s "\t" a[16] "\t" a[12] "\t" a[14] "\t" a[15] }
        } close(LG)
        if (FETOT == "") FETOT = E11
        if (LGTOT == "") LGTOT = E13
        print "TITLE\tPartners in"
        print "DESC\tEvery login a partner connects in with, on one line: its use cases, the last logon here and on the old gateway, its Files in and out with the retrieved, Waiting and Expired ones and the oldest wait, its pickups, and the whole SSH screening funnel — Allowed, Disallowed, Authenticated, No account, Bad key, Key failures, Locked, Auth failed, Session errors, Re-screens — with the first logon, the logon count and the pattern."
        for (i = 1; i <= nw; i++) print W[i]
        # the view row (2026-09-30, user request): this Endpoint view, then the
        # Accounts and Partners views bin/rpt-rollup.awk regroups it into
        print "NAV\t1|Endpoint|partners-in.html\t0|Accounts|partners-in-accounts.html\t0|Partners|partners-in-partners.html"
        # default sort Waiting (column 8) descending; group dividers before
        # Cloud, Files in, Files out, Oldest waiting, Pickups, the funnel
        # (Allowed) and the logon summary (First logon); the funnel counts
        # keep their log-line drills
        print "TABLE\tLogins\twide\tnofilter\trestint\tsort=8:-1\tgsep=2,4,5,10,11,12,22\tdrill=log line"
        print "HEAD\tLogin\tUse cases\tCloud\tGateway\tFiles in\tFiles out\tError\tRetrieved\tWaiting\tExpired\tOldest waiting\tPickups\tAllowed\tDisallowed\tAuthenticated\tNo account\tBad key\tKey failures\tLocked\tAuth failed\tSession errors\tRe-screens\tFirst logon\tLogons\tPattern"
        print "KIND\tlogin\ttext\ttext\ttext\tnum\tnum\tnumfailed\tnumprocessed\tnumwarn\tnumfailed\ttext\tnum\tnumprocessed\tnumfailed\tnumprocessed\tnumfailed\tnumfailed\tnumwarn\tnumwarn\tnumfailed\tnumfailed\tnum\ttext\tnum\ttext"
        for (i = 1; i <= nr; i++) { k = toupper(NAME[i])
            fe = (k in FEROW) ? FEROW[k] : E11; lg = (k in LGROW) ? LGROW[k] : E13
            res = (k in FERES) ? "\t" FERES[k] : ""
            print "ROW\t" NAME[i] fe lg res ((k in LGDR) ? LGDR[k] : "") }
        print "TOTAL\tTotal (" nr " logins)" FETOT LGTOT
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
# cell: Use cases union · Cloud / Gateway newest · the counts summed · Oldest
# waiting the largest · First logon the oldest · Pattern the busiest login's.
PI_RULES="uc max max sum sum sum sum sum sum age sum sum sum sum sum sum sum sum sum sum sum min sum best:25"
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
