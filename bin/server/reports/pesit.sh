#!/usr/bin/env bash
#
# pesit.sh — PeSIT protocol activity from the server log (the PESITD component).
# One pass over the parse cache (data/_parse.tsv: 1=date, 2=time, 3=level,
# 4=component, 5=message) emits, per calendar day (calendar gaps filled with
# "0" rows), the PeSIT signals that never reach the transfer logs:
#   client logins / logouts, inbound transfer completions, network resets, and
#   the "exceeded the maximum number of allowed connections" ceiling hits.
#
# All PeSIT traffic on this platform is the internal cluster CFT (caller id
# P14303_CFT01, remote hosts 145.219.156.20/.21), so there is no partner
# dimension worth a table — the story is per-day volume and the connection
# ceiling being hit. Warnings are tinted amber, Errors red; click a day for its
# 10 most recent Warning/Error lines.
#
# Usage:
#   ./pesit.sh    # reads input/*.csv (via the cache), writes data/pesit.rpt
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib.sh"
mkdir -p "$REPORTS_DIR"
OUT="$REPORTS_DIR/pesit.rpt"
# the 30-minute direction-split sidecar (date<TAB>slot0-47<TAB>out<TAB>in,
# nonzero slots only): the dashboards overview (summed to 6-hour slots) and
# the day pages (as-is) read it for their PeSIT hero view — the problem
# classification lives HERE only, never duplicated downstream.
SLOTS="$REPORTS_DIR/pesit-slots.tsv"

