#!/usr/bin/env bash
#
# recovered-files.sh — the RECOVERED FILES analysis (2026-08-29). A File
# (CoreId) counts as RECOVERED when at least one of its legs FAILED and the
# File still finished OK — a retry delivered it. The same rule and the same
# figure as the Top view's Recovered columns (Automatic + Manual; until
# 2026-09-12 one amber column of its Files group), the home page's Cured cell
# and the subscription detail pages, broken down three ways:
#
#   - per SUBSCRIPTION  (which flows heal themselves, and how often)
#   - per PROTOCOL      (of the FAILED leg — where the healed failures live)
#   - per DAY           (when it happened)
#
# OK follows the site-wide outcome policy (Processed or Waiting; Failed and
# Expired are not OK); everything is attributed to the File's START day,
# exactly like the Top view's Recovered columns. Distinct from recovered.sh ("Recovered
# flows"), which is about SUBSCRIPTIONS coming back green after a red
# episode — this page is about single Files healed by a retry.
#
# Usage:
#   ./recovered-files.sh   # reads the caches, writes data/.../recovered-files.rpt
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib.sh"
mkdir -p "$REPORTS_DIR"
OUT="$REPORTS_DIR/recovered-files.rpt"

shopt -s nullglob
files=("$INPUT_DIR"/*.csv)
shopt -u nullglob
if [ ${#files[@]} -eq 0 ]; then
    echo "No *.csv in $INPUT_DIR — building from the EMPTY caches (config-only estate)" >&2
fi
echo "Found ${#files[@]} file(s) in '$INPUT_DIR', processing..." >&2

# Pass 1 = _files.tsv: outcome, start day, subscription and sortkey per
# CoreId, the resubmitted-leg flag (col 27, the Manual split), plus the
# per-subscription/per-day Files totals (the context columns). Pass 2 =
# _transfers.tsv, failed legs only (it stays: the PROTOCOL of the failed leg
# and the per-leg counts are not in _files.tsv): a failed leg of an
# OK File marks the File recovered (counted once), its protocol counted
# per distinct (File, protocol); every failed leg also feeds the
# per-protocol context, so Healed % is healed legs over ALL failed legs
# of that protocol. Buckets and drills use the File's start day.
agg=$(awk -F'\t' "$COREIDS_AWK"'
    function pc(x, n) { return n > 0 ? sprintf("%.1f", x * 100 / n) : "0.0" }
    FNR==1 { fno++ }
    fno==1 {
        c=$1; d=$4; if(d=="") next
        s=$12; if(s=="") s="-"
        fday[c]=d; fsite[c]=s
        if($2!="Failed" && $2!="Expired"){ okf[c]=1; fsk[c]=$6; ftm[c]=$5 }
        # HOW the File recovered (2026-09-12, user request — the Top view'\''s
        # Automatic / Manual rule): a leg carrying Resubmitted=true (on ANY
        # leg — the delivering one included) makes it a manual RESUBMIT, every
        # other recovered File an automatic RETRY — col 27, the parse'\''s
        # resubmitted-leg flag (2026-09-29; a _transfers.tsv test until then).
        # The split is decided in END.
        if($27=="1") rsb[c]=1
        sc[s]++; scd[s SUBSEP d]++; dayc[d]++; tFC++
        next
    }
    $3=="Processed" { next }
    {   # a FAILED leg
        c=$1; if(!(c in fday)) next
        d=fday[c]; p=$10; if(p=="") p="UNKNOWN"
        af[p]++; afd[p SUBSEP d]++                    # every failed leg (the Healed % base)
        if(!(c in okf)) next                          # the File did not finish OK
        hl[p]++; hld[p SUBSEP d]++; thl++; thld[d]++  # a healed leg
        if(!((c SUBSEP p) in sp)){ sp[c SUBSEP p]=1; rp[p]++; rpd[p SUBSEP d]++
            if(!((d SUBSEP p) in pds)){ pds[d SUBSEP p]=1; pdl2[d] = pdl2[d] (pdl2[d] ? "|" : "") p }
            addtop("P" SUBSEP p, fsk[c], d " " ftm[c], c) }
        if(!(c in rec)){ rec[c]=1; tR++
            s=fsite[c]; rs[s]++; rsd[s SUBSEP d]++; rd[d]++
            if(s in sidx) si=sidx[s]; else { si=++nsi; sidx[s]=si }   # compact id for the uniq payload
            if(!((d SUBSEP si) in sds)){ sds[d SUBSEP si]=1; sdl[d] = sdl[d] (sdl[d] ? "|" : "") si }
            addtop("S" SUBSEP s, fsk[c], d " " ftm[c], c)
            addtop("D" SUBSEP d, fsk[c], d " " ftm[c], c) }
    }
    END {
        # the RETRY / RESUBMIT split per recovered File (see the rsb rule):
        # per subscription, per day and — through its failed-leg protocols —
        # per protocol, each with its per-day bucket twin
        for(c in rec){ s=fsite[c]; d=fday[c]
            if(c in rsb){ rsM[s]++; rsdM[s SUBSEP d]++; rdM[d]++; tM++; tMd[d]++ }
            else        { rsA[s]++; rsdA[s SUBSEP d]++; rdA[d]++; tA++; tAd[d]++ } }
        for(k in sp){ split(k,a,SUBSEP); c=a[1]; p=a[2]; if(!(c in rec)) continue; d=fday[c]
            if(c in rsb){ rpM[p]++; rpdM[p SUBSEP d]++ } else { rpA[p]++; rpdA[p SUBSEP d]++ } }
        for(k in scd){ split(k,a,SUBSEP); if(a[1] in rs) sbk[a[1]] = sbk[a[1]] (sbk[a[1]] ? "," : "") a[2] ":" (rsd[k]+0) ":" (rsdA[k]+0) ":" (rsdM[k]+0) ":" scd[k] }
        for(k in afd){ split(k,a,SUBSEP); pbk[a[1]] = pbk[a[1]] (pbk[a[1]] ? "," : "") a[2] ":" ((k in rpd) ? rpd[k] : 0) ":" ((k in rpdA) ? rpdA[k] : 0) ":" ((k in rpdM) ? rpdM[k] : 0) ":" ((k in hld) ? hld[k] : 0) ":" afd[k] }
        # key | recovered | retry | resubmit | files | share | buckets | drill
        for(s in rs){ printf "SUB|%s|%d|%d|%d|%d|%s|%s|%s\n", s, rs[s], rsA[s]+0, rsM[s]+0, sc[s], pc(rs[s], sc[s]), sbk[s], buildlist(top["S" SUBSEP s]); sFC += sc[s]; nsub++ }
        # key | recovered files | retry | resubmit | healed legs | all failed legs | healed % | buckets | drill
        # EVERY protocol with a failed leg gets its row (2026-09-29 audit: only
        # the protocols with a healed File did, so the rows summed 7,006 Failed
        # legs under a 7,057 TOTAL — the 51 ftp legs had no row)
        for(p in af){ printf "PROTO|%s|%d|%d|%d|%d|%d|%s|%s|%s\n", p, ((p in rp) ? rp[p] : 0), ((p in rpA) ? rpA[p] : 0), ((p in rpM) ? rpM[p] : 0), ((p in hl) ? hl[p] : 0), af[p], pc(((p in hl) ? hl[p] : 0), af[p]), pbk[p], ((("P" SUBSEP p) in top) ? buildlist(top["P" SUBSEP p]) : ""); if (p in hl) pHL += hl[p]; if (p in rp) np++ }   # np: the protocols a File recovered on (the Protocols STAT, as its per-day uniq payload)
        # the Failed legs TOTAL covers EVERY failed leg (2026-09-29 audit: it
        # summed only the protocols with a healed File — 7,006 beside the Top
        # view 7,057), so the TOTAL Healed % is healed over ALL failed legs
        for(p in af) pAF += af[p]
        # the TOTAL row own per-day buckets (2026-09-29): Recovered / Retry /
        # Resubmit as DISTINCT Files per day (a File whose failed legs span two
        # protocols is one row each), the legs summed — so a narrowed range
        # re-totals like the full one; days in date order (deterministic bytes)
        for(k in afd){ split(k,a,SUBSEP); tafd[a[2]] += afd[k]; if(!(a[2] in TBD)){ TBD[a[2]]=1; TBL[++ntb]=a[2] } }
        for(i=2;i<=ntb;i++){ v=TBL[i]; j=i-1; while(j>0 && TBL[j]>v){ TBL[j+1]=TBL[j]; j-- } TBL[j+1]=v }
        # (guarded reads: a bare rd[d] CREATES the key in mawk, and the DAY /
        # STAT loops below then walked every failed-leg day as a "recovery
        # day" — 68 instead of 21; 2026-09-29 audit)
        tb=""; for(i=1;i<=ntb;i++){ d=TBL[i]; tb = tb (tb ? "," : "") d ":" ((d in rd) ? rd[d] : 0) ":" ((d in tAd) ? tAd[d] : 0) ":" ((d in tMd) ? tMd[d] : 0) ":" ((d in thld) ? thld[d] : 0) ":" ((d in tafd) ? tafd[d] : 0) }
        printf "TB|%s\n", tb
        # key | files | recovered | retry | resubmit | share | drill
        for(d in rd){ printf "DAY|%s|%d|%d|%d|%d|%s|%s\n", d, dayc[d], rd[d], rdA[d]+0, rdM[d]+0, pc(rd[d], dayc[d]), buildlist(top["D" SUBSEP d]); dFC += dayc[d]; nd++ }
        # the STAT boxes per-day payloads (report.js recalcStats data-sb):
        # sum / uniq days = the recovery days only; share = EVERY day with
        # Files, so the denominator follows the range too
        for(d in rd){ sbr = sbr (sbr ? "," : "") d ":" rd[d]; sbd = sbd (sbd ? "," : "") d ":1"
            sba = sba (sba ? "," : "") d ":" ((d in tAd) ? tAd[d] : 0); sbm = sbm (sbm ? "," : "") d ":" ((d in tMd) ? tMd[d] : 0)
            sbu = sbu (sbu ? "," : "") d ":" sdl[d]; sbp = sbp (sbp ? "," : "") d ":" pdl2[d]
            sbh = sbh (sbh ? "," : "") d ":" thld[d] }
        for(d in dayc){ sbs = sbs (sbs ? "," : "") d ":" dayc[d] ":" ((d in rd) ? rd[d] : 0) }
        printf "SBR|%s\nSBS|%s\nSBH|%s\nSBU|%s\nSBP|%s\nSBD|%s\nSBA|%s\nSBM|%s\n", sbr, sbs, sbh, sbu, sbp, sbd, sba, sbm
        printf "TOT|%d|%d|%d|%d|%d|%d|%d|%d|%d|%d|%d|%d\n", tR+0, tFC+0, thl+0, nsub+0, np+0, nd+0, sFC+0, pAF+0, pHL+0, dFC+0, tA+0, tM+0
    }
' "$FILES" "$PARSED")

IFS='|' read -r _ tR tFC thl nsub nprot ndays sFC pAF pHL dFC tA tM \
    <<< "$(printf '%s\n' "$agg" | grep '^TOT|')"
sba=$(printf '%s\n' "$agg" | sed -n 's/^SBA|//p')
sbm=$(printf '%s\n' "$agg" | sed -n 's/^SBM|//p')
sbr=$(printf '%s\n' "$agg" | sed -n 's/^SBR|//p')
sbs=$(printf '%s\n' "$agg" | sed -n 's/^SBS|//p')
sbh=$(printf '%s\n' "$agg" | sed -n 's/^SBH|//p')
sbu=$(printf '%s\n' "$agg" | sed -n 's/^SBU|//p')
sbp=$(printf '%s\n' "$agg" | sed -n 's/^SBP|//p')
sbd=$(printf '%s\n' "$agg" | sed -n 's/^SBD|//p')
oshare=$(awk -v r="$tR" -v n="$tFC" 'BEGIN{ printf "%.1f", (n>0 ? r*100/n : 0) }')
sshare=$(awk -v r="$tR" -v n="$sFC" 'BEGIN{ printf "%.1f", (n>0 ? r*100/n : 0) }')
hshare=$(awk -v r="$pHL" -v n="$pAF" 'BEGIN{ printf "%.1f", (n>0 ? r*100/n : 0) }')
dshare=$(awk -v r="$tR" -v n="$dFC" 'BEGIN{ printf "%.1f", (n>0 ? r*100/n : 0) }')

{
    printf 'TITLE\tRecovered files\n'
    # every box carries its per-day payload so the values follow the From/To
    # range (report.js recalcStats; the full range restores the baked figures)
    printf 'STAT\torange\t%s\tRecovered Files\t@data:tok=sum\t@data:sb=%s\n' "$tR" "$sbr"
    printf 'STAT\twhite\t%s\tAutomatic\t@data:tok=sum\t@data:sb=%s\n' "$tA" "$sba"
    printf 'STAT\twhite\t%s\tManual\t@data:tok=sum\t@data:sb=%s\n' "$tM" "$sbm"
    printf 'STAT\twhite\t%s%%\tof all Files\t@data:tok=share\t@data:sb=%s\n' "$oshare" "$sbs"
    printf 'STAT\twhite\t%s\tFailed legs healed\t@data:tok=sum\t@data:sb=%s\n' "$thl" "$sbh"
    printf 'STAT\twhite\t%s\tSubscriptions\t@data:tok=uniq\t@data:sb=%s\n' "$nsub" "$sbu"
    printf 'STAT\twhite\t%s\tProtocols\t@data:tok=uniq\t@data:sb=%s\n' "$nprot" "$sbp"
    printf 'STAT\twhite\t%s\tDays\t@data:tok=sum\t@data:sb=%s\n' "$ndays" "$sbd"

    # Retry / Resubmit (2026-09-12): the split of Recovered — blank when 0,
    # like the Top view's Automatic / Manual cells; bucket metrics 1 and 2
    # tab=recfiles (2026-09-29): the three tables ride ONE tab of Retries & resubmissions
    printf 'TABLE\tPer subscription\tkeephead\tzerohide=0\ttab=recfiles\n'
    printf 'HEAD\tSubscription\tRecovered\tAutomatic\tManual\tFiles\tRecovered %%\n'
    printf 'KIND\tsite\tnumwarn\tnumwarn\tnumwarn\tnum\tnum\n'
    printf 'RECALC\t-\ts0\ts1\ts2\ts3\tp0.3\n'
    printf '%s\n' "$agg" | grep '^SUB|' | sort -t'|' -k3,3nr -k2,2 | awk -F'|' '
        $2 != "" { printf "ROW\t%s\t%s\t%s\t%s\t%s\t%s%%\t@data:buckets=%s\t@data:coreids=%s\n", $2, $3, ($4 > 0 ? $4 : ""), ($5 > 0 ? $5 : ""), $6, $7, $8, $9 }' || true
    printf 'TOTAL\tTotal\t@{class=num warn}%s\t@{class=num warn}%s\t@{class=num warn}%s\t@{class=num}%s\t@{class=num}%s%%\n' "$tR" "$tA" "$tM" "$sFC" "$sshare"

    printf 'TABLE\tPer protocol\tzerohide=0\ttab=recfiles\n'
    printf 'HEAD\tProtocol\tRecovered\tAutomatic\tManual\tFailed legs healed\tFailed legs\tHealed %%\n'
    printf 'KIND\ttext\tnumwarn\tnumwarn\tnumwarn\tnum\tnum\tnum\n'
    printf 'RECALC\t-\ts0\ts1\ts2\ts3\ts4\tp3.4\n'
    printf '%s\n' "$agg" | grep '^PROTO|' | sort -t'|' -k3,3nr -k2,2 | awk -F'|' '
        $2 != "" { printf "ROW\t%s\t%s\t%s\t%s\t%s\t%s\t%s%%\t@data:buckets=%s\t@data:coreids=%s\n", $2, ($3 > 0 ? $3 : ""), ($4 > 0 ? $4 : ""), ($5 > 0 ? $5 : ""), ($6 > 0 ? $6 : ""), $7, $8, $9, $10 }' || true
    # Recovered / Retry / Resubmit total the DISTINCT Files alike (2026-09-28
    # fix: Recovered was distinct while its split summed the per-protocol rows,
    # so Retry + Resubmit could exceed Recovered on the same footer)
    tbk=$(printf "%s\n" "$agg" | awk -F"|" "\$1 == \"TB\" { print \$2; exit }")
    printf 'TOTAL\tTotal\t@{class=num warn}%s\t@{class=num warn}%s\t@{class=num warn}%s\t@{class=num}%s\t@{class=num}%s\t@{class=num}%s%%%s\n' "$tR" "$tA" "$tM" "$pHL" "$pAF" "$hshare" "${tbk:+$'\t'@data:buckets=$tbk}"

    printf 'TABLE\tPer day\tpct=5:2:1\ttab=recfiles\n'
    printf 'HEAD\tDate\tFiles\tRecovered\tAutomatic\tManual\tShare %%\n'
    printf 'KIND\ttext\tnum\tnumwarn\tnumwarn\tnumwarn\tnum\n'
    printf '%s\n' "$agg" | grep '^DAY|' | sort -t'|' -k2,2r | awk -F'|' '
        $2 != "" { printf "ROW\t@{href=../day/%s.html}%s\t%s\t%s\t%s\t%s\t%s%%\t@data:coreids=%s\n", $2, $2, $3, $4, ($5 > 0 ? $5 : ""), ($6 > 0 ? $6 : ""), $7, $8 }' || true
    printf 'TOTAL\tTotal\t@{class=num}%s\t@{class=num warn}%s\t@{class=num warn}%s\t@{class=num warn}%s\t@{class=num}%s%%\n' "$dFC" "$tR" "$tA" "$tM" "$dshare"

    printf 'FOOT\n'
} > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"

echo "Data written to $OUT ($tR recovered file(s))." >&2
