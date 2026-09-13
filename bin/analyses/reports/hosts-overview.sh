#!/usr/bin/env bash
#
# hosts-overview.sh — "Partners - Outgoing" (Analyses → Configuration,
# 2026-09-13, user request): the OPPOSITE of Partners - Incoming
# (fe-overview.sh). One row per REMOTE HOST — the partner-side server WE
# connect to — for UC1 (we deliver to the partner) and UC3 (we collect from
# the partner): the host's contact stamps, its Files and its polls.
#
#   Host           every configured remote host (base/_hosts.tsv roster); a
#                  host that only input/<env>/hosts_old.txt names is listed
#                  too — an old-gateway endpoint with no configuration here
#   Use cases      the use cases of its subscriptions: UC1 (we push), UC3 (we
#                  pull) or UC1/UC3 (both). A subscription's use case is its
#                  name prefix, else the DERIVED one (xref/
#                  _subscriptions-ucderived.tsv); any other use case shows too
#   Cloud          the newest SUCCESSFUL transfer leg with this host on THIS
#                  platform (_transfers.tsv: status Processed, remote host col
#                  16), as date + hh:mm — the last time we reached the
#                  partner; empty when there is none
#   Gateway        the host's stamp on the OLD gateway, verbatim from
#                  input/<env>/hosts_old.txt (the logons_old.txt format: one
#                  host per line, "<host> <stamp…>")
#   Files in/out   the host's Files — the Entities rule: a File whose
#                  CONNECTION side is out (_files.tsv col 16: we dialed)
#                  counts for every host its legs name — split by the FILE
#                  MOVEMENT (col 17): out = delivered to the partner (UC1),
#                  in = collected from it (UC3); a File with no movement
#                  counts in neither; a 0 renders empty
#   Error          the Files that FAILED (outcome Failed) — red when non-zero
#   Delivered      the out-side Files that completed (outcome Processed):
#                  Delivered + the failed deliveries = Files out
#   Auto retries   OK Files that carried a failed leg and no resubmitted leg —
#                  the platform's own retry delivered them (the Entities /
#                  Month stats figure)
#   Resubmit OK / Resubmit Error   the Files an operator resubmitted, by outcome
#   Last error     when the host's newest failed File started, date + hh:mm
#   Polls, Poll pattern   the server-log polls of the host's UC3 subscriptions
#                  (the Polling page, data/<env>/server/reports/polling.rpt,
#                  written by the server pool before the analyses reports):
#                  the polls summed, the pattern = the Observed cadence of
#                  the busiest subscription
#   Connection problems   the server-log connection failures of the host's
#                  subscriptions, summed (site-failures.rpt, the Connection
#                  failures page); the cell links that page with the busiest
#                  subscription's row marked (?axway_row=); a 0 renders
#                  empty. Last column, after a group divider
#
# Rows tint by the host's RESULT colour (restint, the base cache's third
# column); an old-gateway-only host has no result and stays untinted. Every
# figure is full-period (no date filter). Sources the ANALYSES lib, so the
# .rpt lands in data/<env>/analyses/reports/ and the page in
# docs/<env>/analyses/ (SUBS_GROUP_REPORTS, analyses:hosts-overview).
#
# Usage:
#   ./hosts-overview.sh   # -> data/<env>/analyses/reports/hosts-overview.rpt
#
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib.sh"
OUT="$REPORTS_DIR/hosts-overview.rpt"
HBASE="$DATA/flow-manager/base/_hosts.tsv"
HSUB="$DATA/flow-manager/xref/_hosts-subscriptions.tsv"
UCDF="$DATA/flow-manager/xref/_subscriptions-ucderived.tsv"
TF="$DATA/transfer/cache/_files.tsv"
TL="$DATA/transfer/cache/_transfers.tsv"
OLD="$ROOT/input/hosts_old.txt"
POLL="$DATA/server/reports/polling.rpt"          # the Polling page (server pool output)
SFAIL="$DATA/server/reports/site-failures.rpt"   # Connection failures per subscription (server pool output)

if [ ! -f "$HBASE" ]; then
    echo "hosts-overview: no $HBASE (config not extracted) — page not published." >&2
    rm -f "$OUT"
    exit 0
fi
[ -f "$HSUB" ]  || HSUB=/dev/null
[ -f "$UCDF" ]  || UCDF=/dev/null
[ -f "$TF" ]    || TF=/dev/null
[ -f "$TL" ]    || TL=/dev/null
[ -f "$OLD" ]   || OLD=/dev/null
[ -f "$POLL" ]  || POLL=/dev/null
[ -f "$SFAIL" ] || SFAIL=/dev/null
skip_if_fresh "$OUT" "${BASH_SOURCE[0]}" "$HBASE" "$HSUB" "$UCDF" "$TF" "$TL" "$OLD" "$POLL" "$SFAIL"

