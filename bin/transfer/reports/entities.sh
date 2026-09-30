#!/usr/bin/env bash
#
# entities.sh — THE ENTITIES PAGES (2026-09-13, user request: the grouped
# layout, built the same day as a twin under transfer/entities2/, replaced
# the classic Name · Direction · Files · Volume · OK · Retry · Resubmit ·
# Error · Last seen pages): the nine Entities reports in a GROUPED layout,
# one .rpt per entity under data/transfer/reports/entities/, rendered by
# publish_lib's render_entity_report into docs/transfer/entities/. It ALSO
# writes the nine CLASSIC records data/transfer/reports/<name>.rpt (classic_dim,
# at the bottom) — the five classic writers account.sh, subscription.sh,
# login.sh, remote-host.sh and pda-entities.sh were folded in here 2026-09-30
# (user decision; proven byte-identical): showseen.sh, entity-search.sh,
# home.sh and the server rosters read them; they render no page. And the
# MONTH STATS (month_stats, at the bottom — month-stats.sh folded in the same
# day, lean round 1, byte-identical): the 18 data/transfer/reports/month-stats/
# {this,previous}-<entity>.rpt (render_month_stats) and the all-time sidecar
# data/transfer/reports/_alltime.tsv (the analyses Subscriptions page) — sums
# of the same rows' per-day buckets.
#
# Layout: the Name, then SEVEN column groups (a GHEAD banner + the gsep=
# dividers, the Top view way), in this order:
#   Files      In · Out · Error · Error %   In/Out = the MOVEMENT direction
#              (_files.tsv col 17 — the home page's In/Out rule; a File with
#              no movement counts in the total and the Error % only)
#   Retry / Resubmit   Auto · Ok · Error   the Top view rule: Auto = an OK
#              File that carried a failed leg and no resubmitted leg (the
#              classic Retry column); Ok / Error = EVERY File with a
#              resubmitted leg (_files.tsv col 27 — a _transfers.tsv col 22
#              true leg), by its outcome; the failed leg = _files.tsv col 26
#   Duration   p90 · p95 · p99 · p100 of the OK Files' wall-clock span
#   Volume     Total · Avg (per File)
#   Transfers  Ok · Error · Error %      the LEGS (log rows) of the entity's
#              Files — every leg of every attributed File, credited to the
#              File's start day like every per-File figure on the site
#   State      Waiting · Expired         _files.tsv col 2
#   Dates      First · Last · Days (days with traffic)
# Every count cell drills to its 10 newest Files (CoreIds); the Transfers
# cells to the Files that carried a leg of that outcome; a Duration cell to
# the 10 newest OK Files at or above that percentile. An empty Retry /
# Resubmit or State group is hidden per view, the TOTAL row is last
# (publish_lib).
#
# Attribution per entity — the rule of the five former classic writers
# (account.sh, subscription.sh, login.sh, remote-host.sh, pda-entities.sh),
# whose records are written from these same rows since 2026-09-30:
#   account      _files col 3
#   subscription the distinct non-empty _transfers col 6 over the File's legs
#   login        the distinct non-empty _transfers col 5   (each: one count
#                per (name, File) pair, like the classic join)
#   remote-host  the distinct non-empty _transfers col 16, only when the File
#                connects OUT (_files col 16 == out — a host is an outbound
#                endpoint, never an incoming address)
#   logical      col 13 via xref/_profiles-logicals ∪ col 12 via _subscriptions-logicals
#   partner      col 20 ∪ col 12 via _subscriptions-partners
#   application  col 18 ∪ col 12 via _subscriptions-apps
#   domain       col 19
#   bl           col 12 via _subscriptions-bl
# Totals: subscription / login / remote-host sum the (name, File) pairs, the
# others count each File once.
#
# Usage:
#   ./entities.sh    # reads the caches, writes data/transfer/reports/entities/<entity>.rpt + data/transfer/reports/<entity>.rpt (nine each)
#                    # + data/transfer/reports/month-stats/*.rpt (18) + _alltime.tsv
#
# (Until 2026-09-13 this was entities2.sh, the twin experiment; the S| / T|
# streams and the display rules below are its.)
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib.sh"
source "$ROOT/bin/pda-union.sh"   # SP_AWK: the File attribution UNION (sp_union / ap_union / lg_union / bl_union)

