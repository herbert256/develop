#!/usr/bin/env bash
#
# partners-out.sh — "Partners Out" (analyses/partners-out.html, 2026-09-30,
# user request: the Logons › Outgoing page renamed and moved to the Partners
# group, "add all hosts, not only the ones with errors"): one row per host
# this server connects OUT to.
#
#   Rows         every host of base/_hosts.tsv (configured + discovered,
#                every one an out endpoint), every host of logon.rpt's
#                Outgoing table (our failed authentications), and every
#                target address of the logon summary with outbound
#                connections — under the host input/ip/ip-hosts.tsv maps it
#                to, else as the raw address
#   Subscription the subscriptions that TRIED: the Outgoing table's session
#                join (the failed attempt's connection joined to its transfer
#                legs); a host with no resolved failure shows its CONFIGURED
#                subscriptions instead (xref/_hosts-subscriptions.tsv) —
#                one @{alist=subscriptions} cell either way
#   Connections, Last connection
#                our outbound connections to the host — the logon summary
#                (bin/logons.sh _logons-hosts.tsv fields 10 / 12, the "had
#                initiated a connection" lines with login name "") summed
#                over the host's name and its addresses, the host detail
#                page's rule (details_writer host_logons_section)
#   User … Last  the Outgoing table folded per host: the users (accounts)
#                that failed, Failures = Password + Key + Certificate +
#                Other, the reason of the newest failure, the First / Last
#                failure day; the drill = the host's 10 newest failure lines
#
# Row tint = the host's result colour (base/_hosts.tsv col 3); a raw address
# or an unconfigured host stays untinted. 0 renders empty. Full period, no
# date filter (the connection counts have no per-day dimension). Baked order:
# Failures, then Connections descending, then the name. The TOTAL is the
# column sums; the failure sums equal logon.rpt's Outgoing TOTAL.
#
# Usage:
#   ./partners-out.sh   # -> data/analyses/reports/partners-out.rpt
#
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib.sh"
source "$ROOT/bin/logons.sh"     # ensure_logons(): the logon summary (_logons-hosts.tsv)
OUT="$REPORTS_DIR/partners-out.rpt"
HB="$DATA/flow-manager/base/_hosts.tsv"
HS="$DATA/flow-manager/xref/_hosts-subscriptions.tsv"
SCACHE="$DATA/server/cache"
LG="$DATA/server/reports/logon.rpt"

if [ ! -f "$HB" ]; then
    echo "partners-out: no $HB (config not extracted) — page not published." >&2
    rm -f "$OUT"
    exit 0
fi
# the logon summary: bin/build.sh builds it before the server reports; a manual
# run builds it here (atomic). No server parse cache = an EMPTY summary.
ensure_logons "$SCACHE"
LGH="$SCACHE/_logons-hosts.tsv"
IPM="$IP_HOSTS_FILE"
[ -f "$HS" ]  || HS=/dev/null
[ -f "$LG" ]  || LG=/dev/null
[ -f "$IPM" ] || IPM=/dev/null