GENDATE=$(date '+%Y-%m-%d %H:%M:%S')

# One awk pass: the roster + joins in BEGIN (small files), the legs cache
# then the files cache streamed, then one "R" line per host and one "S"
# line of stat figures. The "-" sentinel keeps empty middle fields from
# collapsing (a TAB is IFS whitespace); the row writer swaps them back.
awk -F'\t' -v HBASE="$HBASE" -v HSUB="$HSUB" -v UCDF="$UCDF" -v OLD="$OLD" -v POLL="$POLL" -v SFAIL="$SFAIL" -v TLF="$TL" '
    function ucof(s) { if (match(s, /^UC[0-9]+/)) return substr(s, 1, RLENGTH); if (toupper(s) in UCD) return UCD[toupper(s)]; return "" }
    function trim(s) { sub(/^[ \t\r]+/, "", s); sub(/[ \t\r]+$/, "", s); return s }
    function nz(s) { return (s == "" ? "-" : s) }
    function strip(c) { while (index(c, "@{") == 1) sub(/^@\{[^}]*\}/, "", c); return c }
    function addset(s, v) { return index("\037" s "\037", "\037" v "\037") ? s : (s == "" ? v : s "\037" v) }
    BEGIN {
        while ((getline l < UCDF) > 0) { n = split(l, a, "\t"); if (n >= 2 && a[1] != "" && a[2] != "") UCD[toupper(a[1])] = a[2] } close(UCDF)
        # the roster: every configured host in FILE order (name-sorted), with
        # its result colour (third column, bin/build/result.sh)
        while ((getline l < HBASE) > 0) { n = split(l, a, "\t"); if (a[1] == "") continue
            k = toupper(a[1]); if (!(k in IDX)) { IDX[k] = ++nr; NAME[nr] = a[1]; RES[nr] = (n >= 3 ? a[3] : "") } } close(HBASE)
        # the host -> subscription pairs: the use-case set and the INVERSE map
        # subscription -> hosts (a SUBSEP-led list) the polls and the
        # connection failures join through
        while ((getline l < HSUB) > 0) { n = split(l, a, "\t"); if (n < 2 || a[1] == "" || a[2] == "") continue
            k = toupper(a[1]); if (!(k in IDX)) continue
            su = toupper(a[2])
            if (!((k SUBSEP "S" SUBSEP su) in HAS)) { HAS[k SUBSEP "S" SUBSEP su] = 1; SH[su] = SH[su] SUBSEP k }
            u = ucof(a[2]); if (u == "") continue
            if (!((k SUBSEP u) in HAS)) { HAS[k SUBSEP u] = 1; UCL[k] = UCL[k] (UCL[k] == "" ? "" : SUBSEP) u } } close(HSUB)
        # the old gateway file (format: see the header)
        while ((getline l < OLD) > 0) {
            l = trim(l); if (l == "" || substr(l, 1, 1) == "#") continue
            if (match(l, /[ \t,;]+/)) { u = substr(l, 1, RSTART - 1); s = trim(substr(l, RSTART + RLENGTH)) } else { u = l; s = "" }
            k = toupper(u); if (k == "") continue
            if (!(k in IDX)) { IDX[k] = ++nr; NAME[nr] = u; RES[nr] = ""; OLDONLY[nr] = 1 }
            GW[k] = s } close(OLD)
        # the Polling page rows: 2 subscription, 5 Observed, 6 Polls ("-" =
        # none) — summed onto every host of the subscription, the pattern of
        # the busiest one
        while ((getline l < POLL) > 0) { n = split(l, a, "\t"); if (a[1] != "ROW" || n < 6) continue
            su = toupper(strip(a[2])); if (!(su in SH)) continue
            pk = (a[6] ~ /^[0-9]+$/) ? a[6] + 0 : 0; obs = strip(a[5]); if (obs == "-") obs = ""
            m = split(substr(SH[su], 2), HL9, SUBSEP)
            for (j = 1; j <= m; j++) { k = HL9[j]; PK[k] += pk
                if (pk > 0 && (!(k in PKBEST) || pk > PKBEST[k])) { PKBEST[k] = pk; PAT[k] = obs } } } close(POLL)
        # the Connection failures rows (first table only): 2 subscription, 3
        # failures — summed onto the hosts, the busiest subscription linked
        t = 0
        while ((getline l < SFAIL) > 0) { n = split(l, a, "\t")
            if (a[1] == "TABLE") { t++; continue }
            if (a[1] != "ROW" || t != 1 || n < 3) continue
            nm = strip(a[2]); su = toupper(nm); if (!(su in SH)) continue
            c = a[3] + 0; if (c <= 0) continue
            m = split(substr(SH[su], 2), HL9, SUBSEP)
            for (j = 1; j <= m; j++) { k = HL9[j]; PR[k] += c
                if (!(k in PRBEST) || c > PRBEST[k]) { PRBEST[k] = c; PRSUB[k] = nm } } } close(SFAIL)
    }
    # the legs cache (first on the command line): col 1 CoreId, 3 status, 11/12
    # start date + time, 13 sort key, 16 remote host, 22 resubmitted — the
    # per-File leg facts of the Entities rule, and the newest successful leg
    # per host (the Cloud stamp)
    FILENAME == TLF {
        cid = $1; h = tolower($16)
        if ($3 != "Processed") fl[cid] = 1
        if ($22 == "true") rsb[cid] = 1
        if (h != "") { hs[cid] = addset(hs[cid], h); k = toupper(h)
            if ($3 == "Processed" && (k in IDX) && $13 > CLK[k]) { CLK[k] = $13; CLOUD[k] = $11 " " substr($12, 1, 5) } }
        next }
    # the files cache: col 1 CoreId, 2 outcome, 4/5 start date + time, 6 sort
    # key, 16 the connection side, 17 the file movement
    { cid = $1; if ($16 != "out" || !(cid in hs)) next
      f = ($2 == "Failed" || $2 == "Expired"); ok = ($2 == "Processed")
      n = split(hs[cid], HL, "\037")
      for (i = 1; i <= n; i++) { k = toupper(HL[i]); if (!(k in IDX)) continue
          if ($17 == "in") FIN[k]++; else if ($17 == "out") { FOUT[k]++; if (ok) DEL[k]++ }
          if ($2 == "Failed") { ECNT[k]++; if ($6 > ELK[k]) { ELK[k] = $6; LASTERR[k] = $4 " " substr($5, 1, 5) } }
          if (ok && (cid in fl) && !(cid in rsb)) AUTO[k]++
          if (ok && (cid in rsb)) RMOK[k]++
          if (f && (cid in rsb)) RMERR[k]++ } }
    END {
        for (i = 1; i <= nr; i++) { k = toupper(NAME[i])
            # the use-case cell: UC1..UC4 in order, any other use case after
            uc = ""
            m = split(UCL[k], U, SUBSEP)
            for (j = 1; j <= 4; j++) if ((k SUBSEP "UC" j) in HAS) uc = uc (uc == "" ? "" : "/") "UC" j
            for (j = 1; j <= m; j++) if (U[j] !~ /^UC[1-4]$/) uc = uc (uc == "" ? "" : "/") U[j]
            if (uc == "UC1") s_uc1++; else if (uc == "UC3") s_uc3++; else if (uc == "UC1/UC3") s_both++
            if (k in CLOUD) s_here++; else if (!(i in OLDONLY)) s_never++
            if (k in GW) s_gw++
            if (i in OLDONLY) s_old++
            fin = FIN[k] + 0; fout = FOUT[k] + 0; err = ECNT[k] + 0; del = DEL[k] + 0
            au = AUTO[k] + 0; rmo = RMOK[k] + 0; rme = RMERR[k] + 0; pk = PK[k] + 0; pt = PR[k] + 0
            s_in += fin; s_out += fout; s_err += err; s_del += del; s_au += au; s_rmo += rmo; s_rme += rme; s_pk += pk; s_prob += pt
            pat = (pk > 0 && (k in PAT)) ? PAT[k] : ""
            pr = (pt > 0) ? "@{href=../server/site-failures.html?axway_row=" PRSUB[k] "}" pt : ""
            printf "R\t%s\t%s\t%s\t%s\t%s\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%s\t%d\t%s\t%s\n", \
                NAME[i], nz(uc), ((k in CLOUD) ? CLOUD[k] : "-"), ((k in GW) ? nz(GW[k]) : "-"), nz(RES[i]), \
                fin, fout, err, del, au, rmo, rme, ((k in LASTERR) ? LASTERR[k] : "-"), pk, nz(pat), nz(pr)
        }
        printf "S\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\n", nr, s_uc1 + 0, s_uc3 + 0, s_both + 0, s_here + 0, s_never + 0, s_gw + 0, s_old + 0, \
            s_in + 0, s_out + 0, s_err + 0, s_del + 0, s_au + 0, s_rmo + 0, s_rme + 0, s_pk + 0, s_prob + 0
    }
