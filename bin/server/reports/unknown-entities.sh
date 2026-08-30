#!/usr/bin/env bash
#
# unknown-entities.sh — ALL FIVE unknown-* reports from ONE map-reduce scan of
# the server parse cache (2026-07: merged from unknown-{sites,accounts,hosts,
# logins,whitelisting}.sh — each was an independent full scan of the multi-GB
# cache; the extraction rules are unchanged and the outputs are byte-identical
# apart from the FOOT timestamp and the documented @data:buckets entry-order
# variance). Like cross-reference.sh, one script -> several .rpt files:
#
#   unknown-sites.rpt         subscription names (UC…) in TM messages, absent
#                             from the transfer logs (prefix-matched: the
#                             server truncates long names)
#   unknown-accounts.rpt      account "NAME" mentions (@login stripped), exact
#   unknown-logins.rpt        login name "NAME" mentions, exact
#   unknown-hosts.rpt         CONFIGURED outbound endpoints (base/_hosts.tsv)
#                             in TM messages, never a transfer remote host
#   unknown-whitelisting.rpt  WHITELISTED partner IPs (base/_white.tsv) in ANY
#                             component's messages, never a transfer remote
#                             host (raw IPs of resolved hostnames included)
#
# plus the five data/unknown/ sidecars (the blue-marking seed lists; white.tsv
# takes only TM-mentioned IPs) and the four SSH-LOGON files
# logon-{logins,accounts,ips}.tsv + logon-evidence.tsv (2026-07: the former
# Step F0 of bin/build/seen-in-server-log.sh — a second, UNCONDITIONAL full
# pass over the same cache — extracted here by the same map workers, so the
# cache is read once per rebuild and not at all on a fresh skip; consumers
# are bin/build/result.sh (orange->blue flips), seen-in-server-log.sh's
# recolor exemption and its Step G evidence merge).
#
# MAP-REDUCE (the bin/server/parse.sh pattern): the extraction work is CPU,
# not I/O (a bare mawk read+field-split of the 2.4 GB cache is ~2 s; the five
# extraction rule sets are ~28 s of regex/tokenize work), so NW workers each
# scan the cache gated on FNR % NW == ID — a skipped line costs only the read,
# mawk splits fields lazily — and dump their LOCAL aggregates (per-name
# counts, per-name-per-day counts, latest-mention candidates, the bounded
# logline rings) as small tagged files. ONE merge pass then sums the counts,
# max-picks the latest mentions, re-inserts the ring entries through addline
# (the global top-10 is a subset of the per-worker top-10s), loads the known
# sets from ONE read of the transfer cache, and writes the five .rpt files +
# sidecars. Aggregation is exact: counts add, maxima commute, and addline
# inserts by (timestamp, message) key regardless of arrival order.
#
# Usage:
#   ./unknown-entities.sh    # reads input/*.csv (via the caches) + transfer _transfers.tsv
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib.sh"
source "$ROOT/bin/blacklist.sh"   # BLACKLIST_FILE + BLACKLIST_AWK — the ONE blacklist (input/blacklist.txt)
source "$ROOT/bin/renames.sh"    # RENAMES_FILE + RENAMES_AWK — fold a logged name to its CURRENT one
mkdir -p "$REPORTS_DIR" "$UNKNOWN_DIR"

TCACHE="$TRANSFER_CACHE/_transfers.tsv"      # authoritative per-row entity lists (transfer parse cache)
CFG_HOSTS="$CONFIG_BASE/_hosts.tsv"          # configured outbound endpoints (partners.json host fields)
CFG_WHITE="$CONFIG_BASE/_white.tsv"          # whitelisted partner IPs (partners.json AllowIPxx fields)
HOSTS_CACHE="$IP_HOSTS_FILE"                 # the automatic ip -> endpoint map (bin/ip.sh)

