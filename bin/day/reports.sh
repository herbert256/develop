#!/usr/bin/env bash
#
# bin/day/reports.sh — the PER-DAY page-spec writer: ONE .rpt per calendar day,
#
#   data/day/reports/YYYY-MM-DD.rpt
#
# rendered by bin/day/publish.sh into docs/day/<date>.html. ONE FILE, BOTH LOGS
# (2026-07): the transfer pass writes the header and its own lines, the server
# pass APPENDS its two KPIs, its problems and its facts to the same file — and
# writes the header itself on a day with no transfer data. The file carries
# EXACTLY what the page renders and nothing else: the per-area
# transfer-<date>/server-<date> specs, their table blocks (health by direction,
# protocol health, top-25 accounts, failure hotspots, largest files, newest
# failures, component health, top-25 message shapes, latest events), their
# non-hero chart cards and their unrendered KPIs are GONE — the publish read
# none of them.
#
# Page-spec line protocol (a subset of the dashboards format):
#   TITLE / H1                  page title + <h1> heading ("<Weekday> <date>")
#   NAVROW  label|href ...      prev/next day
#   KPI     val label sub accent href [delta]   the FIVE headline cards, in
#           display order and under their display labels: Transfer files /
#           Transfer error rate / Volume (transfer pass) then Server lines /
#           Server error rate (server pass)
#   CARD    title sub href span chart a1..a5    the HERO chart
#   CARDALT label title sub href span chart a1..a5   an ALTERNATE view of the
#           hero chart (one line per view): label = the switch-button text,
#           the rest = the CARD fields. The six shared slot views — Duration
#           (the CARD) / Files processed / Volume / Error % Files /
#           Transfer errors / PeSIT, the
#           same labels as the dashboards overview. publish.sh renders them
#           CSS-hidden next to the hero card under a button row; report.js
#           (setupHeroToggle) swaps them and remembers the pick across pages.
#   PROBLEM side href headline desc   one problem-list entry; side (transfer|
#           server) picks which of the two lists it lands in
#   FACT    text                one bullet of the "Remarkable facts" list
#
# Data: the transfer caches (_files.tsv, _transfers.tsv), both areas'
# topview.rpt (per-day figures already computed) and ONE single pass over the
# server parse cache (~7M rows) — never a per-day rescan. Day lists come from
# the topview.rpt files, so the Top view date links (../day/<date>.html)
# can never point at a missing page.
#
# Usage:
#   ./reports.sh    # rebuilds data/day/reports/*.rpt from scratch
#
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$ROOT"
source bin/fastawk.sh   # route unqualified `awk` to mawk when installed
source bin/env.sh       # resolve $AXWAY_ENV (acceptance|production, default acceptance)
DATA="data/$AXWAY_ENV"  # the env's data root

RPTDIR="$DATA/day/reports"
mkdir -p "$RPTDIR"

TF="$DATA/transfer/cache/_files.tsv"       # 1 coreid 2 outcome 3 account 4 date 5 time 6 sortkey 8 size 9 dur 11 file 12 site
TP="$DATA/transfer/cache/_transfers.tsv"   # 10 protocol 11 date 18 session_id 24 resubmitted
TT="$DATA/transfer/reports/topview.rpt"    # per-day Files/Transfers counts (col 5 = Files, >0 on data days)
SV="$DATA/server/reports/topview.rpt"      # per-day records/levels/components/first/last
SP="$DATA/server/cache/_parse.tsv"         # 1 date 2 time 3 level 4 component 5 message
SLF="$DATA/server/reports/went-kaput.rpt"   # ROW: 6 = "Latest issue" date+time (per-day "Problems this day" PROBLEM link)
NRD="$DATA/server/reports/no-remote-dir.rpt"   # table 2 "Per day": date, errors, subscriptions (per-day PROBLEM link)
NRF="$DATA/server/reports/no-remote-files.rpt" # table 2 "Per day": date, polls, subscriptions (per-day PROBLEM link)
UC3="$DATA/server/reports/uc3-status.rpt"      # "server - error" rows: newest failure logline date (per-day PROBLEM link)
ANOM="$DATA/transfer/reports/anomalies.rpt"    # ROW: 2 = Date, in BOTH tables (per-day PROBLEM link, offered only on flagged days)
GTR="$DATA/transfer/reports/from-green-to-red.rpt"   # ROW: 4 = "Went red on" date+time (per-day PROBLEM link)
ORED="$DATA/transfer/reports/only-red.rpt"           # ROW: 6 = "First failure" date+time (per-day PROBLEM link)
PSLOTS="$DATA/server/reports/pesit-slots.tsv"   # pesit.sh's 30-min direction split (date slot out in) — the PeSIT hero view
SUBPF="$DATA/flow-manager/xref/_subscriptions-partners.tsv"   # subscription -> partner(s), for the Top-5 partner UNION

