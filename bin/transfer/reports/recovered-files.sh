#!/usr/bin/env bash
#
# recovered-files.sh — the RECOVERED FILES analysis (2026-08-29). A File
# (CoreId) counts as RECOVERED when at least one of its legs FAILED and the
# File still finished OK — a retry delivered it. The same rule and the same
# figure as the amber Recovered column on the Top view, the home page and
# the subscription detail pages, broken down three ways:
#
#   - per SUBSCRIPTION  (which flows heal themselves, and how often)
#   - per PROTOCOL      (of the FAILED leg — where the healed failures live)
#   - per DAY           (when it happened)
#
# OK follows the site-wide outcome policy (Processed or Waiting; Failed and
# Expired are not OK); everything is attributed to the File's START day,
# exactly like the Top view column. Distinct from recovered.sh ("Recovered
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
ensure_parsed
skip_if_fresh "$OUT" "${BASH_SOURCE[0]}"
echo "Found ${#files[@]} file(s) in '$INPUT_DIR', processing..." >&2

# Pass 1 = _files.tsv: outcome, start day, subscription and sortkey per
# CoreId, plus the per-subscription/per-day Files totals (the context
# columns). Pass 2 = _transfers.tsv, failed legs only: a failed leg of an
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
        for(k in scd){ split(k,a,SUBSEP); if(a[1] in rs) sbk[a[1]] = sbk[a[1]] (sbk[a[1]] ? "," : "") a[2] ":" (rsd[k]+0) ":" scd[k] }
        for(k in afd){ split(k,a,SUBSEP); if(a[1] in rp) pbk[a[1]] = pbk[a[1]] (pbk[a[1]] ? "," : "") a[2] ":" (rpd[k]+0) ":" (hld[k]+0) ":" afd[k] }
        # key | recovered | files | share | buckets | drill
        for(s in rs){ printf "SUB|%s|%d|%d|%s|%s|%s\n", s, rs[s], sc[s], pc(rs[s], sc[s]), sbk[s], buildlist(top["S" SUBSEP s]); sFC += sc[s]; nsub++ }
        # key | recovered files | healed legs | all failed legs | healed % | buckets | drill
        for(p in rp){ printf "PROTO|%s|%d|%d|%d|%s|%s|%s\n", p, rp[p], hl[p], af[p], pc(hl[p], af[p]), pbk[p], buildlist(top["P" SUBSEP p]); pAF += af[p]; pHL += hl[p]; np++ }
        # key | files | recovered | share | drill
        for(d in rd){ printf "DAY|%s|%d|%d|%s|%s\n", d, dayc[d], rd[d], pc(rd[d], dayc[d]), buildlist(top["D" SUBSEP d]); dFC += dayc[d]; nd++ }
        # the STAT boxes per-day payloads (report.js recalcStats data-sb):
        # sum / uniq days = the recovery days only; share = EVERY day with
        # Files, so the denominator follows the range too
        for(d in rd){ sbr = sbr (sbr ? "," : "") d ":" rd[d]; sbd = sbd (sbd ? "," : "") d ":1"
            sbu = sbu (sbu ? "," : "") d ":" sdl[d]; sbp = sbp (sbp ? "," : "") d ":" pdl2[d]
            sbh = sbh (sbh ? "," : "") d ":" thld[d] }
        for(d in dayc){ sbs = sbs (sbs ? "," : "") d ":" dayc[d] ":" ((d in rd) ? rd[d] : 0) }
        printf "SBR|%s\nSBS|%s\nSBH|%s\nSBU|%s\nSBP|%s\nSBD|%s\n", sbr, sbs, sbh, sbu, sbp, sbd
        printf "TOT|%d|%d|%d|%d|%d|%d|%d|%d|%d|%d\n", tR+0, tFC+0, thl+0, nsub+0, np+0, nd+0, sFC+0, pAF+0, pHL+0, dFC+0
    }
' "$FILES" "$PARSED")

