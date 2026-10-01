#!/usr/bin/env bash
#
# topview.sh — the "Transfer top view", ONE per-day dashboard page (re-merged
# 2026-07 — the former topview-{ids,entities,state} split is gone: the
# Entities page was removed, the Sessions unit dropped, and the State split
# merged in):
#
#   topview.rpt   ONE per-day table in SIX column groups (2026-09-12 layout):
#                 the Files (per CoreId, activity_stream) with Count / Ok /
#                 Error / Error rate %; RECOVERED — the OK Files that carried
#                 a failed leg (2026-08-29; until 2026-09-12 one amber column
#                 of the Files group), split Automatic (the platform's own
#                 retry delivered them) / Manual (a leg carries the log's
#                 Resubmitted flag, _transfers.tsv col 22 — an operator
#                 resubmitted); RESUBMIT — every File with a resubmitted leg,
#                 Ok / Failed by its outcome; then the physical Transfers
#                 (log rows, _transfers) with Count / Ok / Error / Error %;
#                 then the Files' 4-state outcome split Processed / Failed /
#                 Waiting / Expired (_files.tsv col 2). (2026-08-29: the
#                 Transfers group moved BEFORE State on request.) Every
#                 per-File figure credits the File's START day. Readers of
#                 the ROW fields by index: bin/build/publish.sh (home per-day
#                 table + log-exports facts), bin/day/reports.sh — a linked
#                 cell leads with @{href=…}, which a reader strips.
#                 THE DAY CELLS LINK (2026-10-01, user request), each from
#                 anywhere in its cell, a 0 / blank cell stays plain:
#                   Files Error            failed-files.html narrowed to the day
#                                          (its File drill went)
#                   Recovered Automatic    ../recovered/<date>.html (below)
#                   Recovered Manual,
#                   Resubmit Ok / Error    ../resubmit/<date>.html (below)
#                   Waiting, Expired       waiting-expired.html, that day's
#                                          Summary row marked (?axway_row)
#                   Volume                 files-by-size.html narrowed to the day
#
# THE DAY FILE LISTS (2026-10-01, user request), rendered by
# bin/transfer/publish.sh into the docs ROOT directories resubmit/ and
# recovered/ — Date/time · Subscription · File · CoreId, newest first (sortkey
# descending, CoreId ascending on a tie), tinted by the File colour (col 25),
# a TOTAL row and a NAV row back to the Top view:
#   data/transfer/reports/resubmit/<date>.rpt  -> resubmit/<date>.html
#     EVERY File that started that day and carries a resubmitted leg (col 27),
#     OK and Error alike — the day's Resubmit Ok + Error count. Every row has
#     a File page (bin/transfer/filepages.sh kind R) and the WHOLE row opens it.
#   data/transfer/reports/recovered/<date>.rpt -> recovered/<date>.html
#     the day's AUTOMATICALLY recovered Files (an OK File with a failed leg
#     and no resubmitted leg) — the Recovered › Automatic count. The first
#     five rows of every subscription have a File page (filepages.sh kind A —
#     THE selection) and the whole row opens it; any other row whose File has
#     a page (another kind) does the same, the rest keep the default cell
#     links (@data:norowlink — report.js bindRowlink leaves the row alone).
#
# Each row is one calendar day (gaps filled) — the date only since
# 2026-09-30 (user request: the First / Last time columns and the
# "(partial …)" edge-day marks went); the total row is pinned to the TOP. bin/day/reports.sh reads topview.rpt for its data-day list.
#
# Usage:
#   ./topview.sh    # reads the caches, writes data/transfer/reports/topview.rpt
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib.sh"
mkdir -p "$REPORTS_DIR"

