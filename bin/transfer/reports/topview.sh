#!/usr/bin/env bash
#
# topview.sh — the transfer "Top view", ONE per-day dashboard page (re-merged
# 2026-07 — the former topview-{ids,entities,state} split is gone: the
# Entities page was removed, the Sessions unit dropped, and the State split
# merged in; the old three URLs are redirect stubs to topview.html):
#
#   topview.rpt   per day: the Files (per CoreId, activity_stream) with
#                 Count / Ok / Recovered / Error / Error rate % — Recovered
#                 (2026-08-29) = Files that carried a failed leg but still
#                 finished OK (the retry succeeded) — then the physical
#                 Transfers (log rows, _transfers) with Count / Ok / Error /
#                 Error %, then the Files' 4-state outcome split Processed /
#                 Failed / Waiting / Expired (_files.tsv col 2). (2026-08-29:
#                 the Transfers group moved BEFORE State on request.)
#
# Each row is one calendar day (gaps filled, edge days flagged partial) with
# the day's first and last transfer-log time; the total row is pinned to the
# TOP. bin/day/reports.sh reads topview.rpt for its data-day list.
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
ensure_parsed
skip_if_fresh "$REPORTS_DIR/topview.rpt" "${BASH_SOURCE[0]}"
echo "Found ${#files[@]} file(s) in '$INPUT_DIR', processing..." >&2

OUT="$REPORTS_DIR/topview.rpt"
# the 2026-07 three-page split (stale copies would republish)
rm -f "$REPORTS_DIR/topview-ids.rpt" "$REPORTS_DIR/topview-entities.rpt" "$REPORTS_DIR/topview-state.rpt"

