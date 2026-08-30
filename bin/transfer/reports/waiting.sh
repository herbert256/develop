#!/usr/bin/env bash
#
# waiting.sh — UC2 files STAGED FOR PICKUP: the Waiting outcome. A UC2 file
# arrives from CFT in three quick legs (PeSIT in, routing out, routing in) and
# then sits STAGED until the partner dials in over SSH and collects it. A file
# whose last leg is the (Processed) staging leg carries outcome "Waiting" in
# _files.tsv — arrived and staged, not collected yet; once the nightly File
# Maintenance retention sweep (~11 days) deletes the staged copy before any
# pickup, bin/expire-files.sh flips it to "Expired" (col 22 = the deletion
# timestamp). Four views:
#   Waiting now           per subscription: how many Files sit staged, since
#                         when, and for how long (vs the dataset's end).
#   Files waiting longest the individual staged Files, oldest first.
#   Expired               per subscription: staged Files DELETED before any
#                         pickup — never delivered (col 22 timestamps).
#   Pickup wait           for the files that WERE collected: how long the
#                         partner took (col 21 wait_ms — the staging->collect
#                         gap parse.sh EXCLUDES from Duration).
# Plus four second-pass views (2026-08):
#   Staged backlog        the day-by-day staged-but-uncollected inventory,
#                         reconstructed from every staged File's occupancy
#                         window [staged day, collected/expired day) — Waiting
#                         files occupy through the window end.
#   Will expire next      Waiting Files staged >= 9 days ago: the retention
#                         sweep (~11 days) is about to delete them — the
#                         "call the partner today" list.
#   Pickup percentiles    per PARTNER (site-wide UNION attribution): median /
#                         p95 / max wait + the near-misses (waited > 8 days).
#   Pickup wait per week  median + average wait per staged week for the
#                         10 busiest UC2 subscriptions.
#
# Full-period semantics (`nofilter`, like episodes/stale-accounts): Waiting is
# a state at the dataset's end, not a per-day statistic.
#
# Reads data/_files.tsv (1=coreid, 2=outcome, 3=account, 4=date_iso, 5=time,
# 6=sortkey, 7=jdn, 8=size, 11=file, 12=dest_site, 20=partner, 21=wait_ms,
# 22=expired) + xref/_subscriptions-partners.tsv (the UNION attribution).
# Writes data/waiting.rpt.
#
# Usage:
#   ./waiting.sh    # reads input/*.csv (via the cache), writes data/waiting.rpt
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# TRANSFER lib, not the analyses one: this is a transfer-DATA report (it reads
# the transfer caches and writes data/<env>/transfer/reports/). It lives HERE
# because its page sits in the ANALYSES menu, in the Subscriptions group — the
# same arrangement as cross-reference.sh. bin/transfer/reports.sh still runs it.
source "$SCRIPT_DIR/../lib.sh"
mkdir -p "$REPORTS_DIR"
OUT="$REPORTS_DIR/waiting.rpt"

TOP_FILES=50   # individual waiting files listed