shopt -s nullglob
files=("$INPUT_DIR"/*.csv)
shopt -u nullglob
if [ ${#files[@]} -eq 0 ]; then
    echo "No *.csv in $INPUT_DIR — building from the EMPTY caches (config-only estate)" >&2
fi
echo "Found ${#files[@]} file(s) in '$INPUT_DIR', processing..." >&2

OUT="$REPORTS_DIR/topview.rpt"

# Pass 1 = activity_stream (1=date 2=jdn 3=time 4=proc 5=size 6=sortkey 7=id):
# per-day Files count, Ok/Error, first/last time + the Error/OK cell drills.
# Pass 2 = _files.tsv: per-day 4-state split (col 2, per the file's START
# day) + every CoreId's outcome and start day, plus RECOVERED — an OK File
# (not Failed/Expired) with a failed leg (col 26: the leg failed, a retry
# delivered the file) — and the RESUBMITTED Files (col 27: a leg carries the
# Resubmitted flag). The two leg flags are stored once per File by the parse
# (2026-09-29); until then pass 3 re-derived them from the legs.
# Pass 3 = _transfers.tsv: per-day TRANSFERS (rows) Ok/Error.
# END classifies the recovered Files Automatic/Manual and the resubmitted
# Files Ok/Failed, then walks the Julian-day range so calendar gaps become
# explicit "0" rows.
agg=$(awk -F'\t' "$COREIDS_AWK$AWKLIB"'
    function pr(x, c){ if (c > 0) return sprintf("%.1f", x*100/c); return "0.0" }
    function hb(b){ b+=0; if(b>=1073741824) return sprintf("%.2f GB",b/1073741824); if(b>=1048576) return sprintf("%.2f MB",b/1048576); if(b>=1024) return sprintf("%.2f KB",b/1024); return (b>0) ? sprintf("%d B",b) : "" }
    FNR==1 { fno++ }
    fno==1 {
        d=$1; if(d=="") next
        C[d]++; if($4+0==0) F[d]++; else P[d]++
        if(!(d in FI)||$3<FI[d]) FI[d]=$3; if(!(d in LA)||$3>LA[d]) LA[d]=$3
        allday[d]=1; tC++; if($4+0==0) tF++; else tP++
        if ($4+0 != 0) addtop(d SUBSEP "P", $6, $1 " " $3, $7)   # drill: the 10 most recent OK Files of the day (the Error cell links Failed files instead, 2026-10-01)
        next
    }
    fno==2 {   # _files.tsv: the 4-state split per start day + outcome per CoreId
        if($2!="Failed" && $2!="Expired" && $4!="") fokd[$1]=$4   # OK file -> its START day (the Recovered table credits that day)
        if($4!=""){ fsd[$1]=$4; ferr[$1]=($2=="Failed"||$2=="Expired") }   # every File: start day + Error verdict (the Resubmit table)
        # RECOVERED: this OK File carried a failed leg (col 26) — counted once, on its own start day
        if($26=="1" && ($1 in fokd)){ rvs[$1]=1; RVF[fokd[$1]]++; tRVF++ }
        if($27=="1" && $4!="") rsb[$1]=1   # a File with >=1 resubmitted leg (col 27 — the OPERATOR resubmit flag)
        d=$4; if(d=="") next; allday[d]=1
        VOL[d]+=$8; tVOL+=$8   # the Volume group (2026-09-29): every File started that day, whatever its outcome
        if($2=="Processed"){WP[d]++;wP++} else if($2=="Failed"){WF[d]++;wF++}
        else if($2=="Waiting"){WW[d]++;wW++} else if($2=="Expired"){WX[d]++;wX++}
        next
    }
    {   # _transfers.tsv: per-day TRANSFERS (rows) Ok/Error
        d=$11; if(d=="") next; allday[d]=1
        TC[d]++; tT++
        if($3=="Processed"){ TP2[d]++; tTP++ }
        else { TF2[d]++; tTF++ }
    }
    END {
        mn=0; mx=0
        for(d in allday){ split(d,pp,"-"); j=jdn(pp[1]+0,pp[2]+0,pp[3]+0); if(mn==0||j<mn)mn=j; if(j>mx)mx=j }
        # Recovered = rvs (an OK File with a failed leg): MANUAL when a leg was resubmitted, else AUTOMATIC;
        # Resubmit = rsb (any File with a resubmitted leg): Ok / Failed by the File outcome. Both per START day.
        for(c in rvs){ if(c in rsb){ RVM[fokd[c]]++; tRVM++ } else { RVA[fokd[c]]++; tRVA++ } }
        for(c in rsb){ if(ferr[c]){ RSF[fsd[c]]++; tRSF++ } else { RSO[fsd[c]]++; tRSO++ } }
        if(mn==0) exit   # empty parse: emit no R1 rows — the case guard below renders the empty state (the walk would otherwise print one bogus fromjdn(0) year -4713 row)
        ndays=0
        for(j=mn;j<=mx;j++){
            d=fromjdn(j)
            if(d in C){
                ndays++
                # only the date (2026-09-30, user request: no First / Last
                # columns, no "(partial start)" / "(partial end)" marks — the
                # From/To presets keep reading the partial days from day.rpt)
                # the per-DAY Waiting / Expired cells carry no link (2026-09-30
                # audit T-15: they opened the full-period Waiting / Expired
                # pages, which have no date filter — a day of 5 opened 384);
                # the TOTAL row cells keep theirs (full period = full period).
                # Zero stays a plain blank / 0
                # THE DAY CELL LINKS (2026-10-01, user request — see the
                # header): a nonzero cell leads with @{href=…}; Waiting /
                # Expired open Waiting & Expired with the Summary row of that day
                # marked (?axway_row — the 2026-09-30 "no link" rule T-15 was
                # about the unmarked full-period page)
                wex = "@{href=waiting-expired.html?axway_row=" d "}"
                rsb9 = "@{href=../resubmit/" d ".html}"
                ecell = (F[d]+0>0 ? "@{href=failed-files.html?axway_date=" d "&axway_search=}" (F[d]+0) : "0")
                wcell = (WW[d]+0>0 ? wex (WW[d]+0) : "")
                xcell = (WX[d]+0>0 ? wex (WX[d]+0) : "0")
                vcell = hb(VOL[d]); if (vcell != "") vcell = "@{href=files-by-size.html?axway_date=" d "}" vcell
                # the amber Recovered cells (Automatic / Manual) are blank on 0
                printf "R1\tROW\t@{href=../day/%s.html}%s\t%d\t%d\t%s\t%s%%\t%s\t%s\t%s\t%s\t%d\t%d\t%d\t%s%%\t%d\t%d\t%s\t%s\t%s\t@data:coreids-processed=%s\n", \
                    d, d, \
                    C[d], P[d]+0, ecell, pr(F[d]+0, C[d]), \
                    (RVA[d]+0>0 ? "@{href=../recovered/" d ".html}" (RVA[d]+0) : ""), (RVM[d]+0>0 ? rsb9 (RVM[d]+0) : ""), \
                    (RSO[d]+0>0 ? rsb9 (RSO[d]+0) : "0"), (RSF[d]+0>0 ? rsb9 (RSF[d]+0) : "0"), \
                    TC[d]+0, TP2[d]+0, TF2[d]+0, pr(TF2[d]+0, TC[d]+0), \
                    WP[d]+0, WF[d]+0, wcell, xcell, vcell, \
                    buildlist(top[d SUBSEP "P"])
            } else {
                printf "R1\tROW\t%s\t0\t0\t0\t0.0%%\t\t\t0\t0\t0\t0\t0\t0.0%%\t0\t0\t\t0\t\n", d   # empty Recovered / Waiting / Volume cells: blank
            }
        }
        printf "TOT|%d|%d|%d|%d|%s|%d|%d|%d|%s|%d|%d|%d|%d|%d|%d|%d|%d|%d|%s\n", \
            tC,tP,tRVF+0,tF,pr(tF,tC), tT,tTP,tTF,pr(tTF,tT), wP+0,wF+0,wW+0,wX+0, ndays, tRVA+0,tRVM+0,tRSO+0,tRSF+0, hb(tVOL)
    }
' <(activity_stream) "$FILES" "$PARSED")

# ---- THE DAY FILE LISTS (see the header): resubmit/<date>.rpt and
# recovered/<date>.rpt, one per start day with such a File, staged in *.new/
# and swapped in. The rules are the table's own: Resubmit = a resubmitted leg
# (col 27), any outcome; Recovered (Automatic) = an OK File with a failed leg
# (col 26) and no resubmitted one. A row whose File has a published page
# (_filepages.tsv — kind R covers every resubmit row, kind A the first five
# recovered rows of each subscription) carries @data:href, the whole-row link;
# a recovered row without one carries @data:norowlink (rowlink would fall
# back to the row's first link, the Subscription cell).
RSUB="$REPORTS_DIR/resubmit"
VSUB="$REPORTS_DIR/recovered"
FPL="$CACHE_DIR/_filepages.tsv"; [ -f "$FPL" ] || FPL=/dev/null
rm -rf "$RSUB.new" "$VSUB.new"; mkdir -p "$RSUB.new" "$VSUB.new"
LC_ALL=C awk -F'\t' -v OFS='\t' '
    $4 == "" { next }
    $27 == "1" { print "R", $4, $6, $1, $5, $25, $12, $11; next }
    $26 == "1" && $2 != "Failed" && $2 != "Expired" { print "A", $4, $6, $1, $5, $25, $12, $11 }' "$FILES" \
    | LC_ALL=C sort -t"$(printf '\t')" -k1,1 -k2,2 -k3,3r -k4,4 | LC_ALL=C awk -F'\t' \
    -v rdir="$RSUB.new" -v vdir="$VSUB.new" -v FPL="$FPL" "$AWKLIB"'
    BEGIN { while ((getline l < FPL) > 0) { split(l, a, "\t"); if (a[1] != "") PG[a[1]] = 1 } close(FPL) }
    function clean(s) { gsub(/[\t\r]/, " ", s); return s }
    function finish() { if (out == "") return; printf "TOTAL\tTotal (%d Files)\t\t\t\n", nr > out; printf "FOOT\n" > out; close(out) }
    ($1 SUBSEP $2) != cur {
        finish(); cur = $1 SUBSEP $2; nr = 0
        r = ($1 == "R"); out = (r ? rdir : vdir) "/" $2 ".rpt"
        printf "TITLE\t%s Files: %s\n", (r ? "Resubmitted" : "Recovered"), $2 > out
        if (r) printf "INTRO\tEvery File that started on **%s** and carries a resubmitted leg — an operator resubmitted it — whatever its outcome: the Top view Resubmit Ok + Error of that day (Recovered Manual = the OK ones that also had a failed leg). Newest first; a row opens its File page.\n", $2 > out
        else   printf "INTRO\tEvery File that started on **%s**, had a failed leg and was still delivered without an operator resubmit — the platform retried it: the Top view Recovered Automatic of that day. Newest first; the first five rows of every subscription open their File page.\n", $2 > out
        printf "NAV\t0|Transfer top view|../transfer/topview.html\n" > out
        printf "TABLE\t%s Files\twide\tnofilter\tsort=0:-1\tpager=25\trestint\trowlink\n", (r ? "Resubmitted" : "Recovered") > out
        printf "HEAD\tDate/time\tSubscription\tFile\tCoreId\n" > out
        printf "KIND\ttext\tsite\tmono\tmono\n" > out
    }
    {
        res = ($6 == "green" || $6 == "orange" || $6 == "red") ? "\t@data:res=" $6 : ""
        res = res (($4 in PG) ? "\t@data:href=../files/" $4 ".html" : "\t@data:norowlink=1")
        printf "ROW\t%s %s\t%s\t%s\t%s%s\n", $2, substr($5, 1, 8), clean($7), lit(clean($8)), $4, res > out
        nr++
    }
    END { finish() }'
rm -rf "$RSUB"; mv "$RSUB.new" "$RSUB"
rm -rf "$VSUB"; mv "$VSUB.new" "$VSUB"

# Guard the empty case: with no ROW lines the greps below would abort under
# set -euo pipefail. (Pure-bash pattern test, NOT `printf | grep -q`: grep -q
# exits at the first match and SIGPIPEs the printf feeding it once $agg
# outgrows grep's first read, which pipefail turns into a bogus "no records" —
# same trap as site-failures.sh. The plain `grep '^R1'` extractions below read
# their whole input and are safe.)
nl=$'\n'
case "$agg" in R1*|*"${nl}R1"*) : ;; *) echo "No usable records found." >&2; exit 0 ;; esac
rows=$(printf '%s\n' "$agg" | grep '^R1' | cut -f2-)
IFS='|' read -r _ tC tP tRVF tF tfp tT tTP tTF ttp wP wF wW wX ndays tRVA tRVM tRSO tRSF tVOL \
    <<< "$(printf '%s\n' "$agg" | grep '^TOT|')"
total_label="Total"   # "Total for N days" until 2026-10-01 (user request: "Do not give \"Total for 31 days\"")

{
    printf 'TITLE\tTransfer top view\n'   # = its Reports menu label (2026-09-29)
    # 0-based columns (six groups, 2026-09-12; the First / Last columns went
    # 2026-09-30, user request): Date0 | Files: Count1 Ok2 Error3 Error%4 |
    # Recovered: Automatic5 Manual6 | Resubmit: Ok7 Failed8 | Transfers:
    # Count9 Ok10 Error11 Error%12 | State: Processed13 Failed14 Waiting15
    # Expired16 | Volume17
    # VOLUME (2026-09-29): the last group — the per-day volume the Activity and
    # Volume "Per day" tabs carried (both went); LAST so the positional readers
    # of the ROW fields (the home log table, the day pages) are unchanged
    printf 'TABLE\t\twide\ttotaltop\tdatereset\tpct=4:3:1;12:11:9\tgsep=1,5,7,9,13,17\n'
    printf 'GHEAD\t\t@{colspan=4,class=gband gsep}Files\t@{colspan=2,class=gband gsep}Recovered\t@{colspan=2,class=gband gsep}Resubmit\t@{colspan=4,class=gband gsep}Transfers\t@{colspan=4,class=gband gsep}State\t@{class=gband gsep}\n'
    printf 'HEAD\tDate\tCount\tOk\tError\tError %%\tAutomatic\tManual\tOk\tError\tCount\tOk\tError\tError %%\tProcessed\tFailed\tWaiting\tExpired\tVolume\n'
    # the Resubmit Ok / Error pair uses the TINT-ONLY kinds numok / numerr
    # (2026-09-29 audit): as numprocessed / numfailed they made a second OK /
    # Error cell on the row and report.js bound neither Files drill there
    printf 'KIND\ttext\tnum\tnumprocessed\tnumfailed\tnum\tnumwarn\tnumwarn\tnumok\tnumerr\tnum\tnumok\tnumerr\tnum\tnumok\tnumerr\tnumwarn\tnumerr\tnum\n'
    # a nonzero Waiting / Expired total opens its report too (2026-08-31)
    wW_cell="@{class=num warn}"; [ "${wW:-0}" -gt 0 ] && wW_cell="@{class=num warn,href=waiting-expired.html}$wW"   # 0 -> blank (td.warn:empty drops the tint)
    wX_cell="@{class=num errc}$wX"; [ "${wX:-0}" -gt 0 ] && wX_cell="@{class=num errc,href=waiting-expired.html}$wX"
    # the amber Recovered totals: 0 -> blank (td.warn:empty drops the tint)
    tRVA_cell="@{class=num warn}"; [ "${tRVA:-0}" -gt 0 ] && tRVA_cell="@{class=num warn}$tRVA"
    tRVM_cell="@{class=num warn}"; [ "${tRVM:-0}" -gt 0 ] && tRVM_cell="@{class=num warn}$tRVM"
    printf 'TOTAL\t%s\t@{class=num}%s\t@{class=num processed}%s\t@{class=num failed}%s\t@{class=num}%s%%\t%s\t%s\t@{class=num processed}%s\t@{class=num failed}%s\t@{class=num}%s\t@{class=num okc}%s\t@{class=num errc}%s\t@{class=num}%s%%\t@{class=num okc}%s\t@{class=num errc}%s\t%s\t%s\t@{class=num}%s\n' \
        "$total_label" "$tC" "$tP" "$tF" "$tfp" "$tRVA_cell" "$tRVM_cell" "$tRSO" "$tRSF" "$tT" "$tTP" "$tTF" "$ttp" "$wP" "$wF" "$wW_cell" "$wX_cell" "$tVOL"
    printf '%s\n' "$rows"
    printf 'FOOT\n'
} > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"

echo "Data written to $OUT ($ndays day(s), $tC file(s), $tT row(s); + $(ls "$RSUB" | grep -c '\.rpt$' || true) resubmit / $(ls "$VSUB" | grep -c '\.rpt$' || true) recovered day list(s))." >&2