shopt -s nullglob
files=("$INPUT_DIR"/*.csv)
shopt -u nullglob
if [ ${#files[@]} -eq 0 ]; then
    echo "No files matching '*.csv' found in '$INPUT_DIR'" >&2
    rm -f "$OUT" "$SLOTS"   # no data for this ENV — page not published (an env-split legitimate state)
    exit 0
fi
ensure_parsed
[ -f "$SLOTS" ] || rm -f "$OUT"   # a missing sidecar must force a rebuild (skip_if_fresh checks $OUT only)
skip_if_fresh "$OUT" "${BASH_SOURCE[0]}"
echo "Found ${#files[@]} file(s) in '$INPUT_DIR', processing..." >&2

# ONE pass over the cache for BOTH page halves (formerly two full scans of the
# multi-GB parse cache). The activity half reads every PESITD (component P)
# row: per-day login/logout/transfer/reset/ceiling counts, first/last time,
# and the per-day Warning/Error drill lines (ROW/TOT|/KPI| lines). The
# problems half (prob(), the classify() chain) reads every non-Info PESITD
# row plus every non-Info TM line naming FPDU/PeSIT — a subset that overlaps
# the first, so the same row feeds both — and emits R1/R2/R3/R4/TOT2| lines.
# classify() is FIRST-MATCH in a fixed order (the PesitNetworkException
# wrappers before the bare FPDU lines they quote), so the pick never depends
# on iteration order. Both ENDs walk the Julian-day range so calendar gaps
# become explicit "0" rows (like topview).
agg=$(awk -F'\t' "$LOGLINES_AWK"'
    function jdn(y,m,d,  a){ a=int((14-m)/12); y=y+4800-a; m=m+12*a-3; return d+int((153*m+2)/5)+365*y+int(y/4)-int(y/100)+int(y/400)-32045 }
    function fromjdn(j,  a,b,c,dd,e,mm,day,mon,yr){ a=j+32044; b=int((4*a+3)/146097); c=a-int(146097*b/4); dd=int((4*c+3)/1461); e=c-int(1461*dd/4); mm=int((5*e+2)/153); day=e-int((153*mm+2)/5)+1; mon=mm+3-12*int(mm/10); yr=100*b+dd-4800+int(mm/10); return sprintf("%04d-%02d-%02d",yr,mon,day) }
    # class -> "direction|display name"; OUT = ST->CFT (TM client), IN = CFT->ST (PESITD server)
    function classify(c, m) {
        if (c == "P") {
            if (m ~ /Network error: Connection reset/)                        return "IN|Connection reset by the CFT"
            if (m ~ /exceeded the maximum number of allowed connection/)      return "IN|ST connection ceiling hit (max 100)"
            if (m ~ /exceeded the maximum number of allowed sessions/)        return "IN|ST session ceiling hit"
            if (m ~ /Error sending event|Unable to submit event/)             return "IN|Internal event delivery problem"
            if (m ~ /Send negative FPDU_ACREATE/)                             return "IN|Transfer refused by ST (negative ACREATE sent)"
            return "IN|Other inbound (PESITD) problem"
        }
        if (m ~ /Received negative SEND_CONF/)                                return "OUT|Transfer rejected mid-send (negative SEND_CONF)"
        if (m ~ /Received negative ABORT_IND/)                                return "OUT|Aborted by the CFT (negative ABORT_IND)"
        if (m ~ /Received negative CONNECT_CONF/) {
            if (m ~ /diagCode=309/)                                           return "OUT|CFT connection limit (RCONNECT 309)"
            return "OUT|Connection refused by the CFT (negative CONNECT_CONF)"
        }
        if (m ~ /aborted before SENDENDED/)                                   return "OUT|Transfer aborted before completion (SENDENDED)"
        if (m ~ /Invalid FPDU_AWRITE/)                                        return "OUT|Checkpoint mismatch (invalid FPDU_AWRITE)"
        if (m ~ /Too many connections for this CT/)                           return "OUT|CFT connection limit (RCONNECT 309)"
        if (m ~ /required SSL/)                                               return "OUT|SSL required / handshake mismatch (code 399)"
        if (m ~ /Blocking I\/O error/)                                        return "OUT|CFT file I/O error (Blocking I/O)"
        if (m ~ /File already exists/)                                        return "OUT|File already exists at the CFT"
        if (m ~ /Failure in opening file/)                                    return "OUT|CFT failed to open the file"
        if (m ~ /FPDU_LOGIN/ && m ~ /Network incident/)                       return "OUT|Login failed - network incident (FPDU_LOGIN)"
        if (m ~ /FPDU_ABORT/ && m ~ /Time out/)                               return "OUT|Timeout (FPDU_ABORT)"
        if (m ~ /Receive negative FPDU_ACREATE/)                              return "OUT|Transfer refused by the CFT (negative ACREATE, unspecified)"
        if (m ~ /FPDU_ADESELECT/)                                             return "OUT|Session deselect refused (negative ADESELECT)"
        return "OUT|Other outbound (client) problem"
    }
    # the problems half, for one qualifying row (d already date-validated)
    function prob(d,   m2, t2, cls, cp, dir, s, code, x, line) {
        m2 = $5; t2 = $2
        cls = classify($4, m2)
        split(cls, cp, "|"); dir = cp[1]
        tot++; day[d]++; allday2[d] = 1
        # 30-minute slot split (the pesit-slots.tsv sidecar): slot 0-47
        s = (t2 ~ /^[0-9][0-9]:[0-9][0-9]/) ? substr(t2, 1, 2) * 2 + (substr(t2, 4, 2) + 0 >= 30 ? 1 : 0) : 0
        if (dir == "OUT") { dout++; dayout[d]++; souts[d, s]++ } else { din++; dayin[d]++; sins[d, s]++ }
        cc[cls]++; cd[cls, d]++
        if (!(cls in cfirst) || d " " t2 < cfirst[cls]) cfirst[cls] = d " " t2
        if (!(cls in clast)  || d " " t2 > clast[cls])  clast[cls]  = d " " t2
        code = ""
        if (match(m2, /diagCode=[0-9]+/)) {
            code = substr(m2, RSTART + 9, RLENGTH - 9)
            gc[code]++; gd[code, d]++
            if (!(code in gtxt)) {   # first diagText seen (scan order: deterministic)
                x = m2
                if (match(x, /diagText=[^.]*[.]?/)) { x = substr(x, RSTART + 9, RLENGTH - 9); sub(/[.]$/, "", x) }
                else x = substr(x, 1, 80)
                gtxt[code] = x
            }
        }
        if (t2 != "") { if (!(d in first2) || t2 < first2[d]) first2[d] = t2; if (!(d in last2) || t2 > last2[d]) last2[d] = t2 }
        line = lvlname($3) " " compname($4) "  " substr($5, 1, 200)
        addline("D" SUBSEP d, $1 " " $2, line)
        addline("C" SUBSEP cls, $1 " " $2, line)
        if (code != "") addline("G" SUBSEP code, $1 " " $2, line)
    }
    $4 == "P" {
        d = substr($1, 1, 10); if (d !~ /^[0-9][0-9][0-9][0-9]-/) next
        m = $5; t = $2
        rec[d]++; trec++; allday[d] = 1
        if (m ~ /Client logged in/)                                  { li[d]++;  tli++ }
        else if (m ~ /Client logged out/)                           { lo[d]++;  tlo++ }
        else if (m ~ /transfer completed with diagCode/)            { xf[d]++;  txf++ }
        else if (m ~ /Network error: Connection reset/)             { rs[d]++;  trs++ }
        else if (m ~ /exceeded the maximum number of allowed connections/) { mxc[d]++; tmx++ }
        if (t != "") { if (!(d in first) || t < first[d]) first[d] = t; if (!(d in last) || t > last[d]) last[d] = t }
        if ($3 != "I") { addline(d, $1 " " $2, lvlname($3) " " compname($4) "  " substr($5, 1, 200)); prob(d) }
        next
    }
    $4 == "T" && $3 == "I" {
        # the OUTBOUND FPDU LEDGER (2026-08): the TM component acting as PeSIT
        # CLIENT logs every protocol confirmation at INFO level —
        # connectionConfirmation / sendFileConfirmation / abortIndication with
        # a diagCode. Refusals and aborts here (309 too-many-connections, 310
        # network incident, 214 checkpoint) are invisible to the error
        # reports, which only see E/W lines. Counted at I level ONLY so the
        # E-level wrappers in the Problem types table are never double-counted.
        # (This block intercepts ALL Info TM rows; the block below dropped
        # them unchanged before, so the problems half is unaffected.)
        m = $5
        if (m ~ /^(connectionConfirmation|sendFileConfirmation|abortIndication)\./) {
            d = substr($1, 1, 10)
            if (d ~ /^[0-9][0-9][0-9][0-9]-/) {
                kind = substr(m, 1, index(m, ".") - 1)
                code = "-"; if (match(m, /diagCode=[0-9]+/)) code = substr(m, RSTART + 9, RLENGTH - 9)
                fk = kind SUBSEP code
                fpdu[fk]++; ftot++
                if (ffst[fk] == "" || d < ffst[fk]) ffst[fk] = d
                if (d > flst[fk]) flst[fk] = d
                fdd[fk SUBSEP d]++
                if (ftxt[fk] == "") {   # first diagText seen (scan order: deterministic)
                    x = m
                    if (match(x, /diagText=[^,]*/)) { x = substr(x, RSTART + 9, RLENGTH - 9); sub(/[. ]+$/, "", x) } else x = ""
                    if (x == "") x = (code == "0" ? "(success)" : "-")
                    ftxt[fk] = x
                }
                addline("FP" SUBSEP fk, $1 " " $2, lvlname($3) " " compname($4) "  " substr($5, 1, 200))
            }
        }
        next
    }
    $4 == "T" {
        # TM lines qualify on FPDU/PeSIT keywords OR the negative-response
        # shapes that carry neither ("Received negative CONNECT_CONF/ABORT_IND
        # response: diagCode=..." — 4,160 real ST->CFT failures)
        if ($5 !~ /FPDU|[Pp][Ee][Ss][Ii][Tt]|Received negative|diagCode=/) next
        d = $1; if (d !~ /^[0-9][0-9][0-9][0-9]-/) next
        prob(d)
        next
    }
    END {
        # ---- the activity table (every PESITD row) ----
        mn = 0; mx0 = 0
        for (d in allday) { split(d, pp, "-"); j = jdn(pp[1]+0, pp[2]+0, pp[3]+0); if (mn == 0 || j < mn) mn = j; if (j > mx0) mx0 = j }
        if (mn == 0) exit   # zero PESITD records: emit nothing — the shell empty-guard below handles it (the walk would otherwise print one bogus fromjdn(0) year -4713 row)
        ndays = 0; busyd = ""; busyc = 0
        for (d in rec) if (rec[d] > busyc || (rec[d] == busyc && d < busyd)) { busyc = rec[d]; busyd = d }   # earliest date breaks a tie
        for (j = mn; j <= mx0; j++) {
            d = fromjdn(j)
            if (d in rec) {
                ndays++
                fi = first[d]; sub(/\.[0-9]+$/, "", fi); if (fi == "") fi = "-"
                la = last[d];  sub(/\.[0-9]+$/, "", la); if (la == "") la = "-"
                printf "ROW\t%s\t%d\t%d\t%d\t%d\t%d\t%s\t%s\t@data:loglines=%s\n", \
                    d, li[d]+0, lo[d]+0, xf[d]+0, rs[d]+0, mxc[d]+0, fi, la, lastlines(d)
            } else {
                printf "ROW\t%s\t0\t0\t0\t0\t0\t-\t-\t@data:loglines=\n", d
            }
        }
        printf "TOT|%d|%d|%d|%d|%d|%d\n", trec+0, tli+0, tlo+0, txf+0, trs+0, tmx+0
        printf "KPI|%d|%s|%d|%s|%s\n", ndays, busyd, busyc, fromjdn(mn), fromjdn(mx0)
        # ---- the outbound FPDU ledger (F2/FT2 lines; shares computed here,
        # where the total is) ----
        for (x in fdd) { split(x, fa, SUBSEP); kk = fa[1] SUBSEP fa[2]; fbk[kk] = fbk[kk] (fbk[kk] ? "," : "") fa[3] ":" fdd[x] }
        nf = 0
        for (k in fpdu) { nf++; split(k, fa, SUBSEP)
            printf "F2\t%s\t%s\t%d\t%.1f\t%s\t%s\t%s\t%s\t%s\n", fa[1], fa[2], fpdu[k], (ftot ? fpdu[k]*100/ftot : 0), ftxt[k], ffst[k], flst[k], fbk[k], lastlines("FP" SUBSEP k) }
        if (nf) printf "FT2|%d|%d\n", ftot+0, nf+0
        # ---- the problems tables (both components, non-Info) ----
        if (tot == 0) exit
        mn = 0; mx0 = 0
        for (d in allday2) { split(d, pp, "-"); j = jdn(pp[1]+0, pp[2]+0, pp[3]+0); if (mn == 0 || j < mn) mn = j; if (j > mx0) mx0 = j }
        ndays = 0; busyd = ""; busyc = 0
        for (d in day) { if (day[d] > busyc || (day[d] == busyc && d < busyd)) { busyc = day[d]; busyd = d } }
        for (j = mn; j <= mx0; j++) {
            d = fromjdn(j)
            if (d in day) {
                ndays++
                fi = first2[d]; sub(/\.[0-9]+$/, "", fi); if (fi == "") fi = "-"
                la = last2[d];  sub(/\.[0-9]+$/, "", la); if (la == "") la = "-"
                printf "R1\t%s\t%d\t%d\t%d\t%s\t%s\t@data:loglines=%s\n", \
                    d, day[d]+0, dayout[d]+0, dayin[d]+0, fi, la, lastlines("D" SUBSEP d)
            } else {
                printf "R1\t%s\t0\t0\t0\t-\t-\t@data:loglines=\n", d
            }
        }
        # the 30-minute sidecar rows (nonzero slots only), same calendar walk
        # so the order is deterministic — never awk hash order
        for (j = mn; j <= mx0; j++) {
            d = fromjdn(j)
            for (s = 0; s < 48; s++)
                if ((d, s) in souts || (d, s) in sins)
                    printf "R4\t%s\t%d\t%d\t%d\n", d, s, souts[d, s]+0, sins[d, s]+0
        }
        for (cls in cc) {
            split(cls, cp, "|")
            bk = ""
            for (d in day) if ((cls SUBSEP d) in cd) bk = bk (bk ? "," : "") d ":" cd[cls, d]
            ff = cfirst[cls]; sub(/[.][0-9]+$/, "", ff)
            ll = clast[cls];  sub(/[.][0-9]+$/, "", ll)
            printf "R2\t%d\t%s\t%s\t%.1f%%\t%s\t%s\t@data:buckets=%s\t@data:loglines=%s\n", \
                cc[cls], cp[2], (cp[1] == "OUT" ? "ST \342\206\222 CFT" : "CFT \342\206\222 ST"), \
                cc[cls] * 100 / tot, ff, ll, bk, lastlines("C" SUBSEP cls)
        }
        for (code in gc) {
            bk = ""
            for (d in day) if ((code SUBSEP d) in gd) bk = bk (bk ? "," : "") d ":" gd[code, d]
            printf "R3\t%d\t%s\t%s\t%.1f%%\t@data:buckets=%s\t@data:loglines=%s\n", \
                gc[code], code, gtxt[code], gc[code] * 100 / tot, bk, lastlines("G" SUBSEP code)
        }
        printf "TOT2|%d|%d|%d|%d|%s|%d|%s|%s\n", tot+0, dout+0, din+0, ndays, busyd, busyc, fromjdn(mn), fromjdn(mx0)
    }
