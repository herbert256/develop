#!/usr/bin/env bash
#
# hosts-overview.sh — "Partners - Outgoing" (Analyses → Configuration,
# 2026-09-13, user request): the OPPOSITE of Partners - Incoming
# (fe-overview.sh). One row per REMOTE HOST — the partner-side server WE
# connect to — for UC1 (we deliver to the partner) and UC3 (we collect from
# the partner): the host's contact stamps and its Files.
#
#   Host           every configured remote host (base/_hosts.tsv roster); a
#                  host that only input/hosts_old.txt names is listed too —
#                  an old-gateway endpoint with no configuration here
#   Use cases      the use cases of its subscriptions: UC1 (we push), UC3 (we
#                  pull) or UC1/UC3 (both). A subscription's use case is its
#                  name prefix, else the DERIVED one (xref/
#                  _subscriptions-ucderived.tsv); any other use case shows too
#   Cloud          the newest SUCCESSFUL transfer leg with this host on THIS
#                  platform (_transfers.tsv: status Processed, remote host col
#                  16), as date + hh:mm — the last time we reached the
#                  partner; empty when there is none
#   Gateway        the host's stamp on the OLD gateway, verbatim from
#                  input/hosts_old.txt (the logons_old.txt format: one host
#                  per line, "<host> <stamp…>")
#   Files          a column GROUP — a GHEAD banner over In · Out · Error, the
#                  Entities way (2026-09-14, user request): the host's Files
#                  by the Entities rule — a File whose CONNECTION side is out
#                  (_files.tsv col 16: we dialed) counts for every host its
#                  legs name — split by the FILE MOVEMENT (col 17): Out =
#                  delivered to the partner (UC1), In = collected from it
#                  (UC3); a File with no movement counts in neither; a 0
#                  renders empty. Error = the Files that FAILED (outcome
#                  Failed) — red when non-zero
#   Auto retries   OK Files that carried a failed leg and no resubmitted leg —
#                  the platform's own retry delivered them (the Entities /
#                  Month stats figure)
#   Resubmit OK / Resubmit Error   the Files an operator resubmitted, by outcome
#
# Dropped 2026-09-14 (user request): Delivered, Last error, Polls, Poll
# pattern and Connection problems — the polls and the connection failures
# stay on their own server pages (Polling, Connection failures).
#
# Rows tint by the host's RESULT colour (restint, the base cache's third
# column); an old-gateway-only host has no result and stays untinted. Every
# figure is full-period (no date filter). Sources the ANALYSES lib, so the
# .rpt lands in data/analyses/reports/ and the page in docs/analyses/
# (SUBS_GROUP_REPORTS, analyses:hosts-overview).
#
# Usage:
#   ./hosts-overview.sh   # -> data/analyses/reports/hosts-overview.rpt
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

if [ ! -f "$HBASE" ]; then
    echo "hosts-overview: no $HBASE (config not extracted) — page not published." >&2
    rm -f "$OUT"
    exit 0
fi
[ -f "$HSUB" ] || HSUB=/dev/null
[ -f "$UCDF" ] || UCDF=/dev/null
[ -f "$TF" ]   || TF=/dev/null
[ -f "$TL" ]   || TL=/dev/null
[ -f "$OLD" ]  || OLD=/dev/null
skip_if_fresh "$OUT" "${BASH_SOURCE[0]}" "$HBASE" "$HSUB" "$UCDF" "$TF" "$TL" "$OLD"

GENDATE=$(date '+%Y-%m-%d %H:%M:%S')

