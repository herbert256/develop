#!/usr/bin/env bash
#
# seen-in-server-log.sh — the "Server log → Transfer log" build step (runs right
# BEFORE bin/build/result.sh — the stale-blue reset below depends on result.sh
# coming after): mark every entity that appears in the SERVER logs (TM runtime
# lines only) but never in the transfer logs BLUE in the result column of
# data/flow-manager/base/*.tsv, so those entities surface across the site
# (entity reports, detail pages, coverage, result tints) as a distinct 4th
# result state — server-log-seen — alongside green / red / orange.
#
# NO fake transfer rows are injected any more: _files.tsv and _transfers.tsv
# stay exactly what the parse produced, and there is no data/fakes/ directory.
# The old overlay (a fabricated Failed _files/_transfers row per entity + a
# data/fakes/<type>.tsv membership list consulted at publish time) is replaced
# by a real `blue` value in the base result column that the normal result-tint
# path already renders. Every server-log-only entity today is ALREADY a
# configured name in base/*.tsv, so this step is a pure RECOLOR (it will append
# a blue row for a name absent from base, but that case does not currently
# arise).
#
# Sources: the data/unknown/{accounts,logins,sites,hosts,white}.tsv sidecars
# written by the five server unknown-* reports (one row per unknown entity:
# "name <TAB> latest TM-mention date time <TAB> session_id <TAB> message";
# only cols 1-2 are used here). This script runs those reports first, so the
# sidecars always match the current caches.
#
# The blue SET (which names go blue) is computed exactly as the old data/fakes
# set was: enrich each seed via the data/flow-manager/xref pair caches (the same
# single-value vote as transfer parse.sh's xref_fill, iterated to a fixpoint;
# HOST is never a fill target; a site seed is first canonicalized to the unique
# configured subscription it prefixes), then for each of the 7 entity types the
# enriched values that appear on NO REAL _files.tsv row are the blue names.
#   - a HOST or WHITELISTED-IP seed that enriches to NOTHING (no account/
#     login/subscription/profile) is DROPPED, not counted.
#   - duplicates (two seeds enriching to the same combination) collapse to one.
#
# data/seen-in-server-log.tsv keeps the enriched tuples (the _files.tsv 20-col layout)
# for inspection and for the "Server log → Transfer log" audit page
# (bin/analyses/reports/seen-in-server-log.sh) — it is a standalone intermediate, NEVER appended to any
# cache.
#
# Cache discipline:
#   - _files.tsv / _transfers.tsv are never touched (the blue model
#     fabricates no rows).
#   - base/*.tsv is recolored in place, cmp-guarded per file so a no-op build
#     leaves the mtimes (and docs/) alone.
#
# Usage:
#   ./seen-in-server-log.sh    # refresh sidecars, recolor base/*.tsv blue, rebuild data/seen-in-server-log.tsv
#
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$ROOT/bin/fastawk.sh"   # route unqualified `awk` to mawk when installed
source "$ROOT/bin/env.sh"       # resolve $AXWAY_ENV (acceptance|production, default acceptance)

DATA="$ROOT/data/$AXWAY_ENV"
CACHE="$DATA/transfer/cache"
FILESC="$CACHE/_files.tsv"
TRANSC="$CACHE/_transfers.tsv"
XREF="$DATA/flow-manager/xref"
BASE="$DATA/flow-manager/base"
UNK="$DATA/unknown"
BLUE_TSV="$DATA/seen-in-server-log.tsv"

[ -f "$FILESC" ] || { echo "seen-in-server-log.sh: no $FILESC (run bin/transfer/parse.sh first) — nothing to do." >&2; exit 0; }
[ -f "$TRANSC" ] || { echo "seen-in-server-log.sh: no $TRANSC (run bin/transfer/parse.sh first) — nothing to do." >&2; exit 0; }

tmp="$CACHE/_blue.tmp.$$"
trap 'rm -f "$tmp".*' EXIT

# old-model cleanup: the data/fakes/ overlay directory is gone — blue now lives
# in the base result column. Remove it so a migrated checkout has no stale set.
rm -rf "$ROOT/data/fakes"

# ONE pass over _files.tsv collecting, per entity column, the distinct
# UPPER-CASED values that ride a real row ("col<TAB>VALUE") — recolor() and
# the Step-B SD extraction read THIS small set instead of each re-scanning
# the 117k-row cache (the 8 recolor calls were 8 full passes).
awk -F'\t' '
    { if ($3  != "" && !s[3,  toupper($3)]++)  print 3  "\t" toupper($3)
      if ($12 != "" && !s[12, toupper($12)]++) print 12 "\t" toupper($12)
      if ($13 != "" && !s[13, toupper($13)]++) print 13 "\t" toupper($13)
      if ($14 != "" && !s[14, toupper($14)]++) print 14 "\t" toupper($14)
      if ($15 != "" && !s[15, toupper($15)]++) print 15 "\t" toupper($15)
      if ($18 != "" && !s[18, toupper($18)]++) print 18 "\t" toupper($18)
      if ($19 != "" && !s[19, toupper($19)]++) print 19 "\t" toupper($19)
      if ($20 != "" && !s[20, toupper($20)]++) print 20 "\t" toupper($20) }
