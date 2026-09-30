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
#   Use cases    the use cases of the host's subscriptions — its CONFIGURED
#                ones (xref/_hosts-subscriptions.tsv) plus the ones that
#                TRIED (the Outgoing table's session join: the failed
#                attempt's connection joined to its transfer legs); the
#                Partners in cell's rule (fe-overview.sh): a subscription's
#                use case is its name prefix, else the DERIVED one
#                (xref/_subscriptions-ucderived.tsv), UC1..UC4 in order,
#                any other after, "/"-joined (2026-09-30, user request: it
#                replaced the Subscription column)
#   Files In, Files Out (Count · Errors, 2026-09-30, user request: the same
#                groups as Partners in) — the host's Files by the Entities
#                Remote Hosts rule (entities.sh): every distinct leg host
#                (_transfers.tsv col 16) of a dated File that connects OUT
#                (_files.tsv col 16), In / Out by the MOVEMENT (col 17, else
#                the connection side), Errors = Failed or Expired (the
#                outcome policy) — the Remote Hosts page In / Out / Error
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
UCDF="$DATA/flow-manager/xref/_subscriptions-ucderived.tsv"
SCACHE="$DATA/server/cache"
LG="$DATA/server/reports/logon.rpt"

if [ ! -f "$HB" ]; then
    echo "partners-out: no $HB (config not extracted) — page not published." >&2
    rm -f "$OUT" "$REPORTS_DIR/partners-out-accounts.rpt" "$REPORTS_DIR/partners-out-partners.rpt"
    exit 0
fi
# the logon summary: bin/build.sh builds it before the server reports; a manual
# run builds it here (atomic). No server parse cache = an EMPTY summary.
ensure_logons "$SCACHE"
LGH="$SCACHE/_logons-hosts.tsv"
IPM="$IP_HOSTS_FILE"
[ -f "$HS" ]  || HS=/dev/null
[ -f "$UCDF" ] || UCDF=/dev/null
[ -f "$LG" ]  || LG=/dev/null
[ -f "$IPM" ] || IPM=/dev/null

# the Files per host (see the header): host TAB in TAB in-errors TAB out TAB
# out-errors
TRF="$DATA/transfer/cache/_transfers.tsv"; FLS="$DATA/transfer/cache/_files.tsv"
[ -f "$TRF" ] || TRF=/dev/null
[ -f "$FLS" ] || FLS=/dev/null
HF="$OUT.hf"
awk -F'\t' -v PF="$TRF" '
    FILENAME == PF { if ($16 != "") { k = $1 SUBSEP $16; if (!(k in S)) { S[k] = 1; H[$1] = H[$1] SUBSEP $16 } } next }
    $4 == "" || $16 != "out" || !($1 in H) { next }
    { mv = ($17 != "") ? $17 : $16; e = ($2 == "Failed" || $2 == "Expired")
      n = split(substr(H[$1], 2), A, SUBSEP)
      for (i = 1; i <= n; i++) { h = A[i]; SEENH[h] = 1
          if (mv == "in") { FI[h]++; if (e) EI[h]++ } else if (mv == "out") { FO[h]++; if (e) EO[h]++ } } }
    END { for (h in SEENH) printf "%s\t%d\t%d\t%d\t%d\n", h, FI[h], EI[h], FO[h], EO[h] }
' "$TRF" "$FLS" > "$HF"