shopt -s nullglob
files=("$INPUT_DIR"/*.csv)
shopt -u nullglob
if [ ${#files[@]} -eq 0 ]; then
    echo "No *.csv in $INPUT_DIR — building from the EMPTY caches (config-only estate)" >&2
fi
ensure_parsed
SPX="$CONFIG_XREF/_subscriptions-partners.tsv"   # subscription -> partner (UNION attribution)
skip_if_fresh "$OUT" "${BASH_SOURCE[0]}" "$SPX"
echo "Found ${#files[@]} file(s) in '$INPUT_DIR', processing..." >&2

# Stream _files.tsv grouped by subscription, chronological inside each group.
# Emits pipe-separated (file names go LAST — they may hold any byte but TAB):
#   W|oldsec|site|nwait|oldest_dt|wait_for|newest_dt|ncoll|drill
#   X|site|nexp|first_dt|last_dt|last_del|drill
#   P|site|ncoll|median|avg|max|b1h|b24|bgt
#   F|stagesec|staged_dt|site|acct|bytes|size|wait_for|file
#   TOT|wsites|wtot|csites|ctot|xsites|xtot|oldest_dt|oldest_site|last_dt
agg=$(LC_ALL=C sort -t"$(printf '\t')" -k12,12 -k6,6 "$FILES" | awk -F'\t' "$COREIDS_AWK"'
    function jdn(y,m,d,  a){ a=int((14-m)/12); y=y+4800-a; m=m+12*a-3; return d+int((153*m+2)/5)+365*y+int(y/4)-int(y/100)+int(y/400)-32045 }
    function tsec(d,t){ split(d,p,"-"); return jdn(p[1]+0,p[2]+0,p[3]+0)*86400 + substr(t,1,2)*3600 + substr(t,4,2)*60 + substr(t,7,2) }
    function hdur(s){ s=int(s); if (s<0) s=0
        if (s>=86400) return int(s/86400) "d " int(s%86400/3600) "h"
        if (s>=3600)  return int(s/3600) "h " int(s%3600/60) "m"
        if (s>=60)    return int(s/60) " min"
        return s " s" }
    function hsize(b){ if (b>=1073741824) return sprintf("%.1f GB", b/1073741824)
        if (b>=1048576) return sprintf("%.1f MB", b/1048576)
        if (b>=1024)    return sprintf("%.1f KB", b/1024)
        return b " B" }
    function flush(   i,j,m,a,tmp,med) {
        if (site == "") return
        if (nw > 0) {
            wsites++; wtot += nw
            W[wsites] = oldsec "|" site "|" nw "|" olddt "|" newdt "|" nc "|" buildlist(top["W" SUBSEP site])
            if (g_oldsec == 0 || oldsec < g_oldsec) { g_oldsec = oldsec; g_olddt = olddt; g_oldsite = site }
        }
        if (nx > 0) {
            xsites++; xtot += nx
            X[xsites] = site "|" nx "|" xolddt "|" xnewdt "|" xlastdel "|" buildlist(top["X" SUBSEP site])
        }
        if (nc > 0) {
            csites++; ctot += nc
            m = split(waits, a, " ")
            for (i = 2; i <= m; i++) { tmp = a[i] + 0; j = i - 1
                while (j >= 1 && a[j] + 0 > tmp) { a[j+1] = a[j]; j-- }
                a[j+1] = tmp }
            med = (m % 2) ? a[(m+1)/2] : (a[m/2] + a[m/2+1]) / 2
            P[csites] = site "|" nc "|" med "|" wsum/nc "|" wmax "|" c1h+0 "|" c24+0 "|" cgt+0
        }
    }
    $12 == "" || $4 == "" { next }
    {
        if ($12 != site) { flush()
            site = $12; nw = 0; olddt = ""; oldsec = 0; newdt = ""
            nx = 0; xolddt = ""; xnewdt = ""; xlastdel = ""
            nc = 0; waits = ""; wsum = 0; wmax = 0; c1h = 0; c24 = 0; cgt = 0 }
        if ($6 > g_lastsk) { g_lastsk = $6; g_lastsec = tsec($4, $5); g_lastdt = $4 " " substr($5, 1, 8) }
        if ($2 == "Waiting") {
            nw++
            s = tsec($4, $5)
            if (olddt == "") { olddt = $4 " " substr($5, 1, 8); oldsec = s }   # sortkey-sorted: first = oldest
            newdt = $4 " " substr($5, 1, 8)
            addtop("W" SUBSEP site, $6, $4 " " $5, $1)
            FL[++nf] = s "|" $4 " " substr($5, 1, 8) "|" site "|" $3 "|" ($8 + 0) "|" hsize($8 + 0) "|" $11
        } else if ($2 == "Expired") {
            nx++
            if (xolddt == "") xolddt = $4 " " substr($5, 1, 8)   # sortkey-sorted: first = oldest
            xnewdt = $4 " " substr($5, 1, 8)
            if ($22 > xlastdel) xlastdel = $22
            addtop("X" SUBSEP site, $6, $4 " " $5, $1)
        } else if ($21 != "") {
            nc++
            wv = $21 / 1000
            waits = waits (waits == "" ? "" : " ") wv
            wsum += wv; if (wv > wmax) wmax = wv
            if (wv <= 3600) c1h++; else if (wv <= 86400) c24++; else cgt++
        }
    }
    END {
        flush()
        for (i = 1; i <= wsites; i++) {
            m = split(W[i], a, "|")
            printf "W|%s|%s|%s|%s|%s|%s|%s|%s\n", a[1], a[2], a[3], a[4], hdur(g_lastsec - a[1]), a[5], a[6], a[7]
        }
        for (i = 1; i <= xsites; i++) print "X|" X[i]
        for (i = 1; i <= csites; i++) {
            m = split(P[i], a, "|")
            printf "P|%s|%s|%s|%s|%s|%s|%s|%s\n", a[1], a[2], hdur(a[3]), hdur(a[4]), hdur(a[5]), a[6], a[7], a[8]
        }
        for (i = 1; i <= nf; i++) {
            m = split(FL[i], a, "|")
            # file name may contain "|": re-join everything from field 7 on
            fn = a[7]; for (j = 8; j <= m; j++) fn = fn "|" a[j]
            printf "F|%s|%s|%s|%s|%s|%s|%s|%s\n", a[1], a[2], a[3], a[4], a[5], a[6], hdur(g_lastsec - a[1]), fn
        }
        printf "TOT|%d|%d|%d|%d|%d|%d|%s|%s|%s\n", wsites+0, wtot+0, csites+0, ctot+0, xsites+0, xtot+0, g_olddt, g_oldsite, g_lastdt
    }
')

if [ -z "$agg" ]; then
    echo "No usable records found." >&2
    exit 1
fi

IFS='|' read -r _ n_wsites n_wait n_csites n_coll n_xsites n_exp oldest_dt oldest_site last_dt <<< "$(printf '%s\n' "$agg" | grep '^TOT|')"

# ---------------------------------------------------------------------------
# Second pass: the staged-inventory curve, the expiry-risk list, the per-
# partner pickup percentiles and the per-week medians. A "staged" File is one
# with a staging phase: collected (col 21 set), Waiting or Expired. Every
# END-phase figure uses the FINAL window-end jdn (maxj grows during the scan),
# and an Expired file whose deletion timestamp lies past the transfer window
# is clamped to the window end — so the curve's last day equals the Waiting
# count exactly. Emits pipe-separated:
#   B|date|files|volume            one per day, chronological
#   T2|ndays|peak|peakdate|end     the curve facts
#   E|nfiles|site|oldest_dt|age|drill      Waiting aged >= 9 days
#   Q|files|partner|median|p95|max|nearmiss   collected, UNION attribution
#   K|rank|site|weekdate|files|median|avg     top-10 subs by collected Files
agg2=$(awk -F'\t' -v spx="$SPX" "$COREIDS_AWK"'
    function jdn(y,m,d,  a){ a=int((14-m)/12); y=y+4800-a; m=m+12*a-3; return d+int((153*m+2)/5)+365*y+int(y/4)-int(y/100)+int(y/400)-32045 }
    function jd2date(j,  a,b,c,d,e,m,y,day,mon){ a=j+32044; b=int((4*a+3)/146097); c=a-int(146097*b/4)
        d=int((4*c+3)/1461); e=c-int(1461*d/4); m=int((5*e+2)/153)
        day=e-int((153*m+2)/5)+1; mon=m+3-12*int(m/10); y=100*b+d-4800+int(m/10)
        return sprintf("%04d-%02d-%02d", y, mon, day) }
    function hdur(s){ s=int(s); if (s<0) s=0
        if (s>=86400) return int(s/86400) "d " int(s%86400/3600) "h"
        if (s>=3600)  return int(s/3600) "h " int(s%3600/60) "m"
        if (s>=60)    return int(s/60) " min"
        return s " s" }
    function hsize(b){ if (b>=1073741824) return sprintf("%.1f GB", b/1073741824)
        if (b>=1048576) return sprintf("%.1f MB", b/1048576)
        if (b>=1024)    return sprintf("%.1f KB", b/1024)
        return int(b) " B" }
    # med SUBSEP p95 of a space-separated seconds list (insertion sort; the
    # magic " " separator ignores the leading blank)
    function stats(str,  m,a,i,j,t,med){ m = split(str, a, " ")
        for (i=2;i<=m;i++){ t=a[i]+0; j=i-1; while (j>=1 && a[j]+0>t) { a[j+1]=a[j]; j-- } a[j+1]=t }
        med = (m%2) ? a[(m+1)/2] : (a[int(m/2)]+a[int(m/2)+1])/2
        return med SUBSEP a[int(0.95*(m-1))+1] }
    BEGIN { while ((getline _l < spx) > 0) { split(_l, _a, "\t")
                if (_a[1] != "" && _a[2] != "") sp[_a[1]] = (sp[_a[1]] == "" ? _a[2] : sp[_a[1]] SUBSEP _a[2]) }
            close(spx) }
    $12 == "" || $4 == "" { next }
    { j0 = $7 + 0; if (j0 > maxj) maxj = j0 }
    $2 == "Waiting" {
        nb++; BS[nb] = j0; BE[nb] = -1; BV[nb] = $8 + 0            # occupies through the window end
        nwq++; WSITE[nwq] = $12; WJ[nwq] = j0; WD[nwq] = $4; WT[nwq] = $5; WSK[nwq] = $6; WID[nwq] = $1
        next
    }
    $2 == "Expired" {
        split($22, p, "-"); split(p[3], q, " ")
        nb++; BS[nb] = j0; BE[nb] = jdn(p[1]+0, p[2]+0, q[1]+0); BV[nb] = $8 + 0
        next
    }
    $21 != "" {
        s = j0*86400 + substr($5,1,2)*3600 + substr($5,4,2)*60 + substr($5,7,2)
        nb++; BS[nb] = j0; BE[nb] = int((s + $21/1000) / 86400); BV[nb] = $8 + 0
        if ($2 != "Processed") next
        w = $21 / 1000
        # per PARTNER: the site-wide UNION — the subscription configured
        # partners (SPX) plus the host-resolved col 20, deduped
        pl = ($12 in sp) ? sp[$12] : ""
        h = $20
        if (h != "") { inp = 0; np = split(pl, pa, SUBSEP)
            for (j = 1; j <= np; j++) if (pa[j] == h) { inp = 1; break }
            if (!inp) pl = (pl == "" ? h : pl SUBSEP h) }
        if (pl == "") pl = "(none)"
        np = split(pl, pa, SUBSEP)
        for (j = 1; j <= np; j++) { pt = pa[j]
            if (PW[pt] == "") PLQ[++npq] = pt                       # EMPTINESS, not membership (mawk LHS trap)
            PW[pt] = PW[pt] " " w; PC[pt]++
            if (w > PM[pt]) PM[pt] = w
            if (w > 8*86400) PN[pt]++ }
        # per (subscription, staged week) — Monday-start (jdn%7==0 = Monday)
        ws = j0 - (j0 % 7)
        if (minws == 0 || ws < minws) minws = ws
        if (ws > maxws) maxws = ws
        kk = $12 SUBSEP ws
        if (KW[kk] == "") KWL[++nkk] = kk
        KW[kk] = KW[kk] " " w; KC[kk]++; KA[kk] += w
        if (KS[$12] == "") KSL[++nks] = $12
        KS[$12] = KS[$12] + 1
    }
    END {
        # ---- the backlog curve (diff array; END so maxj is final) ----
        minj = 0
        for (i = 1; i <= nb; i++) {
            sj = BS[i]; ej = BE[i]
            if (ej < 0) ej = maxj + 1                # Waiting: in inventory through the last day
            else if (ej > maxj) ej = maxj            # deletion past the window: leaves on the last day
            if (ej <= sj) continue                   # same-day pickup never sits in overnight inventory
            d1[sj] += 1; d1[ej] -= 1; v1[sj] += BV[i]; v1[ej] -= BV[i]
            if (minj == 0 || sj < minj) minj = sj
        }
        c = 0; v = 0; ndays = 0; peak = 0; peakdate = ""
        for (j = minj; j >= 1 && j <= maxj; j++) {
            c += d1[j] + 0; v += v1[j] + 0; ndays++
            if (c > peak) { peak = c; peakdate = jd2date(j) }
            printf "B|%s|%d|%s\n", jd2date(j), c, hsize(v)
        }
        printf "T2|%d|%d|%s|%d\n", ndays, peak, peakdate, c
        # ---- Waiting aged >= 9 days, per subscription ----
        for (i = 1; i <= nwq; i++) {
            age = maxj - WJ[i]
            if (age < 9) continue
            st = WSITE[i]
            if (EC[st] == "") ESL[++nes] = st
            EC[st] = EC[st] + 1
            if (EO[st] == "" || WD[i] " " WT[i] < EO[st]) EO[st] = WD[i] " " substr(WT[i], 1, 8)
            if (age > EA[st]) EA[st] = age
            addtop("E" SUBSEP st, WSK[i], WD[i] " " WT[i], WID[i])
        }
        for (i = 1; i <= nes; i++) { st = ESL[i]
            printf "E|%d|%s|%s|%d days|%s\n", EC[st], st, EO[st], EA[st], buildlist(top["E" SUBSEP st]) }
        # ---- per-partner percentiles ----
        for (i = 1; i <= npq; i++) { pt = PLQ[i]
            split(stats(PW[pt]), sv, SUBSEP)
            printf "Q|%d|%s|%s|%s|%s|%d\n", PC[pt], pt, hdur(sv[1]), hdur(sv[2]), hdur(PM[pt]), PN[pt]+0 }
        # ---- weekly medians for the top-10 subs by collected Files ----
        for (i = 1; i <= nks; i++) R[i] = KSL[i]
        for (i = 2; i <= nks; i++) { nm = R[i]; j = i - 1
            while (j >= 1 && (KS[R[j]]+0 < KS[nm]+0 || (KS[R[j]]+0 == KS[nm]+0 && R[j] > nm))) { R[j+1] = R[j]; j-- }
            R[j+1] = nm }
        topn = (nks < 10) ? nks : 10
        for (r = 1; r <= topn; r++) { st = R[r]
            for (ws = minws; ws >= 7 && ws <= maxws; ws += 7) {
                kk = st SUBSEP ws
                if (!(kk in KC)) continue
                split(stats(KW[kk]), sv, SUBSEP)
                printf "K|%d|%s|%s|%d|%s|%s\n", r, st, jd2date(ws), KC[kk], hdur(sv[1]), hdur(KA[kk]/KC[kk]) } }
    }
' "$FILES")

IFS='|' read -r _ n_bdays bk_peak bk_peakdate bk_end <<< "$(printf '%s\n' "$agg2" | grep '^T2|' || printf 'T2|0|0||0')"

# All four row loops run INSIDE the report block below (a herestring keeps them
# in this shell), so the counters each table's TOTAL line needs are ready by the
# time that line is printed. The empty-state rows keep their trailing newline —
# without it the TOTAL would glue onto the placeholder.
sum_nc=0
n_wrows=0
n_shown=0; sum_bytes=0
n_xrows=0
b1h_sum=0; b24_sum=0; bgt_sum=0; n_prows=0

oldest_cell="-"
[ -n "$oldest_dt" ] && oldest_cell="$oldest_dt ($oldest_site)"

{
    printf 'TITLE\tWaiting Files\n'
    printf 'DESC\tUC2 files staged for pickup: which subscriptions have Files the partner has not collected yet, how long they have been waiting, and how fast partners usually collect.\n'
    printf 'KEYWORDS\tuc2, pickup, collect, waiting, staged, routing, not collected, partner wait, expired, deleted, retention, file maintenance, never delivered, backlog, inventory, expire soon, at risk, call the partner, percentile, median, p95, near miss, weekly trend, pickup speed\n'
    printf 'INTRO\tA UC2 file is COLLECTED by the partner: it arrives from CFT in three quick legs (PeSIT in, routing out, routing in), then sits STAGED until the partner dials in over SSH and picks it up. A file still staged at the end of the data window has outcome **Waiting** — not an error, just not collected yet. A staged file the nightly File Maintenance retention sweep (~11 days) DELETED before any pickup is **Expired** — never delivered. Right now **%s** File(s) across **%s** subscription(s) are waiting (oldest staged **%s**), **%s** File(s) across **%s** subscription(s) have expired, and **%s** staged File(s) were collected. The pickup wait is EXCLUDED from every UC2 Duration figure on this site. Below the four state tables: the day-by-day **staged backlog** curve (peak **%s** file(s) on %s), the **Will expire next** call list, and the per-partner and per-week **pickup-wait** statistics. Click a row for the 10 most recent Files.\n' \
        "$n_wait" "$n_wsites" "$oldest_cell" "$n_exp" "$n_xsites" "$n_coll" "$bk_peak" "${bk_peakdate:--}"

    printf 'TABLE\tWaiting now — per subscription\twide\tnofilter\n'
    printf 'HEAD\tSubscription\tWaiting Files\tOldest staged\tWaiting for\tNewest staged\tCollected\n'
    printf 'KIND\tsite\tnumwarn\ttext\ttext\ttext\tnum\n'
    # W fields: 2=oldsec 3=site 4=nwait 5=oldest_dt 6=wait_for 7=newest_dt 8=ncoll 9=drill
    while IFS='|' read -r _ oldsec site nw olddt wf newdt nc drill; do
        [ -z "$site" ] && continue
        sum_nc=$((sum_nc + nc)); n_wrows=$((n_wrows + 1))
        printf 'ROW\t%s\t%s\t%s\t%s\t%s\t%s\t@data:coreids=%s\n' "$site" "$nw" "$olddt" "$wf" "$newdt" "$nc" "$drill"
    done <<< "$(printf '%s\n' "$agg" | grep '^W|' | LC_ALL=C sort -t'|' -k2,2n -k3,3)"
    if [ "$n_wrows" -eq 0 ]; then
        printf 'ROW\t@{colspan=6}No Waiting Files — every staged UC2 File in this data window was collected.\n'
    fi
    printf 'TOTAL\tTotal (%s subscriptions)\t@{class=num warn}%s\t%s\t\t\t@{class=num}%s\n' "$n_wsites" "$n_wait" "$oldest_dt" "$sum_nc"
    printf 'NOTE\tA **Waiting** File arrived and was staged (its last leg is the Inbound routing one) but no partner collect leg followed — and its staged copy has NOT been deleted yet, so the partner can still pick it up (once the retention sweep removes it, the File moves to the Expired table below). **Waiting for** counts from the staging moment to the dataset'\''s last record (%s) — a file may have been collected after the export. Collected = the same subscription'\''s Files that WERE picked up. Sorted oldest-waiting first. Click a row for the 10 most recent waiting Files.\n' "$last_dt"

    printf 'TABLE\tFiles waiting the longest\twide\tnofilter\n'
    printf 'HEAD\tStaged\tSubscription\tAccount\tFile\tSize\tWaiting for\n'
    printf 'KIND\ttext\tsite\tacct\tfile\ttext\ttext\n'
    # F fields: 2=stagesec 3=staged_dt 4=site 5=acct 6=bytes 7=size 8=wait_for 9..=file
    while IFS='|' read -r _ s dt site acct bytes size wf fname; do
        [ -z "$site" ] && continue
        n_shown=$((n_shown + 1)); sum_bytes=$((sum_bytes + bytes))
        printf 'ROW\t%s\t%s\t%s\t%s\t%s\t%s\n' "$dt" "$site" "$acct" "$fname" "$size" "$wf"
    done <<< "$(printf '%s\n' "$agg" | grep '^F|' | LC_ALL=C sort -t'|' -k2,2n -k4,4 | awk -v n="$TOP_FILES" 'NR<=n')"
    if [ "$n_shown" -eq 0 ]; then
        printf 'ROW\t@{colspan=6}No Waiting Files in this data window.\n'
    fi
    sum_size=$(awk -v b="$sum_bytes" 'BEGIN{ if (b>=1073741824) printf "%.1f GB", b/1073741824
        else if (b>=1048576) printf "%.1f MB", b/1048576
        else if (b>=1024)    printf "%.1f KB", b/1024
        else                 printf "%d B", b }')
    printf 'TOTAL\tTotal (%s of %s waiting Files shown)\t\t\t\t%s\t\n' "$n_shown" "$n_wait" "$sum_size"
    printf 'NOTE\tThe **%s** longest-waiting individual Files, oldest first.\n' "$TOP_FILES"

    printf 'TABLE\tExpired — deleted before pickup, per subscription\twide\tnofilter\n'
    printf 'HEAD\tSubscription\tExpired Files\tFirst staged\tLast staged\tLast deletion\n'
    printf 'KIND\tsite\tnumwarn\ttext\ttext\ttext\n'
    # X fields: 2=site 3=nexp 4=first_dt 5=last_dt 6=last_del 7=drill
    while IFS='|' read -r _ site nx firstdt lastdt lastdel drill; do
        [ -z "$site" ] && continue
        n_xrows=$((n_xrows + 1))
        printf 'ROW\t%s\t%s\t%s\t%s\t%s\t@data:coreids=%s\n' "$site" "$nx" "$firstdt" "$lastdt" "$lastdel" "$drill"
    done <<< "$(printf '%s\n' "$agg" | grep '^X|' | LC_ALL=C sort -t'|' -k3,3nr -k2,2)"
    if [ "$n_xrows" -eq 0 ]; then
        printf 'ROW\t@{colspan=5}No Expired Files — no staged File was deleted before pickup in this data window.\n'
    fi
    printf 'TOTAL\tTotal (%s subscriptions)\t@{class=num warn}%s\t\t\t\n' "$n_xsites" "$n_exp"
    printf 'NOTE\tStaged Files the nightly **File Maintenance** retention sweep deleted (~11 days after staging) before any partner pickup — **never delivered**, and no longer collectable. The deletion timestamp comes from the server log (there is NO transfer-log record of the deletion) and is stored as the **Expired** field (_files.tsv col 22) by the bin/expire-files.sh build step. Expired Files count as **Error** on every report. Click a row for the 10 most recent expired Files.\n'

    printf 'TABLE\tPickup wait — collected files, per subscription\twide\tnofilter\n'
    printf 'HEAD\tSubscription\tCollected\tMedian wait\tAverage wait\tMax wait\tWithin 1 h\t1 - 24 h\tOver 24 h\n'
    printf 'KIND\tsite\tnum\ttext\ttext\ttext\tnumprocessed\tnum\tnumwarn\n'
    # P fields: 2=site 3=ncoll 4=median 5=avg 6=max 7=b1h 8=b24 9=bgt
    while IFS='|' read -r _ site nc med avg mx b1h b24 bgt; do
        [ -z "$site" ] && continue
        b1h_sum=$((b1h_sum + b1h)); b24_sum=$((b24_sum + b24)); bgt_sum=$((bgt_sum + bgt))
        n_prows=$((n_prows + 1))
        gt_cell=$bgt; [ "$bgt" -gt 0 ] && gt_cell="@{class=failed}$bgt"
        printf 'ROW\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$site" "$nc" "$med" "$avg" "$mx" "$b1h" "$b24" "$gt_cell"
    done <<< "$(printf '%s\n' "$agg" | grep '^P|' | LC_ALL=C sort -t'|' -k3,3nr -k2,2)"
    if [ "$n_prows" -eq 0 ]; then
        printf 'ROW\t@{colspan=8}No collected UC2 pickups in this data window.\n'
    fi
    printf 'TOTAL\tTotal (%s subscriptions)\t@{class=num}%s\t\t\t\t@{class=num processed}%s\t@{class=num}%s\t@{class=num warn}%s\n' \
        "$n_csites" "$n_coll" "$b1h_sum" "$b24_sum" "$bgt_sum"
    printf 'NOTE\tHow long the partner took to collect: from the staging leg ending to the FIRST collect leg starting (repeat collects of the same File count once). This wait is what parse.sh excludes from the UC2 Duration figures.\n'

    # ---- the four second-pass tables --------------------------------------

    printf 'TABLE\tStaged backlog over time\tnofilter\tnosearch\n'
    printf 'HEAD\tDate\tStaged Files in inventory\tStaged volume\n'
    printf 'KIND\ttext\tnum\ttext\n'
    n_brows=0
    # B fields: 2=date 3=files 4=volume
    while IFS='|' read -r _ bdt bcnt bvol; do
        [ -z "$bdt" ] && continue
        n_brows=$((n_brows + 1))
        printf 'ROW\t%s\t%s\t%s\n' "$bdt" "$bcnt" "$bvol"
    done <<< "$(printf '%s\n' "$agg2" | grep '^B|')"
    if [ "$n_brows" -eq 0 ]; then
        printf 'ROW\t@{colspan=3}No staged UC2 Files in this data window.\n'
    fi
    printf 'TOTAL\tTotal (%s days)\t\t\n' "$n_brows"
    printf 'NOTE\tThe staged-but-uncollected inventory, reconstructed per day: every staged File occupies the days from its staging day up to (not including) the day the partner collected it or the retention sweep deleted it — a same-day pickup never sits in the overnight inventory, and a still-Waiting File occupies through the window end, so the LAST day equals the Waiting count above (**%s**). Peak backlog: **%s** file(s) on **%s**. Volume is the staged bytes sitting in inventory that day.\n' \
        "$bk_end" "$bk_peak" "${bk_peakdate:--}"

    n_erows=0; e_files_sum=0
    printf 'TABLE\tWill expire next\twide\tnofilter\trestint\n'
    printf 'HEAD\tSubscription\tFiles at risk\tOldest staged\tAge\n'
    printf 'KIND\tsite\tnum\ttext\ttext\n'
    # E fields: 2=nfiles 3=site 4=oldest_dt 5=age 6=drill
    while IFS='|' read -r _ ecnt esite eold eage edrill; do
        [ -z "$esite" ] && continue
        n_erows=$((n_erows + 1)); e_files_sum=$((e_files_sum + ecnt))
        printf 'ROW\t%s\t%s\t%s\t%s\t@data:coreids=%s\t@data:res=red\n' "$esite" "$ecnt" "$eold" "$eage" "$edrill"
    done <<< "$(printf '%s\n' "$agg2" | grep '^E|' | LC_ALL=C sort -t'|' -k2,2nr -k3,3)"
    if [ "$n_erows" -eq 0 ]; then
        printf 'ROW\t@{colspan=4}No Waiting File has been staged for 9 days or more — nothing is close to the retention sweep.\n'
    fi
    printf 'TOTAL\tTotal (%s subscriptions)\t@{class=num warn}%s\t\t\n' "$n_erows" "$e_files_sum"
    printf 'NOTE\t**Call the partner today.** These Waiting Files have been staged for **9 days or more** (vs the dataset'\''s last day) — the nightly File Maintenance retention sweep deletes staged copies after ~11 days, so without a pickup in the next day or two they move to the Expired table above and are never delivered. Age is the oldest File'\''s. Click a row for the 10 most recent Files at risk.\n'

    n_qrows=0; q_files_sum=0; q_nm_sum=0
    printf 'TABLE\tPickup wait percentiles per partner\twide\tnofilter\n'
    printf 'HEAD\tPartner\tCollected Files\tMedian wait\tp95 wait\tMax wait\tWaited over 8 days\n'
    printf 'KIND\tptn\tnum\ttext\ttext\ttext\tnumwarn\n'
    # Q fields: 2=files 3=partner 4=median 5=p95 6=max 7=nearmiss
    while IFS='|' read -r _ qn qptn qmed qp95 qmax qnm; do
        [ -z "$qptn" ] && continue
        n_qrows=$((n_qrows + 1)); q_files_sum=$((q_files_sum + qn)); q_nm_sum=$((q_nm_sum + qnm))
        nm_cell=$qnm; [ "$qnm" -gt 0 ] && nm_cell="@{class=failed}$qnm"
        printf 'ROW\t%s\t%s\t%s\t%s\t%s\t%s\n' "$qptn" "$qn" "$qmed" "$qp95" "$qmax" "$nm_cell"
    done <<< "$(printf '%s\n' "$agg2" | grep '^Q|' | LC_ALL=C sort -t'|' -k2,2nr -k3,3)"
    if [ "$n_qrows" -eq 0 ]; then
        printf 'ROW\t@{colspan=6}No collected UC2 pickups in this data window.\n'
    fi
    printf 'TOTAL\tTotal (%s partners)\t@{class=num}%s\t\t\t\t@{class=num warn}%s\n' "$n_qrows" "$q_files_sum" "$q_nm_sum"
    printf 'NOTE\tCollected Files rolled up to the PARTNER (the site-wide UNION attribution: a File counts for every partner of its subscription plus the host-resolved one, so the partner counts can sum past the collected total). Median = the typical pickup, **p95** = the slow tail, and **Waited over 8 days** are the near-misses — collected, but within a couple of days of the ~11-day retention sweep. A partner with a fat p95 or near-misses is one pause away from the Expired table.\n'

    n_krows=0; k_files_sum=0
    printf 'TABLE\tPickup wait per week — busiest subscriptions\twide\tnofilter\n'
    printf 'HEAD\tSubscription\tWeek of\tCollected Files\tMedian wait\tAverage wait\n'
    printf 'KIND\tsite\ttext\tnum\ttext\ttext\n'
    # K fields: 2=rank 3=site 4=weekdate 5=files 6=median 7=avg
    while IFS='|' read -r _ _krank ksite kweek kn kmed kavg; do
        [ -z "$ksite" ] && continue
        n_krows=$((n_krows + 1)); k_files_sum=$((k_files_sum + kn))
        printf 'ROW\t%s\t%s\t%s\t%s\t%s\n' "$ksite" "$kweek" "$kn" "$kmed" "$kavg"
    done <<< "$(printf '%s\n' "$agg2" | grep '^K|')"
    if [ "$n_krows" -eq 0 ]; then
        printf 'ROW\t@{colspan=5}No collected UC2 pickups in this data window.\n'
    fi
    printf 'TOTAL\tTotal (%s subscription-weeks)\t\t@{class=num}%s\t\t\n' "$n_krows" "$k_files_sum"
    printf 'NOTE\tThe pickup wait per **staged week** (Monday-start) for the 10 subscriptions with the most collected Files, busiest first. The median shows the typical pickup; the **average** exposes a pause — a partner that stops collecting for days drags the average up long before the median moves, then both fall back once the backlog is cleared. Subscriptions whose staged Files were never collected have no pickup waits and are absent (the Waiting/Expired tables above carry them).\n'

    printf 'SUMMARY\tWaiting Files: %s across %s subscription(s)  |  Expired (deleted before pickup): %s  |  Oldest staged: %s  |  Collected pickups: %s  |  Peak backlog: %s  |  Expiring next: %s File(s) in %s subscription(s)  |  Waited over 8 days: %s  |  Dataset end: %s\n' \
        "$n_wait" "$n_wsites" "$n_exp" "${oldest_dt:--}" "$n_coll" "$bk_peak" "$e_files_sum" "$n_erows" "$q_nm_sum" "$last_dt"
    printf 'FOOT\tGenerated on %s from %s file(s)\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${#files[@]}"
} > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"

echo "Data written to $OUT ($n_wait waiting, $n_exp expired File(s), $n_coll collected pickup(s))." >&2
