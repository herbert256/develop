#!/usr/bin/env bash
#
# entities.sh — THE ENTITIES PAGES (2026-09-13, user request: the grouped
# layout, built the same day as a twin under transfer/entities2/, replaced
# the classic Name · Direction · Files · Volume · OK · Retry · Resubmit ·
# Error · Last seen pages): the nine Entities reports in a GROUPED layout,
# one .rpt per entity under data/transfer/reports/entities/, rendered by
# publish_lib's render_entity_report into docs/transfer/entities/. The nine
# classic writers (account.sh, subscription.sh, login.sh, remote-host.sh,
# pda-entities.sh) keep writing their <name>.rpt as DATA producers —
# showseen.sh, entity-search.sh and the server rosters read them — but
# render no page any more.
#
# Layout: the Name, then SEVEN column groups (a GHEAD banner + the gsep=
# dividers, the Top view way), in this order:
#   Files      In · Out · Error · Error %   In/Out = the MOVEMENT direction
#              (_files.tsv col 17 — the home page's In/Out rule; a File with
#              no movement counts in the total and the Error % only)
#   Retry / Resubmit   Auto · Ok · Error   the Top view rule: Auto = an OK
#              File that carried a failed leg and no resubmitted leg (the
#              classic Retry column); Ok / Error = EVERY File with a
#              resubmitted leg (_transfers.tsv col 22), by its outcome
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
# Attribution per entity mirrors the five classic writers EXACTLY (account.sh,
# subscription.sh, login.sh, remote-host.sh, pda-entities.sh) — so Files,
# Error, Auto, Volume, First and Last agree row for row with their .rpt:
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
# others count each File once — exactly what the classic T| lines do.
#
# Usage:
#   ./entities.sh    # reads the caches, writes data/transfer/reports/entities/<entity>.rpt (nine files)
#
# (Until 2026-09-13 this was entities2.sh, the twin experiment; the S| / T|
# streams and the display rules below are its.)
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib.sh"

