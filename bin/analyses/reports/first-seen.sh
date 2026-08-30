#!/usr/bin/env bash
#
# first-seen.sh — the First seen analysis: for five entity types (partner,
# subscription, account, login, remote host), the calendar day each CONFIGURED
# name was FIRST seen — plus, on top, the names never seen and the names seen
# WITHOUT a dated transfer of their own. The universe and the seen split are
# the COVERAGE TSVs (showseen's healed universe — the same files behind the
# home status tables and the Entities views), so the page's Seen/Not seen
# figures equal the status tables' by construction. TWO VIEWS, rendered as
# two tab pages by bin/analyses/publish.sh:
#
#   Transfer log only          the coverage seen set MINUS blue (the Entities
#                              -transfer scope: a blue, server-log-only entity
#                              counts as Not seen)
#   Both Transfer & Server     the full coverage seen set (the +Server scope);
#                              a blue name (the base result column,
#                              bin/build/seen-in-server-log.sh) never transferred, so it
#                              takes the OLDEST first-transfer of its
#                              cross-referenced entities (the
#                              data/flow-manager/xref pair caches — its
#                              account, subscription, login, host, partner):
#                              the day its surrounding flow first became
#                              active. NO server-log scan — the daily
#                              housekeeping mentions (File Maintenance) would
#                              drown the signal; blue is the site's curated
#                              server-seen set.
#
# A seen name with NO dated transfer of its own — a UC3 clean-poll green
# (works, nothing to fetch yet), a sibling-credited name, an undated blue —
# lands in the "Seen, no date" bucket: per column, Seen + Not seen = Total
# and the day rows + the no-date row = Seen.
#
#   -> data/analyses/reports/first-seen.rpt        the Transfer-only page spec
#   -> data/analyses/reports/first-seen-both.rpt   the both-logs page spec
#      (each: SEEN / NOTSEEN / NODATE / ROW / TOTAL lines, columns partners
#      subscriptions accounts logins hosts)
#   -> data/first-seen/<type>-<key>.rpt            one per NONZERO cell (key =
#      YYYY-MM-DD | notseen | nodate | seen | total; the both-logs cells carry
#      a both- key prefix and a 6th ROW field = Transfer, or Server for a blue
#      name dated via its crosses) — rendered into docs/first-seen/ by
#      bin/analyses/publish.sh, like the coverage cells.
#
# Sources: the coverage TSVs (transfer/reports/coverage/{partners,
# subscriptions,accounts,logins,hosts}.tsv — the seen flags; the partner
# endpoint-alias rows, link col hosts/…, are skipped), the transfer parse
# caches — _files.tsv (accounts col 3, partners col 20 unioned with the
# subscription's configured partners, first-row date/time cols 4/5) and
# _transfers.tsv (subscriptions col 6, logins col 5, hosts
# col 16, date/time cols 11/12) — for the DATES, plus the
# data/flow-manager/base entity lists (configured names + direction + result),
# the 10 xref pair caches among the five types, and the comprehensive
# detail-page slugmaps (links; a name with no map entry renders unlinked).
# Date matching: exact, case aside — subscriptions by prefix (a configured
# name matches the logged site values it prefixes).
#
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib.sh"

TF="$DATA/transfer/cache/_files.tsv"
TT="$DATA/transfer/cache/_transfers.tsv"
if [ ! -f "$TF" ] || [ ! -f "$TT" ]; then
    echo "first-seen: transfer caches missing; skipping." >&2
    exit 0
fi
OUT="$REPORTS_DIR/first-seen.rpt"
OUT2="$REPORTS_DIR/first-seen-both.rpt"

BASE="$DATA/flow-manager/base"
DET="$DATA/transfer/reports/details"
XREF="$DATA/flow-manager/xref"
COV="$DATA/transfer/reports/coverage"
# the seen flags come from the coverage TSVs; the three PDA ones are
# materialized here (idempotent, cmp-guarded — this script runs inside the
# wave-2 ensure_pda_tsvs chain of bin/analyses/reports.sh, never beside
# another caller)
ensure_pda_tsvs
srcs=()
for f in _partners _subscriptions _accounts _logins _hosts; do
    [ -f "$BASE/$f.tsv" ] && srcs+=("$BASE/$f.tsv")