awk -F'\t' -v HB="$HB" -v HS="$HS" -v UCDF="$UCDF" -v LGH="$LGH" -v IPM="$IPM" -v LG="$LG" -v HF="$HF" "$AWKLIB"'
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
    # the use case of a subscription: its name prefix, else the derived one
    function ucof(s) { if (match(s, /^UC[0-9]+/)) return substr(s, 1, RLENGTH); if (toupper(s) in UCD) return UCD[toupper(s)]; return "" }
    # the Use cases cell (the Partners in rule, fe-overview.sh): over the
    # configured AND the tried subscriptions of the host, UC1..UC4 in order, any
    # other use case after (sorted), "/"-joined
    function ucs(h,   s, n, A, i, u, H, o, j, X) {
        s = CSUB[h] TSUB[h]; if (s == "") return ""
        n = split(substr(s, 2), A, SUBSEP); X = ""
        for (i = 1; i <= n; i++) { u = ucof(A[i]); if (u == "" || (u in H)) continue; H[u] = 1; if (u !~ /^UC[1-4]$/) X = X SUBSEP u }
        o = ""; for (j = 1; j <= 4; j++) if (("UC" j) in H) o = o (o == "" ? "" : "/") "UC" j
        if (X != "") { X = sortedlist(X); gsub(/, /, "/", X); o = o (o == "" ? "" : "/") X }
        return o
    }
    function addrow(h, disp) { if (!(h in ROWK)) { ROWK[h] = ++nr; KEY[nr] = h; DISP[nr] = disp } }
    # a set per key, one SEEN space per set (tag): a configured subscription
    # must not hide the same name in the tried set
    function addset(arr, tag, k, v) { if (!((tag SUBSEP k SUBSEP v) in SEEN)) { SEEN[tag SUBSEP k SUBSEP v] = 1; arr[k] = arr[k] SUBSEP v } }
    BEGIN {
        while ((getline l < UCDF) > 0) { n = split(l, a, "\t"); if (n >= 2 && a[1] != "" && a[2] != "") UCD[toupper(a[1])] = a[2] }
        close(UCDF)
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
        # the Files per host (the pre-pass); a host with Files and no row yet
        # (a leg host outside the roster) gets one
        while ((getline l < HF) > 0) { split(l, a, "\t"); h = tolower(a[1]); if (h == "") continue
            HFI[h] += a[2]; HEI[h] += a[3]; HFO[h] += a[4]; HEO[h] += a[5]; addrow(h, a[1]) }
        close(HF)
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
        print "DESC\tEvery host this server connects out to: the use cases of its subscriptions, its Files in and out with their errors, our connections and the last one, and our failed logons there — Password, Key, Certificate and Other with the newest reason and the first and last day."
        # the view row (2026-09-30, user request): this Endpoint view, then the
        # Accounts and Partners views bin/rpt-rollup.awk regroups it into
        print "NAV\t1|Endpoint|partners-out.html\t0|Accounts|partners-out-accounts.html\t0|Partners|partners-out-partners.html"
        # the groups (2026-09-30, the Partners in layout): Files In, Files Out,
        # Connections, Failed logons
        print "TABLE\tHosts\twide\tnofilter\trestint\tgsep=2,4,6,8\tdrill=log line"
        print "GHEAD\t@{colspan=2}\t@{colspan=2,class=gband gsep}Files In\t@{colspan=2,class=gband gsep}Files Out\t@{colspan=2,class=gband gsep}Connections\t@{colspan=9,class=gband gsep}Failed logons"
        print "HEAD\tRemote host\tUse cases\tCount\tErrors\tCount\tErrors\tConnections\tLast connection\tUser\tFailures\tPassword\tKey\tCertificate\tOther\tReason (last seen)\tFirst\tLast"
        print "KIND\thost\ttext\tnum\tnumfailed\tnum\tnumfailed\tnum\ttext\ttext\tnumfailed\tnumfailed\tnumfailed\tnumfailed\tnumfailed\ttext\ttext\ttext"
        tc = 0; tf = 0; tp = 0; tk = 0; tcr = 0; to = 0; tfi = 0; tei = 0; tfo = 0; teo = 0
        for (i = 1; i <= nr; i++) { r = ORD[i]; h = KEY[r]
            uc = ucs(h)
            us = sortedlist(USR[h])
            line = "ROW\t" lit(DISP[r]) "\t" uc "\t" z(HFI[h]) "\t" z(HEI[h]) "\t" z(HFO[h]) "\t" z(HEO[h]) "\t" z(CN[r]) "\t" LCN[r] \
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
            tfi += HFI[h]; tei += HEI[h]; tfo += HFO[h]; teo += HEO[h]
            tc += CN[r]; tf += FA[h]; tp += PW[h]; tk += KY[h]; tcr += CR[h]; to += OT[h] }
        print "TOTAL\t@{colspan=2}Total (" nr " hosts)\t@{class=num}" z(tfi) "\t@{class=num failed}" z(tei) "\t@{class=num}" z(tfo) "\t@{class=num failed}" z(teo) "\t@{class=num}" z(tc) "\t\t\t@{class=num failed}" z(tf) "\t@{class=num failed}" z(tp) "\t@{class=num failed}" z(tk) "\t@{class=num failed}" z(tcr) "\t@{class=num failed}" z(to) "\t\t\t"
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
rm -f "$HF"
IFS=$'\t' read -r n_all n_conn n_fail < "$OUT.stat"; rm -f "$OUT.stat"
echo "Data written to $OUT ($n_all host(s): $n_conn outbound connection(s), $n_fail failed logon(s))." >&2

# THE ACCOUNTS AND PARTNERS VIEWS (2026-09-30, user request: "Accounts &
# Partners must give the same reports, but now with the Entities Accounts &
# Partners"): partners-out-<view>.rpt = this table regrouped per entity
# through the configured host pairs (xref/_hosts-accounts.tsv /
# _hosts-partners.tsv) by bin/rpt-rollup.awk (its header: the union rule, the
# cell rules); a raw address is in neither view. Rules per cell: Use cases and
# User the union · Connections and the failure counts summed · Last connection
# / Last the newest, First the oldest · Reason the newest failure's. Baked
# order Failures, Connections, name — the Endpoint view's.
PO_RULES="uc sum sum sum sum sum max list sum sum sum sum sum stamp min max"
for v in accounts:acct:Account:Accounts partners:ptn:Partner:Partners; do
    IFS=: read -r vk kind headl tname <<< "$v"
    m="$DATA/flow-manager/xref/_hosts-$vk.tsv"; [ -f "$m" ] || m=/dev/null
    b="$DATA/flow-manager/base/_$vk.tsv"; [ -f "$b" ] || b=/dev/null
    vout="$REPORTS_DIR/partners-out-$vk.rpt"
    awk -F'\t' -v MAP="$m" -v BASE="$b" -v KIND="$kind" -v HEADL="$headl" -v TNAME="$tname" -v NOUN="$vk" \
        -v ACTIVE="$tname" -v RULES="$PO_RULES" -v ORDER="11 8" -v DCAP=5 -v LCAP=10 \
        -f "$ROOT/bin/rpt-rollup.awk" "$OUT" > "$vout.tmp" 2> "$vout.stat" && mv "$vout.tmp" "$vout"
    IFS=$'\t' read -r n_v n_drop < "$vout.stat"; rm -f "$vout.stat"
    echo "Data written to $vout ($n_v $vk; $n_drop host row(s) in no $vk view)." >&2
done