' "$PARSED")

if [ -z "$agg" ]; then echo "No PeSIT (PESITD) records found." >&2; rm -f "$OUT" "$SLOTS"; exit 0; fi

rows=$(printf '%s\n' "$agg" | grep '^ROW')
IFS='|' read -r _ trec tli tlo txf trs tmx <<< "$(printf '%s\n' "$agg" | grep '^TOT|')"
IFS='|' read -r _ ndays busyd busyc kfrom kto <<< "$(printf '%s\n' "$agg" | grep '^KPI|')"
[ "$ndays" -eq 1 ] && total_label="Totals for 1 day" || total_label="Totals for $ndays days"

{
    printf 'TITLE\tPeSIT Protocol\n'
    printf 'DESC\tPeSIT (PESITD) activity per day: client logins/logouts, inbound transfers, network resets and connection-ceiling hits.\n'
    printf 'INTRO\tThe PeSIT protocol layer, per day. Over **%s** day(s) (%s → %s): **%s** client login(s), **%s** inbound transfer(s) completed, **%s** network reset(s), and the connection ceiling (max **100**) was hit **%s** time(s). All PeSIT traffic here is the internal cluster CFT (caller `P14303_CFT01`, hosts 145.219.156.20/.21), so this is a capacity and stability view, not a partner view. Click a day for its 10 most recent Warning/Error lines.\n' \
        "$ndays" "$kfrom" "$kto" "$tli" "$txf" "$trs" "$tmx"
    printf 'TABLE\tPeSIT activity per day\twide\ttotaltop\n'
    printf 'HEAD\tDate\tLogins\tLogouts\tTransfers\tConn resets\tMax-conn hits\tFirst\tLast\n'
    printf 'KIND\ttext\tnum\tnum\tnum\tnumfailed\tnumwarn\ttext\ttext\n'
    printf 'TOTAL\t%s\t@{class=num}%s\t@{class=num}%s\t@{class=num}%s\t@{class=num failed}%s\t@{class=num warn}%s\t\t\n' \
        "$total_label" "$tli" "$tlo" "$txf" "$trs" "$tmx"
    printf '%s\n' "$rows"
    printf 'NOTE\tOne row = one calendar day. Logins/Logouts come from "Client logged in/out"; Transfers from "Inbound transfer completed with diagCode"; Conn resets from PESITD "Network error: Connection reset" (also counted in Transfer Error Reasons); Max-conn hits from "PeSIT server has exceeded the maximum number of allowed connections 100" — the internal CFT link saturating the 100-connection limit. Counts are additive, so a date-filtered range re-totals them. Conn resets are tinted red, Max-conn hits amber. Click a day to expand its 10 most recent Warning/Error lines (newest first).\n'
    printf 'SUMMARY\tDays: %s  |  Logins: %s  |  Transfers: %s  |  Conn resets: %s  |  Max-conn hits: %s\n' "$ndays" "$tli" "$txf" "$trs" "$tmx"
# The report is assembled in THREE writes (this block, the problems append,
# the FOOT append) — all land in $OUT.tmp; the mv after the last one publishes
# the complete file atomically, so a killed run can never leave a truncated
# $OUT with a fresh mtime for skip_if_fresh to trust.
} > "$OUT.tmp"

