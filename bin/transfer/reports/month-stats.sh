#!/usr/bin/env bash
#
# month-stats.sh — MONTH STATS (2026-09-13, user request): the nine entity
# types counted over the Files that STARTED in one calendar month — THIS
# month (the month of the newest File start in the cache) and the PREVIOUS
# one — 18 .rpt files under data/transfer/reports/month-stats/:
#   {this,previous}-{account,subscription,login,remote-host,logical,partner,application,domain,bl}.rpt
# rendered by publish_lib's render_month_stats into docs/transfer/month-stats/
# (the Analyses menu's "Month stats" entry; two tab rows: the month, the entity).
#
# Columns per name: Total files · In Files · Out Files · Errors · Auto Retries ·
# Resubmit OK · Resubmit Error · Waiting · Expired — the Entities pages'
# definitions (In/Out = the movement direction, _files.tsv col 17; Errors =
# Failed + Expired; Auto Retries = an OK File with a failed leg and no
# resubmitted leg; Resubmit OK / Error = every File with a resubmitted leg, by
# outcome; Waiting / Expired = the outcome col 2). Attribution per entity
# mirrors entities.sh exactly (see there); totals per (name, File) pair for
# subscription / login / remote-host, once per File for the rest.
#
# Usage:
#   ./month-stats.sh    # reads the caches, writes the 18 .rpt files
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
OUTDIR="$REPORTS_DIR/month-stats"
mkdir -p "$OUTDIR"
rm -f "$OUTDIR"/*.rpt.tmp "$OUTDIR"/.agg.tmp
ensure_parsed

DIMS="account subscription login remote-host logical partner application domain bl"
_fresh=1
for _w in this previous; do for _o in $DIMS; do
    _f="$OUTDIR/$_w-$_o.rpt"
    if ! { [ -f "$_f" ] && ! [ "$PARSED" -nt "$_f" ] && ! [ "$FILES" -nt "$_f" ] && ! [ "${BASH_SOURCE[0]}" -nt "$_f" ] && ! [ "$LIB_DIR/lib.sh" -nt "$_f" ]; }; then
        _fresh=0; break 2
    fi
done; done
if [ "$_fresh" = 1 ]; then
    echo "  month-stats/*.rpt are up to date; skipping." >&2
    exit 0
fi
unset _fresh _w _o _f
echo "Found ${#files[@]} file(s) in '$INPUT_DIR', processing..." >&2

mapf() { [ -f "$CONFIG_XREF/$1.tsv" ] && printf '%s' "$CONFIG_XREF/$1.tsv" || printf ''; }
M_LG=$(mapf _subscriptions-logicals); M_VLG=$(mapf _profiles-logicals)
M_PT=$(mapf _subscriptions-partners); M_AP=$(mapf _subscriptions-apps); M_BL=$(mapf _subscriptions-bl)

# THIS month = the month of the newest File start date in the cache (the
# data, not the wall clock — a lagging export must not show an empty month);
# an empty cache falls back to the calendar month. PREVIOUS = the month before.
newest=$(awk -F'\t' '$4 ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$/ && $4 > m { m = $4 } END { print m }' "$FILES")
if [ -n "$newest" ]; then THIS=${newest:0:7}; else THIS=$(date '+%Y-%m'); fi
PREV=$(awk -v m="$THIS" 'BEGIN { y = substr(m, 1, 4) + 0; mo = substr(m, 6, 2) + 0; mo--; if (mo == 0) { mo = 12; y-- } printf "%04d-%02d", y, mo }')

AGG="$OUTDIR/.agg.tmp"
awk -F'\t' -v PF="$PARSED" -v OUTF="$AGG" -v DIMS="$DIMS" -v THIS="$THIS" -v PREV="$PREV" \
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
    function acc(key) {   # key = month SUBSEP type SUBSEP name
        sc[key]++; if (isin) sin_[key]++; if (isout) sout_[key]++; if (f) sfe[key]++
        if (ra) sra[key]++; if (rmo) smo[key]++; if (rme) sme[key]++; if (wt) swt[key]++; if (ex) sex[key]++ }
    function tot(k) {     # k = month SUBSEP type
        tc[k]++; if (isin) tin[k]++; if (isout) tout[k]++; if (f) tfe[k]++
        if (ra) tra[k]++; if (rmo) tmo[k]++; if (rme) tme[k]++; if (wt) twt[k]++; if (ex) tex[k]++ }
    BEGIN {
        loadmulti(M_LG, LG); loadsingle(M_VLG, VLG); loadmulti(M_PT, PT); loadmulti(M_AP, AP); loadmulti(M_BL, BLM)
        PAIRTOT["subscription"] = 1; PAIRTOT["login"] = 1; PAIRTOT["remote-host"] = 1
    }
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
        mon = substr($4, 1, 7); if (mon != THIS && mon != PREV) next
        cid = $1; f = ($2 == "Failed" || $2 == "Expired")
        isin = ($17 == "in"); isout = ($17 == "out"); wt = ($2 == "Waiting"); ex = ($2 == "Expired")
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
        delete TS
        for (k in NS) { split(k, kk, SUBSEP); t = kk[1]
            acc(mon SUBSEP k); TS[t] = 1
            if (t in PAIRTOT) tot(mon SUBSEP t) }
        for (t in TS) if (!(t in PAIRTOT)) tot(mon SUBSEP t)
    }
    END {
        for (key in sc) { split(key, kk, SUBSEP); ns[kk[1] SUBSEP kk[2]]++
            printf "S|%s|%s|%s|%d|%d|%d|%d|%d|%d|%d|%d|%d\n", kk[1], kk[2], kk[3], sc[key], sin_[key]+0, sout_[key]+0, sfe[key]+0, sra[key]+0, smo[key]+0, sme[key]+0, swt[key]+0, sex[key]+0 > OUTF }
        n2 = split(DIMS, TL, " "); split(THIS " " PREV, MM, " ")
        for (m = 1; m <= 2; m++) for (i2 = 1; i2 <= n2; i2++) { t = TL[i2]; k = MM[m] SUBSEP t
            printf "T|%s|%s|%d|%d|%d|%d|%d|%d|%d|%d|%d|%d\n", MM[m], t, tc[k]+0, tin[k]+0, tout[k]+0, tfe[k]+0, tra[k]+0, tmo[k]+0, tme[k]+0, twt[k]+0, tex[k]+0, ns[k]+0 > OUTF }
    }
' "$PARSED" "$FILES"

for which in this previous; do
    [ "$which" = this ] && mon=$THIS || mon=$PREV
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
        OUT="$OUTDIR/$which-$dim.rpt"
        IFS='|' read -r _ _ _ tc tin tout tfe tra tmo tme twt tex ns \
            <<< "$({ grep "^T|$mon|$dim|" "$AGG" || true; } | awk 'NR == 1')"
        : "${tc:=0}" "${tin:=0}" "${tout:=0}" "${tfe:=0}" "${tra:=0}" "${tmo:=0}" "${tme:=0}" "${twt:=0}" "${tex:=0}" "${ns:=0}"
        # rows busiest first (Total files desc, name tiebreak); In / Out never show a 0
        rows=$({ grep "^S|$mon|$dim|" "$AGG" || true; } | LC_ALL=C sort -t'|' -k5,5nr -k4,4f -k4,4 | awk -F'|' '
            function nz(x) { return (x + 0 == 0) ? "" : x + 0 }
            $4 == "" { next }
            { printf "ROW\t%s\t%d\t%s\t%s\t%d\t%d\t%d\t%d\t%d\t%d\n", $4, $5, nz($6), nz($7), $8, $9, $10, $11, $12, $13 }')
        [ "$which" = this ] && wlabel="this month" || wlabel="previous month"
        {
            printf 'TITLE\tMonth stats — %s — %s\n' "$title" "$mon"
            printf 'DESC\tThe %ss with Files that started in %s (%s): total, in and out Files, Errors, automatic retries, resubmits OK and Error, Waiting and Expired Files.\n' "$noun" "$mon" "$wlabel"
            printf 'META\tmonth\t%s\nMETA\twhich\t%s\n' "$mon" "$which"
            printf 'TABLE\t%s — Files started in %s\twide\tsort=1:-1\n' "$title" "$mon"
            printf 'HEAD\t%s\tTotal files\tIn Files\tOut Files\tErrors\tAuto Retries\tResubmit OK\tResubmit Error\tWaiting\tExpired\n' "$chead"
            printf 'KIND\t%s\tnum\tnum\tnum\tnumfailed\tnumwarn\tnumwarn\tnumfailed\tnumwarn\tnumfailed\n' "$nkind"
            [ -n "$rows" ] && printf '%s\n' "$rows"
            printf 'TOTAL\tTotal (%s %s(s))\t@{class=num}%s\t@{class=num}%s\t@{class=num}%s\t@{class=num failed}%s\t@{class=num warn}%s\t@{class=num warn}%s\t@{class=num failed}%s\t@{class=num warn}%s\t@{class=num failed}%s\n' \
                "$ns" "$noun" "$tc" "$([ "$tin" = 0 ] && printf '' || printf '%s' "$tin")" "$([ "$tout" = 0 ] && printf '' || printf '%s' "$tout")" "$tfe" "$tra" "$tmo" "$tme" "$twt" "$tex"
            printf 'FOOT\tGenerated on %s from %s file(s)\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${#files[@]}"
        } > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"
    done
done
rm -f "$AGG"
echo "Data written to $OUTDIR (this month $THIS, previous $PREV, 18 report(s))." >&2