shopt -s nullglob
files=("$INPUT_DIR"/*.csv)
shopt -u nullglob
if [ ${#files[@]} -eq 0 ]; then
    echo "No *.csv in $INPUT_DIR — building from the EMPTY caches (config-only estate)" >&2
fi
OUTDIR="$REPORTS_DIR/entities"
mkdir -p "$OUTDIR"
rm -f "$OUTDIR"/*.rpt.tmp "$OUTDIR"/.agg.tmp   # orphaned temps from a killed run (reports.sh sweeps the top level only)
ensure_parsed

DIMS="account subscription login remote-host logical partner application domain bl"
# one script, NINE outputs — skip only when ALL are fresh (pda-entities.sh's rule)
_fresh=1
for _o in $DIMS; do
    _f="$OUTDIR/$_o.rpt"
    if ! { [ -f "$_f" ] && ! [ "$PARSED" -nt "$_f" ] && ! [ "$FILES" -nt "$_f" ] && ! [ "${BASH_SOURCE[0]}" -nt "$_f" ] && ! [ "$LIB_DIR/lib.sh" -nt "$_f" ]; }; then
        _fresh=0; break
    fi
done
if [ "$_fresh" = 1 ]; then
    echo "  entities/*.rpt are up to date; skipping." >&2
    exit 0
fi
unset _fresh _o _f
echo "Found ${#files[@]} file(s) in '$INPUT_DIR', processing..." >&2

# the union / value maps (pda-entities.sh's UMAP/VMAP set); a missing map is
# an empty one
mapf() { [ -f "$CONFIG_XREF/$1.tsv" ] && printf '%s' "$CONFIG_XREF/$1.tsv" || printf ''; }
M_LG=$(mapf _subscriptions-logicals); M_VLG=$(mapf _profiles-logicals)
M_PT=$(mapf _subscriptions-partners); M_AP=$(mapf _subscriptions-apps); M_BL=$(mapf _subscriptions-bl)

AGG="$OUTDIR/.agg.tmp"
# ---------------------------------------------------------------------------
# ONE awk, two passes. Pass 1 = _transfers.tsv: per CoreId the OK / failed
# LEG counts, the failed-leg and resubmitted flags, and the distinct login /
# site / host sets. Pass 2 = _files.tsv: per File the nine name sets, then
# per (type, name) the counters, first/last by sortkey, the per-date buckets
# (date:files:in:out:ferr:bytes:tok:terr:rauto:rmok:rmerr:waiting:expired:legs)
# and the ten drill rings. Writes S| / T| lines to a temp file — ten drill
# lists per row are too much for a bash variable.
# ---------------------------------------------------------------------------
awk -F'\t' -v PF="$PARSED" -v FF="$FILES" -v OUTF="$AGG" -v DIMS="$DIMS" \
    -v M_LG="$M_LG" -v M_VLG="$M_VLG" -v M_PT="$M_PT" -v M_AP="$M_AP" -v M_BL="$M_BL" "$COREIDS_AWK"'
    function loadmulti(f, m,   l, n2, z, k) { if (f == "") return   # name -> \037-joined values (UNION maps)
        while ((getline l < f) > 0) { n2 = split(l, z, "\t")
            if (n2 >= 2 && z[1] != "" && z[2] != "") { k = toupper(z[1]); m[k] = m[k] (m[k] == "" ? "" : "\037") z[2] } }
        close(f) }
    function loadsingle(f, m,   l, n2, z) { if (f == "") return      # name -> ONE value (the profile -> Logical map)
        while ((getline l < f) > 0) { n2 = split(l, z, "\t"); if (n2 >= 2 && z[1] != "" && z[2] != "") m[toupper(z[1])] = z[2] }
        close(f) }
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
    function pctls(list,   n2, z, i2, j2, p2, N, Q, C, tmpq, tmpc, out) {
        P90 = ""; P95 = ""; P99 = ""; P100 = ""; HIST = ""; if (list == "") return
        n2 = split(list, z, "|"); N = 0
        for (i2 = 1; i2 <= n2; i2++) { p2 = index(z[i2], "."); Q[i2] = substr(z[i2], 1, p2 - 1) + 0; C[i2] = substr(z[i2], p2 + 1) + 0; N += C[i2] }
        for (i2 = 2; i2 <= n2; i2++) { tmpq = Q[i2]; tmpc = C[i2]; j2 = i2 - 1
            while (j2 >= 1 && Q[j2] > tmpq) { Q[j2 + 1] = Q[j2]; C[j2 + 1] = C[j2]; j2-- }
            Q[j2 + 1] = tmpq; C[j2 + 1] = tmpc }
        out = ""; for (i2 = 1; i2 <= n2; i2++) out = out (out == "" ? "" : ",") Q[i2] "." C[i2]
        HIST = out
        P90 = prank(Q, C, n2, N, 90); P95 = prank(Q, C, n2, N, 95); P99 = prank(Q, C, n2, N, 99); P100 = prank(Q, C, n2, N, 100) }
    function acc(key,   dk) {
        sc[key]++; if (isin) sfin[key]++; if (isout) sfout[key]++; if (f) sfe[key]++; sv[key] += size
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
        loadmulti(M_LG, LG); loadsingle(M_VLG, VLG); loadmulti(M_PT, PT); loadmulti(M_AP, AP); loadmulti(M_BL, BLM)
        PAIRTOT["subscription"] = 1; PAIRTOT["login"] = 1; PAIRTOT["remote-host"] = 1   # totals once per (name, File) pair — the classic join writers
    }
    FILENAME == PF {   # _transfers.tsv first: the per-CoreId leg facts
        cid = $1
        if ($3 == "Processed") tokc[cid]++; else { terrc[cid]++; fl[cid] = 1 }
        if ($22 == "true") rsb[cid] = 1
        if ($5 != "") lg[cid] = addset(lg[cid], $5)
        if ($6 != "") st[cid] = addset(st[cid], $6)
        if ($16 != "") hs[cid] = addset(hs[cid], $16)
        next }
    # _files.tsv comes TWICE: pass 2 aggregates, pass 3 collects the Duration
    # drills against the thresholds pass 2 produced (counted by the FILES
    # starts, so an empty _transfers.tsv cannot shift the numbering)
    FNR == 1 && FILENAME == FF { fpass++; if (fpass == 2) calc_pcts() }
    $4 == "" { next }
    {
        cid = $1; f = ($2 == "Failed" || $2 == "Expired"); date = $4; sk = $6; disp = $4 " " $5; size = $8 + 0
        isin = ($17 == "in"); isout = ($17 == "out"); wt = ($2 == "Waiting"); ex = ($2 == "Expired")
        tk = (cid in tokc) ? tokc[cid] : 0; te = (cid in terrc) ? terrc[cid] : 0
        ra = (!f && (cid in fl) && !(cid in rsb)); rmo = (!f && (cid in rsb)); rme = (f && (cid in rsb))
        dur = $9 + 0; hasd = (!f && dur > 0); q = hasd ? qdur(dur) : 0   # the Duration group: OK Files with a positive wall-clock span
        delete NS
        if ($3 != "") NS["account" SUBSEP $3] = 1
        if (cid in st) addnames("subscription", st[cid])
        if (cid in lg) addnames("login", lg[cid])
        if ($16 == "out" && (cid in hs)) addnames("remote-host", hs[cid])
        if ($13 != "" && (toupper($13) in VLG)) NS["logical" SUBSEP VLG[toupper($13)]] = 1
        if ($12 != "" && (toupper($12) in LG)) addnames("logical", LG[toupper($12)])
        if ($20 != "") NS["partner" SUBSEP $20] = 1
        if ($12 != "" && (toupper($12) in PT)) addnames("partner", PT[toupper($12)])
        if ($18 != "") NS["application" SUBSEP $18] = 1
        if ($12 != "" && (toupper($12) in AP)) addnames("application", AP[toupper($12)])
        if ($19 != "") NS["domain" SUBSEP $19] = 1
        if ($12 != "" && (toupper($12) in BLM)) addnames("bl", BLM[toupper($12)])
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
    END {
        for (dk in ds) { split(dk, kk, SUBSEP); key = kk[1] SUBSEP kk[2]; nd[key]++
            bk[key] = bk[key] (bk[key] ? "," : "") kk[3] ":" dl[dk] ":" (din[dk]+0) ":" (dout[dk]+0) ":" (dfe[dk]+0) ":" (db[dk]+0) ":" (dtok[dk]+0) ":" (dter[dk]+0) ":" (dra[dk]+0) ":" (dmo[dk]+0) ":" (dme[dk]+0) ":" (dwt[dk]+0) ":" (dex[dk]+0) ":" (dtok[dk]+dter[dk]) }
        if (!pdone) calc_pcts()   # no third pass (an empty cache): the percentiles are computed here
        # the per (type, name, DAY) duration histograms — the row payload
        # (";" between the entries of one day: "|" is the S| stream separator)
        for (k in dhd) { split(k, kk, SUBSEP); dk = kk[1] SUBSEP kk[2] SUBSEP kk[3]; dql[dk] = dql[dk] (dql[dk] == "" ? "" : ";") kk[4] "." dhd[k] }
        for (dk in dql) { split(dk, kk, SUBSEP); key = kk[1] SUBSEP kk[2]; ddp[key] = ddp[key] (ddp[key] == "" ? "" : ",") kk[3] ":" dql[dk] }
        for (key in sc) { split(key, kk, SUBSEP); t = kk[1]; ns[t]++
            printf "S|%s|%s|%d|%s|%s|%d|%d|%d|%d|%d|%d|%d|%d|%d|%d|%d|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n", \
                t, kk[2], sc[key], fst[key], lst[key], nd[key]+0, stok[key]+0, ster[key]+0, sfin[key]+0, sfout[key]+0, sfe[key]+0, \
                sra[key]+0, smo[key]+0, sme[key]+0, swt[key]+0, sex[key]+0, sv[key]+0, bk[key], \
                buildlist(top[key SUBSEP "tok"]), buildlist(top[key SUBSEP "terr"]), buildlist(top[key SUBSEP "fin"]), buildlist(top[key SUBSEP "fout"]), \
                buildlist(top[key SUBSEP "ferr"]), buildlist(top[key SUBSEP "rauto"]), buildlist(top[key SUBSEP "rmok"]), buildlist(top[key SUBSEP "rmerr"]), \
                buildlist(top[key SUBSEP "wait"]), buildlist(top[key SUBSEP "exp"]), \
                ((key in KP90) ? KP90[key] : ""), ((key in KP95) ? KP95[key] : ""), ((key in KP99) ? KP99[key] : ""), ((key in KP100) ? KP100[key] : ""), \
                ((key in ddp) ? ddp[key] : ""), \
                buildlist(top[key SUBSEP "d90"]), buildlist(top[key SUBSEP "d95"]), buildlist(top[key SUBSEP "d99"]), buildlist(top[key SUBSEP "d100"]) > OUTF }
        for (k in tdd) { split(k, kk, SUBSEP); tdays[kk[1]]++ }
        n2 = split(DIMS, TL, " ")   # a T| line for EVERY type, data or not (the config-only estate renders zero-row tables)
        for (i2 = 1; i2 <= n2; i2++) { t = TL[i2]
            printf "T|%s|%d|%d|%d|%d|%d|%d|%d|%d|%d|%d|%d|%d|%s|%d|%s|%s|%s|%s\n", t, tc[t]+0, tdays[t]+0, ttok[t]+0, tter[t]+0, tin[t]+0, tout[t]+0, tfe[t]+0, \
                tra[t]+0, tmo[t]+0, tme[t]+0, twt[t]+0, tex[t]+0, tv[t]+0, ns[t]+0, \
                ((t in TP90) ? TP90[t] : ""), ((t in TP95) ? TP95[t] : ""), ((t in TP99) ? TP99[t] : ""), ((t in TP100) ? TP100[t] : "") > OUTF }
    }
' "$PARSED" "$FILES" "$FILES"

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
FMT_AWK='
    function human(b,   u, i, v) { split("B KB MB GB TB PB", u, " "); i = 1; v = b + 0
        while (v >= 1024 && i < 6) { v /= 1024; i++ }
        return sprintf("%.0f %s", v, u[i]) }
    function pr(x, c) { if (x + 0 == 0 || c + 0 == 0) return ""; return sprintf("%.1f%%", x * 100 / c) }
    function nz(x) { return (x + 0 == 0) ? "" : x + 0 }
    function hshort(ms,   v) { v = ms / 1000; if (v < 59.5) return sprintf("%.0f s", v)
        v /= 60; if (v < 59.5) return sprintf("%.0f m", v); v /= 60; if (v < 23.5) return sprintf("%.0f h", v); return sprintf("%.0f d", v / 24) }
    function dtint(ms,   v) { v = ms / 1000; if (v < 59.5) return "processed"; if (v / 60 < 59.5) return "warn"; return "failed" }
    function dcell(ms) { return (ms == "") ? "" : "@{class=" dtint(ms) "}" hshort(ms) }
'

for dim in $DIMS; do
    case $dim in
        account)      title="Accounts";      chead="Account";      nkind=acct;  noun="account" ;;
        subscription) title="Subscriptions"; chead="Subscription"; nkind=site;  noun="subscription" ;;
        login)        title="Logins";        chead="Login";        nkind=login; noun="login" ;;
        remote-host)  title="Remote Hosts";  chead="Remote Host";  nkind=host;  noun="remote host" ;;
        logical)      title="Logical";       chead="Logical";      nkind=lgc;   noun="logical" ;;
        partner)      title="Partners";      chead="Partner";      nkind=ptn;   noun="partner" ;;
        application)  title="Applications";  chead="Application";  nkind=app;   noun="application" ;;
        domain)       title="Domains";       chead="Domain";       nkind=dom;   noun="domain" ;;
        bl)           title="BL";            chead="BL";           nkind=bl;    noun="BL" ;;
    esac
    OUT="$OUTDIR/$dim.rpt"
    IFS='|' read -r _ _ tc tdays ttok tter tin tout tfe tra tmo tme twt tex tv ns tp90 tp95 tp99 tp100 \
        <<< "$({ grep "^T|$dim|" "$AGG" || true; } | awk 'NR == 1')"
    : "${tc:=0}" "${tdays:=0}" "${ttok:=0}" "${tter:=0}" "${tin:=0}" "${tout:=0}" "${tfe:=0}" "${tra:=0}" "${tmo:=0}" "${tme:=0}" "${twt:=0}" "${tex:=0}" "${tv:=0}" "${ns:=0}" "${tp90:=}" "${tp95:=}" "${tp99:=}" "${tp100:=}"
    # the display order (2026-09-13, user request; Transfers moved after
    # Volume the same day): Files · Retry / Resubmit · Duration (p90 p95 p99
    # p100) · Volume · Transfers · State · Dates — 22 cells, the Dates LAST
    rows=$({ grep "^S|$dim|" "$AGG" || true; } | LC_ALL=C sort -t'|' -k4,4nr -k3,3f -k3,3 | awk -F'|' "$FMT_AWK"'
        $3 == "" { next }
        { files = $4 + 0; tok = $8 + 0; ter = $9 + 0; fe = $12 + 0; bytes = $18 + 0
          printf "ROW\t%s\t%s\t%s\t%d\t%s\t%d\t%d\t%d\t%s\t%s\t%s\t%s\t%s\t%s\t%d\t%d\t%s\t%d\t%d\t%s\t%s\t%d\t@data:buckets=%s\t@data:coreids-tok=%s\t@data:coreids-terr=%s\t@data:coreids-fin=%s\t@data:coreids-fout=%s\t@data:coreids-ferr=%s\t@data:coreids-rauto=%s\t@data:coreids-rmok=%s\t@data:coreids-rmerr=%s\t@data:coreids-wait=%s\t@data:coreids-exp=%s\t@data:durdays=%s\t@data:coreids-d90=%s\t@data:coreids-d95=%s\t@data:coreids-d99=%s\t@data:coreids-d100=%s\n", \
              $3, nz($10), nz($11), fe, pr(fe, files), $13, $14, $15, \
              dcell($30), dcell($31), dcell($32), dcell($33), human(bytes), human(files > 0 ? bytes / files : 0), \
              tok, ter, pr(ter, tok + ter), $16, $17, $5, $6, $7, \
              $19, $20, $21, $22, $23, $24, $25, $26, $27, $28, $29, $34, $35, $36, $37, $38 }')
    tot_line=$(awk -F'|' "$FMT_AWK"'BEGIN { tc = ARGV[1]; ttok = ARGV[2]; tter = ARGV[3]; tfe = ARGV[4]; tv = ARGV[5]; tin = ARGV[6]; tout = ARGV[7]
        printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", pr(tter, ttok + tter), pr(tfe, tc), human(tv), human(tc > 0 ? tv / tc : 0), nz(tin), nz(tout), dcell(ARGV[8]), dcell(ARGV[9]), dcell(ARGV[10]), dcell(ARGV[11]); exit }' \
        "$tc" "$ttok" "$tter" "$tfe" "$tv" "$tin" "$tout" "$tp90" "$tp95" "$tp99" "$tp100")
    IFS=$'\t' read -r tterp tfep tvh tavg tinz toutz td90 td95 td99 td100 <<< "$tot_line"
    {
        printf 'TITLE\t%s\n' "$title"
        printf 'DESC\tFiles per %s in the grouped Entities2 layout: dates, transfers, files, recoveries, state and volume — an experiment beside the classic Entities pages.\n' "$noun"
        printf 'INTRO\tEvery %s with its traffic in seven groups — **Files** (one per CoreId, split **In** / **Out** by the movement direction, with its Error count and rate), **Retry / Resubmit** (**Auto** = an OK File that carried a failed leg and was delivered by the platform'\''s own retry; **Ok** / **Error** = every File an operator resubmitted, by its final outcome), **Duration** (the p90 / p95 / p99 / p100 wall-clock duration of its OK Files — p100 = the longest — seconds green, minutes amber, hours and days red), **Volume** (the total, and the average per File), **Transfers** (the physical log rows — every leg of its Files — Ok/Error with the error rate), **State** (the UC2 **Waiting** files — staged, not collected yet — and the **Expired** ones, deleted unclaimed) and **Dates** (first and last day, days with traffic). Same rows, views and scopes as the classic Entities pages; every count opens its 10 most recent Files.\n' "$noun"
        printf 'TABLE\tSummary per %s\twide\tgsep=1,5,8,12,14,17,19\tnoagg=8,9,10,11,13,21\tpct=4:3:1+2;16:15:14+15\tdrillcols=fin:1:Files_In,fout:2:Files_Out,ferr:3:Files_Error,rauto:5:Retry,rmok:6:Resubmit_Ok,rmerr:7:Resubmit_Error,d90:8:Duration_p90,d95:9:Duration_p95,d99:10:Duration_p99,d100:11:Duration_p100,tok:14:Transfers_Ok,terr:15:Transfers_Error,wait:17:Waiting,exp:18:Expired\n' "$chead"
        printf 'GHEAD\t\t@{colspan=4,class=gband gsep}Files\t@{colspan=3,class=gband gsep}Retry / Resubmit\t@{colspan=4,class=gband gsep}Duration\t@{colspan=2,class=gband gsep}Volume\t@{colspan=3,class=gband gsep}Transfers\t@{colspan=2,class=gband gsep}State\t@{colspan=3,class=gband gsep}Dates\n'
        printf 'HEAD\t%s\tIn\tOut\tError\tError %%\tAuto\tOk\tError\tp90\tp95\tp99\tp100\tTotal\tAvg\tOk\tError\tError %%\tWaiting\tExpired\tFirst\tLast\tDays\n' "$chead"
        printf 'KIND\t%s\tnum\tnum\tnumfailed\tnum\tnumwarn\tnumwarn\tnumfailed\tnum\tnum\tnum\tnum\tnum\tnum\tnumok\tnumfailed\tnum\tnumwarn\tnumfailed\ttext\ttext\tnum\n' "$nkind"
        printf 'RECALC\t-\tS1\tS2\ts3\te3.0\ts7\ts8\ts9\tP90\tP95\tP99\tP100\tH4\tV4.0\ts5\ts6\te6.12\ts10\ts11\t-\t-\tc\n'
        [ -n "$rows" ] && printf '%s\n' "$rows"
        printf 'TOTAL\tTotal (%s %s(s))\t@{class=num}%s\t@{class=num}%s\t@{class=num failed}%s\t@{class=num}%s\t@{class=num warn}%s\t@{class=num warn}%s\t@{class=num failed}%s\t%s\t%s\t%s\t%s\t@{class=num}%s\t@{class=num}%s\t@{class=num okc}%s\t@{class=num failed}%s\t@{class=num}%s\t@{class=num warn}%s\t@{class=num failed}%s\t\t\t@{class=num}%s\n' \
            "$ns" "$noun" "$tinz" "$toutz" "$tfe" "$tfep" "$tra" "$tmo" "$tme" "$td90" "$td95" "$td99" "$td100" "$tvh" "$tavg" "$ttok" "$tter" "$tterp" "$twt" "$tex" "$tdays"
        printf 'NOTE\t**Files** = logical transfers (one per CoreId; Waiting counts as OK, Expired as Error), **Transfers** = the physical log rows of those Files (one per leg). **In** / **Out** is the movement direction of the File (a File with no known movement counts in the Files total and Error %% only); an empty Error cell keeps an empty rate beside it, and In / Out never show a 0. **Retry / Resubmit**: **Auto** = an OK File that carried at least one failed leg and no resubmitted leg — the platform'\''s own retry delivered it (the classic Retry column); **Ok** / **Error** = every File with a resubmitted leg (the log'\''s Resubmitted flag), OK or Error by its final outcome (the Top view'\''s Resubmit rule — a resubmitted re-delivery that never failed counts under Ok). **Duration** = the p90 / p95 / p99 / p100 (the longest) of the wall-clock duration of the OK Files (first record start to last record end, as on the Duration report — the Error attempts, mostly instant, are left out), re-picked for the selected From/To like every other figure, as whole seconds / minutes / hours / days (s m h d) — seconds green, minutes amber, hours and days red. **Volume** in whole units; **Avg** = the volume divided by the Files. **Retry / Resubmit** and **State** are shown only on a view where at least one File carries such a value. **Days** = the days with at least one File; First / Last stay full-period under the date filter. Click any count for its 10 most recent Files (newest first, by start time); the Transfers cells list the Files that carried a leg of that outcome, and a Duration cell the 10 most recent OK Files whose span is at or above that percentile, each with its span.\n'
        printf 'FOOT\tGenerated on %s from %s file(s)\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${#files[@]}"
    } > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"
    echo "Data written to $OUT ($ns $noun(s), $tc file(s))." >&2
done
rm -f "$AGG"
