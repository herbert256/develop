#!/usr/bin/env bash
#
# monitor.sh — the MONITOR dashboard spec (docs/<env>/dashboards/monitor.html):
# the CFT end-to-end monitor's three latency views, moved OUT of the Overview
# 2026-08 (the poll-floored loop view crowded the hero row there). One file
# every 15 minutes traverses all four use cases with ourselves as partner
# (windows/monitor/); the three views split its trip into DISJOINT segments:
#   Monitor CFT pickup   name timestamp -> UC1 inbound leg   (before ST)
#   Monitor duration     UC1 inbound   -> UC3 outbound leg   (the whole loop)
#   Monitor staging      UC1 inbound   -> UC2 routing leg    (inside ST, no
#                                                             poll wait)
#
#   -> data/<env>/dashboards/reports/monitor.rpt   (PAGE monitor)
#
# THE RPT'S EXISTENCE IS THE "THIS ENV HAS A MONITOR" FLAG: written only when
# the transfer cache carries monitor rows, REMOVED otherwise. The dashboards
# publish renders the page from it, write_sitemap lists the page and
# ensure_assets bakes the per-env flag into topbar-data.js, where buildTopbar
# shows the top-bar Monitor link — all four react to this one file.
#
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib.sh"
OUT="$REPORTS_DIR/monitor.rpt"

skip_if_fresh "$OUT" "${BASH_SOURCE[0]}"

if [ ! -f "$RW" ]; then
    rm -f "$OUT"
    echo "No transfer cache; monitor.rpt removed." >&2
    exit 0
fi