# Pass 1 = activity_stream (1=date 2=jdn 3=time 4=proc 5=size 6=sortkey 7=id):
# per-day Files count, Ok/Error, first/last time + the Error/OK cell drills.
# Pass 2 = _files.tsv: per-day 4-state split (col 2, per the file's START
# day) + the per-CoreId outcome the Recovered count needs — which is why it
# runs BEFORE the transfers pass since 2026-08-29.
# Pass 3 = _transfers.tsv: per-day TRANSFERS (rows) Ok/Error, plus RECOVERED:
# a failed row whose CoreId file outcome is OK (not Failed/Expired) — the
# leg failed, a retry delivered the file.
# END walks the Julian-day range so calendar gaps become explicit "0" rows.
agg=$(awk -F'\t' "$COREIDS_AWK"'
    function jdn(y,m,d,  a){ a=int((14-m)/12); y=y+4800-a; m=m+12*a-3; return d+int((153*m+2)/5)+365*y+int(y/4)-int(y/100)+int(y/400)-32045 }
    function fromjdn(j,  a,b,c,dd,e,mm,day,mon,yr){ a=j+32044; b=int((4*a+3)/146097); c=a-int(146097*b/4); dd=int((4*c+3)/1461); e=c-int(1461*dd/4); mm=int((5*e+2)/153); day=e-int((153*mm+2)/5)+1; mon=mm+3-12*int(mm/10); yr=100*b+dd-4800+int(mm/10); return sprintf("%04d-%02d-%02d",yr,mon,day) }
    function pr(x, c){ if (c > 0) return sprintf("%.1f", x*100/c); return "0.0" }
    FNR==1 { fno++ }
    fno==1 {
        d=$1; if(d=="") next
        C[d]++; if($4+0==0) F[d]++; else P[d]++
        if(!(d in FI)||$3<FI[d]) FI[d]=$3; if(!(d in LA)||$3>LA[d]) LA[d]=$3
        allday[d]=1; tC++; if($4+0==0) tF++; else tP++
        addtop(d SUBSEP ($4+0==0 ? "F" : "P"), $6, $1 " " $3, $7)   # drill: 10 most recent of each outcome, that day
        next
    }
    fno==2 {   # _files.tsv: the 4-state split per start day + outcome per CoreId
        if($2!="Failed" && $2!="Expired" && $4!="") fokd[$1]=$4   # OK file -> its START day (the Files-group Recovered credits that day)
        d=$4; if(d=="") next; allday[d]=1
        if($2=="Processed"){WP[d]++;wP++} else if($2=="Failed"){WF[d]++;wF++}
        else if($2=="Waiting"){WW[d]++;wW++} else if($2=="Expired"){WX[d]++;wX++}
        next
    }
    {   # _transfers.tsv: per-day TRANSFERS (rows) Ok/Error + Recovered
        d=$11; if(d=="") next; allday[d]=1
        TC[d]++; tT++
        if($3=="Processed"){ TP2[d]++; tTP++ }
        else { TF2[d]++; tTF++
            # the FILES-group Recovered: this OK File carried a failed leg — count it ONCE, on the file s own start day
            if(($1 in fokd) && !($1 in rvs)){ rvs[$1]=1; RVF[fokd[$1]]++; tRVF++ } }
    }
    END {
        mn=0; mx=0
        for(d in allday){ split(d,pp,"-"); j=jdn(pp[1]+0,pp[2]+0,pp[3]+0); if(mn==0||j<mn)mn=j; if(j>mx)mx=j }
        if(mn==0) exit   # empty parse: emit no R1 rows — the case guard below renders the empty state (the walk would otherwise print one bogus fromjdn(0) year -4713 row)
        ndays=0
        for(j=mn;j<=mx;j++){
            d=fromjdn(j)
            if(d in C){
                ndays++
                fi=FI[d]; sub(/\.[0-9]+$/,"",fi); la=LA[d]; sub(/\.[0-9]+$/,"",la)
                mark=""
                if((j==mn || !(fromjdn(j-1) in C)) && FI[d] > "02:00:00") mark=" (partial start)"
                if((j==mx || !(fromjdn(j+1) in C)) && LA[d] < "22:00:00") mark=(mark==""?" (partial end)":" (partial)")
                printf "R1\tROW\t@{href=../day/%s.html}%s%s\t%s\t%s\t%d\t%d\t%s\t%d\t%s%%\t%d\t%d\t%d\t%s%%\t%d\t%d\t%s\t%d\t@data:coreids-failed=%s\t@data:coreids-processed=%s\n", \
                    d, d, mark, fi, la, \
                    C[d], P[d]+0, (RVF[d]+0>0 ? RVF[d]+0 : ""), F[d]+0, pr(F[d]+0, C[d]), \
                    TC[d]+0, TP2[d]+0, TF2[d]+0, pr(TF2[d]+0, TC[d]+0), \
                    WP[d]+0, WF[d]+0, (WW[d]+0>0 ? WW[d]+0 : ""), WX[d]+0, \
                    buildlist(top[d SUBSEP "F"]), buildlist(top[d SUBSEP "P"])
            } else {
                printf "R1\tROW\t%s\t-\t-\t0\t0\t\t0\t0.0%%\t0\t0\t0\t0.0%%\t0\t0\t\t0\n", d   # empty Waiting/Recovered cells: blank
            }
        }
        printf "TOT|%d|%d|%d|%d|%s|%d|%d|%d|%s|%d|%d|%d|%d|%d\n", \
            tC,tP,tRVF+0,tF,pr(tF,tC), tT,tTP,tTF,pr(tTF,tT), wP+0,wF+0,wW+0,wX+0, ndays
    }
' <(activity_stream) "$FILES" "$PARSED")

# Guard the empty case: with no ROW lines the greps below would abort under
# set -euo pipefail. (Pure-bash pattern test, NOT `printf | grep -q`: grep -q
# exits at the first match and SIGPIPEs the printf feeding it once $agg
# outgrows grep's first read, which pipefail turns into a bogus "no records" —
# same trap as site-failures.sh. The plain `grep '^R1'` extractions below read
# their whole input and are safe.)
nl=$'\n'
case "$agg" in R1*|*"${nl}R1"*) : ;; *) echo "No usable records found." >&2; exit 0 ;; esac
rows=$(printf '%s\n' "$agg" | grep '^R1' | cut -f2-)
IFS='|' read -r _ tC tP tRVF tF tfp tT tTP tTF ttp wP wF wW wX ndays \
    <<< "$(printf '%s\n' "$agg" | grep '^TOT|')"