IFS='|' read -r _ tR tFC thl nsub nprot ndays sFC pAF pHL dFC \
    <<< "$(printf '%s\n' "$agg" | grep '^TOT|')"
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
    printf 'DESC\tThe Files that carried a failed transfer leg yet still finished OK — a retry delivered them: which subscriptions have them, which protocols the healed failures happened on, and on what days.\n'
    printf 'KEYWORDS\trecovered, retry, healed, self-healing, failed leg, retries, resilience, per subscription, per protocol, per day\n'
    printf 'INTRO\tA **recovered File** carried at least one FAILED transfer leg and still finished **OK** — a retry delivered it, so it sits under Files/Ok on the Top view while its failed legs sit under Transfers/Error. The same rule and the same figures as the amber **Recovered** column on the Top view, the home page and the subscription detail pages (OK per the site-wide outcome policy: Processed or Waiting; everything on the File'\''s START day). Three breakdowns: which **subscriptions** have it, which **protocols** the healed failures happened on, and on what **days**. Click a row for its 10 most recent recovered Files.\n'
    # every box carries its per-day payload so the values follow the From/To
    # range (report.js recalcStats; the full range restores the baked figures)
    printf 'STAT\torange\t%s\tRecovered Files\t@data:tok=sum\t@data:sb=%s\n' "$tR" "$sbr"
    printf 'STAT\twhite\t%s%%\tof all Files\t@data:tok=share\t@data:sb=%s\n' "$oshare" "$sbs"
    printf 'STAT\twhite\t%s\tFailed legs healed\t@data:tok=sum\t@data:sb=%s\n' "$thl" "$sbh"
    printf 'STAT\twhite\t%s\tSubscriptions\t@data:tok=uniq\t@data:sb=%s\n' "$nsub" "$sbu"
    printf 'STAT\twhite\t%s\tProtocols\t@data:tok=uniq\t@data:sb=%s\n' "$nprot" "$sbp"
    printf 'STAT\twhite\t%s\tDays\t@data:tok=sum\t@data:sb=%s\n' "$ndays" "$sbd"

    printf 'TABLE\tPer subscription\tkeephead\n'
    printf 'HEAD\tSubscription\tRecovered\tFiles\tRecovered %%\n'
    printf 'KIND\tsite\tnumwarn\tnum\tnum\n'
    printf 'RECALC\t-\ts0\ts1\tp0.1\n'
    printf '%s\n' "$agg" | grep '^SUB|' | sort -t'|' -k3,3nr -k2,2 | awk -F'|' '
        $2 != "" { printf "ROW\t%s\t%s\t%s\t%s%%\t@data:buckets=%s\t@data:coreids=%s\n", $2, $3, $4, $5, $6, $7 }' || true
    printf 'TOTAL\tTotal\t@{class=num warn}%s\t@{class=num}%s\t@{class=num}%s%%\n' "$tR" "$sFC" "$sshare"
    printf 'NOTE\t**Recovered %%** = the share of that subscription'\''s Files (in the whole loaded window) that needed a retry to get through — a high share on a busy flow points at a flaky endpoint that succeeds on the second try. The Files column counts ALL of the subscription'\''s Files, whatever their outcome; only subscriptions with at least one recovered File are listed.\n'

    printf 'TABLE\tPer protocol\n'
    printf 'HEAD\tProtocol\tRecovered\tFailed legs healed\tFailed legs\tHealed %%\n'
    printf 'KIND\ttext\tnumwarn\tnum\tnum\tnum\n'
    printf 'RECALC\t-\ts0\ts1\ts2\tp1.2\n'
    printf '%s\n' "$agg" | grep '^PROTO|' | sort -t'|' -k3,3nr -k2,2 | awk -F'|' '
        $2 != "" { printf "ROW\t%s\t%s\t%s\t%s\t%s%%\t@data:buckets=%s\t@data:coreids=%s\n", $2, $3, $4, $5, $6, $7, $8 }' || true
    printf 'TOTAL\tTotal\t@{class=num warn}%s\t@{class=num}%s\t@{class=num}%s\t@{class=num}%s%%\n' "$tR" "$pHL" "$pAF" "$hshare"
    printf 'NOTE\tThe protocol is the FAILED leg'\''s — where the healed failure actually happened, not what finally delivered the File. A File whose failed legs span two protocols counts once under each, so the Recovered column can sum past the %s distinct Files. **Healed %%** = failed legs belonging to recovered Files over ALL failed legs of that protocol (recovered or not) — how often a failure on that protocol turns out to be transient.\n' "$tR"

    printf 'TABLE\tPer day\tpct=3:2:1\n'
    printf 'HEAD\tDate\tFiles\tRecovered\tShare %%\n'
    printf 'KIND\ttext\tnum\tnumwarn\tnum\n'
    printf '%s\n' "$agg" | grep '^DAY|' | sort -t'|' -k2,2r | awk -F'|' '
        $2 != "" { printf "ROW\t@{href=../day/%s.html}%s\t%s\t%s\t%s%%\t@data:coreids=%s\n", $2, $2, $3, $4, $5, $6 }' || true
    printf 'TOTAL\tTotal\t@{class=num}%s\t@{class=num warn}%s\t@{class=num}%s%%\n' "$dFC" "$tR" "$dshare"
    printf 'NOTE\tOnly days with at least one recovered File are listed (the Top view'\''s Files table shows every day); the Date cell opens that day'\''s page. Days are the File'\''s START day, so the figures line up with the Top view'\''s Recovered column exactly.\n'

    printf 'SUMMARY\tRecovered Files: %s (%s%% of %s)  |  Failed legs healed: %s\n' "$tR" "$oshare" "$tFC" "$thl"
    printf 'FOOT\tGenerated on %s from %s file(s)\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${#files[@]}"
} > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"

echo "Data written to $OUT ($tR recovered file(s))." >&2