# ---- the "Monitor CFT pickup" view (conditional) -----------------------------
# The CFT-side end-to-end monitor (windows/monitor) drops
# monitor_ccyymmdd_hhmmss.txt on the CFT server; the file NAME carries the drop
# time. The INBOUND (pesit) leg of UC1[-_]INFRA_ST-MONITOR_INFRA is the CFT
# picking that drop up and delivering it into ST, so leg start - name time =
# CFT directory pickup + PeSIT delivery. One measurement per File (the earliest
# inbound leg of each CoreId, so a retry never double-counts), P50/P90/P98 ms
# per slot — chart kind `durfit`: the dur bands on a per-chart axis fitted to
# this view's own data (slotchart.js fitTicks). Emitted ONLY when
# such rows exist: the view is absent until the monitor is live and, like
# PeSIT, sits LAST so its omission never shifts the earlier button indices.
mcp4=""; mcp6=""; mcp12=""; mcp24=""
if [ -f "$RW" ]; then
    mser=$(awk -F'\t' '
        function jdn(y,m,d,  a){ a=int((14-m)/12); y=y+4800-a; m=m+12*a-3; return d+int((153*m+2)/5)+365*y+int(y/4)-int(y/100)+int(y/400)-32045 }
        function fromjdn(j,   a,b,c,dd,e,mm,day,mon,yr) { a=j+32044; b=int((4*a+3)/146097); c=a-int(146097*b/4); dd=int((4*c+3)/1461); e=c-int(1461*dd/4); mm=int((5*e+2)/153); day=e-int((153*mm+2)/5)+1; mon=mm+3-12*int(mm/10); yr=100*b+dd-4800+int(mm/10); return sprintf("%04d-%02d-%02d", yr, mon, day) }
        function qsort(A, lo, hi,   i, j, p, tmp) {
            while (lo < hi) {
                i = lo; j = hi; p = A[int((lo + hi) / 2)] + 0
                while (i <= j) {
                    while (A[i] + 0 < p) i++
                    while (A[j] + 0 > p) j--
                    if (i <= j) { tmp = A[i]; A[i] = A[j]; A[j] = tmp; i++; j-- }
                }
                if (j - lo < hi - i) { qsort(A, lo, j); lo = i } else { qsort(A, i, hi); hi = j }
            }
        }
        function bump(r, t, ms,   k) {
            k = r SUBSEP t
            if (!(r in tmin) || t < tmin[r]) tmin[r] = t
            if (!(r in tmax) || t > tmax[r]) tmax[r] = t
            v[k] = v[k] " " ms
        }
        function build(r, spd,   t, k, d, lab, nk, dl, i1, i2, i3, s) {
            s = ""
            for (t = tmin[r]; t <= tmax[r]; t++) {
                k = r SUBSEP t
                if (spd == 6)      { d = fromjdn(int(t/6)); lab = substr(d,6) sprintf(" %02dh", (t%6)*4) }
                else if (spd == 4) { d = fromjdn(int(t/4)); lab = substr(d,6) sprintf(" %02dh", (t%4)*6) }
                else if (spd == 2) { d = fromjdn(int(t/2)); lab = substr(d,6) sprintf(" %02dh", (t%2)*12) }
                else               { d = fromjdn(t);        lab = substr(d,6) }
                if (v[k] != "") {
                    nk = split(v[k], dl, " ")
                    qsort(dl, 1, nk)
                    i1 = int(0.50*nk + 0.9999); if (i1 < 1) i1 = 1
                    i2 = int(0.90*nk + 0.9999); if (i2 < 1) i2 = 1
                    i3 = int(0.98*nk + 0.9999); if (i3 < 1) i3 = 1
                    s = s (s==""?"":"|") lab ":" dl[i1] ":" dl[i2] ":" dl[i3] ":" d
                } else
                    s = s (s==""?"":"|") lab "::::" d
            }
            print "MCP" r "\t" s
        }
        $2 != "Inbound" { next }
        $6 !~ /^UC1[-_]INFRA_ST-MONITOR_INFRA$/ { next }
        $8 !~ /^monitor_[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]_[0-9][0-9][0-9][0-9][0-9][0-9]\.txt$/ { next }
        $11 == "" || $12 !~ /^[0-9][0-9]:/ { next }
        {
            nj  = jdn(substr($8,9,4)+0, substr($8,13,2)+0, substr($8,15,2)+0)
            nms = (substr($8,18,2)*3600 + substr($8,20,2)*60 + substr($8,22,2)) * 1000
            sms = int((substr($12,1,2)*3600 + substr($12,4,2)*60) * 1000 + substr($12,7) * 1000 + 0.5)
            delta = ($14 - nj) * 86400000 + sms - nms
            if (delta < 0) next                       # clock skew / foreign file
            cid = $1
            if (!(cid in md) || delta < md[cid]) { md[cid] = delta; mj[cid] = $14; mh[cid] = substr($12,1,2)+0 }
        }
        END {
            # hash order is fine: bump only appends to per-slot lists that
            # qsort re-orders, and tmin/tmax are commutative
            for (cid in md) {
                j = mj[cid]; h = mh[cid]
                bump(4,  j*6 + int(h/4),  md[cid])
                bump(6,  j*4 + int(h/6),  md[cid])
                bump(12, j*2 + int(h/12), md[cid])
                bump(24, j,               md[cid])
            }
            if (!(6 in tmax)) exit
            build(4, 6); build(6, 4); build(12, 2); build(24, 1)
        }' "$RW")
    for r in 4 6 12 24; do
        eval "mcp$r=\$(printf '%s\n' \"\$mser\" | awk -F'\t' -v k=MCP\$r '\$1==k{print \$2}')"
    done
fi

# ---- the "Monitor duration" view (conditional) --------------------------------
# The ST-INTERNAL span of the monitor loop: a) the earliest INBOUND leg start
# of UC1[-_]INFRA_ST-MONITOR_INFRA (the file entering ST from CFT) to b) the
# earliest OUTBOUND leg start of UC3[-_]INFRA_ST-MONITOR_INFRA (ST handing it
# back to CFT), joined on the monitor FILE NAME — the four subscriptions share
# no CoreId, so the name is the loop's only key. A file with a) but no b)
# never completed the loop and counts as ONE HOUR — or the slowest matched
# file when that is longer — so a loss shows up in the percentiles instead of
# vanishing. An unmatched a) younger than 1 hour against the NEWEST monitor
# row is SKIPPED, not penalized: the export was cut mid-flight and the loop
# may still complete. Slotted by the a) time; P50/P90/P98 ms, kind `durfit`
# (each monitor view fits its own duration axis — the loop never beats the
# ~5 min poll floor, so the shared 1 s..1 h axis parked it in a sliver).
# Conditional like the pickup view, and after it, so buttons never shift.
#
# The SAME pass also builds the "Monitor staging" family (MSTG): a) to the
# UC2[-_] flow's INBOUND ROUTING leg — the staging instant, i.e. delivered and
# waiting for pickup. Unlike the loop duration it carries NO poll wait (the
# UC3 cron fires at :05, flooring the loop at ~5 minutes), so it is the view
# that shows ST-internal delivery drift. Same penalty/skip rules per family.
mdur4=""; mdur6=""; mdur12=""; mdur24=""
mstg4=""; mstg6=""; mstg12=""; mstg24=""
if [ -f "$RW" ]; then
    dser=$(awk -F'\t' '
        function jdn(y,m,d,  a){ a=int((14-m)/12); y=y+4800-a; m=m+12*a-3; return d+int((153*m+2)/5)+365*y+int(y/4)-int(y/100)+int(y/400)-32045 }
        function fromjdn(j,   a,b,c,dd,e,mm,day,mon,yr) { a=j+32044; b=int((4*a+3)/146097); c=a-int(146097*b/4); dd=int((4*c+3)/1461); e=c-int(1461*dd/4); mm=int((5*e+2)/153); day=e-int((153*mm+2)/5)+1; mon=mm+3-12*int(mm/10); yr=100*b+dd-4800+int(mm/10); return sprintf("%04d-%02d-%02d", yr, mon, day) }
        function qsort(A, lo, hi,   i, j, p, tmp) {
            while (lo < hi) {
                i = lo; j = hi; p = A[int((lo + hi) / 2)] + 0
                while (i <= j) {
                    while (A[i] + 0 < p) i++
                    while (A[j] + 0 > p) j--
                    if (i <= j) { tmp = A[i]; A[i] = A[j]; A[j] = tmp; i++; j-- }
                }
                if (j - lo < hi - i) { qsort(A, lo, j); lo = i } else { qsort(A, i, hi); hi = j }
            }
        }
        # f = the series FAMILY ("D" loop duration to UC3-out, "S" staged at
        # the UC2 routing leg) — two graphs share this one pass
        function bump(f, r, t, ms,   k, fr) {
            k = f SUBSEP r SUBSEP t; fr = f SUBSEP r
            if (!(fr in tmin) || t < tmin[fr]) tmin[fr] = t
            if (!(fr in tmax) || t > tmax[fr]) tmax[fr] = t
            v[k] = v[k] " " ms
        }
        function build(f, tag, r, spd,   t, k, fr, d, lab, nk, dl, i1, i2, i3, s) {
            fr = f SUBSEP r
            if (!(fr in tmax)) return
            s = ""
            for (t = tmin[fr]; t <= tmax[fr]; t++) {
                k = f SUBSEP r SUBSEP t
                if (spd == 6)      { d = fromjdn(int(t/6)); lab = substr(d,6) sprintf(" %02dh", (t%6)*4) }
                else if (spd == 4) { d = fromjdn(int(t/4)); lab = substr(d,6) sprintf(" %02dh", (t%4)*6) }
                else if (spd == 2) { d = fromjdn(int(t/2)); lab = substr(d,6) sprintf(" %02dh", (t%2)*12) }
                else               { d = fromjdn(t);        lab = substr(d,6) }
                if (v[k] != "") {
                    nk = split(v[k], dl, " ")
                    qsort(dl, 1, nk)
                    i1 = int(0.50*nk + 0.9999); if (i1 < 1) i1 = 1
                    i2 = int(0.90*nk + 0.9999); if (i2 < 1) i2 = 1
                    i3 = int(0.98*nk + 0.9999); if (i3 < 1) i3 = 1
                    s = s (s==""?"":"|") lab ":" dl[i1] ":" dl[i2] ":" dl[i3] ":" d
                } else
                    s = s (s==""?"":"|") lab "::::" d
            }
            print tag r "\t" s
        }
        $8 !~ /^monitor_[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]_[0-9][0-9][0-9][0-9][0-9][0-9]\.txt$/ { next }
        $11 == "" || $12 !~ /^[0-9][0-9]:/ { next }
        {
            abs = $14 * 86400000 + int((substr($12,1,2)*3600 + substr($12,4,2)*60) * 1000 + substr($12,7) * 1000 + 0.5)
            if ($2 == "Inbound" && $6 ~ /^UC1[-_]INFRA_ST-MONITOR_INFRA$/) {
                if (!($8 in A) || abs < A[$8]) { A[$8] = abs; aj[$8] = $14; ah[$8] = substr($12,1,2)+0 }
                if (abs > gmax) gmax = abs
            } else if ($2 == "Outbound" && $6 ~ /^UC3[-_]INFRA_ST-MONITOR_INFRA$/) {
                if (!($8 in B) || abs < B[$8]) B[$8] = abs
                if (abs > gmax) gmax = abs
            } else if ($2 == "Inbound" && $10 == "routing" && $6 ~ /^UC2[-_]INFRA_ST-MONITOR_INFRA$/) {
                # the STAGING leg: the file is delivered, waiting for pickup
                if (!($8 in C) || abs < C[$8]) C[$8] = abs
                if (abs > gmax) gmax = abs
            }
        }
        END {
            # pass 1: the matched pairs per family, and the slowest of each
            # (the penalty floor is one hour; a slower real file raises it)
            maxd = 0; maxs = 0
            for (n in A) {
                if (n in B) { d = B[n] - A[n]; if (d >= 0) { MD[n] = d; if (d > maxd) maxd = d } }
                if (n in C) { d = C[n] - A[n]; if (d >= 0) { MS[n] = d; if (d > maxs) maxs = d } }
            }
            pend = 3600000; if (maxd > pend) pend = maxd
            pens = 3600000; if (maxs > pens) pens = maxs
            # pass 2: bucket — real durations, penalties for the lost, nothing
            # for the still-in-flight tail or a negative (corrupt) pair.
            # Hash order is fine: bump appends to per-slot lists qsort re-orders.
            for (n in A) {
                t4 = aj[n]*6 + int(ah[n]/4); t6 = aj[n]*4 + int(ah[n]/6)
                t12 = aj[n]*2 + int(ah[n]/12); t24 = aj[n]
                d = -1
                if (n in MD)          d = MD[n]
                else if (n in B)      ;                                  # negative pair — drop
                else if (gmax - A[n] >= 3600000) d = pend
                if (d >= 0) { bump("D",4,t4,d); bump("D",6,t6,d); bump("D",12,t12,d); bump("D",24,t24,d) }
                d = -1
                if (n in MS)          d = MS[n]
                else if (n in C)      ;
                else if (gmax - A[n] >= 3600000) d = pens
                if (d >= 0) { bump("S",4,t4,d); bump("S",6,t6,d); bump("S",12,t12,d); bump("S",24,t24,d) }
            }
            build("D", "MDUR", 4, 6); build("D", "MDUR", 6, 4); build("D", "MDUR", 12, 2); build("D", "MDUR", 24, 1)
            build("S", "MSTG", 4, 6); build("S", "MSTG", 6, 4); build("S", "MSTG", 12, 2); build("S", "MSTG", 24, 1)
        }' "$RW")
    for r in 4 6 12 24; do
        eval "mdur$r=\$(printf '%s\n' \"\$dser\" | awk -F'\t' -v k=MDUR\$r '\$1==k{print \$2}')"
        eval "mstg$r=\$(printf '%s\n' \"\$dser\" | awk -F'\t' -v k=MSTG\$r '\$1==k{print \$2}')"
    done
fi

if [ -z "$mcp6" ] && [ -z "$mdur6" ] && [ -z "$mstg6" ]; then
    rm -f "$OUT"
    echo "No monitor rows in the transfer cache; monitor.rpt removed." >&2
    exit 0
fi

{
    printf 'PAGE\tmonitor\n'
    printf 'TITLE\tMonitor — Cloud Reports\n'
    printf 'H1\tMonitor\n'
    printf 'DESC\tThe CFT end-to-end monitor: pickup, loop and staging latency per slot.\n'
    printf 'INTRO\tThe end-to-end monitor drops one file every 15 minutes on the CFT and sends it through all four use cases with ourselves as the remote partner. The three views cut its trip into disjoint segments — before ST (CFT pickup), the whole loop, and inside ST without the poll wait (staging) — so an incident shows up in exactly the segment that owns it.\n'
    printf 'HERO0\tMonitor CFT pickup\n'
    printf 'CARD\tMonitor CFT pickup time per slot\tper monitor file, the time from its drop on the CFT (the timestamp in its name) to the start of its inbound UC1 leg into ST — CFT directory pickup + PeSIT delivery; P50 dark green, P90 orange, P98 dark red; click a slot for its day\t../transfer/punctuality.html\tspan2\tslots\tdurfit\t%s\t../day/{}.html?axway_hero=Files%%20processed\t%s\t%s\t%s\n' "$mcp6" "240:$mcp4" "720:$mcp12" "1440:$mcp24"
    printf 'CARDALT\tMonitor duration\tMonitor loop duration per slot\tper monitor file, the time from entering ST (inbound UC1 leg start) to the final hand-off back to CFT (outbound UC3 leg start), joined on the file name; a file that never reached UC3 counts as 1 hour — or the slowest completed file when longer; P50 dark green, P90 orange, P98 dark red; click a slot for its day\t../transfer/duration.html\tspan2\tslots\tdurfit\t%s\t../day/{}.html?axway_hero=Files%%20processed\t%s\t%s\t%s\n' "$mdur6" "240:$mdur4" "720:$mdur12" "1440:$mdur24"
    printf 'CARDALT\tMonitor staging\tMonitor staging time per slot\tper monitor file, the time from entering ST (inbound UC1 leg start) to staged for pickup (the UC2 flow'"'"'s inbound routing leg) — the delivery path WITHOUT the poll wait that floors Monitor duration at ~5 minutes, so ST-internal drift shows here first; a file that never reached staging counts as 1 hour — or the slowest staged file when longer; P50 dark green, P90 orange, P98 dark red; click a slot for its day\t../transfer/duration.html\tspan2\tslots\tdurfit\t%s\t../day/{}.html?axway_hero=Files%%20processed\t%s\t%s\t%s\n' "$mstg6" "240:$mstg4" "720:$mstg12" "1440:$mstg24"
    printf 'FOOT\tOne cycle per quarter hour; the CFT-side logs live on the CFT server under e:\\admin\\monitor\\9-logs. Figures cover the full log period.\n'
} > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"
echo "Wrote $OUT" >&2