[ "$ndays" -eq 1 ] && total_label="Total for 1 day" || total_label="Total for $ndays days"

{
    printf 'TITLE\tTop view\n'
    printf 'DESC\tThe whole transfer log at a glance, per day: logical Files (per CoreId) with their Count / Ok / Error split, error rate and the Recovered count, the physical Transfers (log rows) with the same Ok/Error split, and the same Files by their final state — Processed, Failed, Waiting and Expired.\n'
    printf 'KEYWORDS\tstate, processed, failed, waiting, expired, recovered, retry, per day, outcome, error rate\n'
    printf 'INTRO\tEvery day of the loaded transfer log on one row — the day counted as **Files** (one per CoreId — the site-wide counting unit) split into Ok/Error with its error rate plus **Recovered** (Files that carried a failed leg but still finished OK — a retry delivered them), the day counted as **Transfers** (physical log rows) with the same Ok/Error split, and the same Files by their **final state**: **Processed** (delivered), **Failed**, **Waiting** (UC2 staged for pickup, not collected yet) and **Expired** (the retention sweep deleted the staged copy before any pickup — never delivered). Newest day on top; the Date cell opens that day'\''s page.\n'
    printf 'TABLE\t\twide\ttotaltop\tdatereset\tpct=7:6:3;11:10:8\tgsep=3,8,12\n'
    printf 'GHEAD\t@{colspan=3}\t@{colspan=5,class=gband gsep}Files\t@{colspan=4,class=gband gsep}Transfers\t@{colspan=4,class=gband gsep}State\n'
    printf 'HEAD\tDate\tFirst\tLast\tCount\tOk\tRecovered\tError\tError %%\tCount\tOk\tError\tError %%\tProcessed\tFailed\tWaiting\tExpired\n'
    printf 'KIND\ttext\ttext\ttext\tnum\tnumprocessed\tnumwarn\tnumfailed\tnum\tnum\tnumok\tnumerr\tnum\tnumok\tnumerr\tnumwarn\tnumerr\n'
    wW_cell="@{class=num warn}"; [ "${wW:-0}" -gt 0 ] && wW_cell="@{class=num warn}$wW"   # 0 -> blank (td.warn:empty drops the tint)
    tRVF_cell="@{class=num warn}"; [ "${tRVF:-0}" -gt 0 ] && tRVF_cell="@{class=num warn}$tRVF"   # 0 -> blank (td.warn:empty drops the tint)
    printf 'TOTAL\t%s\t\t\t@{class=num}%s\t@{class=num processed}%s\t%s\t@{class=num failed}%s\t@{class=num}%s%%\t@{class=num}%s\t@{class=num okc}%s\t@{class=num errc}%s\t@{class=num}%s%%\t@{class=num okc}%s\t@{class=num errc}%s\t%s\t@{class=num errc}%s\n' \
        "$total_label" "$tC" "$tP" "$tRVF_cell" "$tF" "$tfp" "$tT" "$tTP" "$tTF" "$ttp" "$wP" "$wF" "$wW_cell" "$wX"
    printf '%s\n' "$rows"
    printf 'NOTE\t**Files** = logical transfers (all rows sharing one CoreId, Ok when the final row processed), **Transfers** = physical log rows (one per transfer leg). **Recovered** counts the Files that carried at least one failed leg yet still finished OK — the failure was healed by a retry, so those Files sit under Files/Ok while their failed legs sit under Transfers/Error. The **State** columns split the same Files by their final state: on the reports Processed + Waiting count as **OK** and Failed + Expired as **Error** — Waiting is a live state (those files can still be collected, see the Waiting Files report); Expired files were deleted unclaimed ~11 days after staging. Sessions have their own reports (see Session Topview). Click a Files Ok / Error cell for that day'\''s 10 most recent Files.\n'
    printf 'FOOT\tGenerated on %s from %s file(s)\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${#files[@]}"
} > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"

echo "Data written to $OUT ($ndays day(s), $tC file(s), $tT row(s))." >&2