awk -F'\t' -v HB="$HB" -v HS="$HS" -v LGH="$LGH" -v IPM="$IPM" -v LG="$LG" "$AWKLIB"'
    function strip(c) { while (index(c, "@{") == 1) sub(/^@\{[^}]*\}/, "", c); return c }
    function z(v) { return (v + 0 == 0) ? "" : v + 0 }
    # a SUBSEP-joined set -> its members sorted, ", "-joined
    function sortedlist(s,   n, A, i, j, v, o) {
        if (s == "") return ""
        n = split(substr(s, 2), A, SUBSEP)
        for (i = 2; i <= n; i++) { v = A[i]; j = i - 1; while (j >= 1 && A[j] > v) { A[j + 1] = A[j]; j-- } A[j + 1] = v }
        o = ""; for (i = 1; i <= n; i++) o = o (i > 1 ? ", " : "") A[i]
        return o
    }
    function addrow(h, disp) { if (!(h in ROWK)) { ROWK[h] = ++nr; KEY[nr] = h; DISP[nr] = disp } }
    # a set per key, one SEEN space per set (tag): a configured subscription
    # must not hide the same name in the tried set
    function addset(arr, tag, k, v) { if (!((tag SUBSEP k SUBSEP v) in SEEN)) { SEEN[tag SUBSEP k SUBSEP v] = 1; arr[k] = arr[k] SUBSEP v } }
    BEGIN {
        # the hosts (lowercase, canonical) and their result colour
        while ((getline l < HB) > 0) { split(l, a, "\t"); if (a[1] == "") continue
            h = tolower(a[1]); addrow(h, a[1]); if (a[3] != "") RES[h] = a[3] }
        close(HB)
        # the configured subscriptions per host
        while ((getline l < HS) > 0) { split(l, a, "\t"); if (a[1] == "" || a[2] == "" || a[2] == "Unknown") continue
            addset(CSUB, "c", tolower(a[1]), a[2]) }
        close(HS)
        # address -> host(s) (input/ip/ip-hosts.tsv: ip TAB host)
        while ((getline l < IPM) > 0) { split(l, a, "\t"); if (a[1] == "" || a[2] == "") continue
            mh = tolower(a[2]); FW[mh] = FW[mh] SUBSEP a[1]; MAPPED[a[1]] = MAPPED[a[1]] SUBSEP mh }
        close(IPM)
        # the logon summary per target (field 10 out-count, 12 out-last)
        while ((getline l < LGH) > 0) { n = split(l, a, "\t"); if (n < 13 || a[10] + 0 <= 0) continue
            OC[a[1]] = a[10] + 0; OL[a[1]] = (a[12] == "-") ? "" : a[12]; nk++; OK[nk] = a[1] }
        close(LGH)
        # logon.rpt, SECOND table (Outgoing) ROW: 2 Remote host, 3 User, 4
        # Subscription (@{alist=subscriptions}A, B), 5 Failures, 6 Password,
        # 7 Key, 8 Certificate, 9 Other, 10 Reason (last seen), 11 First, 12
        # Last, then @data:loglines (10 newest, newest first)
        t = 0
        while ((getline l < LG) > 0) { n = split(l, a, "\t")
            if (a[1] == "TABLE") { t++; continue }
            if (t != 2 || a[1] != "ROW") continue
            hn = strip(a[2]); h = tolower(hn); if (h == "") continue
            addrow(h, h)
            u = strip(a[3]); if (u != "") addset(USR, "u", h, u)
            s = strip(a[4]); if (s != "") { ns = split(s, SS, ", "); for (i = 1; i <= ns; i++) if (SS[i] != "") addset(TSUB, "t", h, SS[i]) }
            FA[h] += a[5]; PW[h] += a[6]; KY[h] += a[7]; CR[h] += a[8]; OT[h] += a[9]
            if (a[11] != "" && (FST[h] == "" || a[11] < FST[h])) FST[h] = a[11]
            if (a[12] != "" && a[12] > LST[h]) LST[h] = a[12]
            ll = ""; for (i = 13; i <= n; i++) if (index(a[i], "@data:loglines=") == 1) { ll = substr(a[i], 16); break }
            # the reason of the NEWEST failure: the pair whose newest line is
            # newest (its stamp leads the line); an equal stamp keeps the
            # greater reason, so the pick never depends on the row order
            st = substr(ll, 1, 23); rs = (a[10] == "-") ? "" : a[10]
            if (!(h in RST) || st > RST[h] || (st == RST[h] && rs > RSN[h])) { RST[h] = st; RSN[h] = rs }
            if (ll != "") { m = split(ll, LL, "\037"); for (i = 1; i <= m; i++) if (LL[i] != "") { nl[h]++; LN[h, nl[h]] = LL[i] } }
        }
        close(LG)
        # an address with outbound connections: its mapped host(s), else itself
        for (i = 1; i <= nk; i++) { k = OK[i]
            if (tolower(k) in ROWK) continue
            if (k in MAPPED) { m = split(substr(MAPPED[k], 2), MH, SUBSEP); for (j = 1; j <= m; j++) addrow(MH[j], MH[j]) }
            else addrow(k, k) }
        # one line per row: the sort keys first (Failures, Connections, name)
        for (r = 1; r <= nr; r++) { h = KEY[r]
            c = (h in OC) ? OC[h] : 0; lc = (h in OL) ? OL[h] : ""
            if (h in FW) { m = split(substr(FW[h], 2), IPS, SUBSEP)
                for (j = 1; j <= m; j++) if (IPS[j] != h && (IPS[j] in OC)) { c += OC[IPS[j]]; if (OL[IPS[j]] > lc) lc = OL[IPS[j]] } }
            CN[r] = c; LCN[r] = substr(lc, 1, 19)
            ORD[r] = r }
        # insertion sort of the row indexes (n is the host count — small)
        for (i = 2; i <= nr; i++) { v = ORD[i]; j = i - 1
            while (j >= 1 && before(v, ORD[j])) { ORD[j + 1] = ORD[j]; j-- }
            ORD[j + 1] = v }
        print "TITLE\tPartners Out"
        print "DESC\tEvery host this server connects out to: the subscriptions that use it, our connections and the last one, and our failed logons there — Password, Key, Certificate and Other with the newest reason and the first and last day."
        print "TABLE\tHosts\twide\tnofilter\trestint\tgsep=2,4\tdrill=log line"
        print "HEAD\tRemote host\tSubscription\tConnections\tLast connection\tUser\tFailures\tPassword\tKey\tCertificate\tOther\tReason (last seen)\tFirst\tLast"
        print "KIND\thost\ttext\tnum\ttext\ttext\tnumfailed\tnumfailed\tnumfailed\tnumfailed\tnumfailed\ttext\ttext\ttext"
        tc = 0; tf = 0; tp = 0; tk = 0; tcr = 0; to = 0
        for (i = 1; i <= nr; i++) { r = ORD[i]; h = KEY[r]
            sub1 = sortedlist(TSUB[h]); if (sub1 == "") sub1 = sortedlist(CSUB[h])
            us = sortedlist(USR[h])
            line = "ROW\t" lit(DISP[r]) "\t" (sub1 == "" ? "" : "@{alist=subscriptions}" sub1) "\t" z(CN[r]) "\t" LCN[r] \
                   "\t" (us == "" ? "" : "@{alist=accounts}" us) "\t" z(FA[h]) "\t" z(PW[h]) "\t" z(KY[h]) "\t" z(CR[h]) "\t" z(OT[h]) \
                   "\t" RSN[h] "\t" FST[h] "\t" LST[h]
            if (h in RES) line = line "\t@data:res=" RES[h]
            if (nl[h] > 0) {
                # the host lines, newest first (each leads with its stamp),
                # the 10 newest kept
                m = nl[h]; for (j = 1; j <= m; j++) T[j] = LN[h, j]
                for (j = 2; j <= m; j++) { v = T[j]; k2 = j - 1; while (k2 >= 1 && T[k2] < v) { T[k2 + 1] = T[k2]; k2-- } T[k2 + 1] = v }
                d = ""; for (j = 1; j <= m && j <= 10; j++) d = d (j > 1 ? "\037" : "") T[j]
                line = line "\t@data:loglines=" d }
            print line
            tc += CN[r]; tf += FA[h]; tp += PW[h]; tk += KY[h]; tcr += CR[h]; to += OT[h] }
        print "TOTAL\t@{colspan=2}Total (" nr " hosts)\t@{class=num}" z(tc) "\t\t\t@{class=num failed}" z(tf) "\t@{class=num failed}" z(tp) "\t@{class=num failed}" z(tk) "\t@{class=num failed}" z(tcr) "\t@{class=num failed}" z(to) "\t\t\t"
        print "FOOT"
        printf "%d\t%d\t%d\n", nr, tc, tf > "/dev/stderr"
    }
    # row a before row b: more Failures, then more Connections, then the name
    function before(a, b,   fa, fb) {
        fa = FA[KEY[a]] + 0; fb = FA[KEY[b]] + 0
        if (fa != fb) return fa > fb
        if (CN[a] != CN[b]) return CN[a] > CN[b]
        return DISP[a] < DISP[b]
    }
' /dev/null > "$OUT.tmp" 2> "$OUT.stat" && mv "$OUT.tmp" "$OUT"
IFS=$'\t' read -r n_all n_conn n_fail < "$OUT.stat"; rm -f "$OUT.stat"
echo "Data written to $OUT ($n_all host(s): $n_conn outbound connection(s), $n_fail failed logon(s))." >&2