# ---- PeSIT problems (formerly pesit-problems.sh, absorbed 2026-07): every ----
# problem line on the ST<->CFT link, BOTH components, classified per day /
# per problem type / per diagCode. Its SUMMARY line ("Problems: N ...") is
# kept — the dashboards overview reads those figures from this rpt.
(

# The problems half of the SAME single pass above (R1/R2/R3/R4/TOT2 lines) —
# formerly a second full scan of the multi-GB parse cache.
agg=$(printf '%s\n' "$agg" | grep -E '^(R1|R2|R3|R4|TOT2)' || true)

if [ -z "$agg" ]; then echo "No PeSIT problem records found." >&2; rm -f "$OUT" "$SLOTS"; exit 0; fi

TAB=$(printf '\t')
# per-day rows in calendar order (R1: date cnt out in first last drill)
rows_day=$(printf '%s\n' "$agg" | awk -F'\t' -v OFS='\t' '$1 == "R1" { $1 = "ROW"; print }')
# problem types by count desc, name tiebreak; display order: type dir cnt share first last + data
# (`|| true` on both: a log with only ONE problem class — e.g. resets but no
# diagCode lines — must not kill the report under pipefail)
rows_cls=$(printf '%s\n' "$agg" | { grep '^R2' || true; } | sort -t"$TAB" -k2,2rn -k3,3 \
    | awk -F'\t' -v OFS='\t' '{ print "ROW", $3, $4, $2, $5, $6, $7, $8, $9 }')
# diagCodes by count desc, code tiebreak; display order: code text cnt share + data
rows_code=$(printf '%s\n' "$agg" | { grep '^R3' || true; } | sort -t"$TAB" -k2,2rn -k3,3n \
    | awk -F'\t' -v OFS='\t' '{ print "ROW", $3, $4, $2, $5, $6, $7 }')
IFS='|' read -r _ tot dout din ndays busyd busyc kfrom kto <<< "$(printf '%s\n' "$agg" | grep '^TOT2|')"
ncls=$(printf '%s\n' "$rows_cls" | grep -c . || true)
ncode=$(printf '%s\n' "$rows_code" | grep -c . || true)
# Σ Log lines over the diagCode rows only — LESS than $tot, since lines carrying
# no diagCode (connection resets, ceilings) are excluded from this table. The
# diagCode TOTAL must reconcile with its own rows (and with report.js's s0 recalc).
code_tot=$(printf '%s\n' "$agg" | { grep '^R3' || true; } | awk -F'\t' '{ s += $2 } END { print s + 0 }')
topcls=$(printf '%s\n' "$rows_cls" | awk -F'\t' 'NR == 1 { print $2 }')
topcnt=$(printf '%s\n' "$rows_cls" | awk -F'\t' 'NR == 1 { print $4 }')
[ "$ndays" -eq 1 ] && total_label="Totals for 1 day" || total_label="Totals for $ndays days"

{
    printf 'INTRO\tPeSIT is the protocol between SecureTransport in the cloud and the LOCAL CFT. Over **%s** day(s) (%s → %s) the server log recorded **%s** PeSIT problem line(s): **%s** on the outbound leg (ST → CFT, the TM client) and **%s** on the inbound leg (CFT → ST, the PESITD server). The dominant problem is **%s** (**%s** lines); the worst day was **%s** with **%s** lines. The protocol lines carry no flow or partner names, so this is a link-health view: types, volume and timing.\n' \
        "$ndays" "$kfrom" "$kto" "$tot" "$dout" "$din" "$topcls" "$topcnt" "$busyd" "$busyc"
    printf 'TABLE\tPeSIT problems per day\twide\ttotaltop\n'
    printf 'HEAD\tDate\tProblems\tST → CFT\tCFT → ST\tFirst\tLast\n'
    printf 'KIND\ttext\tnumfailed\tnum\tnum\ttext\ttext\n'
    printf 'TOTAL\t%s\t@{class=num failed}%s\t@{class=num}%s\t@{class=num}%s\t\t\n' "$total_label" "$tot" "$dout" "$din"
    printf '%s\n' "$rows_day"
    printf 'NOTE\tOne row = one calendar day (calendar gaps show as 0). **ST → CFT** counts the TM component acting as PeSIT client (SecureTransport dialing the CFT); **CFT → ST** counts the PESITD component acting as server (the CFT dialing SecureTransport). One failed transfer commonly logs SEVERAL lines — the client-side wrapper plus FPDU_AWRITE/FPDU_ABORT pairs — so these are log lines, not failed transfers. Click a day for its 10 most recent problem lines (newest first).\n'
    printf 'TABLE\tProblem types\twide\n'
    printf 'HEAD\tProblem\tDirection\tLog lines\tShare\tFirst seen\tLast seen\n'
    printf 'KIND\ttext\ttext\tnumfailed\tnum\ttext\ttext\n'
    printf 'RECALC\t-\t-\ts0\t%%0\t-\t-\n'
    printf 'TOTAL\tTotal (%s problem types)\t\t@{class=num failed}%s\t@{class=num}100.0%%\t\t\n' "$ncls" "$tot"
    printf '%s\n' "$rows_cls"
    printf 'NOTE\tThe problem lines classified by their message shape, most frequent first. **Transfer rejected/refused** classes are the CFT saying no (negative FPDU_ACREATE / SEND_CONF) — file-side or configuration issues on the CFT; **Checkpoint mismatch** is a restart disagreement after an interrupted transfer; **Connection reset** and **network incident** are the link itself dropping; the two **connection limit** classes are capacity ceilings, one per side (ST refuses above 100 inbound connections, the CFT refuses with RCONNECT 309 outbound). Click a row for that problem'"'"'s 10 most recent lines. First/Last seen stay full-period under a narrowed date range.\n'
    printf 'TABLE\tPeSIT diagnostic codes\n'
    printf 'HEAD\tdiagCode\tTypical text\tLog lines\tShare\n'
    printf 'KIND\ttext\ttext\tnumfailed\tnum\n'
    printf 'RECALC\t-\t-\ts0\t%%0\n'
    printf 'TOTAL\tTotal (%s codes)\t\t@{class=num failed}%s\t\n' "$ncode" "$code_tot"
    printf '%s\n' "$rows_code"
    printf 'NOTE\tThe PeSIT protocol'"'"'s own error taxonomy (the diagCode=N the messages carry; lines without a code — connection resets, ceilings — are not in this table). 2xx codes are transfer-level (213 refused/file error, 214 checkpoint), 3xx are connection-level (309 too many connections, 399 generic/SSL). The Share is of ALL problem lines at the full range, so the codes need not sum to 100%% (a narrowed date range re-shares over this table only).\n'
    printf 'SUMMARY\tProblems: %s  |  ST → CFT: %s  |  CFT → ST: %s  |  Types: %s  |  Worst day: %s (%s)\n' "$tot" "$dout" "$din" "$ncls" "$busyd" "$busyc"
} >> "$OUT.tmp"

# the 30-minute direction sidecar for the overview/day PeSIT hero views
# (inside this subshell — $agg here is the PROBLEMS pass output with the R4
# rows); tmp+mv like the report itself, so its readers never see a torn write
printf '%s\n' "$agg" | awk -F'\t' -v OFS='\t' '$1 == "R4" { print $2, $3, $4, $5 }' > "$SLOTS.tmp"
mv "$SLOTS.tmp" "$SLOTS"

)