# One awk pass: the roster + joins in BEGIN (small files), the legs cache
# then the files cache streamed, then one "R" line per host and one "S"
# line of stat figures. The "-" sentinel keeps empty middle fields from
# collapsing (a TAB is IFS whitespace); the row writer swaps them back.
awk -F'\t' -v HBASE="$HBASE" -v HSUB="$HSUB" -v UCDF="$UCDF" -v OLD="$OLD" -v TLF="$TL" '
    function ucof(s) { if (match(s, /^UC[0-9]+/)) return substr(s, 1, RLENGTH); if (toupper(s) in UCD) return UCD[toupper(s)]; return "" }
    function trim(s) { sub(/^[ \t\r]+/, "", s); sub(/[ \t\r]+$/, "", s); return s }
    function nz(s) { return (s == "" ? "-" : s) }
    function addset(s, v) { return index("\037" s "\037", "\037" v "\037") ? s : (s == "" ? v : s "\037" v) }
    BEGIN {
        while ((getline l < UCDF) > 0) { n = split(l, a, "\t"); if (n >= 2 && a[1] != "" && a[2] != "") UCD[toupper(a[1])] = a[2] } close(UCDF)
        # the roster: every configured host in FILE order (name-sorted), with
        # its result colour (third column, bin/build/result.sh)
        while ((getline l < HBASE) > 0) { n = split(l, a, "\t"); if (a[1] == "") continue
            k = toupper(a[1]); if (!(k in IDX)) { IDX[k] = ++nr; NAME[nr] = a[1]; RES[nr] = (n >= 3 ? a[3] : "") } } close(HBASE)
        # the host -> subscription pairs: the use-case set per host
        while ((getline l < HSUB) > 0) { n = split(l, a, "\t"); if (n < 2 || a[1] == "" || a[2] == "") continue
            k = toupper(a[1]); if (!(k in IDX)) continue
            u = ucof(a[2]); if (u == "") continue
            if (!((k SUBSEP u) in HAS)) { HAS[k SUBSEP u] = 1; UCL[k] = UCL[k] (UCL[k] == "" ? "" : SUBSEP) u } } close(HSUB)
        # the old gateway file (format: see the header)
        while ((getline l < OLD) > 0) {
            l = trim(l); if (l == "" || substr(l, 1, 1) == "#") continue
            if (match(l, /[ \t,;]+/)) { u = substr(l, 1, RSTART - 1); s = trim(substr(l, RSTART + RLENGTH)) } else { u = l; s = "" }
            k = toupper(u); if (k == "") continue
            if (!(k in IDX)) { IDX[k] = ++nr; NAME[nr] = u; RES[nr] = ""; OLDONLY[nr] = 1 }
            GW[k] = s } close(OLD)
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
    # the files cache: col 1 CoreId, 2 outcome, 16 the connection side, 17 the
    # file movement
    { cid = $1; if ($16 != "out" || !(cid in hs)) next
      f = ($2 == "Failed" || $2 == "Expired"); ok = ($2 == "Processed")
      n = split(hs[cid], HL, "\037")
      for (i = 1; i <= n; i++) { k = toupper(HL[i]); if (!(k in IDX)) continue
          if ($17 == "in") FIN[k]++; else if ($17 == "out") FOUT[k]++
          if ($2 == "Failed") ECNT[k]++
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
            fin = FIN[k] + 0; fout = FOUT[k] + 0; err = ECNT[k] + 0
            au = AUTO[k] + 0; rmo = RMOK[k] + 0; rme = RMERR[k] + 0
            s_in += fin; s_out += fout; s_err += err; s_au += au; s_rmo += rmo; s_rme += rme
            printf "R\t%s\t%s\t%s\t%s\t%s\t%d\t%d\t%d\t%d\t%d\t%d\n", \
                NAME[i], nz(uc), ((k in CLOUD) ? CLOUD[k] : "-"), ((k in GW) ? nz(GW[k]) : "-"), nz(RES[i]), \
                fin, fout, err, au, rmo, rme
        }
        printf "S\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\n", nr, s_uc1 + 0, s_uc3 + 0, s_both + 0, s_here + 0, s_never + 0, s_gw + 0, s_old + 0, \
            s_in + 0, s_out + 0, s_err + 0, s_au + 0, s_rmo + 0, s_rme + 0
    }
' "$TL" "$TF" > "$OUT.rows"

IFS=$'\t' read -r _ n_all n_uc1 n_uc3 n_both n_here n_never n_gw n_old n_in n_out n_err n_au n_rmo n_rme <<< "$(command grep $'^S\t' "$OUT.rows")"
# a 0 total renders empty like the 0 cells (the outcome-kind totals z-blank themselves)
nz() { if [ "${1:-0}" -eq 0 ] 2>/dev/null; then printf ''; else printf '%s' "$1"; fi; }

{
    printf 'TITLE\tPartners - Outgoing\n'
    printf 'DESC\tEvery remote host we connect to on one line (UC1 we deliver, UC3 we collect): its use cases, the last successful transfer here and the old-gateway stamp, its Files in, out and failed, and the retried and resubmitted ones.\n'
    # default sort: Error (column 6, 0-based) descending; the rest is the BAKED
    # row order below (Files out, Files in, Cloud, Gateway, name), which
    # report.js stable sort preserves. gsep: the column GROUPS — a divider
    # before Cloud, the Files group and Auto retries. The GHEAD banner labels
    # the Files group (In · Out · Error) and spans the unlabelled columns too,
    # so every column belongs to one group (report.js initGroups: the picker
    # and the drags work per group); its cells carry the same gsep dividers
    printf 'TABLE\tRemote hosts\twide\tnofilter\trestint\tsort=6:-1\tgsep=2,4,7\n'
    printf 'GHEAD\t@{colspan=2}\t@{colspan=2,class=gsep}\t@{colspan=3,class=gband gsep}Files\t@{colspan=3,class=gsep}\n'
    printf 'HEAD\tHost\tUse cases\tCloud\tGateway\tIn\tOut\tError\tAuto retries\tResubmit OK\tResubmit Error\n'
    printf 'KIND\thost\ttext\ttext\ttext\tnum\tnum\tnumfailed\tnumwarn\tnumwarn\tnumfailed\n'
    # R fields: 2 host 3 uc 4 cloud 5 gw 6 res 7 in 8 out 9 error 10 auto 11
    # resubmit ok 12 resubmit error. The outcome-kind counts pass their 0
    # through: the renderer z-blanks them.
    command grep $'^R\t' "$OUT.rows" | LC_ALL=C sort -t$'\t' -k8,8nr -k7,7nr -k4,4r -k5,5r -k2,2f | awk -F'\t' '
        function z(v) { return (v + 0 == 0) ? "" : v }   # a 0 shows empty, like the z-blanked outcome cells
        { uc = ($3 == "-" ? "" : $3); last = ($4 == "-" ? "" : $4); gw = ($5 == "-" ? "" : $5)
          res = ($6 == "-" ? "" : "\t@data:res=" $6)
          printf "ROW\t%s\t%s\t%s\t%s\t%s\t%s\t%d\t%d\t%d\t%d%s\n", $2, uc, last, gw, z($7), z($8), $9, $10, $11, $12, res }'
    printf 'TOTAL\tTotal (%s rows)\t\t\t\t@{class=num}%s\t@{class=num}%s\t@{class=num failed}%s\t@{class=num warn}%s\t@{class=num warn}%s\t@{class=num failed}%s\n' \
        "$n_all" "$(nz "$n_in")" "$(nz "$n_out")" "$n_err" "$n_au" "$n_rmo" "$n_rme"
    printf 'KEYWORDS\tpartners,outgoing,host,hosts,remote host,endpoint,overview,status,use case,uc1,uc3,push,pull,deliver,collect,last transfer,gateway,old gateway,migration,files,in,out,error,retry,retries,resubmit\n'
    printf 'FOOT\tGenerated on %s\n' "$GENDATE"
} > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"
rm -f "$OUT.rows"

echo "Data written to $OUT ($n_all host(s): $n_uc1 UC1, $n_uc3 UC3, $n_both UC1/UC3; $n_here reached here, $n_gw with a gateway stamp, $n_old old-gateway only; $n_in in, $n_out out, $n_err error, $n_au auto retries)." >&2