shopt -s nullglob
files=("$INPUT_DIR"/*.csv)
shopt -u nullglob
# freshness dep: a changed name must force a rebuild. ONE file since 2026-07 —
# it used to be the whole per-<ip>.txt tree (4,241 entries), so the monthly
# whitelist re-resolution sweep bumped thousands of mtimes and forced this
# full map-reduce rescan of the 3 GB parse cache in both envs, for names that
# can never change the answer (see the known.map rule below).
host_deps=()
[ -f "$IP_HOSTS_FILE" ] && host_deps=("$IP_HOSTS_FILE")
if [ ${#files[@]} -eq 0 ]; then
    echo "No files matching '*.csv' found in '$INPUT_DIR'" >&2
    rm -f "$REPORTS_DIR"/unknown-{sites,accounts,logins,hosts,whitelisting}.rpt
    exit 0
fi
ensure_parsed
if [ ! -f "$TCACHE" ]; then
    echo "Transfer parse cache not found: $TCACHE — run bin/transfer/parse.sh first." >&2
    exit 1
fi
[ -f "$CFG_HOSTS" ] || echo "No configured host list ($CFG_HOSTS) — unknown-hosts will be empty." >&2
[ -f "$CFG_WHITE" ] || echo "No whitelist ($CFG_WHITE) — unknown-whitelisting will be empty." >&2

# The two base caches are a freshness dep, but NOT directly: this scan reads
# only their column 1 (the NAME lists — see the cfg[]/white[] rules below), and
# bin/build/result.sh REWRITES base/*.tsv's result column (col 3) after this
# report has already run once per build (bin/build/seen-in-server-log.sh runs
# us in stage 1, bin/server/reports.sh again in stage 2). Depending on the
# files themselves therefore re-ran the whole map-reduce over the server cache
# on every build for a change we never read. Depend instead on a projection of
# just the name columns, and rebuild only when a name is actually added or
# removed. (Same idea as bin/build/expire-files.sh's cmp guard, and the reason
# bin/transfer/lib.sh watches xref/ but not base/.)
# The comparison is by CONTENT, not by mtime: bash 3.2's `-nt` compares whole
# SECONDS, so a dep rewritten in the same second as an output reads as "not
# newer" and the stale output survives. The stored projection is replaced only
# AFTER a successful rebuild (bottom of this script), so an aborted run cannot
# leave the names recorded as up to date while the outputs are stale.
NAMES_DEP="$CACHE_DIR/.config-names.tsv"
mkdir -p "$CACHE_DIR"
NAMES_NEW="$NAMES_DEP.new"
: > "$NAMES_NEW"
if [ -f "$CFG_HOSTS" ]; then cut -f1 "$CFG_HOSTS" >> "$NAMES_NEW"; fi
if [ -f "$CFG_WHITE" ]; then cut -f1 "$CFG_WHITE" >> "$NAMES_NEW"; fi
LC_ALL=C sort -u "$NAMES_NEW" -o "$NAMES_NEW"
names_changed=0
cmp -s "$NAMES_NEW" "$NAMES_DEP" || names_changed=1

# Freshness: ONE scan feeds all five outputs, so skip only when EVERY .rpt and
# sidecar is fresh against the shared dep set (skip_if_fresh exits on the
# first fresh output, so the multi-output check is inlined here; the rules
# mirror skip_if_fresh — script/lib/parse/PARSED plus the extra deps).
all_fresh=1
[ "$names_changed" = 0 ] || all_fresh=0     # a configured name came or went
for out in "$REPORTS_DIR"/unknown-{sites,accounts,logins,hosts,whitelisting}.rpt \
           "$UNKNOWN_DIR"/{sites,accounts,logins,hosts,white}.tsv \
           "$UNKNOWN_DIR"/logon-{logins,accounts,ips,evidence}.tsv; do
    [ "$all_fresh" = 1 ] || break
    [ -f "$out" ] || { all_fresh=0; break; }
    # bin/renames.sh and the MAP decide which logged name a token is folded to
    # before the known-set test, so either one changing changes every output
    # here — they are deps exactly like this script and the parse cache.
    if [ "${BASH_SOURCE[0]}" -nt "$out" ] || [ "$LIB_DIR/lib.sh" -nt "$out" ] \
       || [ "$LIB_DIR/parse.sh" -nt "$out" ] \
       || [ "$ROOT/bin/renames.sh" -nt "$out" ] \
       || { [ -f "$RENAMES_FILE" ] && [ "$RENAMES_FILE" -nt "$out" ]; } \
       || { [ -f "$PARSED" ] && [ "$PARSED" -nt "$out" ]; }; then
        all_fresh=0; break
    fi
    for dep in "$TCACHE" ${host_deps[@]+"${host_deps[@]}"}; do
        if [ -f "$dep" ] && [ "$dep" -nt "$out" ]; then all_fresh=0; break 2; fi
    done
done
if [ "$all_fresh" = 1 ]; then
    rm -f "$NAMES_NEW"
    echo "  unknown-* reports are up to date; skipping." >&2
    exit 0
fi
echo "Found ${#files[@]} file(s) in '$INPUT_DIR', processing..." >&2

TMPD=$(mktemp -d "${TMPDIR:-/tmp}/unkent.XXXXXX")
trap 'rm -rf "$TMPD"' EXIT

# The reverse-DNS cache map for the whitelisting known set: "M ip name" per
# cached entry (an IP is known when its cached NAME appears as a transfer
# host — the out-side substitution replaced the IP by the name). Mere cache
# existence does NOT count: details.sh pre-resolves every whitelisted IP, so
# that old rule pinned the report at permanent zero.
# One read of the cache file. This used to be a bash loop forking a subshell
# (basename) + a pipeline (tr) PER FILE — ~20 s of pure fork cost at 4,000+
# cached addresses, paid by EVERY rescan in EVERY env (it was most of the "why
# is the production scan slow with 375 records" mystery) — then one awk over the
# same 4,000-file glob. Same output: "M <ip> <lowercased name>", empty skipped.
if [ -f "$IP_HOSTS_FILE" ]; then
    awk -F'\t' '$1 != "" && $2 != "" { print "M\t" $1 "\t" tolower($2) }' "$IP_HOSTS_FILE" > "$TMPD/known.map"
else
    : > "$TMPD/known.map"
fi

cfg_hosts_in="$CFG_HOSTS"; [ -f "$cfg_hosts_in" ] || cfg_hosts_in=/dev/null
cfg_white_in="$CFG_WHITE"; [ -f "$cfg_white_in" ] || cfg_white_in=/dev/null

# ---- MAP: NW workers, each scanning its FNR-slice of the parse cache --------
# Extraction rules are copied VERBATIM from the five former scripts; all state
# is namespaced "T SUBSEP name" (T = S sites / A accounts / L logins / H hosts
# / W whitelisted IPs). A worker dumps its local aggregates tagged:
#   C t name count                    per-name mention count
#   D t name date count               per-name-per-day count (the buckets)
#   K t name sk sid msg               latest-mention candidate (max-picked in
#                                     the merge; sk = "date time")
#   T ip sk sid msg                   whitelist: latest TM-mention candidate
#   R t name sk logline               bounded logline-ring entries (<=10/name)
#   G t name                          SSH-logon name (t = L login / A account /
#                                     I source IP), raw spelling
#   E type VALUE sk msg               SSH-logon evidence, latest per (type,
#                                     VALUE) in this slice (type = the blue
#                                     evidence vocabulary login / account /
#                                     whitelisted-ip; VALUE uppercased for
#                                     login and account, the raw IP otherwise)
NW=$( (command -v sysctl >/dev/null 2>&1 && sysctl -n hw.ncpu) 2>/dev/null || echo 4 )
[ "$NW" -ge 1 ] 2>/dev/null || NW=4
[ "$NW" -gt 6 ] && NW=6
wpids=()
for ((id = 0; id < NW; id++)); do
    awk -F'\t' -v NW="$NW" -v ID="$id" -v RNF="$RENAMES_FILE" "$LOGLINES_AWK$RENAMES_AWK"'
        function grabq(m, key,   s3, c3, r3) {   # value inside the quote pair after `key ` (both '\''...'\'' and "..." forms) — the former Step F0 extractor, verbatim
            if (match(m, key " ['\''\"]")) {
                c3 = substr(m, RSTART + RLENGTH - 1, 1); s3 = substr(m, RSTART + RLENGTH)
                r3 = index(s3, c3); if (r3 > 0) return substr(s3, 1, r3 - 1)
            }
            return ""
        }
        function evput(k, sk3, msg) {   # latest evidence per (type, VALUE); ties broken on the SMALLER message — the exact winner of Step G'\''s `sort -k1,1 -k2,2 -k3,3r` + first-per-key
            if (!(k in gsk) || sk3 > gsk[k] || (sk3 == gsk[k] && msg < gmsg[k])) { gsk[k] = sk3; gmsg[k] = msg }
        }
        BEGIN { rn_load(RNF) }
        FILENAME ~ /_hosts\.tsv$/  { if ($1 != "") cfg[tolower($1)] = $1; next }   # config spelling, matched lowercase
        FILENAME ~ /_white\.tsv$/  { if ($1 != "") white[$1] = 1; next }
        FNR % NW != ID { next }                      # this worker'\''s slice only
        {
            d = substr($1, 1, 10)
            sk = $1 " " $2
            delete mseen                             # one log line per entity per record (all types)
            # W: whitelisted partner IPs — ALL components (the report counts
            # every mention; only the TM sighting feeds the sidecar/blue seed)
            if ($5 ~ /[0-9]\.[0-9]/) {
                s = $5
                while (match(s, /[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/)) {
                    ip = substr(s, RSTART, RLENGTH)
                    s = substr(s, RSTART + RLENGTH)
                    if (ip in white) {
                        k = "W" SUBSEP ip
                        cnt[k]++; cd[k SUBSEP d]++
                        if (sk > lsk[k]) { lsk[k] = sk; lmsg[k] = $5 }
                        if ($4 == "T" && sk > lskT[ip]) { lskT[ip] = sk; lmsgT[ip] = $5 }
                        if (!(k in mseen)) { mseen[k] = 1; addline(k, sk, lvlname($3) " " compname($4) "  " substr($5, 1, 200)) }
                    }
                }
            }
            # G/E: SSH-logon evidence (the former bin/build/seen-in-server-log.sh
            # Step F0, merged here 2026-07 so the cache is read once, not twice).
            # ANY component, like the standalone pass (the matching lines are in
            # practice the TM "[Ssh Default]" logon-screening messages).
            if ($5 ~ /Allowed user|Disallowed user|successfully authenticated over SSH/) {
                m0 = $5
                lg0 = grabq(m0, "user"); if (lg0 == "") lg0 = grabq(m0, "login name")
                ac0 = grabq(m0, "account"); sub(/@.*/, "", ac0)
                ip0 = grabq(m0, "from address")
                if (ip0 == "" && match(m0, /Remote address: [0-9.]+/)) { ip0 = substr(m0, RSTART + 16, RLENGTH - 16); sub(/\.$/, "", ip0) }
                if (lg0 != "") { gset["L" SUBSEP lg0] = 1; evput("login" SUBSEP toupper(lg0), sk, $5) }
                if (ac0 != "") { gset["A" SUBSEP ac0] = 1; evput("account" SUBSEP toupper(ac0), sk, $5) }
                if (ip0 != "") { gset["I" SUBSEP ip0] = 1; evput("whitelisted-ip" SUBSEP ip0, sk, $5) }
            }
            if ($4 != "T") next                      # S/A/L/H: TM (Transfer Manager) messages only
            # S: UC<n>_ subscription tokens
            if ($5 ~ /UC[0-9]+_/) {
                s = $5
                while (match(s, /UC[0-9]+_[A-Za-z0-9_-]+/)) {    # hyphens are part of UC4/UC2 names
                    tk = substr(s, RSTART, RLENGTH)
                    sub(/_(SS?|C)CP_.*$/, "", tk)                                        # canonical subscription name (drop the _SCP_ / _SSCP_ / _CCP_ tail)
                    p14 = index(tk, "_P14303_CFT01"); if (p14 > 0) tk = substr(tk, 1, p14 - 1)   # composite <site>_P14303_CFT01[_flow] identifiers
                    # RENAMES: a server line keeps the name that was current
                    # when it was written. Fold it here, where the token is
                    # formed, so the counts aggregate under the CURRENT name and
                    # the known-set test below compares like with like — without
                    # this, every renamed flow reads as an unknown subscription
                    # and bin/build/seen-in-server-log.sh appends it as a second,
                    # blue entity beside the real one (2026-08).
                    # rn_canon_pfx, not rn_canon: the server truncates names,
                    # so a renamed flow arrives as a PREFIX of its old name.
                    tk = rn_canon_pfx(tk)
                    k = "S" SUBSEP tk
                    cnt[k]++; cd[k SUBSEP d]++
                    if (sk > lsk[k]) { lsk[k] = sk; lmsg[k] = $5 }
                    if (!(k in mseen)) { mseen[k] = 1; addline(k, sk, lvlname($3) " " compname($4) "  " substr($5, 1, 200)) }
                    s = substr(s, RSTART + RLENGTH)
                }
            }
            # A: account "NAME" mentions (@login suffix stripped)
            if ($5 ~ /account "/) {
                s = $5
                while (match(s, /account "[^"]+"/)) {
                    m = substr(s, RSTART, RLENGTH)
                    sub(/^account "/, "", m); sub(/"$/, "", m); sub(/@.*/, "", m)
                    if (m != "") {
                        k = "A" SUBSEP m
                        cnt[k]++; cd[k SUBSEP d]++
                        if (sk > lsk[k]) { lsk[k] = sk; lmsg[k] = $5 }
                        if (!(k in mseen)) { mseen[k] = 1; addline(k, sk, lvlname($3) " " compname($4) "  " substr($5, 1, 200)) }
                    }
                    s = substr(s, RSTART + RLENGTH)
                }
            }
            # L: login name "NAME" mentions
            if ($5 ~ /login name "[^"]/) {
                s = $5
                while (match(s, /login name "[^"]+"/)) {
                    m = substr(s, RSTART, RLENGTH)
                    sub(/^login name "/, "", m); sub(/"$/, "", m)
                    if (m != "") {
                        k = "L" SUBSEP m
                        cnt[k]++; cd[k SUBSEP d]++
                        if (sk > lsk[k]) { lsk[k] = sk; lmsg[k] = $5 }
                        if (!(k in mseen)) { mseen[k] = 1; addline(k, sk, lvlname($3) " " compname($4) "  " substr($5, 1, 200)) }
                    }
                    s = substr(s, RSTART + RLENGTH)
                }
            }
            # H: configured endpoint tokens (dots kept so hostnames/IPs stay
            # one token; stray sentence dots trimmed — parse.sh'\''s entity scan)
            if ($5 ~ /[A-Za-z0-9][._-]/) {
                s2 = tolower($5)
                n = split(s2, tok, /[^a-z0-9._-]+/)
                for (i = 1; i <= n; i++) {
                    w = tok[i]; gsub(/^\.+|\.+$/, "", w)
                    if (w == "" || !(w in cfg)) continue
                    k = "H" SUBSEP cfg[w]            # attribute under the config spelling
                    cnt[k]++; cd[k SUBSEP d]++
                    if (sk > lsk[k]) { lsk[k] = sk; lmsg[k] = $5 }
                    if (!(k in mseen)) { mseen[k] = 1; addline(k, sk, lvlname($3) " " compname($4) "  " substr($5, 1, 200)) }
                }
            }
        }
        END {
            for (k in cnt) { split(k, kp, SUBSEP)
                print "C\t" kp[1] "\t" kp[2] "\t" cnt[k]
                print "K\t" kp[1] "\t" kp[2] "\t" lsk[k] "\t" lmsg[k]
                nl = (k in ltop) ? split(ltop[k], le, _US) : 0
                for (i = 1; i <= nl; i++) { split(le[i], lf, SUBSEP)
                    print "R\t" kp[1] "\t" kp[2] "\t" lf[1] "\t" lf[2] } }
            for (k in cd) { nd = split(k, kp, SUBSEP)
                print "D\t" kp[1] "\t" kp[2] "\t" kp[3] "\t" cd[k] }
            for (ip in lskT) print "T\t" ip "\t" lskT[ip] "\t" lmsgT[ip]
            for (k in gset) { split(k, kp, SUBSEP); print "G\t" kp[1] "\t" kp[2] }
            for (k in gsk)  { split(k, kp, SUBSEP); print "E\t" kp[1] "\t" kp[2] "\t" gsk[k] "\t" gmsg[k] }
        }
    ' "$cfg_hosts_in" "$cfg_white_in" "$PARSED" > "$TMPD/part.$id" &
    wpids+=("$!")