# ---- the outbound FPDU ledger (2026-08): the Info-level protocol ----
# confirmations of the TM PeSIT CLIENT (F2/FT2 lines from the same single
# pass). Emitted UNCONDITIONALLY (placeholder row when the family is absent):
# pesit is a merged-component of Capacity, whose tab bar enumerates tables,
# so the TABLE count must not vary per env.
{
    TAB=$(printf '\t')
    frows=$(printf '%s\n' "$agg" | { grep $'^F2\t' || true; } | sort -t"$TAB" -k4,4nr -k2,2 -k3,3)
    IFS='|' read -r _ ftot fn <<< "$(printf '%s\n' "$agg" | grep '^FT2|' || printf 'FT2|0|0\n')"
    if [ "${ftot:-0}" -gt 0 ]; then
        printf 'TABLE\tOutbound FPDU ledger\twide\n'
    else
        printf 'TABLE\tOutbound FPDU ledger\tnofilter\tnosort\n'
    fi
    printf 'HEAD\tFPDU\tdiagCode\tResult\tLog lines\tShare\tTypical text\tFirst\tLast\n'
    printf 'KIND\tmono\tmono\ttext\tnum\tnum\ttext\ttext\ttext\n'
    printf 'RECALC\t-\t-\t-\ts0\t%%0\t-\t-\t-\n'
    if [ "${ftot:-0}" -gt 0 ]; then
        while IFS=$'\t' read -r _ kind code share_c share txt fst lst bk lines; do
            [ -z "$kind" ] && continue
            if [ "$code" = "0" ]; then res='OK'; else res='@{class=failed}Error'; fi
            printf 'ROW\t%s\t%s\t%s\t%s\t%s%%\t%s\t%s\t%s\t@data:buckets=%s\t@data:loglines=%s\n' \
                "$kind" "$code" "$res" "$share_c" "$share" "$txt" "$fst" "$lst" "$bk" "$lines"
        done <<< "$frows"
    else
        printf 'ROW\t@{colspan=8}No Info-level FPDU confirmations in this data window.\n'
    fi
    printf 'TOTAL\tTotal (%s combination(s))\t\t\t@{class=num}%s\t@{class=num}100.0%%\t\t\t\n' "${fn:-0}" "${ftot:-0}"
    printf 'NOTE\tEvery PeSIT protocol confirmation the TM component logs while acting as PeSIT CLIENT (ST → CFT), per FPDU kind and diagCode — connectionConfirmation (session setup), sendFileConfirmation (per file sent) and abortIndication (transfer torn down). These are **Info-level** lines, so a refusal here is INVISIBLE to the error reports: diagCode **309** is the CFT refusing the session ("Too many connections"), **310** a network-incident abort, **214** a checkpoint mismatch on restart, **0** success. The Problem types table above counts the E-level wrappers of the SAME failures — this ledger counts only Info lines, so the two never double-count. Click a row for its 10 most recent lines.\n'
    printf 'SUMMARY\tFPDU confirmations: %s  |  Kinds/codes: %s\n' "${ftot:-0}" "${fn:-0}"
} >> "$OUT.tmp"

printf 'FOOT\tGenerated on %s from %s file(s)\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${#files[@]}" >> "$OUT.tmp"
mv "$OUT.tmp" "$OUT"

echo "Data written to $OUT ($ndays day(s), $trec PeSIT record(s))." >&2
