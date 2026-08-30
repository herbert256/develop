#!/usr/bin/env bash
#
# overview.sh — the Overview dashboard spec (the dashboards landing page,
# published as docs/dashboards/index.html): the 5-KPI headline row plus ONE
# hero graph with the SIX shared slot views (Duration / Files processed /
# Volume / Error % Files / Transfer errors / PeSIT) at 6-HOUR resolution over
# the whole window —
# the SAME view set (and labels) as the day pages' 30-minute hero, so the
# picked view carries between the two (sessionStorage axway-day-hero + the
# slot links' ?axway_hero= param). Below the hero: the day pages' six Top-5
# tables over the FULL period (2026-08; TOP lines, same protocol) — nothing
# else.
# Renders even when a source is missing (KPI figures default to 0; the hero
# block needs the transfer cache, the PeSIT view its pesit-slots.tsv sidecar).
#
#   -> data/dashboards/reports/overview.rpt   (PAGE index)
#
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib.sh"
OUT="$REPORTS_DIR/overview.rpt"

# The four cache/report sources come with the lib; the PeSIT card additionally
# reads the server-side slot sidecar, and the two "seen" cards the partner xref
# maps + the base result caches, the greenpoll sidecar and the first-seen
# ledger (the curated server-only sets and their first-sighting days — see
# the seen block below).
XR="$DATA/flow-manager/xref"
skip_if_fresh "$OUT" "${BASH_SOURCE[0]}" "$DATA/server/reports/pesit-slots.tsv" \
    "$DATA/server/reports/uc1-slots.tsv" "$DATA/server/reports/uc2-slots.tsv" \
    "$DATA/server/reports/uc3-slots.tsv" "$DATA/server/reports/uc4-slots.tsv" \
    "$XR/_subscriptions-partners.tsv" "$XR/_hosts-partners.tsv" \
    "$XR/_partners-accounts.tsv" "$XR/_partners-subscriptions.tsv" \
    "$DATA/flow-manager/base/_subscriptions.tsv" "$DATA/flow-manager/base/_partners.tsv" \
    "$DATA/flow-manager/base/_accounts.tsv" \
    "$DATA/blue/_greenpoll.tsv" "$DATA/blue/_redflip.tsv" \
    "$DATA/server/cache/_subscriptions.tsv" "$DATA/server/cache/_accounts.tsv" \
    "$DATA/first-seen"

transfer_basics || true
server_basics || true