# Freshness: this writer has no area lib to borrow skip_if_fresh from, so the
# same test lives here. The output is a WHOLE DIRECTORY of per-day .rpt written
# in one run, so the newest of them stands for the set — rebuild when any input
# (or this script) is newer than the OLDEST output, which is the one a partial
# previous run would have left behind.
oldest_rpt=$(ls -tr "$RPTDIR"/*.rpt 2>/dev/null | head -1 || true)
if [ -n "$oldest_rpt" ]; then
    stale=0
    for dep in "${BASH_SOURCE[0]}" "$TF" "$TP" "$TT" "$SV" "$SP" "$SLF" "$NRD" "$NRF" "$UC3" "$ANOM" "$GTR" "$ORED" "$PSLOTS" "$SUBPF"; do
        if [ -f "$dep" ] && [ "$dep" -nt "$oldest_rpt" ]; then stale=1; break; fi
    done
    if [ "$stale" = 0 ]; then
        echo "  data/$AXWAY_ENV/day/reports/ is up to date; skipping." >&2
        exit 0
    fi
fi
# A killed run must not leave a half-written day set that the oldest-rpt test
# above would then trust (BOTH passes below append across the whole file set,
# so single-file tmp+mv cannot cover it). The passes write into a STAGING dir
# and the two-rename swap at the bottom publishes the complete set — $RPTDIR
# is only ever the old complete set, empty (rebuild), or the new complete set,
# never a mix. Leftover .new/.old dirs from a killed run are swept here.
RPTNEW="$RPTDIR.new"
rm -rf "$RPTNEW" "$RPTDIR.old"
mkdir -p "$RPTNEW"

# The two full-period SUBSCRIPTION verdicts of the "Subscriptions with
# problems" set, bucketed on the day the state CHANGED — the flip moment
# (from-green-to-red) and the first failure of a never-green flow (only-red)
# — so each lands on the day page of the day it happened, exactly like the
# server side's went-kaput. Both reports are `nofilter` (full-period
# semantics), so their PROBLEM links carry no ?axway_date=. Empty when the
# report is absent (env split) or holds only its "(none)" placeholder row.
daycount() {   # $1 rpt  $2 ROW field holding "ccyy-mm-dd hh:mm:ss" -> "date:count …"
    [ -f "$1" ] || return 0
    awk -F'\t' -v f="$2" '$1=="ROW"{ d=substr($f,1,10); if (d ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$/) c[d]++ }
                          END{ for (k in c) printf "%s:%s ", k, c[k] }' "$1"
}
gtrc=$(daycount "$GTR" 4)
oredc=$(daycount "$ORED" 6)
# The Anomaly-scan entry is offered ONLY on the days the scan actually flagged
# (2026-08 — it used to sit on every day page as the always-there entry). Both
# anomalies tables are counted, the daily and the hourly, since either one is a
# reason to look. daycount cannot serve here: the Date cell carries an
# @{href=…} attribute on every linked row and none on the absent-day Silence
# rows, so it is stripped before the date is read.
anomcount() {   # $1 rpt -> "date:count …"
    [ -f "$1" ] || return 0
    awk -F'\t' '$1=="ROW" { d=$2; sub(/^@\{[^}]*\}/, "", d); d=substr(d, 1, 10)
                            if (d ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$/) c[d]++ }
                END { for (k in c) printf "%s:%s ", k, c[k] }' "$1"
}
anomc=$(anomcount "$ANOM")

# The day lists (data days only — the topview gap rows carry zero counts and
# get no page). The date cell may carry a leading @{href=...} attribute once
# the topviews link here — strip it before reading the date.
tdays=""
[ -f "$TT" ] && tdays=$(awk -F'\t' '$1=="ROW" { d=$2; sub(/^@\{[^}]*\}/,"",d); if ($5+0 > 0) print substr(d,1,10) }' "$TT" | LC_ALL=C sort -u | tr '\n' ' ')
sdays=""
[ -f "$SV" ] && sdays=$(awk -F'\t' '$1=="ROW" { d=$2; sub(/^@\{[^}]*\}/,"",d); if ($3+0 > 0) print substr(d,1,10) }' "$SV" | LC_ALL=C sort -u | tr '\n' ' ')

# ---------------------------------------------------------------------------
# The TRANSFER pass — it CREATES the day .rpt. Pass 1 = _files.tsv (per-day
# counts, the hero slot series, the problem signals and the figures behind the
# remarkable facts); pass 2 = _transfers.tsv (the dominant protocol and the
# resubmitted legs). END writes the header, the three transfer KPIs, the
# transfer problem list, the hero card + its alternates and the facts.
# ---------------------------------------------------------------------------
if [ -f "$TF" ] && [ -n "$tdays" ]; then
awk -F'\t' -v OFS='\t' -v outdir="$RPTNEW" -v tdays="$tdays" -v sdays="$sdays" -v PS="$PSLOTS" \
    -v gtrc="$gtrc" -v oredc="$oredc" -v anomc="$anomc" -v SUBPF="$SUBPF" '
    function human(b,   u,i,v){ split("B KB MB GB TB PB",u," "); i=1; v=b+0; while(v>=1024&&i<6){v/=1024;i++} return (i==1)?sprintf("%d %s",v,u[i]):sprintf("%.2f %s",v,u[i]) }
    function humandur(ms,   s,m,h){ ms+=0; if(ms<1000)return int(ms) "ms"; s=int(ms/1000); if(s<60)return s "s"; m=int(s/60); s=s%60; if(m<60)return m "m " s "s"; h=int(m/60); m=m%60; return h "h " m "m" }
    function jdn(y,m,d,  a){ a=int((14-m)/12); y=y+4800-a; m=m+12*a-3; return d+int((153*m+2)/5)+365*y+int(y/4)-int(y/100)+int(y/400)-32045 }
    function fromjdn(j,   a,b,c,dd,e,mm,day,mon,yr) { a=j+32044; b=int((4*a+3)/146097); c=a-int(146097*b/4); dd=int((4*c+3)/1461); e=c-int(1461*dd/4); mm=int((5*e+2)/153); day=e-int((153*mm+2)/5)+1; mon=mm+3-12*int(mm/10); yr=100*b+dd-4800+int(mm/10); return sprintf("%04d-%02d-%02d", yr, mon, day) }
    function wdname(d,   p){ split(d,p,"-"); return WD[jdn(p[1]+0,p[2]+0,p[3]+0) % 7] }
    function pctd(v, avg,   p) { if (avg <= 0) return ""; p = (v - avg) * 100 / avg; if (p > -0.5 && p < 0.5) return "0%"; return sprintf("%+.0f%%", p) }
    # unpack a "date:count …" string (daycount) into a per-day array
    # ONE File into ONE hero-slot resolution (15/30/60 minutes). The three are
    # aggregated from the raw Files, never re-bucketed from each other:
    # percentiles do not merge (a median of medians is not a median) and the
    # error rate is a ratio, not a sum. Fields are the current record.
    function slotbump(r, d, s,   k) { k = r SUBSEP d SUBSEP s
        SC[k]++                                         # all Files (the rate denominator)
        if ($2 == "Failed" || $2 == "Expired") SF[k]++  # Error Files
        else if ($9 + 0 > 0) SDL[k] = SDL[k] " " $9     # OK durations (the percentile list)
        SVV[k] += $8 }
    # ---- the nine Top-5 tables ----------------------------------------------
    # Per DAY and per entity kind (P partner / A account / S subscription), the
    # five biggest by Files, by Volume and by Errors. Partner attribution is the
    # site-wide UNION (col 20 ∪ the subscription\047s configured partners), the same
    # rule the entity reports use — so the "See more" page shows the same figures
    # for the same day.
    function tally(kind, nm, d,   k) {
        if (nm == "" || d == "") return
        k = kind SUBSEP d SUBSEP nm
        if (!(k in FC)) NL[kind SUBSEP d] = NL[kind SUBSEP d] US nm   # first sighting: join the day\047s name list
        FC[k]++
        VC[k] += $8
        if ($2 == "Failed" || $2 == "Expired") EC[k]++ }
    # the five biggest of ONE metric as "name US value US …". Bounded insert, so
    # no sort; ties break on NAME so the output can never depend on awk hash
    # order (the name list itself is in first-sighting order, also deterministic).
    function top5(A, kind, d,   nn, NM, i, j, nm, v, c, TV, TN, s) {
        c = 0
        nn = split(NL[kind SUBSEP d], NM, US)
        for (i = 1; i <= nn; i++) {
            nm = NM[i]; if (nm == "") continue
            v = A[kind SUBSEP d SUBSEP nm] + 0
            if (v <= 0) continue
            j = c
            while (j >= 1 && (TV[j] < v || (TV[j] == v && TN[j] > nm))) { TV[j+1] = TV[j]; TN[j+1] = TN[j]; j-- }
            TV[j+1] = v; TN[j+1] = nm
            c++; if (c > 5) c = 5
        }
        s = ""
        for (i = 1; i <= c; i++) s = s (s == "" ? "" : US) TN[i] US TV[i]
        return s }
    # the same, with the values humanised as bytes (the Volume tables)
    function top5b(A, kind, d,   raw, nn, Z, i, s) {
        raw = top5(A, kind, d); if (raw == "") return ""
        nn = split(raw, Z, US); s = ""
        for (i = 1; i <= nn; i += 2) s = s (s == "" ? "" : US) Z[i] US human(Z[i+1])
        return s }
    function dcload(s, A,   np, t, i, p) { np = split(s, t, " ")
        for (i = 1; i <= np; i++) { if (t[i] == "") continue
            p = index(t[i], ":"); if (p > 1) A[substr(t[i], 1, p - 1)] = substr(t[i], p + 1) } }
    # the PeSIT 30-min direction sidecar (pesit.sh) — a missing file is a
    # no-op (getline returns < 0), leaving PO/PI empty = an all-zero series
    BEGIN { US = sprintf("%c", 31)
        # subscription -> its configured partner(s); a missing map just leaves the
        # partner tables to col 20 alone (getline returns < 0, so no error)
        while ((getline sl < SUBPF) > 0) { np2 = split(sl, sz, "\t")
            if (np2 >= 2 && sz[1] != "" && sz[2] != "") SUBP[toupper(sz[1])] = SUBP[toupper(sz[1])] US sz[2] }
        close(SUBPF)
        if (PS != "") { while ((getline pl < PS) > 0) { n = split(pl, pz, "\t"); if (n >= 4) { PO[pz[1], pz[2]+0] = pz[3]+0; PI[pz[1], pz[2]+0] = pz[4]+0 } } close(PS) }
        dcload(gtrc, GTRC); dcload(oredc, OREDC); dcload(anomc, ANOMC) }
    FNR == 1 { fno++ }
    fno == 1 {   # _files.tsv
        d = $4; if (d == "") next
        C[d]++; V[d] += $8; tC++; tV += $8
        if (FIRSTK[d] == "" || $6 < FIRSTK[d]) { FIRSTK[d] = $6; FIRSTT[d] = $5 }
        if (LASTK[d] == "" || $6 > LASTK[d]) { LASTK[d] = $6; LASTT[d] = $5 }
        if ($16 == "in") IN[d]++; else if ($16 == "out") OUT[d]++          # per-file CONNECTION side (col 16, renamed from direction)
        if ($9 + 0 > MAXD[d] + 0) { MAXD[d] = $9 + 0; MAXDA[d] = $3; MAXDO[d] = $2 }   # longest transfer (dur_ms)
        if ($8 + 0 == 0) Z[d]++           # zero-byte files
        if ($10 + 0 > MAXR[d] + 0) { MAXR[d] = $10 + 0; MAXRF[d] = $11; MAXRA[d] = $3 }   # most legs (retries) in one transfer
        if ($10 + 0 == 1) PIR[d]++   # single-leg (pirate) transfers -> Problems this day
        # UC2 staged files, by the day they were STAGED -> Problems this day
        if ($2 == "Waiting") WAI[d]++; else if ($2 == "Expired") XPD[d]++
        if ($12 != "") { pf[d SUBSEP $12]++; if ($2 == "Failed" || $2 == "Expired") pff[d SUBSEP $12]++ }   # per-subscription totals/fails
        if ($2 != "Failed" && $2 != "Expired") P[d]++; else F[d]++
        h = substr($5, 1, 2)
        if (h ~ /^[0-9][0-9]$/) {
            HH[d, h]++
            # the hero chart 30-MINUTE slot accumulators (the shared views —
            # Duration/Files processed/Error % Files/Volume; PeSIT comes from
            # the pesit-slots.tsv sidecar, Transfer errors from the
            # _transfers.tsv pass below): slot 0-47 by start time
            mi = h * 60 + (substr($5, 4, 2) + 0)               # minute of the day
            slotbump(15, d, int(mi / 15)); slotbump(30, d, int(mi / 30)); slotbump(60, d, h + 0)
        }
        # the six Top-5 tables: subscription (col 12) and the partner UNION
        # (col 20 ∪ the subscription\047s configured partners — a both-partner File
        # carries an EMPTY col 20, the parse abstains there)
        tally("S", $12, d)
        tally("P", $20, d)
        if ($12 != "" && (toupper($12) in SUBP)) {
            npt = split(substr(SUBP[toupper($12)], 2), PTZ, US)
            for (ipt = 1; ipt <= npt; ipt++) if (PTZ[ipt] != $20) tally("P", PTZ[ipt], d)
        }
        a = $3
        if (a != "") {
            ac[d, a]++
            if (amin[a] == "" || d < amin[a]) amin[a] = d
            if (amax[a] == "" || d > amax[a]) amax[a] = d
        }
        # the largest file of the day (the "Largest file" remarkable fact)
        if (bfnm[d] == "" || $8 + 0 > bfsz[d] + 0) { bfsz[d] = $8; bfnm[d] = $11; bfac[d] = $3 }
        next
    }
    fno == 2 {   # _transfers.tsv
        d = $11; if (d == "") next
        if ($10 != "") PRC[d, $10]++          # the dominant-protocol fact
        if ($22 == "true") RSUB[d]++
        # the Transfer errors hero view: raw legs whose Status is Failed or
        # Failed Subtransmission, per hero slot (same key layout as slotbump)
        if (($3 == "Failed" || $3 == "Failed Subtransmission") && $12 ~ /^[0-9][0-9]:/) {
            emi = (substr($12, 1, 2) + 0) * 60 + (substr($12, 4, 2) + 0)
            SE[15 SUBSEP d SUBSEP int(emi / 15)]++
            SE[30 SUBSEP d SUBSEP int(emi / 30)]++
            SE[60 SUBSEP d SUBSEP int(emi / 60)]++
        }
        next
    }
    END {
        split("Monday Tuesday Wednesday Thursday Friday Saturday Sunday", WD0, " ")
        for (i = 0; i < 7; i++) WD[i] = WD0[i + 1]
        nd = split(tdays, D, " ")
        ns = split(sdays, SD, " "); for (i = 1; i <= ns; i++) issrv[SD[i]] = 1
        # period figures for the narrative
        avg = nd > 0 ? tC / nd : 0
        avgV = nd > 0 ? tV / nd : 0
        prate = tC > 0 ? tF() * 100 / tC : 0
        # per-weekday means for the KPI deltas (average over every same-weekday day in the window, this day included)
        for (x = 1; x <= nd; x++) { d = D[x]; wd = wdname(d); wdc[wd]++
            aFiles[wd] += C[d] + 0
            aErrF[wd]  += F[d] + 0      # pooled error rate = ΣErrors / ΣFiles (not the mean of daily rates, which low-volume days skew)
            aVol[wd]   += V[d] + 0
        }
        # worst fully-failed flow per day (a subscription with >=10 Files, every one failed)
        for (k in pf) { split(k, kv, SUBSEP); dd = kv[1]; pr = kv[2]
            if (pf[k] >= 10 && pff[k] + 0 == pf[k]) {
                brkc[dd]++
                if (pf[k] > brkm[dd] + 0 || (pf[k] == brkm[dd] + 0 && pr < brkn[dd])) { brkm[dd] = pf[k]; brkn[dd] = pr }
            }
        }
        for (x = 1; x <= nd; x++) {
            d = D[x]
            out = outdir "/" d ".rpt"
            q = "?axway_date=" d      # the linked reports open narrowed to this day (report.js)
            rank = 1; for (y = 1; y <= nd; y++) if (C[D[y]] + 0 > C[d] + 0) rank++
            erate = C[d] > 0 ? F[d] * 100 / C[d] : 0
            # ---- header -------------------------------------------------
            print "TITLE\tDay — " d > out
            print "H1\t" wdname(d) " " d > out
            # ---- nav row ------------------------------------------------
            # nav row: exactly two entries — prev then next; empty href = inactive
            if (x > 1)  nav = "\t← " D[x-1] "|" D[x-1] ".html"
            else        nav = "\t← Previous day|"
            if (x < nd) nav = nav "\t" D[x+1] " →|" D[x+1] ".html"
            else        nav = nav "\tNext day →|"
            print "NAVROW" nav > out
            # ---- remarkable facts ----------------------------------------
            # per-day concentration figures used by several facts below
            vrank = 1; for (y = 1; y <= nd; y++) if (V[D[y]] + 0 > V[d] + 0) vrank++
            ph = ""; phc = 0
            for (h = 0; h < 24; h++) { hh = sprintf("%02d", h); if (HH[d, hh] + 0 > phc) { phc = HH[d, hh] + 0; ph = hh } }
            tan = ""; tac = 0                              # busiest single account that day
            for (a in ac) { split(a, aa, SUBSEP); if (aa[1] != d) continue
                if (ac[d, aa[2]] + 0 > tac || (ac[d, aa[2]] + 0 == tac && aa[2] < tan)) { tac = ac[d, aa[2]] + 0; tan = aa[2] } }
            dprn = ""; dprc = 0; dprt = 0                  # dominant protocol (transfer legs)
            for (pp in PRC) { split(pp, qq, SUBSEP); if (qq[1] != d) continue; dprt += PRC[pp]
                if (PRC[pp] > dprc || (PRC[pp] == dprc && qq[2] < dprn)) { dprc = PRC[pp]; dprn = qq[2] } }
            io = IN[d] + OUT[d]

            if (rank == 1 && nd > 1 && avg > 0)
                printf "FACT\tThe **busiest day** of the window — %.1f× the daily average of %d Files.\n", C[d]/avg, avg >> out
            if (rank == nd && nd > 1)
                printf "FACT\tThe **quietest day** of the window.\n" >> out
            if (vrank == 1 && nd > 1 && avgV > 0 && V[d] >= 1.5 * avgV)
                printf "FACT\tThe **heaviest day** by volume — **%s** moved, %.1f× the daily average.\n", human(V[d]), V[d]/avgV >> out
            if (C[d] >= 20 && prate > 0 && erate >= 2 * prate && F[d] >= 10)
                printf "FACT\tError rate **%.1f%%** — %.1f× the period average of %.1f%%.\n", erate, erate/prate, prate >> out
            if (F[d] == 0 && C[d] > 0)
                printf "FACT\tA **clean day**: every one of the %d Files was delivered OK.\n", C[d] >> out
            if (brkn[d] != "")
                printf "FACT\tA **broken flow** — every one of **%s**'"'"'s %d Files failed%s.\n", brkn[d], brkm[d], (brkc[d] > 1 ? sprintf(" (and %d other flow%s failed completely)", brkc[d]-1, (brkc[d]-1 == 1 ? "" : "s")) : "") >> out
            if (Z[d] + 0 >= 20)
                printf "FACT\t**%d zero-byte Files** — empty transfers (failed or placeholder uploads).\n", Z[d] >> out
            if (C[d] >= 50 && tac >= 0.50 * C[d])
                printf "FACT\tOne account, **%s**, drove **%.0f%%** of the day'"'"'s Files (%d of %d).\n", tan, tac * 100 / C[d], tac, C[d] >> out
            if (C[d] >= 50 && phc >= 0.50 * C[d])
                printf "FACT\t**%.0f%%** of the day'"'"'s Files arrived in a single hour, **%s:00** (%d Files).\n", phc * 100 / C[d], ph, phc >> out
            if (io >= 50 && IN[d] >= 0.75 * io)
                printf "FACT\tTraffic was overwhelmingly **inbound** — %.0f%% of Files were partners sending to us.\n", IN[d] * 100 / io >> out
            else if (io >= 50 && OUT[d] >= 0.75 * io)
                printf "FACT\tTraffic was overwhelmingly **outbound** — %.0f%% of Files were us sending to partners.\n", OUT[d] * 100 / io >> out
            if (dprt >= 50 && dprc >= 0.70 * dprt)
                printf "FACT\t**%s** carried **%.0f%%** of the day'"'"'s transfer legs.\n", toupper(dprn), dprc * 100 / dprt >> out
            if (MAXD[d] + 0 >= 1800000)
                printf "FACT\tLongest-running transfer took **%s** — account %s (it %s).\n", humandur(MAXD[d]), MAXDA[d], (MAXDO[d] != "Failed" && MAXDO[d] != "Expired" ? "succeeded" : "failed") >> out
            if (MAXR[d] + 0 >= 15)
                printf "FACT\tOne transfer logged **%d** legs — repeated retries of %s (account %s).\n", MAXR[d], MAXRF[d], MAXRA[d] >> out
            if (bfnm[d] != "")
                printf "FACT\tLargest file: **%s** (**%s**, account %s).\n", bfnm[d], human(bfsz[d]), bfac[d] >> out
            nnew = pickacc(d, amin, L6)
            if (nnew > 0 && d != D[1])
                printf "FACT\t**%d account(s) first seen** on this day: %s%s.\n", nnew, joins(L6, nnew), (nnew > 6 ? ", …" : "") >> out
            ngone = pickacc(d, amax, L6)
            if (ngone > 0 && d != D[nd])
                printf "FACT\t**%d account(s) went quiet** after this day (no transfers since): %s%s.\n", ngone, joins(L6, ngone), (ngone > 6 ? ", …" : "") >> out
            if (RSUB[d] + 0 >= 10)
                printf "FACT\t**%d resubmitted transfer legs** — someone (or something) was retrying.\n", RSUB[d] >> out
            wd = wdname(d)
            if ((wd == "Saturday" || wd == "Sunday") && C[d] > 0)
                printf "FACT\tWeekend activity: %d Files on a %s.\n", C[d], wd >> out
            # ---- KPI cards ------------------------------------------------
            # exactly the three transfer-side cards the day page shows, under
            # the labels it renders (the server pass appends its two)
            cov = (FIRSTT[d] != "" && LASTT[d] != "") ? " · " substr(FIRSTT[d],1,8) "–" substr(LASTT[d],1,8) : ""
            printf "KPI\t%d\tTransfer files\tlogical transfers%s\tblue\t../transfer/activity-per-day.html" q "\t%s\n", C[d], cov, pctd(C[d], wdc[wd] ? aFiles[wd]/wdc[wd] : 0) >> out
            printf "KPI\t%.1f%%\tTransfer error rate\t%d Error / %d OK\tred\t../transfer/failure-rate-days.html" q "\t%s\n", erate, F[d]+0, P[d]+0, pctd(erate, aFiles[wd] ? aErrF[wd]*100/aFiles[wd] : 0) >> out
            printf "KPI\t%s\tVolume\taverage %s per File\tgreen\t../transfer/volume-per-day.html" q "\t%s\n", human(V[d]), human(C[d] ? V[d]/C[d] : 0), pctd(V[d], wdc[wd] ? aVol[wd]/wdc[wd] : 0) >> out
            # ---- problem links ---------------------------------------------
            # PROBLEM<TAB>side<TAB>href<TAB>headline<TAB>desc — side (transfer|
            # server) picks the list on the combined day page, so both passes
            # write into the ONE day .rpt. Together with went-kaput on the
            # server side these cover the whole analyses "Subscriptions with
            # problems" set: one-legged (pirates), from green to red, only red,
            # Waiting and Expired — each on the day it happened. The three
            # subscription verdicts are full-period reports (`nofilter`), so
            # their links carry no ?axway_date=; the file counts do.
            if (F[d] + 0 > 0)
                printf "PROBLEM\ttransfer\t../transfer/failure-rate-days.html" q "\tTransfer failures\t**%d Error / %d OK** — **%.1f%%** error rate; breakdown by account, subscription and hour\n", F[d], P[d]+0, erate >> out
            if (PIR[d] + 0 > 0)
                printf "PROBLEM\ttransfer\t../transfer/pirates-details.html" q "\tPirates (single-leg transfers)\t**%d** logical transfer(s) with only one leg — one-sided, incomplete crossings that never completed\n", PIR[d] >> out
            if (GTRC[d] + 0 > 0)
                printf "PROBLEM\ttransfer\t../transfer/from-green-to-red.html\tFrom green to red\t**%d** subscription(s) went red this day — they delivered OK before and have not recovered since\n", GTRC[d] >> out
            if (OREDC[d] + 0 > 0)
                printf "PROBLEM\ttransfer\t../transfer/only-red.html\tOnly red\t**%d** subscription(s) failed for the first time this day and have never delivered an OK File\n", OREDC[d] >> out
            if (WAI[d] + 0 > 0)
                printf "PROBLEM\ttransfer\t../transfer/waiting.html\tWaiting for pickup\t**%d** File(s) staged this day are still waiting to be collected by the partner\n", WAI[d] >> out
            if (XPD[d] + 0 > 0)
                printf "PROBLEM\ttransfer\t../transfer/expired.html\tExpired before pickup\t**%d** File(s) staged this day were deleted by the retention sweep before the partner ever collected them\n", XPD[d] >> out
            # only on days the scan flagged something — a clean day says so by
            # leaving the entry out, instead of offering a link to nothing
            if (ANOMC[d] + 0 > 0)
                printf "PROBLEM\ttransfer\t../transfer/anomalies.html" q "\tAnomaly scan\t**%d** finding(s) this day — spikes, silence and volume shifts vs the typical hour and the typical day\n", ANOMC[d] >> out
            # ---- chart cards ----------------------------------------------
            # the hero + alternates: the SIX shared slot views at 30-minute
            # resolution — labels EXACTLY as on the dashboards overview
            # (button 0 "Duration" hardcoded in bin/day/publish.sh), so the
            # picked view carries between the two pages. Gap rules mirror the
            # overview: Duration/Error % Files gap on an empty slot, Files
            # processed/Volume/Transfer errors real zeros. No slot links
            # (this IS the day).
            # THREE resolutions per view (2026-07): 15 / 30 / 60 minutes.
            # 30 min stays the BASE (the visible default and the label of the
            # card titles); the other two ride along as "<minutes>:<series>"
            # extras that bin/day/publish.sh turns into data-iv15/data-iv60.
            # PeSIT has no 15-minute variant — its sidecar IS 30-minute — so
            # that card simply carries fewer intervals and slotchart.js falls
            # back to the base for the missing one.
            for (ri = 1; ri <= 3; ri++) {
                rr = (ri == 1) ? 15 : (ri == 2) ? 30 : 60
                nsl = 1440 / rr
                sdur = ""; scnt = ""; srate = ""; svol = ""; spes = ""; serr = ""
                for (s = 0; s < nsl; s++) {
                    # NO colon in the label — ":" is the slots DATA field separator
                    lab = sprintf("%02dh%02d", int(s * rr / 60), (s * rr) % 60); sep = (s ? "|" : "")
                    kk = rr SUBSEP d SUBSEP s
                    if (SDL[kk] != "") {
                        # NOTE the q-prefixed locals: this block sits INSIDE the
                        # END per-day loop, whose counter is x — plain x/y/k/w
                        # here would clobber it (the 2026-07 infinite-loop trap)
                        qk = split(SDL[kk], sdla, " ")
                        for (qx = 2; qx <= qk; qx++) { qw = sdla[qx] + 0; qy = qx - 1; while (qy >= 1 && sdla[qy] + 0 > qw) { sdla[qy+1] = sdla[qy]; qy-- } sdla[qy+1] = qw }
                        i1 = int(0.50 * qk + 0.9999); if (i1 < 1) i1 = 1
                        i2 = int(0.90 * qk + 0.9999); if (i2 < 1) i2 = 1
                        i3 = int(0.98 * qk + 0.9999); if (i3 < 1) i3 = 1
                        sdur = sdur sep lab ":" sdla[i1] ":" sdla[i2] ":" sdla[i3] ":" d
                    } else
                        sdur = sdur sep lab "::::" d
                    scnt = scnt sep lab ":" (SC[kk] - SF[kk] + 0) ":" d
                    if (SC[kk] + 0 > 0) srate = srate sep lab ":" sprintf("%.1f", (SF[kk] + 0) * 100 / SC[kk]) ":" d
                    else                srate = srate sep lab "::" d
                    svol = svol sep lab ":" (SVV[kk] + 0) ":" d
                    serr = serr sep lab ":" (SE[kk] + 0) ":" d
                    # PeSIT: the sidecar is 30-minute, so 15 min is skipped and
                    # 60 min sums the two half hours
                    if (rr == 30)      spes = spes sep lab ":" (PO[d, s] + 0) ":" (PI[d, s] + 0) ":" d
                    else if (rr == 60) spes = spes sep lab ":" (PO[d, s*2] + PO[d, s*2+1] + 0) ":" (PI[d, s*2] + PI[d, s*2+1] + 0) ":" d
                }
                DURS[rr] = sdur; CNTS[rr] = scnt; RATES[rr] = srate; VOLS[rr] = svol; PESS[rr] = spes; ERRS[rr] = serr
            }
            printf "CARD\tFile duration percentiles per slot\t%s · P50 dark green, P90 orange, P98 dark red — each band tops out at that percentile of the OK File durations in that slot\t../transfer/duration.html" q "\tspan2\tslots\tdur\t%s\t\t15:%s\t60:%s\n", d, DURS[30], DURS[15], DURS[60] >> out
            # Files processed is the ONE day card that fills a3 (the plot link):
            # clicking the graph opens the SUBSCRIPTIONS behind this day rather
            # than the per-day report the title links. The other slot cards leave
            # a3 empty and fall back to their own href (bin/day/publish.sh).
            # ?axway_date beats the Entities pages datereset, so the view opens
            # narrowed to this day — the same target the Top-5 "See more" links use.
            printf "CARDALT\tFiles processed\tFiles processed per slot\t%s · OK Files (Processed + Waiting) per slot, by start time — the graph opens the subscriptions of this day\t../transfer/activity-per-day.html" q "\tspan2\tslots\tcount\t%s\t../transfer/entities/subscription-all.html" q "\t15:%s\t60:%s\n", d, CNTS[30], CNTS[15], CNTS[60] >> out
            printf "CARDALT\tVolume\tVolume per slot\t%s · bytes moved per slot, by start time\t../transfer/volume-per-day.html" q "\tspan2\tslots\tbytes\t%s\t\t15:%s\t60:%s\n", d, VOLS[30], VOLS[15], VOLS[60] >> out
            printf "CARDALT\tError %% Files\tTransfer error rate per slot\t%s · per slot, the %% of its Files that Failed or Expired — a slot with no Files shows a gap\t../transfer/failure-rate-days.html" q "\tspan2\tslots\trate\t%s\t\t15:%s\t60:%s\n", d, RATES[30], RATES[15], RATES[60] >> out
            printf "CARDALT\tTransfer errors\tTransfer errors per slot\t%s · Transfers (raw log records) whose Status is Failed or Failed Subtransmission, per slot — one File can contribute several failed legs; a quiet slot is a real zero\t../transfer/failure-heatmap.html" q "\tspan2\tslots\terrs\t%s\t\t15:%s\t60:%s\n", d, ERRS[30], ERRS[15], ERRS[60] >> out
            # ---- the six Top-5 tables --------------------------------------
            # TOP<TAB>kind<TAB>title<TAB>unit<TAB>href<TAB>name US value US …
            # Emitted one row per METRIC (Files, Volume, Errors), two columns per
            # row — PARTNERS then SUBSCRIPTIONS — which is the reading order of
            # the 2-column .daytop grid. The kind field also fixes each card to
            # its column in CSS, so a metric with nothing on one side leaves a
            # HOLE rather than shifting the other side across.
            # The "See more" href opens the matching Transfer > Entities view
            # NARROWED TO THIS DAY and sorted descending on the same column —
            # ?axway_date beats the page\047s data-date-reset, and the Entities
            # layout is Name 0 · Direction 1 · Files 2 · Volume 3 · OK 4 · Error 5.
            for (tm = 1; tm <= 3; tm++) {
                tmet = (tm == 1) ? "Files" : (tm == 2) ? "Volume" : "Errors"
                tcol = (tm == 1) ? 2 : (tm == 2) ? 3 : 5
                for (tk = 1; tk <= 2; tk++) {
                    tkind = (tk == 1) ? "P" : "S"
                    tname = (tk == 1) ? "partners" : "subscriptions"
                    tpage = (tk == 1) ? "partner" : "subscription"
                    trows = (tm == 1) ? top5(FC, tkind, d) : (tm == 2) ? top5b(VC, tkind, d) : top5(EC, tkind, d)
                    if (trows == "") continue
                    printf "TOP\t%s\tTop 5 %s by %s\t%s\t../transfer/entities/%s-all.html?axway_date=%s&axway_sort=%d:-1\t%s\n", \
                        tkind, tname, tmet, tmet, tpage, d, tcol, trows >> out
                }
            }
            if (issrv[d]) printf "CARDALT\tPeSIT\tPeSIT problems per slot\t%s · ST \342\206\222 CFT (red) vs CFT \342\206\222 ST (purple) problem lines on the CFT link\t../server/capacity-pesit-per-day.html" q "\tspan2\tslots\tpesit\t%s\t\t\t60:%s\n", d, PESS[30], PESS[60] >> out
            close(out)
        }
    }
    function tF(   y, s) { s = 0; for (y = 1; y <= nd; y++) s += F[D[y]] + 0; return s }
    # accounts whose MARK[account] == d (first/last day), name-sorted into
    # L[1..6] by bounded insertion — independent of hash iteration order
    function pickacc(d, MARK, L,   a, n, i, j) {
        n = 0
        for (i = 1; i <= 6; i++) L[i] = ""
        for (a in MARK) {
            if (MARK[a] != d || !(ac[d, a] > 0)) continue
            n++
            for (i = 1; i <= 6; i++) {
                if (L[i] == "" || a < L[i]) {
                    for (j = 6; j > i; j--) L[j] = L[j-1]
                    L[i] = a
                    break
                }
            }
        }
        return n
    }
    function joins(L, n,   i, r, m) {
        m = (n < 6) ? n : 6
        r = ""
        for (i = 1; i <= m && L[i] != ""; i++) r = r (r == "" ? "" : ", ") L[i]
        return r
    }
' "$TF" "$TP"
fi

# ---------------------------------------------------------------------------
# The SERVER pass — it APPENDS to the day .rpt the transfer pass created (and
# writes the header itself on a server-only day). topview.rpt supplies the
# per-day totals; ONE pass over the parse cache adds the per-hour records and
# errors, the problem signals and the dominant ERROR message shape (digits
# folded to N, picked count desc / shape asc so it never depends on hash
# iteration order).
# ---------------------------------------------------------------------------
# Per-day count of subscriptions whose LATEST post-transfer issue (the
# went-kaput report's ROW col 6 = "date time") falls on that day
# — surfaced as a "Problems this day" PROBLEM link. Empty when the report is
# absent (env split) or has no rows (the "(none)" placeholder has no date).
# The no-remote-dir per-day figures (its SECOND table: Date, Errors,
# Subscriptions) — the missing-remote-directory errors of that day, surfaced as
# a "Server log problems this day" PROBLEM link. The report lists only OPEN
# problems, so a day whose directories were fixed later contributes nothing.
nrdc=""
if [ -f "$NRD" ]; then
    nrdc=$(awk -F'\t' '$1=="TABLE"{t++} $1=="ROW" && t==2 && $2 ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$/ { printf "%s:%s:%s ", $2, $3, $4 }' "$NRD")
fi
# the same, for the always-empty UC3 pollers (no-remote-files "Per day":
# date, polls, subscriptions)
nrfc=""
if [ -f "$NRF" ]; then
    nrfc=$(awk -F'\t' '$1=="TABLE"{t++} $1=="ROW" && t==2 && $2 ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$/ { printf "%s:%s:%s ", $2, $3, $4 }' "$NRF")
fi
slfc=""
if [ -f "$SLF" ]; then
    slfc=$(awk -F'\t' '$1=="ROW"{ d=substr($6,1,10); if (d ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$/) c[d]++ } END{ for (k in c) printf "%s:%s ", k, c[k] }' "$SLF")
fi
# Per-day count of UC3 subscriptions in "server - error" (the scheduled poll
# itself fails server-side — the Failing polls box), bucketed by the date of
# the row's NEWEST failure line: the @data:loglines payload carries the
# failures newest-first, so entry 1 is the latest — the same instant the boxes
# page reads. A "server - error" row always has one (its status IS decided by
# a failure line); a row without stays unbucketed rather than guessing.
u3c=""
if [ -f "$UC3" ]; then
    u3c=$(awk -F'\t' '$1=="ROW"{ st=$2; sub(/^@\{[^}]*\}/,"",st); if (st != "server - error") next
            for (i=3; i<=NF; i++) if (index($i,"@data:loglines=")==1) {
                split(substr($i,16), L, "\037"); d=substr(L[1],1,10)
                if (d ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$/) c[d]++
                break } }
          END{ for (k in c) printf "%s:%s ", k, c[k] }' "$UC3")
fi
if [ -f "$SV" ] && [ -f "$SP" ] && [ -n "$sdays" ]; then
awk -F'\t' -v OFS='\t' -v outdir="$RPTNEW" -v tdays="$tdays" -v sdays="$sdays" -v slfc="$slfc" -v nrdc="$nrdc" -v nrfc="$nrfc" -v u3c="$u3c" -v anomc="$anomc" '
    BEGIN { ns = split(slfc, _sa, " "); for (i = 1; i <= ns; i++) { if (_sa[i] == "") continue; p = index(_sa[i], ":"); if (p > 1) SLFC[substr(_sa[i], 1, p - 1)] = substr(_sa[i], p + 1) }
        na = split(anomc, _aa, " "); for (i = 1; i <= na; i++) { if (_aa[i] == "") continue; p = index(_aa[i], ":"); if (p > 1) ANOMC[substr(_aa[i], 1, p - 1)] = substr(_aa[i], p + 1) }
        nu = split(u3c, _ua, " "); for (i = 1; i <= nu; i++) { if (_ua[i] == "") continue; p = index(_ua[i], ":"); if (p > 1) U3C[substr(_ua[i], 1, p - 1)] = substr(_ua[i], p + 1) }
        # "date:errors:subscriptions …" — the no-remote-dir per-day table
        nn = split(nrdc, _na, " "); for (i = 1; i <= nn; i++) { if (_na[i] == "") continue
            if (split(_na[i], _nb, ":") == 3) { NRDE[_nb[1]] = _nb[2] + 0; NRDS[_nb[1]] = _nb[3] + 0 } }
        nf = split(nrfc, _fa, " "); for (i = 1; i <= nf; i++) { if (_fa[i] == "") continue
            if (split(_fa[i], _fb, ":") == 3) { NRFP[_fb[1]] = _fb[2] + 0; NRFS[_fb[1]] = _fb[3] + 0 } } }
    function jdn(y,m,d,  a){ a=int((14-m)/12); y=y+4800-a; m=m+12*a-3; return d+int((153*m+2)/5)+365*y+int(y/4)-int(y/100)+int(y/400)-32045 }
    function wdname(d,   p){ split(d,p,"-"); return WD[jdn(p[1]+0,p[2]+0,p[3]+0) % 7] }
    function pctd(v, avg,   p) { if (avg <= 0) return ""; p = (v - avg) * 100 / avg; if (p > -0.5 && p < 0.5) return "0%"; return sprintf("%+.0f%%", p) }
    function lvlname(l){ return l == "W" ? "Warning" : (l == "E" ? "Error" : "Info") }
    function compname(c){ return c=="T"?"TM":(c=="P"?"PESITD":(c=="S"?"SSHD":c)) }
    FNR == 1 { fno++ }
    fno == 1 {   # server topview.rpt
        if ($1 != "ROW") next
        d = $2; sub(/^@\{[^}]*\}/, "", d); d = substr(d, 1, 10)
        REC[d]=$3; WRN[d]=$6; ERR[d]=$7; CT[d]=$9; CP[d]=$10; CS[d]=$11; FI[d]=$12; LA[d]=$13
        next
    }
    {   # _parse.tsv — the one full pass
        d = substr($1, 1, 10); if (d !~ /^[0-9][0-9][0-9][0-9]-/) next
        h = substr($2, 1, 2); if (h !~ /^[0-9][0-9]$/) h = "00"
        rc[d, h]++                              # the busiest-hour figure + a server-only day hero
        if ($3 == "E") er[d, h]++               # the errors-peaked fact
        if ($3 == "W" && index($5, "exceeded the maximum number of allowed connections")) CEIL[d]++
        if ($4 == "T" && $5 ~ /uthentication fail|Login failed/) AF[d]++
        # extra per-day problem signals -> PROBLEM links in the combined day page
        # "Problems this day" section (emitted below, one report per non-zero signal)
        if ($5 ~ /^Connection failure while /) CF[d]++                                              # site-failures
        if ($5 ~ /^Authentication failure connecting to remote host /) LGO[d]++                     # logons-outgoing (us failing AT the partner)
        if (index($5, "stop further route execution")) DEP[d]++                                     # deploy-errors (ARSP0001 route abandoned)
        if ($4 == "T" && index($5, "[Ssh Default]")) {                                              # incoming logon funnel
            if ($5 ~ /\[Ssh Default\] Disallowed user /) LGF[d]++                                   #   Disallowed
            else if (index($5, "no certificate is found for user ")) LGF[d]++                       #   Bad key
            else if ($5 ~ /\[Ssh Default\] User [A-Za-z0-9_.-]+ failed to login successfully/) LGF[d]++   # Key failures
            else if (index($5, "[Ssh Default] User ") && index($5, "is locked")) LGF[d]++           #   Locked
        }
        if ($5 ~ /unresponsive or stopped/ || $5 ~ /No peer has been selected/ || $5 ~ /Streaming not ready/) CLD[d]++   # cluster distress
        if (index($5, "Unable to submit event") || index($5, "Error sending event")) EVE[d]++       # event-feed errors
        # ERROR message shapes (digits folded to N) — the dominant-error fact
        if ($3 == "E") {
            m = substr($5, 1, 160); gsub(/[0-9]+/, "N", m)
            SH[d SUBSEP m]++
        }
    }
    END {
        split("Monday Tuesday Wednesday Thursday Friday Saturday Sunday", WD0, " ")
        for (i = 0; i < 7; i++) WD[i] = WD0[i + 1]
        nd = split(sdays, D, " ")
        nt = split(tdays, TD, " "); for (i = 1; i <= nt; i++) istr[TD[i]] = 1
        trec = 0; twarn = 0; sumAF = 0; tT=0; tP=0; tS=0
        for (x = 1; x <= nd; x++) { d = D[x]; trec += REC[d]+0; twarn += WRN[d]+0; sumAF += AF[d]+0; tT += CT[d]+0; tP += CP[d]+0; tS += CS[d]+0
            wd = wdname(d); wdc[wd]++; aRec[wd] += REC[d]+0; aErr[wd] += ERR[d]+0; aWrn[wd] += WRN[d]+0 }
        avgW = nd > 0 ? twarn / nd : 0
        avgAF = nd > 0 ? sumAF / nd : 0
        # busiest single ERROR shape per day (the dominant-error fact) — count
        # desc, shape asc, so the pick never depends on hash iteration order
        for (k in SH) {
            split(k, kk, SUBSEP); d = kk[1]; cnt = SH[k]
            if (cnt > ebest[d] || (cnt == ebest[d] && kk[2] < ebn[d])) { ebest[d] = cnt; ebn[d] = kk[2] }
        }
        for (x = 1; x <= nd; x++) {
            d = D[x]
            # ONE .rpt per day, shared with the transfer pass: this pass only
            # APPENDS (its file was written and closed there). A day with no
            # transfer data has no file yet, so this pass writes the header —
            # and its own nav, walking the SERVER day list.
            out = outdir "/" d ".rpt"
            q = "?axway_date=" d      # the linked reports open narrowed to this day (report.js)
            rank = 1;  for (y = 1; y <= nd; y++) if (REC[D[y]] + 0 > REC[d] + 0) rank++
            erank = 1; for (y = 1; y <= nd; y++) if (ERR[D[y]] + 0 > ERR[d] + 0) erank++
            ep = REC[d] > 0 ? ERR[d] * 100 / REC[d] : 0
            if (!(d in istr)) {
                print "TITLE\tDay — " d >> out
                print "H1\t" wdname(d) " " d >> out
                # nav row: exactly two entries — prev then next; empty href = inactive
                if (x > 1)  nav = "\t← " D[x-1] "|" D[x-1] ".html"
                else        nav = "\t← Previous day|"
                if (x < nd) nav = nav "\t" D[x+1] " →|" D[x+1] ".html"
                else        nav = nav "\tNext day →|"
                print "NAVROW" nav >> out
            }
            # ---- facts ----------------------------------------------------
            if (rank == 1 && nd > 1)
                printf "FACT\tThe **busiest server day** of the window (%.1f× the daily average of %d records).\n", (trec ? REC[d]*nd/trec : 0), int(trec/nd) >> out
            if (rank == nd && nd > 1)
                printf "FACT\tThe **quietest server day** of the window.\n" >> out
            if (erank == 1 && nd > 1 && ERR[d] + 0 > 0)
                printf "FACT\t**Most errors of any day** in the window: %d.\n", ERR[d] >> out
            peh = ""; pec = 0
            for (h = 0; h < 24; h++) { hh = sprintf("%02d", h); if (er[d, hh] + 0 > pec) { pec = er[d, hh]; peh = hh } }
            if (pec >= 100)
                printf "FACT\tErrors peaked at **%s:00** with **%d** in one hour.\n", peh, pec >> out
            if (nd > 1 && avgW > 0 && WRN[d] + 0 >= 3 * avgW && WRN[d] + 0 >= 5000)
                printf "FACT\t**Warnings surged** to %d — %.1f× the daily average of %d.\n", WRN[d]+0, WRN[d]/avgW, int(avgW) >> out
            if (CEIL[d] + 0 >= 10)
                printf "FACT\tThe PeSIT server hit its **100-connection ceiling** %d times — new clients were turned away.\n", CEIL[d] >> out
            if (ERR[d] + 0 > 0 && ebest[d] + 0 >= 0.40 * ERR[d])
                printf "FACT\t**%.0f%%** of the day'"'"'s errors were one repeated message — %s.\n", ebest[d]*100/ERR[d], (length(ebn[d]) > 80 ? substr(ebn[d], 1, 80) "…" : ebn[d]) >> out
            if (AF[d] + 0 >= 300 && (avgAF <= 0 || AF[d] + 0 >= 2 * avgAF))
                printf "FACT\t**Authentication failures** spiked to %d%s — a partner credential problem or probing.\n", AF[d]+0, (avgAF > 0 ? sprintf(" (%.1f× the daily average)", AF[d]/avgAF) : "") >> out
            # component share anomaly vs the period share
            if (trec > 0 && REC[d] + 0 > 0) {
                cshare(d, "TM",     CT[d]+0, tT)
                cshare(d, "PESITD", CP[d]+0, tP)
                cshare(d, "SSHD",   CS[d]+0, tS)
                for (i = 1; i <= nfacts; i++) print facts[i] >> out
                nfacts = 0
            }
            # ---- KPIs: the two server-side cards of the day page -----------
            cov = (FI[d] != "" && FI[d] != "-" && LA[d] != "" && LA[d] != "-") ? FI[d] "–" LA[d] : "log messages"
            wd = wdname(d)      # same-weekday means for the KPI deltas
            printf "KPI\t%d\tServer lines\t%s\tpurple\t../server/topview.html" q "\t%s\n", REC[d]+0, cov, pctd(REC[d], wdc[wd] ? aRec[wd]/wdc[wd] : 0) >> out
            printf "KPI\t%.1f%%\tServer error rate\terrors ÷ records\tblue\t../server/errors-per-day.html" q "\t%s\n", ep, pctd(ep, aRec[wd] ? aErr[wd]*100/aRec[wd] : 0) >> out
            # ---- PROBLEM links: this day problem reports, dated (?axway_date),
            #      surfaced in the combined day page "Problems this day" section ----
            if (ERR[d] + 0 > 0 || WRN[d] + 0 > 0)
                printf "PROBLEM\tserver\t../server/errors-top-messages.html" q "\tServer errors/warnings\t**%d** errors (%.2f%% of records) and **%d** warnings (%.2f%%) — the most-repeated message shapes\n", ERR[d]+0, ep, WRN[d]+0, (REC[d] > 0 ? WRN[d]*100/REC[d] : 0) >> out
            if (LGF[d] + 0 > 0)
                printf "PROBLEM\tserver\t../server/logons-incoming.html" q "\tLogon screening failures\t**%d** disallowed / bad-key / key-failure / locked SSH logons — the incoming screening funnel\n", LGF[d] >> out
            if (LGO[d] + 0 > 0)
                printf "PROBLEM\tserver\t../server/logons-outgoing.html" q "\tOutbound logon failures\t**%d** failed authentications AT remote hosts — us being refused by the partner (expired password, refused key, certificate policy)\n", LGO[d] >> out
            if (CF[d] + 0 > 0)
                printf "PROBLEM\tserver\t../server/site-failures.html" q "\tConnection failures\t**%d** connection-failure messages — retry storms toward an unreachable partner\n", CF[d] >> out
            # deploy-errors is a per-entity unresolved list with no date-aware
            # table, so like went-kaput its link carries no q
            if (DEP[d] + 0 > 0)
                printf "PROBLEM\tserver\t../server/deploy-errors.html\tDeploy errors\t**%d** route-abandon errors (ARSP0001) — a routing step failed and its configuration stopped the rest of the route\n", DEP[d] >> out
            if (CEIL[d] + 0 > 0)
                printf "PROBLEM\tserver\t../server/capacity-pesit-per-day.html" q "\tPeSIT connection ceiling\t**%d** hits of the PeSIT 100-connection ceiling — new clients were turned away\n", CEIL[d] >> out
            if (CLD[d] + 0 > 0)
                printf "PROBLEM\tserver\t../server/platform-health.html" q "\tCluster distress\t**%d** watchdog / Coherence / dispatch-policy distress messages\n", CLD[d] >> out
            if (EVE[d] + 0 > 0)
                printf "PROBLEM\tserver\t../server/errors-reasons.html" q "\tEvent-feed errors\t**%d** monitoring-feed delivery errors (unable to submit / error sending event)\n", EVE[d] >> out
            # subscriptions whose last transfer was OK but that logged an
            # error/warning in the server log afterwards, latest issue this day
            # (the went-kaput report — no date filter, so no q)
            if (NRDE[d] + 0 > 0)
                printf "PROBLEM\tserver\t../server/no-remote-dir.html" q "\tNo remote dir\t**%d** failed listing(s) on **%d** subscription(s) whose configured remote directory does not exist — the partner answered \"No such file\", so no transfer was ever started\n", NRDE[d], NRDS[d] >> out
            if (NRFP[d] + 0 > 0)
                printf "PROBLEM\tserver\t../server/no-remote-files.html" q "\tNo remote files\t**%d** poll(s) by **%d** UC3 subscription(s) that have NEVER found a file — the listing works, the remote directory is always empty\n", NRFP[d], NRFS[d] >> out
            # UC3 subscriptions whose scheduled poll itself errors server-side
            # ("server - error" on UC status / UC3), newest failure this day
            # (a full-period status report — no date filter, so no q)
            if (U3C[d] + 0 > 0)
                printf "PROBLEM\tserver\t../analyses/uc-status-uc3.html\tFailing polls\t**%d** UC3 subscription(s) whose scheduled poll errors server-side — nothing is ever listed or collected; latest failure this day\n", U3C[d] >> out
            if (SLFC[d] + 0 > 0)
                printf "PROBLEM\tserver\t../server/went-kaput.html\tWent kaput\t**%d** subscription(s) whose last transfer was OK but that logged a server-log error/warning afterwards, most recently today\n", SLFC[d] >> out
            # A day with NO transfer data got no hero from the transfer pass:
            # give it the records-per-hour chart, plus the anomaly-scan entry
            # the transfer pass adds on the days the scan flagged (such a day
            # normally IS one — no transfers where ≥20 are typical is a daily
            # Silence finding — but it is checked, never assumed).
            if (!(d in istr)) {
                if (ANOMC[d] + 0 > 0)
                    printf "PROBLEM\ttransfer\t../transfer/anomalies.html" q "\tAnomaly scan\t**%d** finding(s) this day — spikes, silence and volume shifts vs the typical hour and the typical day\n", ANOMC[d] >> out
                hs = ""
                for (h = 0; h < 24; h++) { hh = sprintf("%02d", h); hs = hs (h ? "|" : "") hh ":" (rc[d, hh] + 0) }
                printf "CARD\tRecords per hour\t%s\t../server/topview.html" q "\tspan2\tvbar\t%s\tCH_PURPLE\n", d, hs >> out
            }
            close(out)
        }
    }
    function cshare(d, nm, dc, tc,   ds, ps) {
        if (tc + 0 < 1000 || dc < 500) return
        ds = dc / (REC[d] + 0); ps = tc / trec
        if (ps > 0 && ds >= 2 * ps)
            facts[++nfacts] = sprintf("FACT\t**%s** was unusually busy: %.1f%% of the day'"'"'s records vs %.1f%% over the period.", nm, ds*100, ps*100)
    }
' "$SV" "$SP"
fi

# Publish the complete staged set with two renames (see the staging comment at
# the top): a kill between them leaves NO $RPTDIR, which the freshness test
# reads as "rebuild" — never a half-written set with fresh mtimes.
mv "$RPTDIR" "$RPTDIR.old"
mv "$RPTNEW" "$RPTDIR"
rm -rf "$RPTDIR.old"

nrpt=$(ls "$RPTDIR" 2>/dev/null | grep -c '\.rpt$' || true)
echo "Wrote $nrpt day page spec(s) to $RPTDIR/." >&2