done
for p in "${wpids[@]}"; do wait "$p"; done

# ---- REDUCE: merge the worker aggregates, filter against the known sets -----
SIDE_S="$UNKNOWN_DIR/sites.tsv"; SIDE_A="$UNKNOWN_DIR/accounts.tsv"
SIDE_L="$UNKNOWN_DIR/logins.tsv"; SIDE_H="$UNKNOWN_DIR/hosts.tsv"
SIDE_W="$UNKNOWN_DIR/white.tsv"
rm -f "$SIDE_S" "$SIDE_A" "$SIDE_L" "$SIDE_H" "$SIDE_W"   # every run first deletes the sidecars
# the SSH-logon outputs (the merged Step F0). The raw temps are pre-created so
# the post-reduce writers below always see a file, logons in the window or not.
LOGON_L="$UNKNOWN_DIR/logon-logins.tsv"; LOGON_A="$UNKNOWN_DIR/logon-accounts.tsv"
LOGON_I="$UNKNOWN_DIR/logon-ips.tsv";    LOGON_E="$UNKNOWN_DIR/logon-evidence.tsv"
: > "$TMPD/logon.raw"; : > "$TMPD/evid.raw"
agg=$(awk -F'\t' -v side_s="$SIDE_S" -v side_a="$SIDE_A" -v side_l="$SIDE_L" \
        -v side_h="$SIDE_H" -v side_w="$SIDE_W" -v BLF="$BLACKLIST_FILE" \
        -v logon_raw="$TMPD/logon.raw" -v evid_raw="$TMPD/evid.raw" \
        "$LOGLINES_AWK$BLACKLIST_AWK"'
    # Seeded from input/blacklist.txt via bin/blacklist.sh — the same file
    # bin/transfer/parse.sh blanks with. Values the parse BLANKS can never
    # enter the cache-built known sets, yet server messages name them
    # constantly, so they are seeded as known here.
    BEGIN { bl_load(BLF)
            for (blk in BL_DROP) { split(blk, blf_, SUBSEP)
                if (blf_[1] == "account") aknown[blf_[2]] = 1
                else if (blf_[1] == "login") lknown[blf_[2]] = 1 } }
    FILENAME ~ /known\.map$/ { if ($1 == "M") mip[$2] = $3; next }             # ip -> cached reverse-DNS name
    FILENAME ~ /_transfers\.tsv$/ {                  # ONE read fills all five known sets
        # ^UC — the SAME expression bin/transfer/parse.sh blanks sites with
        # (site !~ /^UC/), not a narrower one: a UC-prefixed name that is not
        # UC<digits>_ survives the parse, so registering it here too keeps it
        # out of the unknown list. col 6 is already the clean pre-_SCP_ name.
        if ($6 != "" && !bl_blank("site", $6)) { sknown[$6] = 1; sbase[$6] = 1 }
        if ($4 != "") aknown[$4] = 1                 # col 4 accounts (@-stripped by the parse)
        if ($5 != "") lknown[$5] = 1                 # col 5 logins
        if ($16 != "") { hknown[tolower($16)] = 1; wH[$16] = 1 }   # col 16 remote hosts (lowercase / raw)
        next }
    # worker aggregate lines
    $1 == "C" { k = $2 SUBSEP $3; cnt[k] += $4; next }
    $1 == "D" { k = $2 SUBSEP $3; cd[k SUBSEP $4] += $5; next }
    $1 == "K" { k = $2 SUBSEP $3; if ($4 > lsk[k]) { lsk[k] = $4; lmsg[k] = $5 }; next }
    $1 == "T" { if ($3 > lskT[$2]) { lskT[$2] = $3; lmsgT[$2] = $4 }; tmm[$2] = 1; next }
    $1 == "R" { addline($2 SUBSEP $3, $4, $5); next }
    $1 == "G" { print $2 "\t" $3 > logon_raw; next }              # SSH-logon names (dups across workers fold in the sort -u below)
    $1 == "E" { k = $2 SUBSEP $3                                  # SSH-logon evidence: same max-pick as the workers (latest sk, then smallest message)
                if (!(k in gsk) || $4 > gsk[k] || ($4 == gsk[k] && $5 < gmsg[k])) { gsk[k] = $4; gmsg[k] = $5 }
                next }
    # an IP is known when it appears as a transfer host itself, or when its
    # cached reverse-DNS name does (the parse substituted the name for it)
    function wknown(ip2) { return (ip2 in wH) || ((ip2 in mip) && (mip[ip2] in hknown)) }
    END {
        for (k in cd) { p = k; sub(SUBSEP "[^" SUBSEP "]*$", "", p)   # strip the trailing date
            nd = split(k, kp, SUBSEP)
            bk[p] = bk[p] (bk[p] ? "," : "") kp[nd] ":" cd[k] }
        for (k in cnt) {
            split(k, kp, SUBSEP); t = kp[1]; nm = kp[2]
            unknown = 0
            if (t == "S") {
                found = 0
                for (kk in sknown) { if (index(kk, nm) == 1) { found = 1; break } }          # server truncated the name
                if (!found) for (b in sbase) {                                               # token overran the name (joined identifier)
                    if (index(nm, b) == 1 && (length(nm) == length(b) || substr(nm, length(b) + 1, 1) ~ /[_-]/)) { found = 1; break } }
                unknown = !found
            }
            else if (t == "A") unknown = !(nm in aknown)
            else if (t == "L") unknown = !(nm in lknown)
            else if (t == "H") unknown = !(tolower(nm) in hknown)
            else if (t == "W") unknown = !wknown(nm)
            if (!unknown) continue
            un[t]++; um[t] += cnt[k]              # the per-type row count + mention sum (the TOT lines below)
            printf "%s\t%d\t%s\t%s\t%s\n", t, cnt[k], bk[k], nm, lastlines(k)
            if      (t == "S") print nm "\t" lsk[k] "\t" lmsg[k] > side_s
            else if (t == "A") print nm "\t" lsk[k] "\t" lmsg[k] > side_a
            else if (t == "L") print nm "\t" lsk[k] "\t" lmsg[k] > side_l
            else if (t == "H") print nm "\t" lsk[k] "\t" lmsg[k] > side_h
            # the WHITE sidecar (the blue-marking seed list) takes only IPs
            # with a TRANSFER MANAGER mention, dated/quoted by their latest TM
            # line — an ADMIN/AUDIT config-dump quote is not a partner connecting
            else if (t == "W" && (nm in tmm)) print nm "\t" lskT[nm] "\t" lmsgT[nm] > side_w
        }
        for (k in gsk) { split(k, kp, SUBSEP); print kp[1] "\t" kp[2] "\t" gsk[k] "\t" gmsg[k] > evid_raw }   # SSH-logon evidence (order fixed by the sort below)
        # per-type totals for the five page headers, in a FIXED order (never a
        # for-in): each was a grep -c + an awk fork per report down in the shell
        ntg = split("S A L H W", TG, " ")
        for (i = 1; i <= ntg; i++) printf "TOT\t%s\t%d\t%d\n", TG[i], un[TG[i]]+0, um[TG[i]]+0
    }
' "$TMPD/known.map" "$TCACHE" "$TMPD"/part.*)
# for-in emits in hash order; the sidecars are data files, so sort them (name-sorted)
# a type with NO unknowns keeps an EMPTY sidecar: the all-outputs freshness
# check above treats a missing one as "rebuild", so deleting a zero-row
# sidecar made every build redo the whole scan (and its fresh rpts cascaded
# into incoming-connections + showseen) in an env with nothing unknown
for sc in "$SIDE_S" "$SIDE_A" "$SIDE_L" "$SIDE_H" "$SIDE_W"; do
    if [ -f "$sc" ]; then LC_ALL=C sort -o "$sc" "$sc"; else : > "$sc"; fi
done

# The SSH-logon files, in the former Step F0's exact shape: one name per line
# behind a "#" sentinel (never-empty, so downstream awk file routing stays
# safe), C-collation sorted, dups folded. Rewritten every scan like the five
# sidecars above — NOT cmp-guarded: these are all-outputs freshness members,
# and a kept old mtime would read as stale against a newer parse cache,
# forcing the whole scan every build. The evidence file is the latest line
# per (type, VALUE), whole-line sorted for determinism; seen-in-server-log.sh
# Step G merges it with its own candidate evidence.
for _lp in "L:$LOGON_L" "A:$LOGON_A" "I:$LOGON_I"; do
    _lt=${_lp%%:*}; _lf=${_lp##*:}
    { printf '#\n'; awk -F'\t' -v T="$_lt" '$1 == T { print $2 }' "$TMPD/logon.raw" | LC_ALL=C sort -u; } > "$_lf"
done
LC_ALL=C sort "$TMPD/evid.raw" > "$LOGON_E"

# The five per-type row counts and mention sums, from the agg's TOT lines (bash
# 3.2 has no associative arrays, so flat variables).
n_S=0; n_A=0; n_L=0; n_H=0; n_W=0
m_S=0; m_A=0; m_L=0; m_H=0; m_W=0
while IFS=$'\t' read -r _ t nn mm; do
    case $t in
        S) n_S=$nn; m_S=$mm ;;
        A) n_A=$nn; m_A=$mm ;;
        L) n_L=$nn; m_L=$mm ;;
        H) n_H=$nn; m_H=$mm ;;
        W) n_W=$nn; m_W=$mm ;;
    esac