done
for f in partners subscriptions accounts logins hosts; do
    [ -f "$COV/$f.tsv" ] && srcs+=("$COV/$f.tsv")
done
for d in partners subscriptions accounts logins hosts; do
    [ -f "$DET/$d/_slugmap.tsv" ] && srcs+=("$DET/$d/_slugmap.tsv")
done
# the 10 cross-reference pairs among the five types (one direction each — the
# loader stores both ways). Optional: without them the blue names simply stay
# in the both view's Not seen.
for f in _partners-accounts _partners-subscriptions _partners-logins _partners-hosts \
         _accounts-subscriptions _accounts-logins _accounts-hosts \
         _subscriptions-logins _subscriptions-hosts _logins-hosts \
         _subscriptions-partners; do
    [ -f "$XREF/$f.tsv" ] && srcs+=("$XREF/$f.tsv")
done

# This report writes THREE kinds of output — the two .rpt above and one cell
# .rpt per First-seen day — so all of them must be present before the mtime
# check can stand in for the lot (skip_if_fresh exits on the first fresh one).
shopt -s nullglob
_cells=("$FSRPT_DIR"/*.rpt)
shopt -u nullglob
if [ -f "$OUT" ] && [ -f "$OUT2" ] && [ ${#_cells[@]} -gt 0 ]; then
    skip_if_fresh "$OUT" "${BASH_SOURCE[0]}" "$TF" "$TT" ${srcs[@]+"${srcs[@]}"}
fi
rm -f "$FSRPT_DIR"/*.rpt

# ---- pass A: one line per CONFIGURED entity per view -------------------------
# view <TAB> type <TAB> sortk <TAB> key <TAB> name <TAB> dir <TAB> seen <TAB>
# link <TAB> first_ts <TAB> log   (sortk "0" = notseen, "0z" = seen-no-date,
# "1<date>" = a day — so notseen, then nodate, sort before the days per type;
# view 1 = transfer-only, 2 = both logs; log = Transfer, or Server for a blue
# name dated via its crosses), plus one "#DATE <TAB> 0 <TAB> date" line per
# calendar day in the logs (the main tables list EVERY log day, blank when
# nothing was first seen). Emission order is hash-order; the sort(1) between
# the passes makes the output deterministic.
# A configured RAW-IP endpoint used to log under its PTR name, so an alias
# bridged the two. With no reverse DNS (2026-07) such an address stays raw in
# col 16 and matches _hosts.tsv directly, so the alias is gone — showseen.sh
# dropped the same bridge, and the two pages still cannot disagree.
LC_ALL=C awk -F'\t' -v OFS='\t' '
    function dirl(d) { return (d == "in") ? "I" : (d == "out") ? "O" : (d == "both") ? "B" : "" }
    function conf(t, n, d, r,   cu) {
        cu = toupper(n)
        if ((t SUBSEP cu) in cname) return
        cname[t SUBSEP cu] = n; cdir[t SUBSEP cu] = d; cres[t SUBSEP cu] = r
        # NB: cn[t]++ on its own line — "t SUBSEP ++cn[t]" lexes as a
        # post-increment of SUBSEP itself (t (SUBSEP++) cn[t]), silently
        # turning SUBSEP into a growing integer and corrupting every key.
        cn[t]++; ck[t SUBSEP cn[t]] = cu
    }
    function upd(t, n, d, tm,   cu, k, ts) {
        if (n == "" || d == "") return
        cu = toupper(n); k = t SUBSEP cu; ts = d " " tm
        if (!(k in first) || ts < first[k]) { first[k] = ts; fdisp[k] = n }
    }
    function addx(tA, a, tB, b,   ka, kb) {
        ka = tA SUBSEP toupper(a); kb = tB SUBSEP toupper(b)
        xn[ka]++; xr[ka SUBSEP xn[ka]] = kb   # (increments separated — see conf())
        xn[kb]++; xr[kb SUBSEP xn[kb]] = ka
    }
    # first transfer of the cross-referenced entity key k2 ("" if never seen);
    # a subscription cross falls back to the prefix rule against the logged
    # site values (a configured name matches the logged values it prefixes)
    function xfirst(k2,   s, t2, cu2, m, lk, P2) {
        if (k2 in first) return first[k2]
        split(k2, P2, SUBSEP); t2 = P2[1]; cu2 = P2[2]
        s = ""
        if (t2 == "subscriptions")
            for (m = 1; m <= ln[t2]; m++) {
                lk = t2 SUBSEP lv[t2 SUBSEP m]
                if (index(lv[t2 SUBSEP m], cu2) == 1 && (s == "" || first[lk] < s)) s = first[lk]
            }
        return s
    }
    FILENAME ~ /base\/_partners\.tsv$/      { conf("partners",      $1, $2, $3); next }
    # "UCx_<account>" = the parse-time SYNTHETIC subscription for transfers no
    # attribution pass could place (bin/transfer/parse.sh). It reaches the base
    # cache like every logged-but-unconfigured name (result.sh discover_logged)
    # but is EXCLUDED from First seen by design: nothing was configured, so
    # there is nothing whose first sighting could be dated.
    FILENAME ~ /base\/_subscriptions\.tsv$/ { if ($1 ~ /^UCx_/) next; conf("subscriptions", $1, $2, $3); next }
    FILENAME ~ /base\/_accounts\.tsv$/      { conf("accounts",      $1, $2, $3); next }
    FILENAME ~ /base\/_logins\.tsv$/        { conf("logins",        $1, $2, $3); next }
    FILENAME ~ /base\/_hosts\.tsv$/         { conf("hosts",         $1, $2, $3); next }
    # the coverage seen flags (col 3) — the healed universe the status tables
    # and Entities views are built on
    # (NB: keys fold case here while home.sh pda_seen_total matches exactly —
    # equal today because no base list carries case-variant duplicates; a
    # case-variant pair would make the two seen counts diverge); the partner ENDPOINT-ALIAS rows (link
    # col hosts/…) are shared-endpoint bookkeeping, not partner names. A "1"
    # always wins (OR-merge, mirroring home.sh).
    function covput(t9, n9, s9,   k9) { k9 = t9 SUBSEP toupper(n9); if (s9 == "1") cov[k9] = "1"; else if (!(k9 in cov)) cov[k9] = s9 }
    FILENAME ~ /coverage\/partners\.tsv$/ {
        if ($2 == "I") { inptn[toupper($1)] = 1; covput("partners", $1, $3); next }
        # a non-In row whose col 8 names a known In partner FOLDS onto it —
        # seen when either side is (home.sh pda_seen_total; in practice the
        # shared-endpoint ALIAS rows, whose own name is a host, not a
        # partner); anything else stands as its own partner row. The file
        # lists the In rows first, like pda_seen_total assumes.
        if ($8 != "" && (toupper($8) in inptn)) { if ($3 == "1") cov["partners" SUBSEP toupper($8)] = "1" }
        else covput("partners", $1, $3)
        next
    }
    FILENAME ~ /coverage\/subscriptions\.tsv$/ { if ($1 ~ /^UCx_/) next; covput("subscriptions", $1, $3); next }
    FILENAME ~ /coverage\/accounts\.tsv$/      { covput("accounts",      $1, $3); next }
    FILENAME ~ /coverage\/logins\.tsv$/        { covput("logins",        $1, $3); next }
    FILENAME ~ /coverage\/hosts\.tsv$/         { covput("hosts",         $1, $3); next }
    FILENAME ~ /details\/partners\/_slugmap\.tsv$/       { smap["partners"      SUBSEP toupper($1)] = "partners/" $2;       next }
    FILENAME ~ /details\/subscriptions\/_slugmap\.tsv$/ { smap["subscriptions" SUBSEP toupper($1)] = "subscriptions/" $2; next }
    FILENAME ~ /details\/accounts\/_slugmap\.tsv$/       { smap["accounts"      SUBSEP toupper($1)] = "accounts/" $2;       next }
    FILENAME ~ /details\/logins\/_slugmap\.tsv$/         { smap["logins"        SUBSEP toupper($1)] = "logins/" $2;         next }
    FILENAME ~ /details\/hosts\/_slugmap\.tsv$/          { smap["hosts"         SUBSEP toupper($1)] = "hosts/" $2;          next }
    FILENAME ~ /xref\/_subscriptions-partners\.tsv$/ { if ($1 != "" && $2 != "") SUBP2[toupper($1)] = SUBP2[toupper($1)] SUBSEP $2; next }
    FILENAME ~ /xref\/_partners-accounts\.tsv$/      { addx("partners", $1, "accounts", $2);      next }
    FILENAME ~ /xref\/_partners-subscriptions\.tsv$/ { addx("partners", $1, "subscriptions", $2); next }
    FILENAME ~ /xref\/_partners-logins\.tsv$/        { addx("partners", $1, "logins", $2);        next }
    FILENAME ~ /xref\/_partners-hosts\.tsv$/         { addx("partners", $1, "hosts", $2);         next }
    FILENAME ~ /xref\/_accounts-subscriptions\.tsv$/ { addx("accounts", $1, "subscriptions", $2); next }
    FILENAME ~ /xref\/_accounts-logins\.tsv$/        { addx("accounts", $1, "logins", $2);        next }
    FILENAME ~ /xref\/_accounts-hosts\.tsv$/         { addx("accounts", $1, "hosts", $2);         next }
    FILENAME ~ /xref\/_subscriptions-logins\.tsv$/   { addx("subscriptions", $1, "logins", $2);   next }
    FILENAME ~ /xref\/_subscriptions-hosts\.tsv$/    { addx("subscriptions", $1, "hosts", $2);    next }
    FILENAME ~ /xref\/_logins-hosts\.tsv$/           { addx("logins", $1, "hosts", $2);           next }
    FILENAME ~ /_files\.tsv$/ {
        if ($4 != "") dates[$4] = 1
        FCN[$1] = $16   # connection side per CoreId, for the hosts out-gate below
        upd("accounts", $3, $4, $5); upd("partners", $20, $4, $5)
        # partner = the UNION of col 20 and the subscription'\''s configured
        # partner(s) — a both-partner file carries an empty col 20 (the parse
        # abstains on a two-group account); cf. pda-entities.sh
        if ($12 != "" && (toupper($12) in SUBP2)) {
            n9 = split(substr(SUBP2[toupper($12)], 2), Z9, SUBSEP)
            for (i9 = 1; i9 <= n9; i9++) upd("partners", Z9[i9], $4, $5)
        }
        next
    }
    FILENAME ~ /_transfers\.tsv$/ {
        if ($11 != "") dates[$11] = 1
        upd("subscriptions", $6, $11, $12); upd("logins", $5, $11, $12)
        # HOST entities are OUTBOUND endpoints only (the hosts we dial): on an
        # incoming-connection File col 16 is the partner SOURCE address — it
        # belongs to the whitelist/incoming views, never the Hosts column
        if (FCN[$1] == "out") upd("hosts", $16, $11, $12)
        next
    }
    END {
        # per-type upper lists of the LOGGED values — the subscription prefix
        # rule in xfirst() matches configured names against them
        for (k in first) {
            split(k, P, SUBSEP); t = P[1]
            ln[t]++; lv[t SUBSEP ln[t]] = P[2]   # (increment separated — see conf())
        }
        # one line per CONFIGURED name per view. The seen SPLIT is the
        # coverage flag (view 1 minus blue — the Entities -transfer scope);
        # the DATE is the name'\''s own first transfer (subscriptions by
        # prefix), for a blue name in view 2 the oldest first-transfer of its
        # xref crosses. Seen without a date -> the "nodate" bucket, so the
        # day rows + nodate always sum to Seen.
        nt = split("partners subscriptions accounts logins hosts", TL, " ")
        for (i = 1; i <= nt; i++) {
            t = TL[i]
            for (j = 1; j <= cn[t]; j++) {
                cu = ck[t SUBSEP j]; k = t SUBSEP cu
                covseen = ((k in cov) && cov[k] == "1")
                blue = (cres[k] == "blue")
                d1 = xfirst(k)
                nm = cname[k]; dl = dirl(cdir[k]); lk2 = smap[k]
                if (covseen && !blue) {
                    if (d1 != "") { d = substr(d1, 1, 10); print 1, t, "1" d, d, nm, dl, 1, lk2, d1, "Transfer" }
                    else            print 1, t, "0z", "nodate", nm, dl, 1, lk2, "", ""
                } else {
                    print 1, t, "0", "notseen", nm, dl, 0, lk2, "", ""
                }
                if (covseen) {
                    d2 = d1; lg = "Transfer"
                    if (d2 == "" && blue) {
                        bd = ""
                        for (m = 1; m <= xn[k] + 0; m++) {
                            s = xfirst(xr[k SUBSEP m])
                            if (s != "" && (bd == "" || s < bd)) bd = s
                        }
                        if (bd != "") { d2 = bd; lg = "Server" }
                    }
                    if (d2 != "") { d = substr(d2, 1, 10); print 2, t, "1" d, d, nm, dl, 1, lk2, d2, lg }
                    else            print 2, t, "0z", "nodate", nm, dl, 1, lk2, "", ""
                } else {
                    print 2, t, "0", "notseen", nm, dl, 0, lk2, "", ""
                }
            }
        }
        for (d in dates) print "#DATE", "0", d
    }
' ${srcs[@]+"${srcs[@]}"} "$TF" "$TT" \
| LC_ALL=C sort -t"$(printf '\t')" -k1,1 -k2,2 -k3,3 -k4,4 -k5,5 \
| LC_ALL=C awk -F'\t' -v OFS='\t' -v FSD="$FSRPT_DIR" -v MAIN="$OUT.tmp" -v MAIN2="$OUT2.tmp" \
      -v GENDATE="$(date '+%Y-%m-%d %H:%M:%S')" '
    # ---- pass B: split the sorted stream into the cell .rpts + the two page
    # specs. The stream sorts view 1 (transfer-only) before view 2 (both logs);
    # the both-logs cell files carry a both- key prefix and a 6th ROW field.
    function lbl(t) {
        return (t == "partners") ? "Partners" : (t == "subscriptions") ? "Subscriptions" : \
               (t == "accounts") ? "Accounts" : (t == "logins") ? "Logins" : "Hosts"
    }
    function celltitle(v, t, key, n) {
        if (v == 2) {
            if (key == "notseen") return lbl(t) ": Not seen — transfer & server logs (" n ")"
            if (key == "nodate")  return lbl(t) ": Seen, no dated transfer — transfer & server logs (" n ")"
            if (key == "seen")    return lbl(t) ": Seen — transfer & server logs (" n ")"
            if (key == "total")   return lbl(t) ": All — transfer & server logs (" n ")"
            return lbl(t) ": First seen " key " (" n ") — transfer & server logs"
        }
        if (key == "notseen") return lbl(t) ": Not seen in the transfer logs (" n ")"
        if (key == "nodate")  return lbl(t) ": Seen, no dated transfer (" n ")"
        if (key == "seen")    return lbl(t) ": Seen in the transfer logs (" n ")"
        if (key == "total")   return lbl(t) ": All (" n ")"
        return lbl(t) ": First seen " key " (" n ")"
    }
    function fkey(v, key) { return (v == 2) ? "both-" key : key }
    function flushcell(   f, i, v, t) {
        if (bn == 0) return
        split(cvt, VT, SUBSEP); v = VT[1]; t = VT[2]
        f = FSD "/" t "-" fkey(v, cck) ".rpt"
        print "TITLE\t" celltitle(v, t, cck, bn) > f
        print "MEMBER\t" t > f
        print "KEY\t" fkey(v, cck) > f
        for (i = 1; i <= bn; i++) print buf[i] > f
        close(f); bn = 0
    }
    function flushtotal(vt,   f, i, v, t) {
        if (vt == "" || tn[vt] + 0 == 0) return
        split(vt, VT, SUBSEP); v = VT[1]; t = VT[2]
        f = FSD "/" t "-" fkey(v, "total") ".rpt"
        print "TITLE\t" celltitle(v, t, "total", tn[vt]) > f
        print "MEMBER\t" t > f
        print "KEY\t" fkey(v, "total") > f
        for (i = 1; i <= tn[vt]; i++) print tb[vt SUBSEP i] > f
        close(f)
    }
    function flushseen(vt,   f, i, v, t) {   # every seen row: dated days + nodate (Total minus Not seen)
        if (vt == "" || sn[vt] + 0 == 0) return
        split(vt, VT, SUBSEP); v = VT[1]; t = VT[2]
        f = FSD "/" t "-" fkey(v, "seen") ".rpt"
        print "TITLE\t" celltitle(v, t, "seen", sn[vt]) > f
        print "MEMBER\t" t > f
        print "KEY\t" fkey(v, "seen") > f
        for (i = 1; i <= sn[vt]; i++) print sb[vt SUBSEP i] > f
        close(f)
    }
    function pagespec(v, out, desc,   line, i, k) {
        print "TITLE\tFirst seen" > out
        print "DESC\t" desc > out
        line = "SEEN"; for (i = 1; i <= nt; i++) line = line OFS ((tn[v SUBSEP TL[i]] + 0) - (cnt[v SUBSEP TL[i] SUBSEP "notseen"] + 0))
        print line > out
        line = "NOTSEEN"; for (i = 1; i <= nt; i++) line = line OFS (cnt[v SUBSEP TL[i] SUBSEP "notseen"] + 0)
        print line > out
        line = "NODATE"; for (i = 1; i <= nt; i++) line = line OFS (cnt[v SUBSEP TL[i] SUBSEP "nodate"] + 0)
        print line > out
        for (k = nd; k >= 1; k--) {   # newest day first
            line = "ROW" OFS days[k]
            for (i = 1; i <= nt; i++) line = line OFS (cnt[v SUBSEP TL[i] SUBSEP days[k]] + 0)
            print line > out
        }
        line = "TOTAL"; for (i = 1; i <= nt; i++) line = line OFS (tn[v SUBSEP TL[i]] + 0)
        print line > out
        print "FOOT\tGenerated on " GENDATE > out
        close(out)
    }
    $1 == "#DATE" { alldates[$3] = 1; next }
    {
        vt = $1 SUBSEP $2; key = $4
        if (vt != cvt || key != cck) flushcell()
        if (vt != cvt) { flushtotal(cvt); flushseen(cvt) }
        cvt = vt; cck = key
        row = "ROW\t" $5 "\t" $6 "\t" $7 "\t" $8 "\t" $9
        if ($1 == 2) row = row "\t" $10
        buf[++bn] = row
        tn[vt]++; tb[vt SUBSEP tn[vt]] = row   # (increment separated — see pass A conf())
        if (key != "notseen") { sn[vt]++; sb[vt SUBSEP sn[vt]] = row }
        cnt[vt SUBSEP key]++
    }
    END {
        flushcell(); flushtotal(cvt); flushseen(cvt)
        nt = split("partners subscriptions accounts logins hosts", TL, " ")
        # ordered day list (shared by both views)
        nd = 0; for (d in alldates) days[++nd] = d
        for (i = 2; i <= nd; i++) { v = days[i]; j = i - 1; while (j >= 1 && days[j] > v) { days[j+1] = days[j]; j-- } days[j+1] = v }
        pagespec(1, MAIN,  "On what day each configured partner, subscription, account, login and remote host was first seen in the transfer logs — the same Seen/Not seen split as the home status tables. Per column: Seen + Not seen = Total; the day rows plus the no-date row sum to Seen.")
        pagespec(2, MAIN2, "On what day each configured partner, subscription, account, login and remote host was first seen — including the server-log-only (blue) names, each dated by the OLDEST first transfer of its cross-referenced entities. Per column: Seen + Not seen = Total; the day rows plus the no-date row sum to Seen.")
    }
'
# The awk wrote both pages to .tmp (after the per-cell rpts); the renames here
# publish them only once the whole run completed — a killed run leaves the old
# complete reports with stale mtimes (rebuild) instead of fresh truncated ones.
mv "$OUT.tmp" "$OUT"
mv "$OUT2.tmp" "$OUT2"

echo "Data written to $OUT + $OUT2 (+ $(ls "$FSRPT_DIR" | wc -l | tr -d ' ') cell rpt(s) in $FSRPT_DIR)." >&2
