#!/usr/bin/env bash
#
# alltime-counts.sh — the ALL-TIME count sidecar of the analyses Subscriptions
# page (bin/analyses/publish.sh write_subscriptions_page): every File of the
# cache, nine counts per (entity type, name) —
#   type<TAB>name<TAB>total in out errors auto rmok rmerr waiting expired
# sorted. Unpublished (no page). The Entities definitions: In / Out = the
# movement direction (_files.tsv col 17, else the connection side col 16);
# Errors = Failed + Expired; Auto = an OK File with a failed leg and no
# resubmitted leg; Resubmit OK / Error = every File with a resubmitted leg, by
# outcome; Waiting / Expired = the outcome (col 2). Attribution per entity
# mirrors bin/transfer/reports/entities.sh.
# (2026-09-29: was month-stats.sh, whose 18 Month stats pages went — the
# Entities pages under the date filter's This month / Previous month presets
# show the same figures; only this sidecar had another reader.)
#
# Usage:
#   ./alltime-counts.sh    # -> data/<env>/transfer/reports/_alltime.tsv
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib.sh"
mkdir -p "$REPORTS_DIR"
ALLF="$REPORTS_DIR/_alltime.tsv"
rm -rf "$REPORTS_DIR/month-stats"   # the retired Month stats .rpt set

mapf() { [ -f "$CONFIG_XREF/$1.tsv" ] && printf '%s' "$CONFIG_XREF/$1.tsv" || printf ''; }
M_LG=$(mapf _subscriptions-logicals); M_VLG=$(mapf _profiles-logicals)
M_PT=$(mapf _subscriptions-partners); M_AP=$(mapf _subscriptions-apps); M_BL=$(mapf _subscriptions-bl)

awk -F'\t' -v PF="$PARSED" \
    -v M_LG="$M_LG" -v M_VLG="$M_VLG" -v M_PT="$M_PT" -v M_AP="$M_AP" -v M_BL="$M_BL" '
    function loadmulti(f, m,   l, n2, z, k) { if (f == "") return
        while ((getline l < f) > 0) { n2 = split(l, z, "\t")
            if (n2 >= 2 && z[1] != "" && z[2] != "") { k = toupper(z[1]); m[k] = m[k] (m[k] == "" ? "" : "\037") z[2] } }
        close(f) }
    function loadsingle(f, m,   l, n2, z) { if (f == "") return
        while ((getline l < f) > 0) { n2 = split(l, z, "\t"); if (n2 >= 2 && z[1] != "" && z[2] != "") m[toupper(z[1])] = z[2] }
        close(f) }
    function addset(s, v) { return index("\037" s "\037", "\037" v "\037") ? s : (s == "" ? v : s "\037" v) }
    function addnames(t, s,   n2, z, i2) { if (s == "") return; n2 = split(s, z, "\037"); for (i2 = 1; i2 <= n2; i2++) NS[t SUBSEP z[i2]] = 1 }
    function acc(key) {   # key = type SUBSEP name
        sc[key]++; if (isin) sin_[key]++; if (isout) sout_[key]++; if (f) sfe[key]++
        if (ra) sra[key]++; if (rmo) smo[key]++; if (rme) sme[key]++; if (wt) swt[key]++; if (ex) sex[key]++ }
    BEGIN { loadmulti(M_LG, LG); loadsingle(M_VLG, VLG); loadmulti(M_PT, PT); loadmulti(M_AP, AP); loadmulti(M_BL, BLM) }
    FILENAME == PF {
        cid = $1
        if ($3 != "Processed") fl[cid] = 1
        if ($22 == "true") rsb[cid] = 1
        if ($5 != "") lg[cid] = addset(lg[cid], $5)
        if ($6 != "") st[cid] = addset(st[cid], $6)
        if ($16 != "") hs[cid] = addset(hs[cid], $16)
        next }
    $4 == "" { next }
    {
        cid = $1; f = ($2 == "Failed" || $2 == "Expired")
        # In / Out: the movement, else the connection side (entities.sh rule)
        mv = ($17 != "") ? $17 : $16
        isin = (mv == "in"); isout = (mv == "out"); wt = ($2 == "Waiting"); ex = ($2 == "Expired")
        ra = (!f && (cid in fl) && !(cid in rsb)); rmo = (!f && (cid in rsb)); rme = (f && (cid in rsb))
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
        for (k in NS) acc(k)
    }
    END {
        for (key in sc) { split(key, kk, SUBSEP)
            printf "%s\t%s\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\n", kk[1], kk[2], sc[key], sin_[key]+0, sout_[key]+0, sfe[key]+0, sra[key]+0, smo[key]+0, sme[key]+0, swt[key]+0, sex[key]+0 }
    }
' "$PARSED" "$FILES" | LC_ALL=C sort -t"$(printf '\t')" -k1,1 -k2,2 > "$ALLF.tmp"
mv "$ALLF.tmp" "$ALLF"
echo "Data written to $ALLF ($(wc -l < "$ALLF" | tr -d ' ') name(s))." >&2