done <<< "$(printf '%s\n' "$agg" | grep $'^TOT\t')"

# This type's ROW lines, count desc then name — printed STRAIGHT to stdout
# inside the page block below, where a `rows+=$(printf …)` per row forked a
# subshell per row for nothing.
unknown_rows() {   # $1 = tag
    local count bucket name lines
    while IFS=$'\t' read -r count bucket name lines; do
        [ -z "$name" ] && continue
        printf 'ROW\t%s\t%s\t@data:buckets=%s\t@data:loglines=%s\n' "$name" "$count" "$bucket" "$lines"
    done <<< "$(printf '%s\n' "$agg" | awk -F'\t' -v t="$1" '$1 == t { sub(/^[^\t]*\t/, ""); print }' \
                | sort -t"$(printf '\t')" -k1,1nr -k3,3)"
}

# One .rpt per type from the tagged agg lines — the page texts are verbatim
# from the five former single-scan scripts.
write_unknown_rpt() {   # $1 tag  $2 basename  $3 unit label ("subscription"…)
    local tag=$1 base=$2 unit=$3 n mentions
    case $tag in
        S) n=$n_S; mentions=$m_S ;;
        A) n=$n_A; mentions=$m_A ;;
        L) n=$n_L; mentions=$m_L ;;
        H) n=$n_H; mentions=$m_H ;;
        W) n=$n_W; mentions=$m_W ;;
    esac
    {
        case $tag in
        S)  printf 'TITLE\tSubscriptions Missing from Transfer Logs\n'
            printf 'DESC\tSubscription names (UC…) referenced in server-log messages but absent from the transfer logs.\n'
            printf 'INTRO\t**%s** subscription names appear in server-log messages (Transfer Manager log lines only) but never in the transfer logs (checked against every transfer row'"'"'s subscription in the parse cache). These are subscriptions the server touched — typically failed connections — that produced no transfer. Server messages may truncate long names, so a name counts as known when it is a prefix of a real subscription.\n' "$n"
            printf 'TABLE\tSubscriptions in server logs, not in transfer logs\twide\n'
            printf 'HEAD\tSubscription (as logged by the server)\tServer-log mentions\n' ;;
        A)  printf 'TITLE\tAccounts Missing from Transfer Logs\n'
            printf 'DESC\tAccount names referenced in server-log messages but absent from the transfer logs.\n'
            printf 'INTRO\t**%s** account names appear in server-log messages (Transfer Manager log lines only, as `associated with account "…"`) but never in the transfer logs (checked against every transfer row'"'"'s account in the parse cache). These are accounts that connected to the server but produced no transfer. Any @login suffix is stripped to match the transfer account format.\n' "$n"
            printf 'TABLE\tAccounts in server logs, not in transfer logs\n'
            printf 'HEAD\tAccount (as logged by the server)\tServer-log mentions\n' ;;
        L)  printf 'TITLE\tLogins Missing from Transfer Logs\n'
            printf 'DESC\tLogin names referenced in server-log messages but absent from the transfer logs.\n'
            printf 'INTRO\t**%s** login names appear in server-log messages (Transfer Manager log lines only, as `login name "…"`) but never in the transfer logs (checked against every transfer row'"'"'s login in the parse cache). These are logins that authenticated to the server but produced no transfer.\n' "$n"
            printf 'TABLE\tLogins in server logs, not in transfer logs\n'
            printf 'HEAD\tLogin (as logged by the server)\tServer-log mentions\n' ;;
        H)  printf 'TITLE\tOutbound Hosts Missing from Transfer Logs\n'
            printf 'DESC\tConfigured outbound endpoints (the partners.json host fields) referenced in server-log messages but absent from the transfer logs.\n'
            printf 'INTRO\t**%s** configured outbound hosts appear in server-log messages (Transfer Manager log lines only) but never as a remote host in the transfer logs (checked against every transfer row'"'"'s remote host in the parse cache). These are endpoints the server tried to reach — typically failed connections — that never produced a transfer. Incoming partner addresses are the **Missing whitelist IPs** report.\n' "$n"
            printf 'TABLE\tConfigured hosts in server logs, not in transfer logs\n'
            printf 'HEAD\tHost (as configured)\tServer-log mentions\n' ;;
        W)  printf 'TITLE\tWhitelisted IPs Missing from Transfer Logs\n'
            printf 'DESC\tWhitelisted partner addresses (the partners.json AllowIP fields) referenced in server-log messages but absent from the transfer logs.\n'
            printf 'INTRO\t**%s** whitelisted partner IPs appear in server-log messages (any component) but never as a remote host in the transfer logs (checked against every transfer row'"'"'s remote host in the parse cache, raw IPs of resolved hostnames included). These are addresses a partner is allowed to connect from that connected — or tried to — without ever producing a transfer. Outgoing endpoints are the **Missing hosts** report.\n' "$n"
            printf 'TABLE\tWhitelisted IPs in server logs, not in transfer logs\n'
            printf 'HEAD\tIP address (whitelisted)\tServer-log mentions\n' ;;
        esac
        printf 'KIND\tmono\tnum\n'
        printf 'RECALC\t-\ts0\n'
        unknown_rows "$tag"
        printf 'TOTAL\tTotal (%s %s(s))\t@{class=num}%s\n' "$n" "$unit" "$mentions"
        printf 'NOTE\tClick a row to expand its 10 most recent server-log lines.\n'
        printf 'FOOT\tGenerated on %s from %s file(s)\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${#files[@]}"
    } > "$REPORTS_DIR/$base.rpt.tmp" && mv "$REPORTS_DIR/$base.rpt.tmp" "$REPORTS_DIR/$base.rpt"
    echo "Data written to $REPORTS_DIR/$base.rpt ($n unknown $unit(s), $mentions mention(s))." >&2
}

write_unknown_rpt S unknown-sites        subscription
write_unknown_rpt A unknown-accounts     account
write_unknown_rpt L unknown-logins       login
write_unknown_rpt H unknown-hosts        host
write_unknown_rpt W unknown-whitelisting IP

# Every output is written: record the name list this scan was built from, so the
# next run skips when only the RESULT column of the base caches changed.
mv -f "$NAMES_NEW" "$NAMES_DEP"
