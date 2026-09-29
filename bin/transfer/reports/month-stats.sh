#!/usr/bin/env bash
#
# month-stats.sh — MONTH STATS (2026-09-13, user request): the nine entity
# types counted over the Files that STARTED in one calendar month — THIS
# month (the month of the newest File start in the cache) and the PREVIOUS
# one — 18 .rpt files under data/transfer/reports/month-stats/:
#   {this,previous}-{account,subscription,login,remote-host,logical,partner,application,domain,bl}.rpt
# rendered by publish_lib's render_month_stats into docs/transfer/month-stats/
# (a member of the Reports pulldown's Activity & volume group; two tab rows:
# the month, the entity). Retired 2026-09-29 morning as alltime-counts.sh
# (sidecar only) and BROUGHT BACK the same day, user request.
#
# PLUS the ALL-TIME sidecar $REPORTS_DIR/_alltime.tsv — every File, the same
# nine counts per (entity type, name) — the analyses Subscriptions page reads it.
#
# Columns per name: Total files · In Files · Out Files · Errors · Automatic ·
# Resubmit OK · Resubmit Error · Waiting · Expired — the Entities pages'
# definitions (In/Out = the movement direction, _files.tsv col 17, else the
# connection side col 16; Errors =
# Failed + Expired; Automatic = an OK File with a failed leg and no
# resubmitted leg; Resubmit OK / Error = every File with a resubmitted leg, by
# outcome — the leg flags _files.tsv col 26 / col 27; Waiting / Expired = the
# outcome col 2). Attribution per entity
# mirrors entities.sh exactly (see there); totals per (name, File) pair for
# subscription / login / remote-host, once per File for the rest.
#
# Usage:
#   ./month-stats.sh    # reads the caches, writes the 18 .rpt files
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
OUTDIR="$REPORTS_DIR/month-stats"
mkdir -p "$OUTDIR"
rm -f "$OUTDIR"/*.rpt.tmp "$OUTDIR"/.agg.tmp "$REPORTS_DIR"/_alltime.tsv.tmp "$REPORTS_DIR"/_alltime.tsv.tmp2

DIMS="account subscription login remote-host logical partner application domain bl"
echo "Found ${#files[@]} file(s) in '$INPUT_DIR', processing..." >&2

# THIS month = the month of the newest File start date in the cache (the
# data, not the wall clock — a lagging export must not show an empty month);
# an empty cache falls back to the calendar month. PREVIOUS = the month before.
newest=$(awk -F'\t' '$4 ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$/ && $4 > m { m = $4 } END { print m }' "$FILES")
if [ -n "$newest" ]; then THIS=${newest:0:7}; else THIS=$(date '+%Y-%m'); fi
PREV=$(awk -v m="$THIS" 'BEGIN { y = substr(m, 1, 4) + 0; mo = substr(m, 6, 2) + 0; mo--; if (mo == 0) { mo = 12; y-- } printf "%04d-%02d", y, mo }')

AGG="$OUTDIR/.agg.tmp"
# The ALL-TIME sidecar (2026-09-13, user request): every File regardless of
# month, the same nine counts per (type, name) — "type<TAB>name<TAB>total in
# out errors auto rmok rmerr waiting expired", sorted. Unpublished; the
# analyses Subscriptions page (bin/analyses/publish.sh write_subscriptions_page)
# reads its subscription rows for the count columns.
ALLF="$REPORTS_DIR/_alltime.tsv"   # beside the .rpt files (2026-09-29 — not in month-stats/)
: > "$ALLF.tmp"
awk -F'\t' -v PF="$PARSED" -v OUTF="$AGG" -v ALLF="$ALLF.tmp" -v DIMS="$DIMS" -v THIS="$THIS" -v PREV="$PREV" \
    "${SP_AWK_V[@]}" "$SP_AWK"'
    function addset(s, v) { return index("\037" s "\037", "\037" v "\037") ? s : (s == "" ? v : s "\037" v) }
    function addnames(t, s,   n2, z, i2) { if (s == "") return; n2 = split(s, z, "\037"); for (i2 = 1; i2 <= n2; i2++) NS[t SUBSEP z[i2]] = 1 }
    function acc(key) {   # key = month SUBSEP type SUBSEP name
        sc[key]++; if (isin) sin_[key]++; if (isout) sout_[key]++; if (f) sfe[key]++
        if (ra) sra[key]++; if (rmo) smo[key]++; if (rme) sme[key]++; if (wt) swt[key]++; if (ex) sex[key]++ }
    function tot(k) {     # k = month SUBSEP type
        tc[k]++; if (isin) tin[k]++; if (isout) tout[k]++; if (f) tfe[k]++
        if (ra) tra[k]++; if (rmo) tmo[k]++; if (rme) tme[k]++; if (wt) twt[k]++; if (ex) tex[k]++ }
    BEGIN {
        PAIRTOT["subscription"] = 1; PAIRTOT["login"] = 1; PAIRTOT["remote-host"] = 1
    }
    FILENAME == PF {   # _transfers.tsv: the per-File login / site / host sets (the leg flags come from _files.tsv col 26 / 27)
        cid = $1
        if ($5 != "") lg[cid] = addset(lg[cid], $5)
        if ($6 != "" && $6 != "Unknown") st[cid] = addset(st[cid], $6)   # "Unknown" = no subscription (2026-09-29)
        if ($16 != "") hs[cid] = addset(hs[cid], $16)
        next }
    $4 == "" { next }
    {
        mon = substr($4, 1, 7); inm = (mon == THIS || mon == PREV)   # the ALL-TIME bucket below takes every File
        cid = $1; f = ($2 == "Failed" || $2 == "Expired")
        # In / Out: the movement, else the connection side (entities.sh rule)
        mv = ($17 != "") ? $17 : $16
        isin = (mv == "in"); isout = (mv == "out"); wt = ($2 == "Waiting"); ex = ($2 == "Expired")
        ra = (!f && $26 == "1" && $27 != "1"); rmo = (!f && $27 == "1"); rme = (f && $27 == "1")   # col 26 = a failed leg, col 27 = a resubmitted leg
        delete NS
        if ($3 != "") NS["account" SUBSEP $3] = 1
        if (cid in st) addnames("subscription", st[cid])
        if (cid in lg) addnames("login", lg[cid])
        if ($16 == "out" && (cid in hs)) addnames("remote-host", hs[cid])
        # logical / partner / application / BL = the UNION sets (bin/pda-union.sh)
        addnames("logical", lg_union($13, $12))
        addnames("partner", sp_union($20, $12))
        addnames("application", ap_union($18, $12))
        if ($19 != "") NS["domain" SUBSEP $19] = 1
        addnames("bl", bl_union($12))
        delete TS
        for (k in NS) { split(k, kk, SUBSEP); t = kk[1]
            acc("all" SUBSEP k)                     # the _alltime.tsv sidecar (analyses/subscriptions.html)
            if (!inm) continue
            acc(mon SUBSEP k); TS[t] = 1
            if (t in PAIRTOT) tot(mon SUBSEP t) }
        if (inm) for (t in TS) if (!(t in PAIRTOT)) tot(mon SUBSEP t)
    }
    END {
        for (key in sc) { split(key, kk, SUBSEP)
            if (kk[1] == "all") { printf "%s\t%s\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\n", kk[2], kk[3], sc[key], sin_[key]+0, sout_[key]+0, sfe[key]+0, sra[key]+0, smo[key]+0, sme[key]+0, swt[key]+0, sex[key]+0 > ALLF; continue }
            ns[kk[1] SUBSEP kk[2]]++
            printf "S|%s|%s|%s|%d|%d|%d|%d|%d|%d|%d|%d|%d\n", kk[1], kk[2], kk[3], sc[key], sin_[key]+0, sout_[key]+0, sfe[key]+0, sra[key]+0, smo[key]+0, sme[key]+0, swt[key]+0, sex[key]+0 > OUTF }
        n2 = split(DIMS, TL, " "); split(THIS " " PREV, MM, " ")
        for (m = 1; m <= 2; m++) for (i2 = 1; i2 <= n2; i2++) { t = TL[i2]; k = MM[m] SUBSEP t
            printf "T|%s|%s|%d|%d|%d|%d|%d|%d|%d|%d|%d|%d\n", MM[m], t, tc[k]+0, tin[k]+0, tout[k]+0, tfe[k]+0, tra[k]+0, tmo[k]+0, tme[k]+0, twt[k]+0, tex[k]+0, ns[k]+0 > OUTF }
    }
'  "$PARSED" "$FILES"
LC_ALL=C sort -t"$(printf '\t')" -k1,1 -k2,2 "$ALLF.tmp" > "$ALLF.tmp2" && mv "$ALLF.tmp2" "$ALLF" && rm -f "$ALLF.tmp"

nz0() { [ "${1:-0}" = 0 ] || printf '%s' "$1"; }   # a count cell shows blank, never 0

for which in this previous; do
    [ "$which" = this ] && mon=$THIS || mon=$PREV
    for dim in $DIMS; do
        case $dim in
            account)      title="Accounts";      chead="Account";      nkind=acct;  noun="account" ;;
            subscription) title="Subscriptions"; chead="Subscription"; nkind=site;  noun="subscription" ;;
            login)        title="Logins";        chead="Login";        nkind=login; noun="login" ;;
            remote-host)  title="Hosts";         chead="Remote Host";  nkind=host;  noun="remote host" ;;   # title = the menu label (entities.sh)
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
        # rows busiest first (Total files desc, name tiebreak); no count cell
        # ever shows a 0 (2026-09-29: only In / Out were blanked)
        rows=$({ grep "^S|$mon|$dim|" "$AGG" || true; } | LC_ALL=C sort -t'|' -k5,5nr -k4,4f -k4,4 | awk -F'|' '
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
            printf 'META\tmonth\t%s\n' "$mon"
            printf 'TABLE\t%s — Files started in %s\twide\tsort=1:-1\n' "$title" "$mon"
            printf 'HEAD\t%s\tTotal files\tIn Files\tOut Files\tErrors\tAutomatic\tResubmit OK\tResubmit Error%s\n' "$chead" "$hstate"
            printf 'KIND\t%s\tnum\tnum\tnum\tnumfailed\tnumwarn\tnumwarn\tnumfailed%s\n' "$nkind" "$kstate"
            [ -n "$rows" ] && printf '%s\n' "$rows"
            printf 'TOTAL\tTotal (%s %s(s))\t@{class=num}%s\t@{class=num}%s\t@{class=num}%s\t@{class=num failed}%s\t@{class=num warn}%s\t@{class=num warn}%s\t@{class=num failed}%s%s\n' \
                "$ns" "$noun" "$tc" "$(nz0 "$tin")" "$(nz0 "$tout")" "$(nz0 "$tfe")" "$(nz0 "$tra")" "$(nz0 "$tmo")" "$(nz0 "$tme")" "$tstate"
            printf 'FOOT\n'
        } > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"
    done
done
rm -f "$AGG"
echo "Data written to $OUTDIR (this month $THIS, previous $PREV, 18 report(s))." >&2