shopt -s nullglob
files=("$INPUT_DIR"/*.csv)
shopt -u nullglob
if [ ${#files[@]} -eq 0 ]; then
    echo "No *.csv in $INPUT_DIR — building from the EMPTY caches (config-only estate)" >&2
fi
OUTDIR="$REPORTS_DIR/entities"
mkdir -p "$OUTDIR"
rm -f "$OUTDIR"/*.rpt.tmp "$OUTDIR"/.agg.tmp "$OUTDIR"/.agg.tmp.*   # orphaned temps from a killed run (reports.sh sweeps the top level only)

DIMS="account subscription login remote-host logical partner application domain bl"
echo "Found ${#files[@]} file(s) in '$INPUT_DIR', processing..." >&2

# THE MONTH STATS months (month-stats.sh until 2026-09-30): THIS month = the
# month of the newest File start date in the cache (the data, not the wall
# clock — a lagging export must not show an empty month); an empty cache
# falls back to the calendar month. PREVIOUS = the month before. Over EVERY
# File with a start date (not only the attributed ones).
MSDIR="$REPORTS_DIR/month-stats"
ALLF="$REPORTS_DIR/_alltime.tsv"   # beside the .rpt files (2026-09-29 — not in month-stats/)
mkdir -p "$MSDIR"
rm -f "$MSDIR"/*.rpt.tmp "$MSDIR"/.agg.tmp "$ALLF".tmp "$ALLF".tmp2
MS_NEWEST=$(awk -F'\t' '$4 ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$/ && $4 > m { m = $4 } END { print m }' "$FILES")
if [ -n "$MS_NEWEST" ]; then MS_THIS=${MS_NEWEST:0:7}; else MS_THIS=$(date '+%Y-%m'); fi
MS_PREV=$(awk -v m="$MS_THIS" 'BEGIN { y = substr(m, 1, 4) + 0; mo = substr(m, 6, 2) + 0; mo--; if (mo == 0) { mo = 12; y-- } printf "%04d-%02d", y, mo }')

AGG="$OUTDIR/.agg.tmp"
# ---------------------------------------------------------------------------
# ONE awk, two passes. Pass 1 = _transfers.tsv: per CoreId the OK / failed
# LEG counts and the distinct login / site / host sets. Pass 2 = _files.tsv
# (whose cols 26 / 27 carry the failed-leg and resubmitted-leg flags since
# 2026-09-29 — pass 1 derived them until then): per File the nine name sets, then
# per (type, name) the counters, first/last by sortkey, the per-date buckets
# (date:files:in:out:ferr:bytes:tok:terr:rauto:rmok:rmerr:waiting:expired:legs)
# and the ten drill rings. Writes S| / T| lines to a temp file PER TYPE
# ($AGG.<type>) — ten drill lists per row are too much for a bash variable.
# PARALLEL BY TYPE (2026-09-27, build-speed round 1): a type's rows depend
# only on its own names' Files, so agg_run SEL computes just the types in
# SEL (every name set outside it is skipped, and the pass-1 login / site /
# host sets are built only for the types that read them) — the type groups
# below run side by side, each reading the caches itself. Same rows, same
# order of processing, so every value is what the one-process run gave.
# ---------------------------------------------------------------------------
agg_run() {   # $1 = the space-separated types this run computes
awk -F'\t' -v PF="$PARSED" -v FF="$FILES" -v OUTP="$AGG" -v DSEL="$1" \
    "${SP_AWK_V[@]}" "$SP_AWK$COREIDS_AWK$AWKLIB"'
    function addset(s, v) { return index("\037" s "\037", "\037" v "\037") ? s : (s == "" ? v : s "\037" v) }   # a distinct-value set as a \037 string (tests emptiness, never membership — the mawk LHS trap)
    function addnames(t, s,   n2, z, i2) { if (s == "") return; n2 = split(s, z, "\037"); for (i2 = 1; i2 <= n2; i2++) NS[t SUBSEP z[i2]] = 1 }
    # THE DURATION GROUP (p90 · p95 · p99): the wall-clock span (_files col 9)
    # of the OK Files with a positive span — duration.sh'"'"'s default scope, the
    # Error attempts being mostly instant. Each span is QUANTIZED to the
    # humandur DISPLAY grid (rounded like the format), so a histogram of grid
    # values per (type, name) replaces the sorted list: the percentile picked
    # by rank displays exactly what the exact values would. The SAME
    # histogram PER DAY rides the row as @data:durdays ("date:q.c;q.c,…"):
    # report.js re-picks the percentiles for the selected From/To from the
    # in-range days (RECALC P90 / P95 / P99 — the user rule, 2026-09-13:
    # Duration follows the date period like every other group) and the
    # publish-time subset totals merge it the same way.
    function qdur(ms) {
        if (ms < 1000)    return int(ms + 0.5)
        if (ms < 60000)   return int(ms / 10 + 0.5) * 10
        if (ms < 3600000) return int(ms / 6000 + 0.5) * 6000
        return int(ms / 36000 + 0.5) * 36000 }
    function hshort(ms,   v) { v = ms / 1000; if (v < 59.5) return sprintf("%.0f s", v)   # the drill entries carry the span (the ROW formatter has its own copy)
        v /= 60; if (v < 59.5) return sprintf("%.0f m", v); v /= 60; if (v < 23.5) return sprintf("%.0f h", v); return sprintf("%.0f d", v / 24) }
    # prank: the nearest-rank rule of duration.sh / duration-slowest.sh —
    # T[int((N - 1) * P / 100 + 0.5) + 1] over the sorted values — walked
    # over the (sorted) histogram Q[]/C[]
    function prank(Q, C, n2, N, P,   r, cum, i2) { r = int((N - 1) * P / 100 + 0.5) + 1; cum = 0
        for (i2 = 1; i2 <= n2; i2++) { cum += C[i2]; if (cum >= r) return Q[i2] } return Q[n2] }
    # pctls(list): list = "q.count|q.count|…" (any order) -> the globals P90 /
    # P95 / P99 / P100 (grid ms values; "" when empty — the ROW formatter
    # spells and tints them; P100 = the maximum) and HIST (the list sorted by
    # q, comma-joined)
    # qsortn(A, lo, hi): A[lo..hi] ascending, numerically. The lists below
    # hold DISTINCT values (histogram keys), so the order is fully defined;
    # an insertion sort here ran 34M inner steps on the sample alone (the
    # per-type lists hold thousands of grid values) — speed round 5.
    function pctls(list,   n2, z, i2, p2, N, Q, C, CM, out) {
        P90 = ""; P95 = ""; P99 = ""; P100 = ""; HIST = ""; if (list == "") return
        n2 = split(list, z, "|"); N = 0
        for (i2 = 1; i2 <= n2; i2++) { p2 = index(z[i2], "."); Q[i2] = substr(z[i2], 1, p2 - 1) + 0; CM[Q[i2]] = substr(z[i2], p2 + 1) + 0; N += CM[Q[i2]] }
        qsortn(Q, 1, n2)
        for (i2 = 1; i2 <= n2; i2++) C[i2] = CM[Q[i2]]
        out = ""; for (i2 = 1; i2 <= n2; i2++) out = out (out == "" ? "" : ",") Q[i2] "." C[i2]
        HIST = out
        P90 = prank(Q, C, n2, N, 90); P95 = prank(Q, C, n2, N, 95); P99 = prank(Q, C, n2, N, 99); P100 = prank(Q, C, n2, N, 100) }
    function acc(key,   dk, lv) {
        sc[key]++; if (isin) sfin[key]++; if (isout) sfout[key]++; if (f) sfe[key]++; sv[key] += size
        # the newest Error / OK File start per key, as "sortkey SUBSEP date
        # time" — the CLASSIC records (below) carry it as Last Error / Last OK
        lv = sk SUBSEP disp
        if (f) { if (!(key in LTE) || lv > LTE[key]) LTE[key] = lv } else { if (!(key in LTO) || lv > LTO[key]) LTO[key] = lv }
        stok[key] += tk; ster[key] += te
        if (ra) sra[key]++; if (rmo) smo[key]++; if (rme) sme[key]++; if (wt) swt[key]++; if (ex) sex[key]++
        if (!(key in havemin) || sk < mink[key]) { mink[key] = sk; fst[key] = date; havemin[key] = 1 }
        if (!(key in havemax) || sk > maxk[key]) { maxk[key] = sk; lst[key] = date; havemax[key] = 1 }
        dk = key SUBSEP date; ds[dk] = 1; dl[dk]++; if (isin) din[dk]++; if (isout) dout[dk]++; if (f) dfe[dk]++; db[dk] += size
        dtok[dk] += tk; dter[dk] += te; if (ra) dra[dk]++; if (rmo) dmo[dk]++; if (rme) dme[dk]++; if (wt) dwt[dk]++; if (ex) dex[dk]++
        if (tk > 0) addtop(key SUBSEP "tok", sk, disp, cid); if (te > 0) addtop(key SUBSEP "terr", sk, disp, cid)
        if (isin) addtop(key SUBSEP "fin", sk, disp, cid); if (isout) addtop(key SUBSEP "fout", sk, disp, cid)
        if (f) addtop(key SUBSEP "ferr", sk, disp, cid)
        if (ra) addtop(key SUBSEP "rauto", sk, disp, cid); if (rmo) addtop(key SUBSEP "rmok", sk, disp, cid); if (rme) addtop(key SUBSEP "rmerr", sk, disp, cid)
        if (wt) addtop(key SUBSEP "wait", sk, disp, cid); if (ex) addtop(key SUBSEP "exp", sk, disp, cid)
        if (hasd) { dh[key SUBSEP q]++; dhd[key SUBSEP date SUBSEP q]++ }
    }
    function tot(t) {
        tc[t]++; if (isin) tin[t]++; if (isout) tout[t]++; if (f) tfe[t]++; tv[t] += size; ttok[t] += tk; tter[t] += te
        if (ra) tra[t]++; if (rmo) tmo[t]++; if (rme) tme[t]++; if (wt) twt[t]++; if (ex) tex[t]++
        tdd[t SUBSEP date] = 1
        # the per-DAY distinct totals (2026-09-29): the TOTAL row own
        # @data:buckets, so a narrowed range re-totals a type whose Files count
        # for several names (BL / partner / application) as DISTINCT Files,
        # not as the sum of the rows — the bucket layout of a row (see bk)
        tdk = t SUBSEP date; tdl[tdk]++; if (isin) tdin[tdk]++; if (isout) tdout[tdk]++; if (f) tdfe[tdk]++; tdb[tdk] += size
        tdtok[tdk] += tk; tdter[tdk] += te; if (ra) tdra[tdk]++; if (rmo) tdmo[tdk]++; if (rme) tdme[tdk]++; if (wt) tdwt[tdk]++; if (ex) tdex[tdk]++
        if (hasd) th[t SUBSEP q]++
    }
    # calc_pcts: the per-(type, name) and per-type percentiles from the
    # histograms — run when the THIRD pass (the Duration drills, _files.tsv
    # read again) starts, so the drills can compare every File against its
    # keys'"'"' thresholds; END computes them itself when that pass never came
    # (an empty cache)
    function calc_pcts(   k, kk, key, t) {
        pdone = 1
        for (k in dh) { split(k, kk, SUBSEP); key = kk[1] SUBSEP kk[2]; ql[key] = ql[key] (ql[key] == "" ? "" : "|") kk[3] "." dh[k] }
        for (k in th) { split(k, kk, SUBSEP); tql[kk[1]] = tql[kk[1]] (tql[kk[1]] == "" ? "" : "|") kk[2] "." th[k] }
        for (key in ql) { pctls(ql[key]); KP90[key] = P90; KP95[key] = P95; KP99[key] = P99; KP100[key] = P100 }
        for (t in tql) { pctls(tql[t]); TP90[t] = P90; TP95[t] = P95; TP99[t] = P99; TP100[t] = P100 }
    }
    BEGIN {
        nsel = split(DSEL, SL, " "); for (i2 = 1; i2 <= nsel; i2++) SEL[SL[i2]] = 1
        SAC = ("account" in SEL); SSU = ("subscription" in SEL); SLO = ("login" in SEL); SRH = ("remote-host" in SEL)
        SLC = ("logical" in SEL); SPA = ("partner" in SEL); SAP = ("application" in SEL); SDO = ("domain" in SEL); SBL = ("bl" in SEL)
        PAIRTOT["subscription"] = 1; PAIRTOT["login"] = 1; PAIRTOT["remote-host"] = 1   # totals once per (name, File) pair — the classic join writers
    }
    FILENAME == PF {   # _transfers.tsv first: the per-CoreId leg facts
        cid = $1
        if ($3 == "Processed") tokc[cid]++; else terrc[cid]++
        if (SLO && $5 != "") lg[cid] = addset(lg[cid], $5)
        if (SSU && $6 != "" && $6 != "Unknown") st[cid] = addset(st[cid], $6)   # "Unknown" = no subscription (2026-09-29)
        if (SRH && $16 != "") hs[cid] = addset(hs[cid], $16)
        next }
    # _files.tsv comes TWICE: pass 2 aggregates, pass 3 collects the Duration
    # drills against the thresholds pass 2 produced (counted by the FILES
    # starts, so an empty _transfers.tsv cannot shift the numbering)
    FNR == 1 && FILENAME == FF { fpass++; if (fpass == 2) calc_pcts() }
    $4 == "" { next }
    {
        cid = $1; f = ($2 == "Failed" || $2 == "Expired"); date = $4; sk = $6; disp = $4 " " $5; size = $8 + 0
        # In / Out by MOVEMENT; a File of an unconfigured subscription (or of
        # none — "Unknown") has none and counts by its CONNECTION side, so
        # In + Out = Files and the Error % recompute (Error over In + Out)
        # holds on a narrowed range (2026-09-28 fix: it read 0.0% there) —
        # the home page Per day table uses the same fallback
        mv = ($17 != "") ? $17 : $16
        isin = (mv == "in"); isout = (mv == "out"); wt = ($2 == "Waiting"); ex = ($2 == "Expired")
        tk = (cid in tokc) ? tokc[cid] : 0; te = (cid in terrc) ? terrc[cid] : 0
        ra = (!f && $26 == "1" && $27 != "1"); rmo = (!f && $27 == "1"); rme = (f && $27 == "1")   # the leg flags: col 26 = a failed leg, col 27 = a resubmitted leg
        dur = $9 + 0; hasd = ($2 == "Processed" && dur > 0); q = hasd ? qdur(dur) : 0   # the Duration group: DELIVERED Files with a positive wall-clock span — the Duration report scope (F08, 2026-09-28; 2026-09-29: a Waiting File span, its staging wait, counted here)
        delete NS
        if (SAC && $3 != "") NS["account" SUBSEP $3] = 1
        if (SSU && (cid in st)) addnames("subscription", st[cid])
        if (SLO && (cid in lg)) addnames("login", lg[cid])
        if (SRH && $16 == "out" && (cid in hs)) addnames("remote-host", hs[cid])
        # logical / partner / application / BL = the UNION sets (bin/pda-union.sh)
        if (SLC) addnames("logical", lg_union($13, $12))
        if (SPA) addnames("partner", sp_union($20, $12))
        if (SAP) addnames("application", ap_union($18, $12))
        if (SDO && $19 != "") NS["domain" SUBSEP $19] = 1
        if (SBL) addnames("bl", bl_union($12))
        if (fpass == 2) {   # the DURATION DRILLS (2026-09-13, user request): per key the 10 newest OK Files at or above each percentile, each entry with its span
            if (!hasd) next
            for (k in NS) { if (!(k in KP90) || KP90[k] == "") continue
                if (q >= KP90[k])  addtop(k SUBSEP "d90",  sk, disp, cid "  " hshort(dur))
                if (q >= KP95[k])  addtop(k SUBSEP "d95",  sk, disp, cid "  " hshort(dur))
                if (q >= KP99[k])  addtop(k SUBSEP "d99",  sk, disp, cid "  " hshort(dur))
                if (q >= KP100[k]) addtop(k SUBSEP "d100", sk, disp, cid "  " hshort(dur)) }
            next }
        delete TS
        for (k in NS) { split(k, kk, SUBSEP); t = kk[1]
            acc(k); TS[t] = 1
            if (t in PAIRTOT) tot(t) }
        for (t in TS) if (!(t in PAIRTOT)) tot(t)
    }
    # the "date time" of a newest-File value, read the way the classic
    # account.sh LAST_AWK read it (cut at the first "," and the first double
    # space) — the Last Error / Last OK of the classic records
    function lastts(s,   c) { s = substr(s, index(s, SUBSEP) + 1) "  "
        c = index(s, ","); if (c) s = substr(s, 1, c - 1); c = index(s, "  "); return c ? substr(s, 1, c - 1) : s }
    # the entries of a per-day duration histogram ("q.c;q.c"), ordered by q
    function sortqc(s,   n3, a3, i3, p3, Q3, E3) { n3 = split(s, a3, ";"); if (n3 < 2) return s
        for (i3 = 1; i3 <= n3; i3++) { p3 = index(a3[i3], "."); Q3[i3] = substr(a3[i3], 1, p3 - 1) + 0; E3[Q3[i3]] = a3[i3] }
        qsortn(Q3, 1, n3)
        s = E3[Q3[1]]; for (i3 = 2; i3 <= n3; i3++) s = s ";" E3[Q3[i3]]; return s }
    END {
        # The per-DAY payloads (@data:buckets, @data:durdays) list their days
        # in DATE order (2026-09-27, build-speed round 1): they used to follow
        # the awk hash order of every key this process held, which moved as
        # soon as the types ran in separate processes. report.js reads both
        # as sets (sums, maxima, merged histograms), so only the bytes change.
        for (dk in ds) { split(dk, kk, SUBSEP); if (!(kk[3] in DSEEN)) { DSEEN[kk[3]] = 1; DL[++ndl] = kk[3] } }
        for (i2 = 2; i2 <= ndl; i2++) { v2 = DL[i2]; j2 = i2 - 1; while (j2 > 0 && DL[j2] > v2) { DL[j2 + 1] = DL[j2]; j2-- } DL[j2 + 1] = v2 }
        for (key in sc) for (i2 = 1; i2 <= ndl; i2++) { dk = key SUBSEP DL[i2]; if (!(dk in ds)) continue; nd[key]++
            bk[key] = bk[key] (bk[key] ? "," : "") DL[i2] ":" dl[dk] ":" (din[dk]+0) ":" (dout[dk]+0) ":" (dfe[dk]+0) ":" (db[dk]+0) ":" (dtok[dk]+0) ":" (dter[dk]+0) ":" (dra[dk]+0) ":" (dmo[dk]+0) ":" (dme[dk]+0) ":" (dwt[dk]+0) ":" (dex[dk]+0) ":" (dtok[dk]+dter[dk]) }
        if (!pdone) calc_pcts()   # no third pass (an empty cache): the percentiles are computed here
        # the per (type, name, DAY) duration histograms — the row payload
        # (";" between the entries of one day: "|" is the S| stream separator)
        for (k in dhd) { split(k, kk, SUBSEP); dk = kk[1] SUBSEP kk[2] SUBSEP kk[3]; dql[dk] = dql[dk] (dql[dk] == "" ? "" : ";") kk[4] "." dhd[k] }
        for (key in sc) for (i2 = 1; i2 <= ndl; i2++) { dk = key SUBSEP DL[i2]; if (!(dk in dql)) continue
            ddp[key] = ddp[key] (ddp[key] == "" ? "" : ",") DL[i2] ":" sortqc(dql[dk]) }
        for (key in sc) { split(key, kk, SUBSEP); t = kk[1]; ns[t]++
            printf "S|%s|%s|%d|%s|%s|%d|%d|%d|%d|%d|%d|%d|%d|%d|%d|%d|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n", \
                t, kk[2], sc[key], fst[key], lst[key], nd[key]+0, stok[key]+0, ster[key]+0, sfin[key]+0, sfout[key]+0, sfe[key]+0, \
                sra[key]+0, smo[key]+0, sme[key]+0, swt[key]+0, sex[key]+0, sv[key]+0, bk[key], \
                buildlist(top[key SUBSEP "tok"]), buildlist(top[key SUBSEP "terr"]), buildlist(top[key SUBSEP "fin"]), buildlist(top[key SUBSEP "fout"]), \
                buildlist(top[key SUBSEP "ferr"]), buildlist(top[key SUBSEP "rauto"]), buildlist(top[key SUBSEP "rmok"]), buildlist(top[key SUBSEP "rmerr"]), \
                buildlist(top[key SUBSEP "wait"]), buildlist(top[key SUBSEP "exp"]), \
                ((key in KP90) ? KP90[key] : ""), ((key in KP95) ? KP95[key] : ""), ((key in KP99) ? KP99[key] : ""), ((key in KP100) ? KP100[key] : ""), \
                ((key in ddp) ? ddp[key] : ""), \
                buildlist(top[key SUBSEP "d90"]), buildlist(top[key SUBSEP "d95"]), buildlist(top[key SUBSEP "d99"]), buildlist(top[key SUBSEP "d100"]), \
                ((key in LTE) ? lastts(LTE[key]) : ""), ((key in LTO) ? lastts(LTO[key]) : "") > (OUTP "." t) }
        for (k in tdd) { split(k, kk, SUBSEP); tdays[kk[1]]++ }
        for (t in tc) for (i2 = 1; i2 <= ndl; i2++) { dk = t SUBSEP DL[i2]; if (!(dk in tdd)) continue
            tbk[t] = tbk[t] (tbk[t] ? "," : "") DL[i2] ":" tdl[dk] ":" (tdin[dk]+0) ":" (tdout[dk]+0) ":" (tdfe[dk]+0) ":" (tdb[dk]+0) ":" (tdtok[dk]+0) ":" (tdter[dk]+0) ":" (tdra[dk]+0) ":" (tdmo[dk]+0) ":" (tdme[dk]+0) ":" (tdwt[dk]+0) ":" (tdex[dk]+0) ":" (tdtok[dk]+tdter[dk]) }
        n2 = split(DSEL, TL, " ")   # a T| line for EVERY selected type, data or not (the config-only estate renders zero-row tables)
        for (i2 = 1; i2 <= n2; i2++) { t = TL[i2]
            printf "T|%s|%d|%d|%d|%d|%d|%d|%d|%d|%d|%d|%d|%d|%s|%d|%s|%s|%s|%s|%s\n", t, tc[t]+0, tdays[t]+0, ttok[t]+0, tter[t]+0, tin[t]+0, tout[t]+0, tfe[t]+0, \
                tra[t]+0, tmo[t]+0, tme[t]+0, twt[t]+0, tex[t]+0, tv[t]+0, ns[t]+0, \
                ((t in TP90) ? TP90[t] : ""), ((t in TP95) ? TP95[t] : ""), ((t in TP99) ? TP99[t] : ""), ((t in TP100) ? TP100[t] : ""), ((t in tbk) ? tbk[t] : "") > (OUTP "." t) }
    }
' "$PARSED" "$FILES" "$FILES"
}
# the type groups, one background job each (fastawk: mawk when present);
# the groups weigh roughly alike (the develop profile)
AGG_GROUPS=("subscription remote-host" "login account" "partner logical" "application domain bl")
AGG_PIDS=()
agg_timed() { local t0=$SECONDS; agg_run "$1"; printf 'TIME %5ds  %s\n' "$(( SECONDS - t0 ))" "entities: aggregate $1" >&2; }
for _g in "${AGG_GROUPS[@]}"; do agg_timed "$_g" & AGG_PIDS+=("$!"); done
for _p in "${AGG_PIDS[@]}"; do wait "$_p" || { echo "entities: an aggregation job failed" >&2; exit 1; }; done
unset _g _p

# ROW formatter: ONE awk pass over the busiest-first stream (S| fields: 2 type
# 3 name 4 files 5 first 6 last 7 days 8 tok 9 terr 10 in 11 out 12 ferr
# 13 rauto 14 rmok 15 rmerr 16 waiting 17 expired 18 bytes 19 buckets
# 20-29 the drills tok terr fin fout ferr rauto rmok rmerr wait exp,
# 30-33 p90 p95 p99 p100 (grid ms), 34 the per-day duration histograms,
# 35-38 the Duration drills d90 d95 d99 d100). The renderer blanks a 0 in
# the tinted cells itself (its z rule).
# DISPLAY RULES (2026-09-13, user request): Volume in INTEGER units; a
# Duration as an integer with a one-letter unit (s m h d), tinted by the
# unit — s green (processed) · m amber (warn) · h/d red (failed); an empty
# Error cell keeps an EMPTY rate beside it; Files In / Out never show a 0.
# The red tint is the `failed` class, not `errc`: the row tints of the
# views (seenrows / restint) paint over every cell except .failed /
# .processed, so an errc cell reads green inside a green row.
FMT_AWK="$AWKLIB"'
    function pr(x, c) { if (x + 0 == 0 || c + 0 == 0) return ""; return sprintf("%.1f%%", x * 100 / c) }
    function nz(x) { return (x + 0 == 0) ? "" : x + 0 }
    function hshort(ms,   v) { v = ms / 1000; if (v < 59.5) return sprintf("%.0f s", v)
        v /= 60; if (v < 59.5) return sprintf("%.0f m", v); v /= 60; if (v < 23.5) return sprintf("%.0f h", v); return sprintf("%.0f d", v / 24) }
    function dtint(ms,   v) { v = ms / 1000; if (v < 59.5) return "processed"; if (v / 60 < 59.5) return "warn"; return "failed" }
    function dcell(ms) { return (ms == "") ? "" : "@{class=" dtint(ms) "}" hshort(ms) }
'

# one .rpt per type, formatted side by side (each reads only $AGG.<type>)
fmt_dim() {
    local dim=$1 title chead nkind noun OUT rows tot_line
    case $dim in
        account)      title="Accounts";      chead="Account";      nkind=acct;  noun="account" ;;
        subscription) title="Subscriptions"; chead="Subscription"; nkind=site;  noun="subscription" ;;
        login)        title="Logins";        chead="Login";        nkind=login; noun="login" ;;
        remote-host)  title="Hosts";         chead="Remote Host";  nkind=host;  noun="remote host" ;;
        logical)      title="Logical";       chead="Logical";      nkind=lgc;   noun="logical" ;;
        partner)      title="Partners";      chead="Partner";      nkind=ptn;   noun="partner" ;;
        application)  title="Applications";  chead="Application";  nkind=app;   noun="application" ;;
        domain)       title="Domains";       chead="Domain";       nkind=dom;   noun="domain" ;;
        bl)           title="BL";            chead="BL";           nkind=bl;    noun="BL" ;;
    esac
    OUT="$OUTDIR/$dim.rpt"
    IFS='|' read -r _ _ tc tdays ttok tter tin tout tfe tra tmo tme twt tex tv ns tp90 tp95 tp99 tp100 tbk \
        <<< "$({ grep "^T|$dim|" "$AGG.$dim" 2>/dev/null || true; } | awk 'NR == 1')"
    : "${tc:=0}" "${tdays:=0}" "${ttok:=0}" "${tter:=0}" "${tin:=0}" "${tout:=0}" "${tfe:=0}" "${tra:=0}" "${tmo:=0}" "${tme:=0}" "${twt:=0}" "${tex:=0}" "${tv:=0}" "${ns:=0}" "${tp90:=}" "${tp95:=}" "${tp99:=}" "${tp100:=}"
    # the display order (2026-09-13, user request; Transfers moved after
    # Volume the same day): Files · Retry / Resubmit · Duration (p90 p95 p99
    # p100) · Volume · Transfers · State · Dates — 22 cells, the Dates LAST
    # NOFERR: the Subscriptions view's Error cell links Failed files (its
    # drillcols leave ferr out), so its ferr list is not shipped (2026-09-29 audit)
    rows=$({ grep "^S|$dim|" "$AGG.$dim" 2>/dev/null || true; } | LC_ALL=C sort -t'|' -k4,4nr -k3,3f -k3,3 | awk -F'|' -v NOFERR="$([ "$dim" = subscription ] && echo 1)" "$FMT_AWK"'
        $3 == "" { next }
        { files = $4 + 0; tok = $8 + 0; ter = $9 + 0; fe = $12 + 0; bytes = $18 + 0
          printf "ROW\t%s\t%s\t%s\t%d\t%s\t%d\t%d\t%d\t%s\t%s\t%s\t%s\t%s\t%s\t%d\t%d\t%s\t%d\t%d\t%s\t%s\t%d\t@data:buckets=%s\t@data:coreids-tok=%s\t@data:coreids-terr=%s\t@data:coreids-fin=%s\t@data:coreids-fout=%s\t@data:coreids-ferr=%s\t@data:coreids-rauto=%s\t@data:coreids-rmok=%s\t@data:coreids-rmerr=%s\t@data:coreids-wait=%s\t@data:coreids-exp=%s\t@data:durdays=%s\t@data:coreids-d90=%s\t@data:coreids-d95=%s\t@data:coreids-d99=%s\t@data:coreids-d100=%s\n", \
              $3, nz($10), nz($11), fe, pr(fe, files), $13, $14, $15, \
              dcell($30), dcell($31), dcell($32), dcell($33), hbytes0(bytes), hbytes0(files > 0 ? bytes / files : 0), \
              tok, ter, pr(ter, tok + ter), $16, $17, $5, $6, $7, \
              $19, $20, $21, $22, $23, (NOFERR ? "" : $24), $25, $26, $27, $28, $29, $34, $35, $36, $37, $38 }')
    tot_line=$(awk -F'|' "$FMT_AWK"'BEGIN { tc = ARGV[1]; ttok = ARGV[2]; tter = ARGV[3]; tfe = ARGV[4]; tv = ARGV[5]; tin = ARGV[6]; tout = ARGV[7]
        printf "%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\n", pr(tter, ttok + tter), pr(tfe, tc), hbytes0(tv), hbytes0(tc > 0 ? tv / tc : 0), nz(tin), nz(tout), dcell(ARGV[8]), dcell(ARGV[9]), dcell(ARGV[10]), dcell(ARGV[11]); exit }' \
        "$tc" "$ttok" "$tter" "$tfe" "$tv" "$tin" "$tout" "$tp90" "$tp95" "$tp99" "$tp100")
    # \037, NOT a TAB: TAB is IFS whitespace, so an EMPTY cell (nz/dcell of a
    # zero — no errors, no In, no Out) collapsed and shifted every later
    # total one column left (2026-09-28 fix)
    IFS=$'\037' read -r tterp tfep tvh tavg tinz toutz td90 td95 td99 td100 <<< "$tot_line"
    {
        printf 'TITLE\t%s\n' "$title"
        printf 'DESC\tOne row per %s: its Files in and out with the error rate, retries and resubmits, duration percentiles, volume, transfer legs, waiting and expired Files, and first and last day — every configured and logged name, in six views (All, Seen, Not seen, OK, Warning, Error).\n' "$noun"
        # the Files group Error cell drills to its 10 newest Files on every entity page but the SUBSCRIPTION ones, where
        # it opens transfer/failed-files.html for that subscription and the active From/To (report.js
        # setupEntityErrorLinks, 2026-09-15 user request) — so its drill is left out there
        ferrdc="ferr:3:Files_Error,"; [ "$chead" = "Subscription" ] && ferrdc=""
        printf 'TABLE\tSummary per %s\twide\tgsep=1,5,8,12,14,17,19\tnoagg=8,9,10,11,13,21\tpct=4:3:1+2;16:15:14+15\tautohide=Retry / Resubmit;State\tdrillcols=fin:1:Files_In,fout:2:Files_Out,%srauto:5:Retry,rmok:6:Resubmit_Ok,rmerr:7:Resubmit_Error,d90:8:Duration_p90,d95:9:Duration_p95,d99:10:Duration_p99,d100:11:Duration_p100,tok:14:Transfers_Ok,terr:15:Transfers_Error,wait:17:Waiting,exp:18:Expired\n' "$chead" "$ferrdc"
        printf 'GHEAD\t\t@{colspan=4,class=gband gsep}Files\t@{colspan=3,class=gband gsep}Retry / Resubmit\t@{colspan=4,class=gband gsep}Duration\t@{colspan=2,class=gband gsep}Volume\t@{colspan=3,class=gband gsep}Transfers\t@{colspan=2,class=gband gsep}State\t@{colspan=3,class=gband gsep}Dates\n'
        printf 'HEAD\t%s\tIn\tOut\tError\tError %%\tAuto\tOk\tError\tp90\tp95\tp99\tp100\tTotal\tAvg\tOk\tError\tError %%\tWaiting\tExpired\tFirst\tLast\tDays\n' "$chead"
        printf 'KIND\t%s\tnum\tnum\tnumfailed\tnum\tnumwarn\tnumwarn\tnumfailed\tnum\tnum\tnum\tnum\tnum\tnum\tnumok\tnumfailed\tnum\tnumwarn\tnumfailed\ttext\ttext\tnum\n' "$nkind"
        printf 'RECALC\t-\tS1\tS2\ts3\te3.0\ts7\ts8\ts9\tP90\tP95\tP99\tP100\tH4\tV4.0\ts5\ts6\te6.12\ts10\ts11\t-\t-\tc\n'
        [ -n "$rows" ] && printf '%s\n' "$rows"
        printf 'TOTAL\tTotal (%s %s(s))\t@{class=num}%s\t@{class=num}%s\t@{class=num failed}%s\t@{class=num}%s\t@{class=num warn}%s\t@{class=num warn}%s\t@{class=num failed}%s\t%s\t%s\t%s\t%s\t@{class=num}%s\t@{class=num}%s\t@{class=num okc}%s\t@{class=num failed}%s\t@{class=num}%s\t@{class=num warn}%s\t@{class=num failed}%s\t\t\t@{class=num}%s%s\n' \
            "$ns" "$noun" "$tinz" "$toutz" "$tfe" "$tfep" "$tra" "$tmo" "$tme" "$td90" "$td95" "$td99" "$td100" "$tvh" "$tavg" "$ttok" "$tter" "$tterp" "$twt" "$tex" "$tdays" \
            "${tbk:+$'\t'@data:buckets=$tbk}"   # the DISTINCT per-day totals (2026-09-29: report.js re-totals a narrowed range from them)
        printf 'FOOT\n'
    } > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"
    echo "Data written to $OUT ($ns $noun(s), $tc file(s))." >&2
}
# THE CLASSIC RECORDS (2026-09-30, user decision — the five classic writers
# account.sh, subscription.sh, login.sh, remote-host.sh and pda-entities.sh
# are folded in here): data/transfer/reports/<dim>.rpt, ONE table, one ROW per
# name, busiest first — the classic four: name · Files · Error · OK · Last
# Error · Last OK (the start "date time" of the newest Error / OK File); the
# Logical / PDA five and BL: name · Files · Error · OK. Read by showseen.sh,
# entity-search.sh, home.sh (the names), the server rosters (known_names)
# and the Entities page render gate (bin/transfer/publish.sh). Same
# attribution as the grouped rows above (it IS their S| stream: Files = $4,
# Error = $12, OK = the rest, the stamps $39 / $40), and the classic writers'
# own S| line + `sort -t'|' -k3,3nr` (ties fall back to the whole line), so
# the files are byte-identical to what the five scripts wrote.
classic_dim() {
    local dim=$1 title table chead stamps OUT rows
    case $dim in
        account)      title="Accounts";      table="Summary per Account";      chead="Account";      stamps=1 ;;
        subscription) title="Subscriptions"; table="Summary per Subscription"; chead="Subscription"; stamps=1 ;;
        login)        title="Logins";        table="Summary per login";        chead="Login";        stamps=1 ;;
        remote-host)  title="Hosts";         table="Summary per Remote Host";  chead="Remote Host";  stamps=1 ;;
        logical)      title="Logical";       table="Summary per Logical";      chead="Logical";      stamps=0 ;;
        partner)      title="Partners";      table="Summary per Partner";      chead="Partner";      stamps=0 ;;
        application)  title="Applications";  table="Summary per Application";  chead="Application";  stamps=0 ;;
        domain)       title="Domains";       table="Summary per Domain";       chead="Domain";       stamps=0 ;;
        bl)           title="BL";            table="Summary per BL";           chead="BL";           stamps=0 ;;
    esac
    OUT="$REPORTS_DIR/$dim.rpt"
    rows=$({ grep "^S|$dim|" "$AGG.$dim" 2>/dev/null || true; } | awk -F'|' -v ST="$stamps" '
        ST == 1 { printf "S|%s|%d|%d|%d|%s|%s\n", $3, $4, $12, $4 - $12, $39, $40; next }
                { printf "S|%s|%d|%d|%d\n", $3, $4, $12, $4 - $12 }' | sort -t'|' -k3,3nr | awk -F'|' -v ST="$stamps" '
        $2 == "" { next }
        ST == 1 { printf "ROW\t%s\t%s\t%s\t%s\t%s\t%s\n", $2, $3, $4, $5, $6, $7; next }
                { printf "ROW\t%s\t%s\t%s\t%s\n", $2, $3, $4, $5 }')
    {
        printf 'TITLE\t%s\n' "$title"
        printf 'TABLE\t%s\n' "$table"
        if [ "$stamps" = 1 ]; then printf 'HEAD\t%s\tFiles\tError\tOK\tLast Error\tLast OK\n' "$chead"
        else printf 'HEAD\t%s\tFiles\tError\tOK\n' "$chead"; fi
        [ -n "$rows" ] && printf '%s\n' "$rows"
        printf 'FOOT\n'
    } > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"
}
# THE MONTH STATS (2026-09-13, user request; month-stats.sh until 2026-09-30,
# folded in here — lean round 1, byte-identical): the nine entity types
# counted over the Files that STARTED in one calendar month — THIS month and
# the PREVIOUS one — 18 .rpt files under data/transfer/reports/month-stats/
#   {this,previous}-{account,subscription,login,remote-host,logical,partner,application,domain,bl}.rpt
# rendered by publish_lib's render_month_stats into docs/transfer/month-stats/,
# PLUS the ALL-TIME sidecar _alltime.tsv — every File, the same nine counts per
# (type, name), "type<TAB>name<TAB>total in out errors auto rmok rmerr waiting
# expired", sorted; the analyses Subscriptions page (bin/analyses/publish.sh
# write_subscriptions_page) reads its subscription rows for the count columns.
# Columns per name: Files · In Files · Out Files · Error · Automatic · Resubmit
# Ok · Resubmit Error · Waiting · Expired — the grouped rows' own counters: a
# (type, name) month figure is the sum of its row's per-day buckets over the
# month (date:files:in:out:ferr:bytes:tok:terr:rauto:rmok:rmerr:waiting:expired:legs),
# a type's month total the sum of its TOTAL row's per-day DISTINCT buckets
# (tot(): per (name, File) pair for subscription / login / remote-host, once
# per File for the rest — the classic rule month-stats.sh had), the name count
# the names with a File in the month.
month_stats() {
    local MSA="$MSDIR/.agg.tmp" which mon dim title chead nkind noun OUT rows hstate kstate tstate
    local tc tin tout tfe tra tmo tme twt tex ns
    local aggs=() d
    for d in $DIMS; do [ -f "$AGG.$d" ] && aggs+=("$AGG.$d"); done
    : > "$ALLF.tmp"; : > "$MSA"
    awk -F'|' -v THIS="$MS_THIS" -v PREV="$MS_PREV" -v MSA="$MSA" -v ALLF="$ALLF.tmp" -v DIMS="$DIMS" '
        # the month sums of one per-day bucket list into M[1..9] (files in out
        # ferr rauto rmok rmerr waiting expired = bucket fields 2 3 4 5 9 10 11 12 13)
        function msum(bl, mon,   n, B, i, z) { for (i = 1; i <= 9; i++) M[i] = 0
            n = split(bl, B, ",")
            for (i = 1; i <= n; i++) { if (substr(B[i], 1, 7) != mon) continue
                split(B[i], z, ":"); M[1] += z[2]; M[2] += z[3]; M[3] += z[4]; M[4] += z[5]
                M[5] += z[9]; M[6] += z[10]; M[7] += z[11]; M[8] += z[12]; M[9] += z[13] } }
        $1 == "S" {
            # the all-time counters are the row own totals (S| 4 files 10 in 11 out
            # 12 ferr 13 rauto 14 rmok 15 rmerr 16 waiting 17 expired)
            printf "%s\t%s\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\n", $2, $3, $4, $10, $11, $12, $13, $14, $15, $16, $17 > ALLF
            for (m = 1; m <= 2; m++) { mon = (m == 1) ? THIS : PREV; msum($19, mon)
                if (M[1] == 0) continue
                NSN[mon SUBSEP $2]++
                printf "S|%s|%s|%s|%d|%d|%d|%d|%d|%d|%d|%d|%d\n", mon, $2, $3, M[1], M[2], M[3], M[4], M[5], M[6], M[7], M[8], M[9] > MSA }
            next }
        $1 == "T" { for (m = 1; m <= 2; m++) { mon = (m == 1) ? THIS : PREV; msum($21, mon)
                for (i = 1; i <= 9; i++) TT[mon SUBSEP $2 SUBSEP i] = M[i] }
            next }
        END { n2 = split(DIMS, TL, " ")
            for (m = 1; m <= 2; m++) { mon = (m == 1) ? THIS : PREV
                for (i2 = 1; i2 <= n2; i2++) { t = TL[i2]; k = mon SUBSEP t
                    printf "T|%s|%s|%d|%d|%d|%d|%d|%d|%d|%d|%d|%d\n", mon, t, TT[k SUBSEP 1]+0, TT[k SUBSEP 2]+0, TT[k SUBSEP 3]+0, TT[k SUBSEP 4]+0, TT[k SUBSEP 5]+0, TT[k SUBSEP 6]+0, TT[k SUBSEP 7]+0, TT[k SUBSEP 8]+0, TT[k SUBSEP 9]+0, NSN[k]+0 > MSA } } }
    ' ${aggs[@]+"${aggs[@]}"} < /dev/null
    LC_ALL=C sort -t"$(printf '\t')" -k1,1 -k2,2 "$ALLF.tmp" > "$ALLF.tmp2" && mv "$ALLF.tmp2" "$ALLF" && rm -f "$ALLF.tmp"

    nz0() { [ "${1:-0}" = 0 ] || printf '%s' "$1"; }   # a count cell shows blank, never 0
    for which in this previous; do
        [ "$which" = this ] && mon=$MS_THIS || mon=$MS_PREV
        for dim in $DIMS; do
            case $dim in
                account)      title="Accounts";      chead="Account";      nkind=acct;  noun="account" ;;
                subscription) title="Subscriptions"; chead="Subscription"; nkind=site;  noun="subscription" ;;
                login)        title="Logins";        chead="Login";        nkind=login; noun="login" ;;
                remote-host)  title="Hosts";         chead="Remote Host";  nkind=host;  noun="remote host" ;;   # title = the menu label
                logical)      title="Logical";       chead="Logical";      nkind=lgc;   noun="logical" ;;
                partner)      title="Partners";      chead="Partner";      nkind=ptn;   noun="partner" ;;
                application)  title="Applications";  chead="Application";  nkind=app;   noun="application" ;;
                domain)       title="Domains";       chead="Domain";       nkind=dom;   noun="domain" ;;
                bl)           title="BL";            chead="BL";           nkind=bl;    noun="BL" ;;
            esac
            OUT="$MSDIR/$which-$dim.rpt"
            IFS='|' read -r _ _ _ tc tin tout tfe tra tmo tme twt tex ns \
                <<< "$({ grep "^T|$mon|$dim|" "$MSA" || true; } | awk 'NR == 1')"
            : "${tc:=0}" "${tin:=0}" "${tout:=0}" "${tfe:=0}" "${tra:=0}" "${tmo:=0}" "${tme:=0}" "${twt:=0}" "${tex:=0}" "${ns:=0}"
            # rows busiest first (Files desc, name tiebreak); no count cell
            # ever shows a 0 (2026-09-29: only In / Out were blanked)
            rows=$({ grep "^S|$mon|$dim|" "$MSA" || true; } | LC_ALL=C sort -t'|' -k5,5nr -k4,4f -k4,4 | awk -F'|' '
                function nz(x) { return (x + 0 == 0) ? "" : x + 0 }
                $4 == "" { next }
                { printf "ROW\t%s\t%d\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", $4, $5, nz($6), nz($7), nz($8), nz($9), nz($10), nz($11), nz($12), nz($13) }')
            # the HOST pages have no Waiting / Expired columns (2026-09-29 audit):
            # a host counts OUT-connection Files, and Waiting / Expired are UC2
            # pickups — Files the partner connects IN for — so the two were blank
            # on every row (the Entities host views drop that State group too)
            if [ "$dim" = remote-host ]; then
                rows=$(printf '%s\n' "$rows" | awk -F'\t' -v OFS='\t' 'NF { NF = 9; print }')
                hstate=""; kstate=""; tstate=""
            else
                hstate=$'\tWaiting\tExpired'; kstate=$'\tnumwarn\tnumfailed'
                tstate=$'\t@{class=num warn}'"$(nz0 "$twt")"$'\t@{class=num failed}'"$(nz0 "$tex")"
            fi
            {
                printf 'TITLE\tMonth stats — %s — %s\n' "$title" "$mon"
                # the month label: publish_lib render_month_stats reads it from the
                # two subscription files only (the tab row), so only they carry it
                [ "$dim" = subscription ] && printf 'META\tmonth\t%s\n' "$mon"
                printf 'TABLE\t%s — Files started in %s\twide\tsort=1:-1\n' "$title" "$mon"
                # the site words (2026-09-30 audit T-10): Files · Error · Ok, as the
                # Entities groups and the Top view ("Total files", "Errors" and
                # "Resubmit OK" until then)
                printf 'HEAD\t%s\tFiles\tIn Files\tOut Files\tError\tAutomatic\tResubmit Ok\tResubmit Error%s\n' "$chead" "$hstate"
                printf 'KIND\t%s\tnum\tnum\tnum\tnumfailed\tnumwarn\tnumwarn\tnumfailed%s\n' "$nkind" "$kstate"
                [ -n "$rows" ] && printf '%s\n' "$rows"
                printf 'TOTAL\tTotal (%s %s(s))\t@{class=num}%s\t@{class=num}%s\t@{class=num}%s\t@{class=num failed}%s\t@{class=num warn}%s\t@{class=num warn}%s\t@{class=num failed}%s%s\n' \
                    "$ns" "$noun" "$tc" "$(nz0 "$tin")" "$(nz0 "$tout")" "$(nz0 "$tfe")" "$(nz0 "$tra")" "$(nz0 "$tmo")" "$(nz0 "$tme")" "$tstate"
                printf 'FOOT\n'
            } > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"
        done
    done
    rm -f "$MSA"
    echo "Data written to $MSDIR (this month $MS_THIS, previous $MS_PREV, 18 report(s)) + $ALLF." >&2
}
FMT_PIDS=()
month_stats & FMT_PIDS+=("$!")
for dim in $DIMS; do fmt_dim "$dim" & FMT_PIDS+=("$!"); classic_dim "$dim" & FMT_PIDS+=("$!"); done
for _p in "${FMT_PIDS[@]}"; do wait "$_p" || { echo "entities: a report writer failed" >&2; exit 1; }; done
rm -f "$AGG".*
echo "Data written to $REPORTS_DIR/{account,subscription,login,remote-host,logical,partner,application,domain,bl}.rpt (the classic records)." >&2