' "$FILESC" > "$tmp.fseen"

# ---------------------------------------------------------------------------
# Step A — refresh the sidecars: run the unknown-* scan (ONE map-reduce pass
# for all five reports since 2026-07 — bin/server/reports/unknown-entities.sh,
# with its own all-outputs freshness check, so a steady-state build costs one
# fast skip). Run it only when server inputs exist; without them, whatever
# sidecars are on disk are used as-is (none at all = an empty seed set, which
# cleanly clears all blue below). bin/server/parse.sh runs ONCE up front (an
# early-exit no-op when the cache is fresh, which in a bin/build.sh run it
# always is: the parse step precedes this one).
# ---------------------------------------------------------------------------
shopt -s nullglob
srv_inputs=("$ROOT/input/$AXWAY_ENV/server/"*.csv)   # the ACTIVE ENV's server inputs (pre-split path missed in the 2026-07 env sweep)
shopt -u nullglob
if [ ${#srv_inputs[@]} -gt 0 ]; then
    "$ROOT/bin/server/parse.sh"
    "$ROOT/bin/server/reports/unknown-entities.sh"
else
    echo "seen-in-server-log.sh: no input/server/*.csv — using the sidecars on disk as-is." >&2
fi

# ---------------------------------------------------------------------------
# Step B — build the candidate rows. One awk pass over (1) the xref vote map
# (the same 16 pair caches, X records, as transfer parse.sh's fallback),
# (2) the configured subscription list (site-seed canonicalization) and
# (3) the five sidecars (accounts, logins, sites, hosts, white). Emits one 14-column coreid-less _files row per seed
# (outcome..host, cols 2-15 of the final layout), immediately per input line —
# never from a for-in loop — so the output order is the sidecar order and no
# awk hash-iteration order can leak into the data.
# ---------------------------------------------------------------------------
xmap="$tmp.xmap"
{
    printf '#\n'   # sentinel: keeps the map file non-empty so awk file routing stays safe
    for _xs in \
        "A:S:_accounts-subscriptions" "L:S:_logins-subscriptions" "H:S:_hosts-subscriptions" "P:S:_profiles-subscriptions" \
        "L:A:_logins-accounts" "S:A:_subscriptions-accounts" "H:A:_hosts-accounts" "P:A:_profiles-accounts" \
        "A:L:_accounts-logins" "S:L:_subscriptions-logins" "H:L:_hosts-logins" "P:L:_profiles-logins" \
        "A:P:_accounts-profiles" "S:P:_subscriptions-profiles" "L:P:_logins-profiles" "H:P:_hosts-profiles" \
        "W:S:_white-subscriptions" "W:A:_white-accounts" "W:L:_white-logins" "W:P:_white-profiles"; do
        _sk=${_xs%%:*}; _rest=${_xs#*:}; _dk=${_rest%%:*}; _xf="$XREF/${_rest#*:}.tsv"
        if [ -f "$_xf" ]; then
            awk -F'\t' -v sk="$_sk" -v dk="$_dk" -v OFS='\t' '$1 != "" && $2 != "" { print "X", sk, dk, $1, $2 }' "$_xf"
        fi
    done
    if [ -f "$BASE/_subscriptions.tsv" ]; then
        awk -F'\t' '$1 != "" { print "C\t" $1 }' "$BASE/_subscriptions.tsv"
    fi
    # whitelisted-IP -> subscription full list (WS) + the subscriptions with
    # REAL transfer data (SD): a white seed whose partner already transfers is
    # merely an unused alternate address, NOT a server-log-only discovery —
    # the seed loop below drops it.
    if [ -f "$XREF/_white-subscriptions.tsv" ]; then
        awk -F'\t' '$1 != "" && $2 != "" { print "WS\t" $1 "\t" $2 }' "$XREF/_white-subscriptions.tsv"
    fi
    awk -F'\t' '$1 == "12" { print "SD\t" $2 }' "$tmp.fseen"   # distinct col-12, first-occurrence order preserved
} > "$xmap"

sidecars=()
for sc in accounts logins sites hosts white; do
    [ -f "$UNK/$sc.tsv" ] && sidecars+=("$UNK/$sc.tsv")
done

cand="$tmp.cand"
: > "$tmp.evid"   # blue-evidence: type<TAB>UPPER(value)<TAB>"date time"<TAB>server-log message (appended by Step B, the app/domain/partner join, and Step F0; consolidated to latest-per-key at the end)
if [ ${#sidecars[@]} -gt 0 ]; then
    awk -F'\t' -v OFS='\t' -v evid="$tmp.evid" '
        # jdn(): Julian day number (bin/transfer/parse.sh) — date arithmetic
        # without the date command.
        function jdn(y,m,d,   a) { a=int((14-m)/12); y=y+4800-a; m=m+12*a-3; return d+int((153*m+2)/5)+365*y+int(y/4)-int(y/100)+int(y/400)-32045 }
        # xone1 / xref_fill: the single-value cross-reference vote, verbatim
        # from bin/transfer/parse.sh — every populated other field that maps to
        # exactly ONE candidate votes; all voters must agree, else "".
        function xone1(sk, dk, val,   kk) {
            if (val == "" || val == "UNKNOWN") return ""
            kk = sk SUBSEP dk SUBSEP toupper(val)
            return (xn[kk] == 1) ? xone[kk] : ""
        }
        function xref_fill(dk, a, l, s, h, p, w,   c, v) {
            c = xone1("A", dk, a)
            v = xone1("L", dk, l); if (v != "") { if (c == "") c = v; else if (toupper(c) != toupper(v)) return "" }
            v = xone1("S", dk, s); if (v != "") { if (c == "") c = v; else if (toupper(c) != toupper(v)) return "" }
            v = xone1("H", dk, h); if (v != "") { if (c == "") c = v; else if (toupper(c) != toupper(v)) return "" }
            v = xone1("P", dk, p); if (v != "") { if (c == "") c = v; else if (toupper(c) != toupper(v)) return "" }
            v = xone1("W", dk, w); if (v != "") { if (c == "") c = v; else if (toupper(c) != toupper(v)) return "" }
            return c
        }
        FILENAME ~ /xmap/ {
            if ($1 == "X") {
                kk = $2 SUBSEP $3 SUBSEP toupper($4)
                if (!((kk, toupper($5)) in xseen)) { xseen[kk, toupper($5)] = 1; xn[kk]++; xone[kk] = $5 }
            } else if ($1 == "C") { ns++; csub[ns] = $2; cidx[toupper($2)] = 1 }
            else if ($1 == "WS") { wsub[toupper($2)] = wsub[toupper($2)] SUBSEP toupper($3) }
            else if ($1 == "SD") { sdata[$2] = 1 }
            next
        }
        # ---- sidecar rows: name <TAB> "YYYY-MM-DD HH:MM:SS.mmm" <TAB> session_id
        $1 == "" || $2 == "" { next }
        {
            if      (FILENAME ~ /accounts\.tsv$/) { ty = "A"; tyname = "account" }
            else if (FILENAME ~ /logins\.tsv$/)   { ty = "L"; tyname = "login" }
            else if (FILENAME ~ /sites\.tsv$/)    { ty = "S"; tyname = "subscription" }
            else if (FILENAME ~ /hosts\.tsv$/)    { ty = "H"; tyname = "host" }
            else if (FILENAME ~ /white\.tsv$/)    { ty = "W"; tyname = "whitelisted IP" }
            else next
            name = $1
            a = ""; l = ""; s = ""; h = ""; p = ""; w = ""
            if      (ty == "A") a = name
            else if (ty == "L") l = name
            else if (ty == "H") h = name
            else if (ty == "W") {
                w = name
                # already-seen guard: an IP whose partner has REAL transfer
                # data (any connected subscription on a real _files row) is
                # not "seen only in the server log" — its address is merely
                # unused; the unknown-whitelisting report still lists it.
                nws = split(substr(wsub[toupper(name)], 2), WA, SUBSEP)
                for (i2 = 1; i2 <= nws; i2++) if (WA[i2] in sdata) { wdrop++; w = ""; break }
                if (w == "") next
            }
            else {
                # site seeds: server messages truncate long names — canonicalize
                # to the configured subscription when the token is exactly one,
                # or extends to exactly one (exact match wins; ambiguity keeps
                # the token as logged).
                s = name
                if (!(toupper(name) in cidx)) {
                    hits = 0
                    for (i = 1; i <= ns; i++) if (index(csub[i], name) == 1) { hits++; cs = csub[i] }
                    if (hits == 1) s = cs
                }
            }
            # fixpoint: parse.sh fill order (site — the hub — then account,
            # login, profile), repeated until a pass adds nothing. Host is
            # never filled (parse.sh precedent) but votes as a source.
            changed = 1
            for (iter = 1; iter <= 5 && changed; iter++) {
                changed = 0
                if (s == "") { v = xref_fill("S", a, l, "", h, p, w); if (v != "") { s = v; changed = 1 } }
                if (a == "") { v = xref_fill("A", "", l, s, h, p, w); if (v != "") { a = v; changed = 1 } }
                if (l == "") { v = xref_fill("L", a, "", s, h, p, w); if (v != "") { l = v; changed = 1 } }
                if (p == "") { v = xref_fill("P", a, l, s, h, "", w); if (v != "") { p = v; changed = 1 } }
            }
            if (a != "" || l != "" || s != "" || p != "") enriched++
            # a HOST or WHITELISTED-IP seed that ties to nothing (no account,
            # login, subscription or profile — a bare address the config does
            # not connect to anything unambiguously) is DROPPED: a server-log-
            # only entity with only an IP attribution is noise (the whitelist
            # side keeps its own unknown-whitelisting report either way).
            if ((ty == "H" || ty == "W") && a == "" && l == "" && s == "" && p == "") { ndrop++; next }
            # date parts -> the parse.sh derivations (sortkey = YYYYMMDD||time)
            d = substr($2, 1, 10); t = substr($2, 12)
            sk2 = substr(d,1,4) substr(d,6,2) substr(d,9,2) t
            jd  = jdn(substr(d,1,4)+0, substr(d,6,2)+0, substr(d,9,2)+0)
            # blue-evidence: the seed server-log line ($3 = message) attributed
            # to every entity value it produces, so bin/build/result.sh can write the
            # per-entity blue/<type>/<name>.txt file. Hosts/IPs keyed lowercase.
            if (a != "") print "account",      toupper(a), d " " t, $3 >> evid
            if (s != "") print "subscription", toupper(s), d " " t, $3 >> evid
            if (l != "") print "login",        toupper(l), d " " t, $3 >> evid
            if (h != "") print "host",         tolower(h), d " " t, $3 >> evid
            if (ty == "W" && w != "") print "whitelisted-ip", w, d " " t, $4 >> evid
            nseed[ty]++
            # a whitelisted-IP seed carries its address in the HOST column (it
            # IS the source address; since the side-aware parse the real
            # in-side hosts are raw IPs too) — the recolor below excludes
            # BLUE: whitelisted IP rows from the _hosts pass, so a whitelist
            # address never lands in the hosts base cache.
            print "Failed", a, d, t, sk2, jd, 0, 0, 1, "BLUE: " tyname, s, p, l, (ty == "W" ? w : h)
        }
        END {
            printf "seen-in-server-log.sh: %d seed(s) (%d account, %d login, %d site, %d host, %d whitelisted IP), %d enriched by xref, %d unlinked host/IP seed(s) dropped, %d already-seen IP seed(s) dropped.\n", \
                nseed["A"]+nseed["L"]+nseed["S"]+nseed["H"]+nseed["W"], nseed["A"]+0, nseed["L"]+0, nseed["S"]+0, nseed["H"]+0, nseed["W"]+0, enriched+0, ndrop+0, wdrop+0 | "cat 1>&2"
        }
    ' "$xmap" "${sidecars[@]}" > "$cand"
else
    : > "$cand"
    echo "seen-in-server-log.sh: no data/unknown sidecars — empty blue set (any leftover blue will be cleared by bin/build/result.sh)." >&2
fi

# ---------------------------------------------------------------------------
# Step C — dedup: two seeds that enriched to the same (account, login, site,
# host, profile) combination are the same entity; keep the row with the LATEST
# date/time (sortkey desc), the seed-type file value as the deterministic
# tiebreaker ("BLUE: account" < "BLUE: host" < …).
# Candidate columns: 1 outcome 2 account 3 date 4 time 5 sortkey 6 jdn 7 size
# 8 dur 9 rows 10 file 11 site 12 profile 13 login 14 host.
# Step D — stable order + deterministic CoreIds + the config-column join (cols 16-20; movement stays blank),
# exactly parse.sh's join: after prepending the coreid the account sits in
# col 3 and the host in col 15, the columns parse.sh's join reads. The result
# (data/seen-in-server-log.tsv) is the enriched-tuple audit intermediate.
# ---------------------------------------------------------------------------
dedup="$tmp.dedup"
LC_ALL=C sort -t"$(printf '\t')" -k2,2 -k13,13 -k11,11 -k14,14 -k12,12 -k5,5r -k10,10 "$cand" \
    | awk -F'\t' '{ k = $2 SUBSEP $13 SUBSEP $11 SUBSEP $14 SUBSEP $12; if (k in seen) next; seen[k] = 1; print }' \
    | LC_ALL=C sort \
    | awk -F'\t' -v OFS='\t' '{ printf "fa4e0000-0000-4000-8000-%012x\t%s\n", NR, $0 }' > "$dedup"
n_cand=$(wc -l < "$cand" | tr -d ' ')
n_blue=$(wc -l < "$dedup" | tr -d ' ')

pda_caches=()
for cf in "$XREF/_accounts-logins.tsv" "$XREF/_accounts-hosts.tsv" "$XREF/_accounts-apps.tsv" \
          "$XREF/_accounts-domains.tsv" "$XREF/_accounts-partners.tsv" "$XREF/_hosts-partners.tsv" \
          "$XREF/_subscriptions-apps.tsv" "$XREF/_subscriptions-domains.tsv" \
          "$XREF/_subscriptions-partners.tsv" "$BASE/_subscriptions.tsv"; do
    [ -f "$cf" ] && pda_caches+=("$cf")
done
newfiles="$tmp.newfiles"
if [ ${#pda_caches[@]} -eq 0 ]; then
    awk -F'\t' 'BEGIN{OFS="\t"} { print $0, "", "", "", "", "" }' "$dedup" > "$newfiles"
else
    # col 17 (movement, the file-movement direction) stays "" on blue tuples —
    # they are server-log-only markers, no file actually moved.
    awk -F'\t' 'BEGIN{OFS="\t"; AMB=sprintf("%c",1)}
        FILENAME ~ /_accounts-logins\.tsv$/   { al[toupper($1)]=1; next }
        FILENAME ~ /_accounts-hosts\.tsv$/    { ah[toupper($1)]=1; next }
        # app/domain: the tuple SUBSCRIPTION first (the FlowID spine, 1:1),
        # the account only as an unambiguous fallback (2026-08-31)
        FILENAME ~ /_accounts-apps\.tsv$/     { k=toupper($1); if(!(k in aa)) aa[k]=$2; else if(aa[k]!=$2) aa[k]=AMB; next }
        FILENAME ~ /_accounts-domains\.tsv$/  { k=toupper($1); if(!(k in ad)) ad[k]=$2; else if(ad[k]!=$2) ad[k]=AMB; next }
        FILENAME ~ /_subscriptions-apps\.tsv$/    { k=toupper($1); if(!(k in sa)) sa[k]=$2; else if(sa[k]!=$2) sa[k]=AMB; next }
        FILENAME ~ /_subscriptions-domains\.tsv$/ { k=toupper($1); if(!(k in sd)) sd[k]=$2; else if(sd[k]!=$2) sd[k]=AMB; next }
        # partner: subscription -> host -> account, every map AMB-guarded, and
        # the connection side from the SUBSCRIPTION comm-profile side (base
        # _subscriptions.tsv col 2) before the account rule — the parse-time
        # rules for _files.tsv cols 16/20 (2026-08-31 audit: hp was the one
        # bare last-row-wins map here, and a hybrid account carrying hosts AND
        # logins always read "out")
        FILENAME ~ /_accounts-partners\.tsv$/ { k=toupper($1); if(!(k in ap)) ap[k]=$2; else if(ap[k]!=$2) ap[k]=AMB; next }
        FILENAME ~ /_subscriptions-partners\.tsv$/ { k=toupper($1); if(!(k in sp)) sp[k]=$2; else if(sp[k]!=$2) sp[k]=AMB; next }
        FILENAME ~ /_hosts-partners\.tsv$/    { k=tolower($1); if(!(k in hp)) hp[k]=$2; else if(hp[k]!=$2) hp[k]=AMB; next }
        FILENAME ~ /base\/_subscriptions\.tsv$/ { if($2=="in"||$2=="out") scn[toupper($1)]=$2; next }
        {
            a=toupper($3); h=tolower($15); s=toupper($12)
            d=(s!="" && (s in scn))?scn[s]:((a in ah)?"out":((a in al)?"in":""))
            p=""
            if(s!="" && (s in sp) && sp[s]!=AMB) p=sp[s]
            else if(h!="" && (h in hp) && hp[h]!=AMB) p=hp[h]
            else if((a in ap) && ap[a]!=AMB) p=ap[a]
            a18=""; if(s!="" && (s in sa) && sa[s]!=AMB) a18=sa[s]; if(a18=="" && (a in aa) && aa[a]!=AMB) a18=aa[a]
            d19=""; if(s!="" && (s in sd) && sd[s]!=AMB) d19=sd[s]; if(d19=="" && (a in ad) && ad[a]!=AMB) d19=ad[a]
            print $0, d, "", a18, d19, p
        }
    ' "${pda_caches[@]}" "$dedup" > "$newfiles"
fi

# blue-evidence for application/domain/partner/logical/bl: the tuple's
# SUBSCRIPTION seed line when it has one (the values ride the subscription
# since 2026-08-31, so must the evidence — the account's newest line is about
# some other flow of a hybrid account), else the account seed's line, keyed
# to the newfiles row's own date/time. newfiles cols: 3 account 4 date 5 time
# 12 subscription 13 profile 18 app 19 domain 20 partner; the profile resolves
# to its Logical through the FlowID map. Appended to $tmp.evid.
awk -F'\t' -v OFS='\t' -v PLM="$XREF/_profiles-logicals.tsv" -v SBL="$XREF/_subscriptions-bl.tsv" '
    BEGIN { while ((getline pl9 < PLM) > 0) { n9 = split(pl9, p9, "\t")
                if (n9 >= 2 && p9[1] != "" && p9[2] != "") PM[toupper(p9[1])] = p9[2] }
            close(PLM)
            while ((getline pl9 < SBL) > 0) { n9 = split(pl9, p9, "\t")
                if (n9 >= 2 && p9[1] != "" && p9[2] != "") BM[toupper(p9[1])] = BM[toupper(p9[1])] "\037" p9[2] }
            close(SBL) }
    FILENAME==ARGV[1] && $1=="account"      { if ($3 > adt[$2]) { adt[$2]=$3; amsg[$2]=$4 }; next }
    FILENAME==ARGV[1] && $1=="subscription" { if ($3 > sdt[$2]) { sdt[$2]=$3; smsg[$2]=$4 }; next }
    FILENAME==ARGV[1] { next }
    FILENAME==ARGV[2] { ac=toupper($3); su=toupper($12); when=$4 " " $5
        m=(su!="" && (su in smsg))?smsg[su]:((ac in amsg)?amsg[ac]:"")
        if ($13!="" && (toupper($13) in PM)) print "logical", toupper(PM[toupper($13)]), when, m
        if ($12!="" && (toupper($12) in BM)) { nb9=split(substr(BM[toupper($12)],2),B9,"\037")
            for (ib9=1; ib9<=nb9; ib9++) print "bl", toupper(B9[ib9]), when, m }
        if ($18!="") print "application", toupper($18), when, m
        if ($19!="") print "domain",      toupper($19), when, m
        if ($20!="") print "partner",     toupper($20), when, m }
' "$tmp.evid" "$newfiles" > "$tmp.evid2" && cat "$tmp.evid2" >> "$tmp.evid"

# (The former Step E — stripping leftover FAKE rows from the caches — was
# REMOVED 2026-07: the old-model rows are long gone from every checkout and
# the blue model fabricates none.)

# data/seen-in-server-log.tsv: the enriched tuples (audit intermediate for
# the Seen-in-server-log page). NOT appended to any cache. cmp-guarded.
if ! cmp -s "$newfiles" "$BLUE_TSV" 2>/dev/null; then
    cp "$newfiles" "$BLUE_TSV.tmp.$$" && mv "$BLUE_TSV.tmp.$$" "$BLUE_TSV"
fi

# ---------------------------------------------------------------------------
# Step F — the BLUE recolor. For each of the 10 entity types, the enriched
# values (newfiles cols) that appear on NO REAL _files.tsv row are the
# server-log-only entities -> result = blue in base/*.tsv (add a row with an
# empty direction if the name is somehow absent from base; today every one is
# already configured). Mirrors the old data/fakes computation exactly (Fk-Rk).
# NON-subscription candidates carry one more guard: an entity whose OWN column
# never rides a real row can still be SEEN through its connected
# subscriptions (its column simply went unattributed on those files) — so a
# candidate is skipped when ANY subscription connected to it (the
# xref/_<item>-subscriptions.tsv pair cache) carries real transfer data
# (appears as a real row's site, = result.sh's green/red). Being blue must
# mean: nothing about this entity ever reached the transfer log.
# _files/newfiles cols: 3 account 12 sub 13 profile 14 login 15 host
#                       18 application 19 domain 20 partner.
# cmp-guarded per file so a no-op build leaves the mtimes alone.
# ---------------------------------------------------------------------------
recolor() {   # $1 = newfiles/_files entity column   $2 = base file basename
    # $3 = optional mode: "skipwhite" = ignore BLUE: whitelisted IP rows (the
    # _hosts pass — a whitelist address must never enter the hosts base);
    # "onlywhite" = ONLY those rows (the _white pass — the address itself).
    # $4 = the _<item>-subscriptions xref pair basename ("" = the
    # subscriptions pass itself: its own column decides).
    local col=$1 bf="$BASE/$2.tsv" mode="${3:-}" pair=/dev/null
    [ -f "$bf" ] || return 0
    [ -n "${4:-}" ] && [ -f "$XREF/$4.tsv" ] && pair="$XREF/$4.tsv"
    local extra="${5:-$tmp.noextra}"   # optional list of extra blue-candidate names (SSH-logon logins/accounts/IPs)
    # $6 = optional value map (the _logicals pass: FlowID -> Logical) —
    # candidate AND real-seen values resolve through it; an unmapped value
    # evidences nothing and is skipped.
    local pmapf="${6:-}"
    # The UC3 CLEAN-POLL greens (data/<env>/blue/_greenpoll.tsv, written by
    # bin/build/result.sh): subscriptions with no transfer row that result.sh
    # deliberately colours GREEN because the server log shows them polling
    # successfully. Marking them blue here only to have result.sh flip them
    # back rewrote this cache on EVERY build — and with it every report that
    # depends on the base colours (2026-08). result.sh still recomputes the
    # flip from live evidence each run, so this file only stops the churn; it
    # never decides a colour.
    local gpoll="$DATA/blue/_greenpoll.tsv"; [ -f "$gpoll" ] || gpoll="$tmp.noextra"
    awk -F'\t' -v OFS='\t' -v col="$col" -v mode="$mode" -v PMAPF="$pmapf" '
        BEGIN { if (PMAPF != "") { while ((getline pl9 < PMAPF) > 0) {
                    n9 = split(pl9, p9, "\t")
                    if (n9 >= 2 && p9[1] != "" && p9[2] != "") PM[toupper(p9[1])] = p9[2] }
                close(PMAPF) } }
        # any connected subscription with real transfer data -> the entity is
        # already seen through it, so it must not be marked blue
        function subseen(k,   n2, A, i2) {
            n2 = split(substr(xs[k], 2), A, SUBSEP)
            for (i2 = 1; i2 <= n2; i2++) if (A[i2] in sd) return 1
            return 0
        }
        FILENAME==ARGV[1] { if (mode == "skipwhite" && $11 == "BLUE: whitelisted IP") next
                            if (mode == "onlywhite" && $11 != "BLUE: whitelisted IP") next
                            v = $col
                            if (v != "" && PMAPF != "") v = ((toupper(v) in PM) ? PM[toupper(v)] : "")
                            if (v != "") { u=toupper(v); if (!(u in fk)) { fk[u]=v; ord[++nf]=u } } next }  # enriched (blue-candidate) values
        FILENAME==ARGV[2] { # the distinct real _files values ($tmp.fseen: col<TAB>UPPER value)
                            if ($1 == col) { v2 = $2
                                if (PMAPF != "") v2 = ((v2 in PM) ? toupper(PM[v2]) : "")
                                if (v2 != "") rk[v2]=1 }
                            if ($1 == 12)  sd[$2]=1
                            next }
        FILENAME==ARGV[3] { if ($1!="" && $2!="") xs[toupper($1)] = xs[toupper($1)] SUBSEP toupper($2); next }    # entity -> its configured subscriptions
        FILENAME==ARGV[4] { if ($1!="" && $1!="#") xf[toupper($1)]=1; next }
        FILENAME==ARGV[5] { if ($1!="") gpx[toupper($1)]=1; next }                                                # UC3 clean-poll greens: never blue here                                     # SSH-logon names (Step F0): exempt from the stale-blue RESET below — bin/build/result.sh owns their orange->blue flip, so seen-in-server-log.sh must not wipe it
        FILENAME==ARGV[6] { k=toupper($1)
            if ((k in fk) && !(k in rk) && !subseen(k) && !(k in gpx)) { inb[k]=1; nb++; print $1, $2, "blue" }
            else if ($3 == "blue" && !(k in xf)) print $1, $2, "unknown"   # STALE blue from a previous run (this run does not re-mark it, e.g. after a seed-rule change): reset so bin/build/result.sh assigns the computed color — without this, shrinking the seed set left ghost blues in the base caches. SSH-logon blues (k in xf) are KEPT: result.sh re-derives them.
            else print $0
            next }
        END {
            for (i=1;i<=nf;i++){ u=ord[i]; if (!(u in rk) && !(u in inb) && !subseen(u) && !(u in gpx)) { print fk[u], "", "blue"; nadd++ } }
            printf "recolor %s: %d blue%s\n", ARGV[6], nb+0, (nadd ? " (+" nadd " appended, not in base)" : "") | "cat 1>&2"
        }
    ' "$newfiles" "$tmp.fseen" "$pair" "$extra" "$gpoll" "$bf" > "$tmp.rc" \
        && { cmp -s "$tmp.rc" "$bf" || {
               # NAME-SET change (an appended discovered entity, not a mere
               # recolor): the server per-entity mention scan ran BEFORE this
               # step and does not know the new name — its detail page would
               # lose the server-log table on a from-scratch build. Drop the
               # rescan marker; bin/build.sh re-runs the server parse next,
               # which rescans exactly once (2026-08-15 fresh-build fix).
               if ! cmp -s <(cut -f1 "$bf" | LC_ALL=C sort -u) <(cut -f1 "$tmp.rc" | LC_ALL=C sort -u); then
                   : > "$DATA/server/cache/.rescan-mentions"
               fi
               cp "$tmp.rc" "$bf"; }; }
}
# ---------------------------------------------------------------------------
# Step F0 — SSH-logon evidence. The TM "[Ssh Default]" lines "Allowed user",
# "Disallowed user" and "... successfully authenticated over SSH ..." each name
# a login, its source IP and its account (@-stripped). The EXTRACTION lives in
# the unknown-* map-reduce since 2026-07 (bin/server/reports/
# unknown-entities.sh, run in Step A): it used to be a second, UNCONDITIONAL
# full pass over the multi-GB server parse cache on every build; the scan's
# workers now emit the same three name sets + evidence while reading the cache
# anyway, writing $UNK/logon-{logins,accounts,ips}.tsv (one name per line + a
# "#" sentinel, sorted) and logon-evidence.tsv (latest line per type+VALUE,
# merged into Step G below). bin/build/result.sh flips any of them whose base
# status is orange -> blue (server-log-seen, never in the transfer log). Here
# they are passed to recolor ONLY so its stale-blue RESET leaves those blues
# alone across rebuilds — result.sh owns the orange->blue decision (it is the
# step that knows the final orange), so seen-in-server-log.sh (build step) never marks them itself.
# An env whose scan never ran (no server inputs) gets sentinel-only
# placeholders so recolor and result.sh read a stable shape.
# ---------------------------------------------------------------------------
printf '#\n' > "$tmp.noextra"
mkdir -p "$UNK"
lg_logins="$UNK/logon-logins.tsv"; lg_accounts="$UNK/logon-accounts.tsv"; lg_ips="$UNK/logon-ips.tsv"
for _lf in "$lg_logins" "$lg_accounts" "$lg_ips"; do
    [ -f "$_lf" ] || printf '#\n' > "$_lf"
done

recolor 3  _accounts       ''          _accounts-subscriptions   "$lg_accounts"
recolor 12 _subscriptions
recolor 14 _logins         ''          _logins-subscriptions     "$lg_logins"
recolor 15 _hosts          skipwhite   _hosts-subscriptions
recolor 15 _white          onlywhite   _white-subscriptions      "$lg_ips"
recolor 13 _logicals       ''          _logicals-subscriptions   '' "$XREF/_profiles-logicals.tsv"
recolor 12 _bl             ''          _bl-subscriptions         '' "$XREF/_subscriptions-bl.tsv"
recolor 18 _apps           ''          _apps-subscriptions
recolor 19 _domains        ''          _domains-subscriptions
recolor 20 _partners       ''          _partners-subscriptions
echo "seen-in-server-log.sh: $n_blue server-log-only entity tuple(s) ($((n_cand - n_blue)) duplicate(s) collapsed); base/*.tsv recolored blue." >&2

# ---------------------------------------------------------------------------
# Step G — consolidate the blue-evidence map to the LATEST server-log line per
# (type, value). bin/build/result.sh (runs next, once the FINAL blue set is known —
# incl. its own orange->blue SSH-logon flips) reads this to write the per-entity
# data/<env>/blue/<type>/<name>.txt files.
# Inputs: Step B's candidate evidence ($tmp.evid) + the scan's
# logon-evidence.tsv (the merged Step F0 lines, already latest-per-key with
# the same comparator, so the combined extremum below is unchanged).
# ---------------------------------------------------------------------------
BLUEDIR="$DATA/blue"
mkdir -p "$BLUEDIR"
if [ -f "$UNK/logon-evidence.tsv" ]; then cat "$UNK/logon-evidence.tsv" >> "$tmp.evid"; fi
if [ -s "$tmp.evid" ]; then
    LC_ALL=C sort -t"$(printf '\t')" -k1,1 -k2,2 -k3,3r "$tmp.evid" \
        | awk -F'\t' '!seen[$1,$2]++' > "$BLUEDIR/_evidence.tsv.tmp.$$" \
        && mv "$BLUEDIR/_evidence.tsv.tmp.$$" "$BLUEDIR/_evidence.tsv"
else
    : > "$BLUEDIR/_evidence.tsv"
fi