' "$TL" "$TF" > "$OUT.rows"

IFS=$'\t' read -r _ n_all n_uc1 n_uc3 n_both n_here n_never n_gw n_old n_in n_out n_err n_del n_au n_rmo n_rme n_pk n_prob <<< "$(command grep $'^S\t' "$OUT.rows")"
# a 0 total renders empty like the 0 cells (the outcome-kind totals z-blank themselves)
nz() { if [ "${1:-0}" -eq 0 ] 2>/dev/null; then printf ''; else printf '%s' "$1"; fi; }

{
    printf 'TITLE\tPartners - Outgoing\n'
    printf 'DESC\tEvery remote host we connect to on one line (UC1 we deliver, UC3 we collect): its use cases, the last successful transfer here and the old-gateway stamp, its Files in and out with the delivered, failed, retried and resubmitted ones, its polls with their cadence, and its connection problems.\n'
    # default sort: Error (column 6, 0-based) descending; the rest is the BAKED
    # row order below (Files out, Files in, Polls, Cloud, Gateway, name),
    # which report.js stable sort preserves. gsep: the column GROUPS — a
    # divider before Cloud, Files in, Files out, Auto retries, Polls and
    # Connection problems (Partners - Incoming layout)
    printf 'TABLE\tRemote hosts\twide\tnofilter\trestint\tsort=6:-1\tgsep=2,4,5,8,12,14\n'
    printf 'HEAD\tHost\tUse cases\tCloud\tGateway\tFiles in\tFiles out\tError\tDelivered\tAuto retries\tResubmit OK\tResubmit Error\tLast error\tPolls\tPoll pattern\tConnection problems\n'
    printf 'KIND\thost\ttext\ttext\ttext\tnum\tnum\tnumfailed\tnumprocessed\tnumwarn\tnumwarn\tnumfailed\ttext\tnum\ttext\tnum\n'
    # R fields: 2 host 3 uc 4 cloud 5 gw 6 res 7 in 8 out 9 error 10 delivered
    # 11 auto 12 resubmit ok 13 resubmit error 14 last error 15 polls 16
    # pattern 17 connection problems. The outcome-kind counts pass their 0
    # through: the renderer z-blanks them.
    command grep $'^R\t' "$OUT.rows" | LC_ALL=C sort -t$'\t' -k8,8nr -k7,7nr -k15,15nr -k4,4r -k5,5r -k2,2f | awk -F'\t' '
        function z(v) { return (v + 0 == 0) ? "" : v }   # a 0 shows empty, like the z-blanked outcome cells
        { uc = ($3 == "-" ? "" : $3); last = ($4 == "-" ? "" : $4); gw = ($5 == "-" ? "" : $5)
          le = ($14 == "-" ? "" : $14); pat = ($16 == "-" ? "" : $16); prob = ($17 == "-" ? "" : $17)
          res = ($6 == "-" ? "" : "\t@data:res=" $6)
          printf "ROW\t%s\t%s\t%s\t%s\t%s\t%s\t%d\t%d\t%d\t%d\t%d\t%s\t%s\t%s\t%s%s\n", \
              $2, uc, last, gw, z($7), z($8), $9, $10, $11, $12, $13, le, z($15), pat, prob, res }'
    printf 'TOTAL\tTotal (%s rows)\t\t\t\t@{class=num}%s\t@{class=num}%s\t@{class=num failed}%s\t@{class=num processed}%s\t@{class=num warn}%s\t@{class=num warn}%s\t@{class=num failed}%s\t\t@{class=num}%s\t\t%s\n' \
        "$n_all" "$(nz "$n_in")" "$(nz "$n_out")" "$n_err" "$n_del" "$n_au" "$n_rmo" "$n_rme" "$(nz "$n_pk")" "$(nz "$n_prob")"
    printf 'KEYWORDS\tpartners,outgoing,host,hosts,remote host,endpoint,overview,status,use case,uc1,uc3,push,pull,deliver,collect,last transfer,gateway,old gateway,migration,files,in,out,delivered,error,retry,retries,resubmit,last error,poll,polls,pattern,cadence,connection,failures\n'
    printf 'FOOT\tGenerated on %s\n' "$GENDATE"
} > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"
rm -f "$OUT.rows"

echo "Data written to $OUT ($n_all host(s): $n_uc1 UC1, $n_uc3 UC3, $n_both UC1/UC3; $n_here reached here, $n_gw with a gateway stamp, $n_old old-gateway only; $n_in in, $n_out out, $n_err error, $n_del delivered, $n_au auto retries; $n_pk poll(s), $n_prob connection problem(s))." >&2