# ---- the slot views, at THREE resolutions ----------------------------------
# ONE pass over the logical-transfer cache (+ the raw per-record cache for the
# Transfer errors count) emits the five transfer series for each of the three
# bucket sizes the chart STYLES use (2026-07): solid = 6
# hours, line = 12 hours, bar = 1 day. Percentiles and error rates cannot be
# re-bucketed after the fact (a median of medians is not a median, and a mean
# of percentages is not a rate), so every resolution is aggregated from the
# raw Files here. Slot key = jdn*slots-per-day + hour/bucket, walked
# numerically so no awk hash order leaks; label = "MM-DD HHh" ("MM-DD" for the
# daily buckets). Gaps: Duration and Error % Files emit empty values for a slot
# with no (OK) Files; Files processed, Volume and Transfer errors emit real
# zeros — a quiet slot is data there.
dur1=""; cnt1=""; rate1=""; vol1=""; err1=""; thr1=""; con1=""
dur2=""; cnt2=""; rate2=""; vol2=""; err2=""; thr2=""; con2=""
dur4=""; cnt4=""; rate4=""; vol4=""; err4=""; thr4=""; con4=""
dur6=""; cnt6=""; rate6=""; vol6=""; err6=""; thr6=""; con6=""
dur12=""; cnt12=""; rate12=""; vol12=""; err12=""; thr12=""; con12=""
dur24=""; cnt24=""; rate24=""; vol24=""; err24=""; thr24=""; con24=""
if [ -f "$TR" ]; then
    RWSRC="$RW"; [ -f "$RWSRC" ] || RWSRC=/dev/null
    ser=$(awk -F'\t' '
        function fromjdn(j,   a,b,c,dd,e,mm,day,mon,yr) { a=j+32044; b=int((4*a+3)/146097); c=a-int(146097*b/4); dd=int((4*c+3)/1461); e=c-int(1461*dd/4); mm=int((5*e+2)/153); day=e-int((153*mm+2)/5)+1; mon=mm+3-12*int(mm/10); yr=100*b+dd-4800+int(mm/10); return sprintf("%04d-%02d-%02d", yr, mon, day) }
        # O(n log n) — a daily bucket holds thousands of durations, where the
        # insertion sort this replaced would be O(n^2). Tail-recursion on the
        # larger half keeps the depth logarithmic.
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
        # one File into one resolution bucket (the fields are the current record)
        function bump(r, t,   k) {
            k = r SUBSEP t
            if (!(r in tmin) || t < tmin[r]) tmin[r] = t
            if (!(r in tmax) || t > tmax[r]) tmax[r] = t
            tc[k]++; vol[k] += $8
            if ($2 == "Failed" || $2 == "Expired") tf[k]++
            else { ok[k]++; if ($9 + 0 > 0) v[k] = v[k] " " $9 }
        }
        # one RAW failed leg into one resolution bucket — it extends the shared
        # window, so a failed leg trailing the last File start still lands in a
        # walked slot
        function bumpe(r, t,   k) {
            k = r SUBSEP t
            if (!(r in tmin) || t < tmin[r]) tmin[r] = t
            if (!(r in tmax) || t > tmax[r]) tmax[r] = t
            ef[k]++
        }
        # the series of ONE resolution; spd = buckets per day
        function build(r, spd,   t, k, d, lab, nk, dl, i1, i2, i3, sd, sc, sr, sv, se, st9, sn9) {
            sd = ""; sc = ""; sr = ""; sv = ""; se = ""; st9 = ""; sn9 = ""
            for (t = tmin[r]; t <= tmax[r]; t++) {
                k = r SUBSEP t
                if (spd == 24)     { d = fromjdn(int(t/24)); lab = substr(d,6) sprintf(" %02dh", t%24) }
                else if (spd == 12) { d = fromjdn(int(t/12)); lab = substr(d,6) sprintf(" %02dh", (t%12)*2) }
                else if (spd == 6) { d = fromjdn(int(t/6)); lab = substr(d,6) sprintf(" %02dh", (t%6)*4) }
                else if (spd == 4) { d = fromjdn(int(t/4)); lab = substr(d,6) sprintf(" %02dh", (t%4)*6) }
                else if (spd == 2) { d = fromjdn(int(t/2)); lab = substr(d,6) sprintf(" %02dh", (t%2)*12) }
                else               { d = fromjdn(t);        lab = substr(d,6) }
                if (v[k] != "") {
                    nk = split(v[k], dl, " ")
                    qsort(dl, 1, nk)
                    i1 = int(0.50*nk + 0.9999); if (i1 < 1) i1 = 1
                    i2 = int(0.90*nk + 0.9999); if (i2 < 1) i2 = 1
                    i3 = int(0.98*nk + 0.9999); if (i3 < 1) i3 = 1
                    sd = sd (sd==""?"":"|") lab ":" dl[i1] ":" dl[i2] ":" dl[i3] ":" d
                } else
                    sd = sd (sd==""?"":"|") lab "::::" d
                sc = sc (sc==""?"":"|") lab ":" ok[k]+0 ":" d
                if (tc[k]+0 > 0) sr = sr (sr==""?"":"|") lab ":" sprintf("%.1f", (tf[k]+0)*100/tc[k]) ":" d
                else             sr = sr (sr==""?"":"|") lab "::" d
                sv = sv (sv==""?"":"|") lab ":" vol[k]+0 ":" d
                se = se (se==""?"":"|") lab ":" ef[k]+0 ":" d
                # throughput: the slot\047s measured bytes over its measured wire
                # time (MB/s). No qualifying leg -> an EMPTY value, like the
                # Duration view: a slot with nothing big enough to time has no
                # rate, which is not the same as a rate of zero.
                if (tms[k] + 0 > 0)
                    st9 = st9 (st9==""?"":"|") lab ":" sprintf("%.3f", (tby[k] + 0) / 1048576 / ((tms[k] + 0) / 1000)) ":" d
                else
                    st9 = st9 (st9==""?"":"|") lab "::" d
                sn9 = sn9 (sn9==""?"":"|") lab ":" cnu[k]+0 ":" cns[k]+0 ":" d
            }
            print "DUR" r "\t" sd; print "CNT" r "\t" sc; print "RATE" r "\t" sr; print "VOL" r "\t" sv; print "ERR" r "\t" se
            print "THR" r "\t" st9; print "CON" r "\t" sn9
        }
        raw != 1 && ($4=="" || $5 !~ /^[0-9][0-9]:/) { next }
        raw != 1 {
          h = int(substr($5,1,2))
          bump(1,  $7*24 + h)
          bump(2,  $7*12 + int(h/2))
          bump(4,  $7*6 + int(h/4))
          bump(6,  $7*4 + int(h/6))
          bump(12, $7*2 + int(h/12))
          bump(24, $7)
          next }
        # from here on raw == 1 — the per-record cache (_transfers.tsv): count
        # the legs whose raw Status is Failed or Failed Subtransmission (the
        # Transfer errors view); slot = jdn (col 14) + start hour (col 12)
        $11=="" || $12 !~ /^[0-9][0-9]:/ { next }
        {
          h = int(substr($12,1,2))
          # THROUGHPUT: only legs big and slow enough to measure a real rate —
          # the same floors bin/transfer/reports/route-throughput.sh uses, so
          # the card and that report cannot tell different stories. Duration is
          # the record\047s own wire time; the dwell between legs is not in it.
          if ($15 + 0 > 500 && $9 + 0 > 1048576) {
              tby[1  SUBSEP ($14*24 + h)]        += $9; tms[1  SUBSEP ($14*24 + h)]        += $15
              tby[2  SUBSEP ($14*12 + int(h/2))] += $9; tms[2  SUBSEP ($14*12 + int(h/2))] += $15
              tby[4  SUBSEP ($14*6 + int(h/4))]  += $9; tms[4  SUBSEP ($14*6 + int(h/4))]  += $15
              tby[6  SUBSEP ($14*4 + int(h/6))]  += $9; tms[6  SUBSEP ($14*4 + int(h/6))]  += $15
              tby[12 SUBSEP ($14*2 + int(h/12))] += $9; tms[12 SUBSEP ($14*2 + int(h/12))] += $15
              tby[24 SUBSEP $14]                 += $9; tms[24 SUBSEP $14]                 += $15
          }
          # CONNECTIONS: one technical session (col 24) counts ONCE, in the slot
          # it OPENED in — so keep its earliest hour and who dialled (col 7:
          # User = the partner\047s client, Server = us). The cache is CoreId-
          # sorted, so a session\047s legs arrive scattered; END buckets them.
          if ($24 != "" && $24 != "UNKNOWN") {
              hk = $14 * 24 + h
              if (!($24 in SES) || hk < SESH[$24]) { SESH[$24] = hk; SES[$24] = ($7 == "User") ? "U" : "S" }
          }
        }
        $3 == "Failed" || $3 == "Failed Subtransmission" {
          h = int(substr($12,1,2))
          bumpe(1,  $14*24 + h)
          bumpe(2,  $14*12 + int(h/2))
          bumpe(4,  $14*6 + int(h/4))
          bumpe(6,  $14*4 + int(h/6))
          bumpe(12, $14*2 + int(h/12))
          bumpe(24, $14) }
        END {
            if (!(6 in tmax)) exit
            # each session into the slot it opened in, per resolution. Hash
            # order is fine: every target is a commutative counter. A session
            # outside the walked window (its file never entered the caches) is
            # clamped out rather than stretching the window.
            for (sid in SES) {
                sh = SESH[sid]; sj = int(sh / 24); sx = sh % 24
                SL[1] = sj*24 + sx; SL[2] = sj*12 + int(sx/2); SL[4] = sj*6 + int(sx/4); SL[6] = sj*4 + int(sx/6); SL[12] = sj*2 + int(sx/12); SL[24] = sj
                for (rq = 1; rq <= 6; rq++) {
                    rr = (rq == 1 ? 1 : rq == 2 ? 2 : rq == 3 ? 4 : rq == 4 ? 6 : rq == 5 ? 12 : 24)
                    if (SL[rr] < tmin[rr] || SL[rr] > tmax[rr]) continue
                    if (SES[sid] == "U") cnu[rr SUBSEP SL[rr]]++; else cns[rr SUBSEP SL[rr]]++
                }
            }
            build(1, 24); build(2, 12); build(4, 6); build(6, 4); build(12, 2); build(24, 1)
        }' "$TR" raw=1 "$RWSRC")
    for r in 1 2 4 6 12 24; do
        eval "dur$r=\$(printf '%s\n' \"\$ser\" | awk -F'\t' -v k=DUR\$r  '\$1==k{print \$2}')"
        eval "cnt$r=\$(printf '%s\n' \"\$ser\" | awk -F'\t' -v k=CNT\$r  '\$1==k{print \$2}')"
        eval "rate$r=\$(printf '%s\n' \"\$ser\" | awk -F'\t' -v k=RATE\$r '\$1==k{print \$2}')"
        eval "vol$r=\$(printf '%s\n' \"\$ser\" | awk -F'\t' -v k=VOL\$r  '\$1==k{print \$2}')"
        eval "err$r=\$(printf '%s\n' \"\$ser\" | awk -F'\t' -v k=ERR\$r  '\$1==k{print \$2}')"
        eval "thr$r=\$(printf '%s\n' \"\$ser\" | awk -F'\t' -v k=THR\$r  '\$1==k{print \$2}')"
        eval "con$r=\$(printf '%s\n' \"\$ser\" | awk -F'\t' -v k=CON\$r  '\$1==k{print \$2}')"
    done
fi

# ---- the two CUMULATIVE "seen" views ---------------------------------------
# How many Subscriptions / Partners the site had seen AT OR BEFORE each slot,
# counted FOUR ways:
#   v0 blue   seen in transfer + server  — the UNION, so always the HIGHEST
#   v1 orange seen in the transfer log   — v1 <= v0
#   v2 green  GREEN at the end of the slot — its latest File so far was OK
#   v3 red    NOT green at the end of the slot
# v0 and v1 are cumulative first-sightings, so they only ever RISE. v2 and v3
# each rise AND fall as entities flip state, and by construction v2 + v3 == v1:
# every transfer-seen entity is, at every later slot, in exactly one of them.
#
# GREEN/RED use the site-wide subscription rule (CLAUDE.md Result colours): red
# when the LATEST outcome so far is Failed or Expired, green otherwise — a
# Waiting last File counts green. The state is re-evaluated per slot from the
# latest File AT OR BEFORE it, so a flip either way moves one entity between the
# two counts. For a PARTNER this is its own last File, not the config rollup the
# base cache stores (a rollup over connected subscriptions has no time axis).
#
# BOTH curves count CONFIGURED entities (2026-08-15 audit A4 — they used to
# count distinct raw logged names against the flat server mention TSVs, whose
# first mentions are dominated by the nightly File Maintenance sweep; the
# partner blue curve claimed the whole roster while first-seen-both said 26
# were never seen). A logged site value is canonicalized to the configured
# subscription it uniquely prefixes (the uc-status/first-seen rule); a value
# matching no configured name drops out.
#
# ORANGE is transfer evidence only. BLUE = orange plus the CURATED server-only
# sets — the base-cache blue entities (and, for subscriptions, the UC3
# clean-poll greens of blue/_greenpoll.tsv, seen with no transfer rows) — each
# entering on its FIRST-SEEN day from the first-seen ledger, clamped into the
# slot window (a
# transfer-seen entity enters blue with orange, at its first File). So at the
# last slot: blue == orange + the blue(+greenpoll) count — which is
# first-seen-both.rpt's SEEN, while orange ends at first-seen.rpt's DATED Seen
# (its Seen minus the no-date bucket). Those two identities are the
# cross-checks after any change here.
#
# PARTNER attribution is the site-wide UNION rule plus the coverage pages'
# host evidence: col 20 ∪ the subscription's configured partner(s) (col 12 on
# xref/_subscriptions-partners.tsv) ∪ the remote host's partner(s) (col 15 on
# xref/_hosts-partners.tsv) — a both-partner File carries an EMPTY col 20
# because the parse abstains on a two-group account.
#
# A missing base cache, xref map or ledger just collapses blue onto orange;
# nothing fails.
sub1=""; sub2=""; sub4=""; sub6=""; sub12=""; sub24=""
ptn1=""; ptn2=""; ptn4=""; ptn6=""; ptn12=""; ptn24=""
acc1=""; acc2=""; acc4=""; acc6=""; acc12=""; acc24=""
# The first-seen ledger day files, listed for the awk (which cannot glob):
# <member>-both-<date>.rpt, written by bin/analyses/reports/first-seen.sh —
# which the build runs BEFORE the dashboards (CLAUDE.md's report order), so
# the list is this run's. No files -> an empty list -> undated extras, which
# the walker places at the window start.
_fsl=$(mktemp "${TMPDIR:-/tmp}/axfsl.XXXXXX")
_sflat="$DATA/server/cache/_subscriptions.tsv"; [ -f "$_sflat" ] || _sflat=/dev/null
_aflat="$DATA/server/cache/_accounts.tsv"; [ -f "$_aflat" ] || _aflat=/dev/null
trap 'rm -f "$_fsl"' EXIT
if [ -d "$DATA/first-seen" ]; then
    find "$DATA/first-seen" -name 'subscriptions-both-*.rpt' -o -name 'partners-both-*.rpt' -o -name 'accounts-both-*.rpt' \
        2>/dev/null | LC_ALL=C sort > "$_fsl" || : > "$_fsl"
fi
if [ -f "$TR" ]; then
    sser=$(awk -F'\t' -v SUBPF="$XR/_subscriptions-partners.tsv" \
               -v HPF="$XR/_hosts-partners.tsv" \
               -v SUBBF="$DATA/flow-manager/base/_subscriptions.tsv" \
               -v PTNBF="$DATA/flow-manager/base/_partners.tsv" \
               -v ACCBF="$DATA/flow-manager/base/_accounts.tsv" \
               -v GPF="$DATA/blue/_greenpoll.tsv" \
               -v RFF="$DATA/blue/_redflip.tsv" \
               -v PACCF="$XR/_partners-accounts.tsv" \
               -v PSUBF="$XR/_partners-subscriptions.tsv" \
               -v SFLAT="$_sflat" -v AFLAT="$_aflat" \
               -v FSLIST="$_fsl" '
        function jdn(y,m,d,  a){ a=int((14-m)/12); y=y+4800-a; m=m+12*a-3; return d+int((153*m+2)/5)+365*y+int(y/4)-int(y/100)+int(y/400)-32045 }
        function fromjdn(j,   a,b,c,dd,e,mm,day,mon,yr) { a=j+32044; b=int((4*a+3)/146097); c=a-int(146097*b/4); dd=int((4*c+3)/1461); e=c-int(1461*dd/4); mm=int((5*e+2)/153); day=e-int((153*mm+2)/5)+1; mon=mm+3-12*int(mm/10); yr=100*b+dd-4800+int(mm/10); return sprintf("%04d-%02d-%02d", yr, mon, day) }
        # a missing file makes getline return -1, so an absent map is simply empty
        function load_pairs(f, M,   l, z, n) {
            while ((getline l < f) > 0) { n = split(l, z, "\t")
                if (n >= 2 && z[1] != "" && z[2] != "") M[toupper(z[1])] = M[toupper(z[1])] SUBSEP z[2] }
            close(f) }
        # slot index of one "YYYY-MM-DD HH:MM:SS.mmm" server timestamp
        function ts2slot(ts, r,   d, h, j) {
            d = substr(ts, 1, 10); h = substr(ts, 12, 2) + 0
            j = jdn(substr(d,1,4)+0, substr(d,6,2)+0, substr(d,9,2)+0)
            if (r == 1)  return j*24 + h
            if (r == 2)  return j*12 + int(h/2)
            if (r == 4)  return j*6 + int(h/4)
            if (r == 6)  return j*4 + int(h/6)
            if (r == 12) return j*2 + int(h/12)
            return j }
        # a logged site value -> the configured subscription it IS or uniquely
        # prefixes (the uc-status/first-seen canonicalization rule); "" = not
        # configured. Memoized — the fallback is a roster scan.
        function canon(u,   i, hit, c) {
            if (u == "") return ""
            if (u in ROST) return u
            if (u in memo) return memo[u]
            hit = ""; c = 0
            for (i = 1; i <= nro; i++) if (index(u, RO[i]) == 1 || index(RO[i], u) == 1) { hit = RO[i]; c++ }
            return memo[u] = (c == 1) ? hit : ""
        }
        # ALL the configured subscriptions a logged site value credits as SEEN
        # (2026-08-22): every roster name that PREFIXES the value — the
        # showseen/first-seen rule, which marks a configured parent name
        # (UC1_ODV_LIFE_ROTAFORM) seen through its child flows
        # (UC1_ODV_LIFE_ROTAFORM2). canon() alone dropped those four parents
        # and the curve endpoints disagreed with the First-seen figures the
        # header promises they equal (orange 279 vs 283). Falls back to the
        # unique reverse match (a truncated logged value) exactly like canon.
        # A BLUE (server-log-only) roster name is prefix-credited only on an
        # EXACT match: the First seen transfer view counts blue as Not seen, so
        # a blue parent (UC2_ZG_IKAZ_CLIX) must stay off the orange curve however
        # its child flows spell — it enters the BLUE curve at its ledger day.
        # Returns a SUBSEP-joined list, memoized per distinct value.
        function credits(u,   i, s, c) {
            if (u == "") return ""
            if (u in mcred) return mcred[u]
            s = ""; c = ""
            for (i = 1; i <= nro; i++) {
                if (index(u, RO[i]) == 1) { if (u == RO[i] || !(RO[i] in BXB)) s = s SUBSEP RO[i] }
                else if (index(RO[i], u) == 1) c = (c == "") ? RO[i] : "?"
            }
            if (s == "" && c != "" && c != "?") s = SUBSEP c
            return mcred[u] = s
        }
        # one server-only (blue/greenpoll) entity enters blue on the day it was
        # FIRST seen, per the first-seen ledger (data/<env>/first-seen/
        # <member>-both-<date>.rpt — the same dating the First seen (both logs)
        # page publishes), clamped into the slot window. A day, not a
        # timestamp: the ledger is day-granular, so the entity joins at that
        # day\047s first slot. An entity the ledger cannot date (its "no date"
        # bucket) enters at the window start — the least-wrong choice that
        # keeps the endpoint equal to orange + the extras.
        # NEVER blue/_evidence.tsv: that file holds each entity\047s LATEST
        # mention, so using it made 55 subscriptions enter on the last day
        # (2026-08-14) in one lump instead of on their real first sighting.
        # the day a server-only entity was FIRST seen: the ledger where it can
        # date the entity, else its earliest server MENTION (a subscription /
        # account by name; a partner through its accounts and subscriptions),
        # else "" -> the window start
        function firstday(kind, u,   ts, n2, A2, i2, k2, t2, best) {
            if ((kind SUBSEP u) in FSD) return FSD[kind SUBSEP u]
            ts = ""
            if (kind == "S") { if (u in SM) ts = SM[u] }
            else if (kind == "A") { if (u in AM) ts = AM[u] }
            else {
                if (u in PACC) { n2 = split(substr(PACC[u], 2), A2, SUBSEP)
                    for (i2 = 1; i2 <= n2; i2++) { k2 = toupper(A2[i2])
                        if (k2 in AM) { t2 = AM[k2]; if (best == "" || t2 < best) best = t2 } } }
                if (u in PSUB) { n2 = split(substr(PSUB[u], 2), A2, SUBSEP)
                    for (i2 = 1; i2 <= n2; i2++) { k2 = toupper(A2[i2])
                        if (k2 in SM) { t2 = SM[k2]; if (best == "" || t2 < best) best = t2 } } }
                ts = best
            }
            return (ts != "") ? substr(ts, 1, 10) : ""
        }
        function mark(kind, u, dy,   ri9, r9, sl9) {
            for (ri9 = 1; ri9 <= 6; ri9++) {
                r9 = RQ[ri9]
                sl9 = (dy != "") ? ts2slot(dy " 00:00:00.000", r9) : tmin[r9]
                if (sl9 < tmin[r9]) sl9 = tmin[r9]
                if (sl9 > tmax[r9]) sl9 = tmax[r9]
                bl[r9 SUBSEP kind SUBSEP sl9]++
            }
        }
        # one entity sighting: its FIRST slot, its membership in the per-(r,kind)
        # entity list, and the outcome of its LATEST File within this slot (the
        # cache is CoreId-sorted, so compare sortkeys — not arrival order)
        function note(r, kind, e, t,   k, u, ek) {
            if (e == "") return
            u = toupper(e); k = r SUBSEP kind SUBSEP u
            if (!(k in f1)) { f1[k] = t; ents[r SUBSEP kind] = ents[r SUBSEP kind] SUBSEP u }
            else if (t < f1[k]) f1[k] = t
            ek = k SUBSEP t
            if (!(ek in mk) || $6 > mk[ek]) { mk[ek] = $6; lo[ek] = BAD } }
        # one kind at one resolution; spd = buckets per day. Walks the slot range
        # NUMERICALLY (no awk hash order in the output), carrying four running
        # figures: two cumulative first-sighting counts and the green/red split,
        # which it re-derives from each entity state transition.
        function build(kind, r, spd,   t, d, lab, s, blue, org, grn, red, ne, EZ, i, e, st, ek) {
            ne = split(substr(ents[r SUBSEP kind], 2), EZ, SUBSEP)
            delete ST
            s = ""; blue = 0; org = 0; grn = 0; red = 0
            for (t = tmin[r]; t <= tmax[r]; t++) {
                blue += bl[r SUBSEP kind SUBSEP t] + 0
                org  += og[r SUBSEP kind SUBSEP t] + 0
                for (i = 1; i <= ne; i++) {
                    e = EZ[i]; ek = r SUBSEP kind SUBSEP e SUBSEP t
                    if (!(ek in lo)) continue
                    st = lo[ek]
                    if (!(e in ST))       { if (st) red++; else grn++ }
                    else if (ST[e] != st) { if (st) { red++; grn-- } else { grn++; red-- } }
                    ST[e] = st
                }
                if (spd == 24)     { d = fromjdn(int(t/24)); lab = substr(d,6) sprintf(" %02dh", t%24) }
                else if (spd == 12) { d = fromjdn(int(t/12)); lab = substr(d,6) sprintf(" %02dh", (t%12)*2) }
                else if (spd == 6) { d = fromjdn(int(t/6)); lab = substr(d,6) sprintf(" %02dh", (t%6)*4) }
                else if (spd == 4) { d = fromjdn(int(t/4)); lab = substr(d,6) sprintf(" %02dh", (t%4)*6) }
                else if (spd == 2) { d = fromjdn(int(t/2)); lab = substr(d,6) sprintf(" %02dh", (t%2)*12) }
                else               { d = fromjdn(t);        lab = substr(d,6) }
                s = s (s==""?"":"|") lab ":" blue ":" org ":" grn ":" red ":" d
            }
            print "SEEN" kind r "\t" s }
        BEGIN {
            RQ[1]=1; RQ[2]=2; RQ[3]=4; RQ[4]=6; RQ[5]=12; RQ[6]=24
            load_pairs(SUBPF, SUBP); load_pairs(HPF, HP)
            load_pairs(PACCF, PACC); load_pairs(PSUBF, PSUB)   # the blue partners\047 mention fallback
            # the configured subscription roster (canonicalization) + its blue
            # set; a missing file makes getline return -1 -> empty
            # The base cache is AMENDED after flow-manager (result.sh
            # discover_logged appends every logged-but-unconfigured name, the
            # synthetic "<account>_UNKNOWN" ones included). First seen excludes
            # the synthetic names, and the curve endpoints must keep equalling
            # its figures — so they stay out of the roster here too (2026-08-22).
            while ((getline l9 < SUBBF) > 0) { n9 = split(l9, z9, "\t")
                if (n9 >= 1 && z9[1] != "" && z9[1] !~ /_UNKNOWN$/) { u9 = toupper(z9[1]); ROST[u9] = 1; RO[++nro] = u9
                    # BXB = BASE blue only — the credits() prefix-skip must not
                    # catch the greenpoll names BXS also holds (green, dated in
                    # First seen, legitimately prefix-credited)
                    if (n9 >= 3 && z9[3] == "blue") { BXS[u9] = 1; BXB[u9] = 1 } } }
            close(SUBBF)
            while ((getline l9 < PTNBF) > 0) { n9 = split(l9, z9, "\t")
                if (n9 >= 3 && z9[1] != "" && z9[3] == "blue") BXP[toupper(z9[1])] = 1 }
            close(PTNBF)
            # accounts: the configured roster (only configured names are
            # counted, as for subscriptions) + its blue set
            while ((getline l9 < ACCBF) > 0) { n9 = split(l9, z9, "\t")
                if (n9 >= 1 && z9[1] != "") { u9 = toupper(z9[1]); AROST[u9] = 1
                    if (n9 >= 3 && z9[3] == "blue") BXA[u9] = 1 } }
            close(ACCBF)
            # the UC3 clean-poll greens: seen with no transfer rows -> blue side
            while ((getline l9 < GPF) > 0) { sub(/\t.*$/, "", l9); if (l9 != "") BXS[toupper(l9)] = 1 }
            close(GPF)
            # the FIRST-SEEN ledger, both-logs view: one file per member and
            # day, its ROWs the entities first seen that day. Read through the
            # file LIST the shell globbed (awk cannot glob), so a member/day
            # with no file simply contributes nothing.
            while ((getline l9 < FSLIST) > 0) {
                if (l9 == "") continue
                fb = l9; sub(/^.*\//, "", fb)                       # <member>-both-<date>.rpt
                if (fb !~ /-both-[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]\.rpt$/) continue
                fk = (index(fb, "subscriptions-both-") == 1) ? "S" \
                     : ((index(fb, "partners-both-") == 1) ? "P" \
                     : ((index(fb, "accounts-both-") == 1) ? "A" : ""))
                if (fk == "") continue
                fd = substr(fb, length(fb) - 13, 10)                 # the date in the name
                while ((getline m9 < l9) > 0) {
                    if (substr(m9, 1, 4) != "ROW\t") continue
                    split(m9, z9, "\t"); if (z9[2] == "") continue
                    FSD[fk SUBSEP toupper(z9[2])] = fd
                }
                close(l9)
            }
            close(FSLIST)
        }
        # the flat server MENTION streams ("date time <TAB> name", one row per
        # runtime record naming a configured entity), reduced to the EARLIEST
        # mention per name — the fallback first sighting for a server-only
        # entity the first-seen ledger cannot date (its dating rule is the
        # oldest first TRANSFER of the cross-referenced entities, which a
        # never-transferred flow simply has none of)
        FILENAME == SFLAT { if ($2 != "") { u9 = toupper($2); if (!(u9 in SM) || $1 < SM[u9]) SM[u9] = $1 } next }
        FILENAME == AFLAT { if ($2 != "") { u9 = toupper($2); if (!(u9 in AM) || $1 < AM[u9]) AM[u9] = $1 } next }
        $4=="" || $5 !~ /^[0-9][0-9]:/ { next }
        {
            h = int(substr($5,1,2))
            T[1]  = $7*24 + h
            T[2]  = $7*12 + int(h/2)
            T[4]  = $7*6 + int(h/4)
            T[6]  = $7*4 + int(h/6)
            T[12] = $7*2 + int(h/12)
            T[24] = $7
            # RED = the RESULT COLOUR, not the outcome policy (2026-08): an
            # expired-last flow is ORANGE site-wide — a pickup problem, not a
            # failure — so only a FAILED File reddens the stack. Expired and
            # Waiting Files leave the state green ("not failing"), which keeps
            # green + red summing to the seen total the card promises.
            BAD = ($2 == "Failed")
            cs = canon(toupper($12))                     # the ONE flow (partner join below)
            ncr = split(substr(credits(toupper($12)), 2), CRZ, SUBSEP)   # + every prefix-parent it credits as seen
            for (ri = 1; ri <= 6; ri++) {
                r = RQ[ri]; t = T[r]
                if (!(r in tmin) || t < tmin[r]) tmin[r] = t
                if (!(r in tmax) || t > tmax[r]) tmax[r] = t
                for (icr = 1; icr <= ncr; icr++) note(r, "S", CRZ[icr], t)
                note(r, "P", $20, t)
                # accounts: the File\047s own account (col 3), configured only —
                # its green/red is its own last File, like a partner\047s
                if ($3 != "" && (toupper($3) in AROST)) note(r, "A", $3, t)
            }
            if (cs != "" && (cs in SUBP)) {
                np = split(substr(SUBP[cs], 2), PZ, SUBSEP)
                for (ip = 1; ip <= np; ip++)
                    for (ri = 1; ri <= 6; ri++) note(RQ[ri], "P", PZ[ip], T[RQ[ri]])
            }
            if ($15 != "" && (toupper($15) in HP)) {     # the coverage pages'\'' host evidence
                np = split(substr(HP[toupper($15)], 2), PZ, SUBSEP)
                for (ip = 1; ip <= np; ip++)
                    for (ri = 1; ri <= 6; ri++) note(RQ[ri], "P", PZ[ip], T[RQ[ri]])
            }
        }
        END {
            if (!(6 in tmax)) exit
            # THE SERVER-LOG RED FLIPS (2026-08): bin/build/result.sh reddens a
            # flow on an E-level line AFTER its last OK transfer, and the home
            # counts those flows red — so this stack must too, or its last slot
            # disagrees with the home figure. blue/_redflip.tsv carries the
            # evidence stamp ("YYYY-MM-DD HH:MM:SS.mmm"), which converts to the
            # sortkey shape and lands in the slot it happened in; injected as an
            # observation, so a LATER OK File still turns the flow back green.
            # Subscriptions only — the flip is a subscription verdict; partner
            # and account stacks stay per-File (their base colours are rollups
            # this walk cannot reproduce per slot).
            while ((getline l9 < RFF) > 0) {
                n9 = split(l9, z9, "\t")
                if (n9 < 2 || z9[1] == "") continue
                u9 = canon(toupper(z9[1])); if (u9 == "") continue
                d9 = substr(z9[2], 1, 10); h9 = int(substr(z9[2], 12, 2))
                if (d9 !~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$/) continue
                sk9 = substr(d9,1,4) substr(d9,6,2) substr(d9,9,2) substr(z9[2], 12)
                j9 = jdn(substr(d9,1,4)+0, substr(d9,6,2)+0, substr(d9,9,2)+0)
                TF[1] = j9*24 + h9; TF[2] = j9*12 + int(h9/2); TF[4] = j9*6 + int(h9/4); TF[6] = j9*4 + int(h9/6)
                TF[12] = j9*2 + int(h9/12); TF[24] = j9
                for (ri = 1; ri <= 6; ri++) {
                    r9 = RQ[ri]; t9 = TF[r9]
                    if (!(r9 in tmin) || t9 < tmin[r9] || t9 > tmax[r9]) continue
                    k9 = r9 SUBSEP "S" SUBSEP u9
                    if (!(k9 in f1)) continue        # a flip needs a transfer-seen flow
                    ek9 = k9 SUBSEP t9
                    if (!(ek9 in mk) || sk9 > mk[ek9]) { mk[ek9] = sk9; lo[ek9] = 1 }
                }
            }
            close(RFF)
            # transfer first-sightings: the orange increments, and blue with
            # them (a transfer-seen entity enters the union at its first File).
            # Hash iteration order is fine: every target is a commutative sum.
            for (k in f1) {
                split(k, a, SUBSEP); r = a[1]; kind = a[2]; e = a[3]
                f = f1[k]
                og[r SUBSEP kind SUBSEP f]++
                bl[r SUBSEP kind SUBSEP f]++
                dn[kind SUBSEP e] = 1                 # already counted in blue
            }
            # the SERVER-ONLY entities: the curated blue sets (+ greenpoll for
            # subscriptions), never seen in a File — blue and nothing else, at
            # their FIRST-SEEN day (the ledger)
            for (u in BXS) if (!(("S" SUBSEP u) in dn)) mark("S", u, firstday("S", u))
            for (u in BXP) if (!(("P" SUBSEP u) in dn)) mark("P", u, firstday("P", u))
            for (u in BXA) if (!(("A" SUBSEP u) in dn)) mark("A", u, firstday("A", u))
            build("S", 1, 24); build("S", 2, 12); build("S", 4, 6); build("S", 6, 4); build("S", 12, 2); build("S", 24, 1)
            build("P", 1, 24); build("P", 2, 12); build("P", 4, 6); build("P", 6, 4); build("P", 12, 2); build("P", 24, 1)
            build("A", 1, 24); build("A", 2, 12); build("A", 4, 6); build("A", 6, 4); build("A", 12, 2); build("A", 24, 1)
        }' "$_sflat" "$_aflat" "$TR")
    for r in 1 2 4 6 12 24; do
        eval "sub$r=\$(printf '%s\n' \"\$sser\" | awk -F'\t' -v k=SEENS\$r '\$1==k{print \$2}')"
        eval "ptn$r=\$(printf '%s\n' \"\$sser\" | awk -F'\t' -v k=SEENP\$r '\$1==k{print \$2}')"
        eval "acc$r=\$(printf '%s\n' \"\$sser\" | awk -F'\t' -v k=SEENA\$r '\$1==k{print \$2}')"
    done
fi

# ---- the four UC STATUS views ----------------------------------------------
# One card per use case, OVERVIEW ONLY (the day pages keep their own five views).
# Each is a total-preserving STACK: every slot sums to that UC's configured
# subscription count, which never moves — we hold no config history, so the top
# edge is flat and the card reads purely as a composition shifting over time.
#
# The classification lives in the report that owns it (the pesit-slots.tsv
# pattern): bin/analyses/reports/uc<n>-status.sh writes a PER-HOUR sidecar
# `date <TAB> hour <TAB> <the statuses in stack order>`, and all this does is
# re-bucket. A status is a STATE, not a rate, so a coarser slot takes the LAST
# hour inside it — never a sum, and never an average. One hour divides 4/6/12/24
# exactly, so int(abs_hour / bucket) aligns every bucket on a day boundary.
# A slot with no sidecar row CARRIES THE PREVIOUS STATE FORWARD (that is what a
# state series does between observations) rather than showing a gap.
#
# UC1/UC3/UC4 share the 7-status shape (chart kind `ucst`) — UC1 has no "no
# files" status and emits a constant 0 there, so one kind covers the three.
# UC2's five statuses are a different set entirely (kind `ucst2`).
for u in 1 2 3 4; do
    eval "uc${u}s1=''; uc${u}s2=''; uc${u}s4=''; uc${u}s6=''; uc${u}s12=''; uc${u}s24=''"
    US="$DATA/server/reports/uc$u-slots.tsv"
    [ -s "$US" ] || continue
    userr=$(awk -F'\t' '
        function jdn(y,m,d,  a){ a=int((14-m)/12); y=y+4800-a; m=m+12*a-3; return d+int((153*m+2)/5)+365*y+int(y/4)-int(y/100)+int(y/400)-32045 }
        function fromjdn(j,   a,b,c,dd,e,mm,day,mon,yr) { a=j+32044; b=int((4*a+3)/146097); c=a-int(146097*b/4); dd=int((4*c+3)/1461); e=c-int(1461*dd/4); mm=int((5*e+2)/153); day=e-int((153*mm+2)/5)+1; mon=mm+3-12*int(mm/10); yr=100*b+dd-4800+int(mm/10); return sprintf("%04d-%02d-%02d", yr, mon, day) }
        $1 ~ /^[0-9][0-9][0-9][0-9]-/ {
            k = jdn(substr($1,1,4)+0, substr($1,6,2)+0, substr($1,9,2)+0) * 24 + ($2+0)
            v = ""; for (i = 3; i <= NF; i++) v = v ":" $i
            V[k] = v
            if (kmin == "" || k < kmin) kmin = k
            if (k > kmax) kmax = k
        }
        END {
            if (kmin == "") exit
            nr = split("1 2 4 6 12 24", RS_, " ")
            for (q = 1; q <= nr; q++) {
                r = RS_[q]; ser = ""; last = ""
                for (sl = int(kmin/r); sl <= int(kmax/r); sl++) {
                    cur = ""                                  # the LAST hour of this slot that has data
                    for (hh = sl*r + r - 1; hh >= sl*r; hh--) if (hh in V) { cur = V[hh]; break }
                    if (cur == "") cur = last                 # carry the state forward
                    if (cur == "") continue                   # nothing observed yet at all
                    last = cur
                    d = fromjdn(int(sl*r/24))
                    lab = substr(d,6,5); if (r < 24) lab = lab sprintf(" %02dh", (sl*r)%24)
                    ser = ser (ser==""?"":"|") lab cur ":" d
                }
                print "S" r "\t" ser
            }
        }' "$US")
    for r in 1 2 4 6 12 24; do
        eval "uc${u}s$r=\$(printf '%s\n' \"\$userr\" | awk -F'\t' -v k=S\$r '\$1==k{print \$2}')"
    done
done

# the PeSIT view: bin classification lives in bin/server/reports/pesit.sh,
# which writes the 30-minute pesit-slots.tsv sidecar — summed here to the same
# three resolutions (12 half-hours per 6h bucket, 24 per 12h, 48 per day),
# zeros filled across the sidecar day span. Plain sums, unlike the transfer
# percentiles, but kept in one place with them.
pes1=""; pes2=""; pes4=""; pes6=""; pes12=""; pes24=""
PS="$DATA/server/reports/pesit-slots.tsv"
if [ -s "$PS" ]; then
    pser=$(awk -F'\t' '
        function jdn(y,m,d,  a){ a=int((14-m)/12); y=y+4800-a; m=m+12*a-3; return d+int((153*m+2)/5)+365*y+int(y/4)-int(y/100)+int(y/400)-32045 }
        function fromjdn(j,   a,b,c,dd,e,mm,day,mon,yr) { a=j+32044; b=int((4*a+3)/146097); c=a-int(146097*b/4); dd=int((4*c+3)/1461); e=c-int(1461*dd/4); mm=int((5*e+2)/153); day=e-int((153*mm+2)/5)+1; mon=mm+3-12*int(mm/10); yr=100*b+dd-4800+int(mm/10); return sprintf("%04d-%02d-%02d", yr, mon, day) }
        function bump(r, t,   k) { k = r SUBSEP t
            if (!(r in tmin) || t < tmin[r]) tmin[r] = t
            if (!(r in tmax) || t > tmax[r]) tmax[r] = t
            o[k] += $3; i[k] += $4 }
        function build(r, spd,   t, k, d, lab, s) {
            s = ""
            for (t = tmin[r]; t <= tmax[r]; t++) {
                k = r SUBSEP t
                if (spd == 24)     { d = fromjdn(int(t/24)); lab = substr(d,6) sprintf(" %02dh", t%24) }
                else if (spd == 12) { d = fromjdn(int(t/12)); lab = substr(d,6) sprintf(" %02dh", (t%12)*2) }
                else if (spd == 6) { d = fromjdn(int(t/6)); lab = substr(d,6) sprintf(" %02dh", (t%6)*4) }
                else if (spd == 4) { d = fromjdn(int(t/4)); lab = substr(d,6) sprintf(" %02dh", (t%4)*6) }
                else if (spd == 2) { d = fromjdn(int(t/2)); lab = substr(d,6) sprintf(" %02dh", (t%2)*12) }
                else               { d = fromjdn(t);        lab = substr(d,6) }
                s = s (s==""?"":"|") lab ":" o[k]+0 ":" i[k]+0 ":" d
            }
            print "PES" r "\t" s
        }
        { split($1, p, "-"); j = jdn(p[1]+0, p[2]+0, p[3]+0)
          bump(1,  j*24 + int($2/2))
          bump(2,  j*12 + int($2/4))
          bump(4,  j*6 + int($2/8))
          bump(6,  j*4 + int($2/12))
          bump(12, j*2 + int($2/24))
          bump(24, j) }
        END { if (6 in tmax) { build(1, 24); build(2, 12); build(4, 6); build(6, 4); build(12, 2); build(24, 1) } }' "$PS")
    for r in 1 2 4 6 12 24; do
        eval "pes$r=\$(printf '%s\n' \"\$pser\" | awk -F'\t' -v k=PES\$r '\$1==k{print \$2}')"
    done
fi

# ---- the KPI daily series ---------------------------------------------------
# One K line per calendar day (K⇥YYYYMMDD⇥files⇥failed⇥volume⇥records⇥errors):
# the five KPI cards follow the From/To range client-side (report.js
# setupDaytop) — Files/failure-rate/Volume from the logical-transfer cache,
# Server records/error-rate from the per-day topview rows (the Date cell
# stripped of its @{href=…} attr). A dateless File is in the baked full-period
# figures only — the full range restores those exactly.
kpid=""
if [ -f "$TR" ] || [ -f "$SV" ]; then
    _trsrc="$TR"; [ -f "$_trsrc" ] || _trsrc=/dev/null
    _svsrc="$SV"; [ -f "$_svsrc" ] || _svsrc=/dev/null
    kpid=$(awk -F'\t' -v SVF="$_svsrc" '
        FILENAME == SVF {
            if ($1 == "ROW") { d = $2; sub(/^@\{[^}]*\}/, "", d)
                if (d ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$/) { R[d] += $3; E[d] += $7; D[d] = 1 } }
            next }
        $4 != "" { F[$4]++; if ($2 == "Failed" || $2 == "Expired") X[$4]++; V[$4] += $8; D[$4] = 1 }
        END {
            n = 0
            for (d in D) {                        # sorted by insertion, never hash order
                j = ++n; DT[j] = d
                while (j > 1 && DT[j-1] > DT[j]) { t = DT[j-1]; DT[j-1] = DT[j]; DT[j] = t; j-- }
            }
            for (i = 1; i <= n; i++) { d = DT[i]; dc = d; gsub(/-/, "", dc)
                printf "K\t%s\t%d\t%d\t%d\t%d\t%d\n", dc, F[d]+0, X[d]+0, V[d]+0, R[d]+0, E[d]+0 }
        }' "$_svsrc" "$_trsrc")
fi

# ---- the six Top-5 tables ---------------------------------------------------
# The day pages' "Busiest this day" block over the FULL period: the five
# biggest partners and subscriptions by Files, Volume and Errors, emitted as
# the same TOP lines (TOP⇥kind⇥title⇥unit⇥href⇥name␟value…) the day .rpts
# carry, rendered by publish_lib's shared top_table. Same rules as
# bin/day/reports.sh: partner attribution is the site-wide UNION (col 20 ∪ the
# subscription's configured partners), top5 is a bounded insert breaking ties
# on NAME (never awk hash order), Volume values are humanised. The "See more"
# links open the matching Entities view sorted descending on the same column —
# no ?axway_date, so the page opens at its full-range default (datereset).
tops=""
if [ -f "$TR" ]; then
    tops=$(awk -F'\t' -v SUBPF="$XR/_subscriptions-partners.tsv" '
        function human(b,   u,i,v){ split("B KB MB GB TB PB",u," "); i=1; v=b+0; while(v>=1024&&i<6){v/=1024;i++} return (i==1)?sprintf("%d %s",v,u[i]):sprintf("%.2f %s",v,u[i]) }
        function tally(kind, nm,   k, kd, e9) {
            if (nm == "") return
            e9 = ($2 == "Failed" || $2 == "Expired") ? 1 : 0
            k = kind SUBSEP nm
            if (!(k in FC)) NL[kind] = NL[kind] US nm   # first sighting: join the name list
            FC[k]++
            VC[k] += $8
            EC[k] += e9
            # the per-day cells behind the client-side date filter (TOPDATA
            # below). A dateless File is in the full-period figures only —
            # report.js restores the baked rows at the full range, so nothing
            # is lost there.
            if ($4 != "") {
                kd = k SUBSEP $4
                DS[$4] = 1
                FCD[kd]++
                VCD[kd] += $8
                ECD[kd] += e9
            } }
        # the five biggest of ONE metric as "name US value US …" (the day
        # pages rule: bounded insert, ties break on NAME)
        function top5(A, kind,   nn, NM, i, j, nm, v, c, TV, TN, s) {
            c = 0
            nn = split(NL[kind], NM, US)
            for (i = 1; i <= nn; i++) {
                nm = NM[i]; if (nm == "") continue
                v = A[kind SUBSEP nm] + 0
                if (v <= 0) continue
                j = c
                while (j >= 1 && (TV[j] < v || (TV[j] == v && TN[j] > nm))) { TV[j+1] = TV[j]; TN[j+1] = TN[j]; j-- }
                TV[j+1] = v; TN[j+1] = nm
                c++; if (c > 5) c = 5
            }
            s = ""
            for (i = 1; i <= c; i++) s = s (s == "" ? "" : US) TN[i] US TV[i]
            return s }
        function top5b(A, kind,   raw, nn, Z, i, s) {
            raw = top5(A, kind); if (raw == "") return ""
            nn = split(raw, Z, US); s = ""
            for (i = 1; i <= nn; i += 2) s = s (s == "" ? "" : US) Z[i] US human(Z[i+1])
            return s }
        BEGIN { US = sprintf("%c", 31)
            # subscription -> its configured partner(s); a missing map just
            # leaves the partner tables to col 20 alone (getline returns < 0)
            while ((getline sl < SUBPF) > 0) { np2 = split(sl, sz, "\t")
                if (np2 >= 2 && sz[1] != "" && sz[2] != "") SUBP[toupper(sz[1])] = SUBP[toupper(sz[1])] US sz[2] }
            close(SUBPF) }
        {
            tally("S", $12)
            tally("P", $20)
            if ($12 != "" && (toupper($12) in SUBP)) {
                npt = split(substr(SUBP[toupper($12)], 2), PTZ, US)
                for (ipt = 1; ipt <= npt; ipt++) if (PTZ[ipt] != $20) tally("P", PTZ[ipt])
            }
        }
        END {
            # the Entities layout is Name 0 · Direction 1 · Files 2 · Volume 3
            # · OK 4 · Error 5 — the sort target of each "See more" link
            for (tm = 1; tm <= 3; tm++) {
                tmet = (tm == 1) ? "Files" : (tm == 2) ? "Volume" : "Errors"
                tcol = (tm == 1) ? 2 : (tm == 2) ? 3 : 5
                for (tk = 1; tk <= 2; tk++) {
                    tkind = (tk == 1) ? "P" : "S"
                    tname = (tk == 1) ? "partners" : "subscriptions"
                    tpage = (tk == 1) ? "partner" : "subscription"
                    trows = (tm == 1) ? top5(FC, tkind) : (tm == 2) ? top5b(VC, tkind) : top5(EC, tkind)
                    if (trows == "") continue
                    printf "TOP\t%s\tTop 5 %s by %s\t%s\t../transfer/entities/%s-all.html?axway_sort=%d:-1\t%s\n", \
                        tkind, tname, tmet, tmet, tpage, tcol, trows
                }
            }
            # the per-entity daily series behind the client-side date filter
            # (TOPDATA<TAB>kind<TAB>name<TAB>YYYYMMDD:files:vol:errs|…, one line
            # per entity): a narrowed From/To must RE-SELECT the Top 5 — the
            # busiest of a week need not be the busiest of the period — so
            # report.js setupDaytop rebuilds the six tables from these. Dates
            # sorted by insertion, entities in first-sighting order (never awk
            # hash order).
            nds = 0
            for (d in DS) {
                j = ++nds; DT[j] = d
                while (j > 1 && DT[j-1] > DT[j]) { tmp = DT[j-1]; DT[j-1] = DT[j]; DT[j] = tmp; j-- }
            }
            for (tk = 1; tk <= 2; tk++) {
                tkind = (tk == 1) ? "P" : "S"
                nn = split(NL[tkind], NM, US)
                for (i = 1; i <= nn; i++) {
                    nm = NM[i]; if (nm == "") continue
                    s = ""
                    for (jd = 1; jd <= nds; jd++) {
                        kd = tkind SUBSEP nm SUBSEP DT[jd]
                        if (!(kd in FCD)) continue
                        dc = DT[jd]; gsub(/-/, "", dc)
                        s = s (s == "" ? "" : "|") dc ":" FCD[kd]+0 ":" VCD[kd]+0 ":" ECD[kd]+0
                    }
                    if (s != "") printf "TOPDATA\t%s\t%s\t%s\n", tkind, nm, s
                }
            }
        }' "$TR")
fi

{
    printf 'PAGE\tindex\n'
    printf 'TITLE\tDashboards — Cloud Reports\n'
    printf 'H1\tDashboard\n'
    printf 'DESC\tA single graphical read of both logs — the headline figures and the 6-hour trends; click any slot to drill into that day.\n'
    printf 'KPI\t%s\tFiles transferred\tlogical transfers\tblue\t../transfer/activity-per-day.html\n' "$(knum_files "${T_FILES:-0}")"
    printf 'KPI\t%s%%\tTransfer failure rate\t\tred\t../transfer/failure-rate-days.html\n' "${T_FPCT:-0}"
    printf 'KPI\t%s\tVolume moved\t\tgreen\t../transfer/volume-per-day.html\n' "$(humanbytes "${T_VOL:-0}")"
    printf 'KPI\t%s\tServer records\tlog messages\tpurple\t../server/topview.html\n' "$(knum_recs "${S_REC:-0}")"
    printf 'KPI\t%s%%\tServer error rate\t\tamber\t../server/topview.html\n' "${S_EPCT:-0}"
    # the hero + its alternates: the SIX shared slot views plus the two
    # overview-only cumulative curves, chart type
    # `slots` (KIND, DATA, LINKPAT args). Labels must stay EXACTLY in sync
    # with the day pages' CARDALT labels (button 0 "Duration" is hardcoded in
    # both publishes) — the view selection carries via them. PeSIT is LAST
    # and conditional, so omitting it never shifts the earlier button indices.
    if [ -n "$dur6" ]; then
        printf 'CARD\tFile duration percentiles\tP50 dark green, P90 orange, P98 dark red — each band tops out at that percentile of the OK File durations in that slot; click a slot for its day\t../transfer/duration.html\tspan2\tslots\tdur\t%s\t../day/{}.html?axway_hero=Duration\t%s\t%s\t%s\t%s\t%s\n' "$dur6" "60:$dur1" "120:$dur2" "240:$dur4" "720:$dur12" "1440:$dur24"
        printf 'CARDALT\tFiles processed\tFiles processed\tOK Files (Processed + Waiting) per slot; click a slot for its day\t../transfer/activity-per-day.html\tspan2\tslots\tcount\t%s\t../day/{}.html?axway_hero=Files%%20processed\t%s\t%s\t%s\t%s\t%s\n' "$cnt6" "60:$cnt1" "120:$cnt2" "240:$cnt4" "720:$cnt12" "1440:$cnt24"
        printf 'CARDALT\tVolume\tVolume\tbytes moved per slot; click a slot for its day\t../transfer/volume-per-day.html\tspan2\tslots\tbytes\t%s\t../day/{}.html?axway_hero=Volume\t%s\t%s\t%s\t%s\t%s\n' "$vol6" "60:$vol1" "120:$vol2" "240:$vol4" "720:$vol12" "1440:$vol24"
        [ -n "$thr6" ] && printf 'CARDALT\tThroughput\tWire throughput\tMB/s per slot — the slot'"'"'s counted bytes over its counted leg durations, from the legs big and slow enough to measure a rate (over 1 MB, over 500 ms); an empty slot had none\t../transfer/route-throughput.html\tspan2\tslots\tspeed\t%s\t../day/{}.html?axway_hero=Duration\t%s\t%s\t%s\t%s\t%s\n' "$thr6" "60:$thr1" "120:$thr2" "240:$thr4" "720:$thr12" "1440:$thr24"
        printf 'CARDALT\tError %% Files\tTransfer error rate\tper slot, the %% of its Files that Failed or Expired — a slot with no Files shows a gap\t../transfer/failure-rate-days.html\tspan2\tslots\trate\t%s\t../day/{}.html?axway_hero=Error%%20%%25%%20Files\t%s\t%s\t%s\t%s\t%s\n' "$rate6" "60:$rate1" "120:$rate2" "240:$rate4" "720:$rate12" "1440:$rate24"
        printf 'CARDALT\tTransfer errors\tTransfer errors\tTransfers (raw log records) whose Status is Failed or Failed Subtransmission, per slot — one File can contribute several failed legs; a quiet slot is a real zero\t../transfer/failure-heatmap.html\tspan2\tslots\terrs\t%s\t../day/{}.html?axway_hero=Transfer%%20errors\t%s\t%s\t%s\t%s\t%s\n' "$err6" "60:$err1" "120:$err2" "240:$err4" "720:$err12" "1440:$err24"
        [ -n "$con6" ] && printf 'CARDALT\tConnections\tConnections opened\ttechnical connections (SSH or PeSIT sessions) OPENED in the slot, split by who dialled: the partner'"'"'s client, or us; one session counts once, in the slot it started\t../transfer/connection-efficiency.html\tspan2\tslots\tconns\t%s\t../day/{}.html?axway_hero=Files%%20processed\t%s\t%s\t%s\t%s\t%s\n' "$con6" "60:$con1" "120:$con2" "240:$con4" "720:$con12" "1440:$con24"
        # The two CUMULATIVE views. Their slot links deliberately carry
        # ?axway_hero=Files%20processed, NOT their own label: a day page has no
        # "seen" curve to show (a single day is one point on it), so clicking a
        # slot opens that day's Files-processed graph. The link pattern is a
        # free-form string — nothing ties it to the card's own view.
        [ -n "$ptn6" ] && printf 'CARDALT\tSeen|Partners\tPartners seen\thow many partners the site had seen by then: blue in the transfer + server logs, orange in the transfer log, then that orange split into green (its latest File was delivered — expired pickups and waiting files count green, matching the site-wide colours) and red (its latest File FAILED) — green and red move both ways and always sum to orange; click a slot for that day'"'"'s Files processed\t../transfer/entities/partner-all.html\tspan2\tslots\tseen\t%s\t../day/{}.html?axway_hero=Files%%20processed\t%s\t%s\t%s\t%s\t%s\n' "$ptn6" "60:$ptn1" "120:$ptn2" "240:$ptn4" "720:$ptn12" "1440:$ptn24"
        [ -n "$acc6" ] && printf 'CARDALT\tSeen|Accounts\tAccounts seen\thow many accounts the site had seen by then: blue in the transfer + server logs, orange in the transfer log, then that orange split into green (its latest File was delivered — expired pickups and waiting files count green, matching the site-wide colours) and red (its latest File FAILED) — green and red move both ways and always sum to orange; click a slot for that day'"'"'s Files processed\t../transfer/entities/account-all.html\tspan2\tslots\tseen\t%s\t../day/{}.html?axway_hero=Files%%20processed\t%s\t%s\t%s\t%s\t%s\n' "$acc6" "60:$acc1" "120:$acc2" "240:$acc4" "720:$acc12" "1440:$acc24"
        [ -n "$sub6" ] && printf 'CARDALT\tSeen|Subscriptions\tSubscriptions seen\thow many subscriptions the site had seen by then: blue in the transfer + server logs, orange in the transfer log, then that orange split into green and red by the site-wide RESULT colour: red = the flow is failing (its latest File FAILED, or the server log erred after its last delivery — the same red as the home page), green = everything else, expired pickups and waiting files included. Green and red move both ways and always sum to orange; click a slot for that day'"'"'s Files processed\t../transfer/entities/subscription-all.html\tspan2\tslots\tseen\t%s\t../day/{}.html?axway_hero=Files%%20processed\t%s\t%s\t%s\t%s\t%s\n' "$sub6" "60:$sub1" "120:$sub2" "240:$sub4" "720:$sub12" "1440:$sub24"
        # the four UC status stacks — OVERVIEW ONLY, so their labels deliberately
        # match no day-page button (picking one and opening a day page falls back
        # to Duration, exactly as picking "Partners seen" already does)
        for u in 1 2 3 4; do
            eval "s6=\$uc${u}s6; s1=\$uc${u}s1; s2=\$uc${u}s2; s4=\$uc${u}s4; s12=\$uc${u}s12; s24=\$uc${u}s24"
            [ -n "$s6" ] || continue
            k=ucst; [ "$u" = 2 ] && k=ucst2
            case "$u" in
                1) w='push flows (CFT delivers to us, we send on to the partner)' ;;
                2) w='pickup flows (the partner collects from us)' ;;
                3) w='pull flows (we poll the partner)' ;;
                4) w='delivery flows (the partner connects in and delivers to us)' ;;
            esac
            # slot clicks open the UC's status page too (2026-08) — the stack is
            # a composition over configured subscriptions, so the status page,
            # not a day page, is where a slot's story continues
            printf 'CARDALT\tUse cases|UC%s\tUC%s subscription status\tthe UC%s %s, every slot a full stack of the configured subscriptions: green OK at the bottom, the problem states ramping up, never seen (light orange) on top — the total never moves, so only the composition does\t../analyses/uc-status-uc%s.html\tspan2\tslots\t%s\t%s\t../analyses/uc-status-uc%s.html\t%s\t%s\t%s\t%s\t%s\n' \
                "$u" "$u" "$u" "$w" "$u" "$k" "$s6" "$u" "60:$s1" "120:$s2" "240:$s4" "720:$s12" "1440:$s24"
        done
        [ -n "$pes6" ] && printf 'CARDALT\tPeSIT\tPeSIT problems\tST %s CFT (red) vs CFT %s ST (purple) problem lines on the CFT link\t../server/capacity-pesit-per-day.html\tspan2\tslots\tpesit\t%s\t../day/{}.html?axway_hero=PeSIT\t%s\t%s\t%s\t%s\t%s\n' "$(printf '\342\206\222')" "$(printf '\342\206\222')" "$pes6" "60:$pes1" "120:$pes2" "240:$pes4" "720:$pes12" "1440:$pes24"
    fi
    [ -n "$tops" ] && printf '%s\n' "$tops"
    [ -n "$kpid" ] && printf '%s\n' "$kpid"
    printf 'FOOT\tOpen any report from the top-bar menus; the graph views and the Line/Bar/Solid style follow you to the day pages.\n'
} > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"
echo "Wrote $OUT" >&2
