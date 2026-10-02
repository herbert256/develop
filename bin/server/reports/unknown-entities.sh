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
# plus the four data/unknown/ sidecars — the server-log sighting lists, one
# NAME per line (accounts / sites / logins / hosts), read by Entity Search and
# Cross reference (2026-09-29 audit: their latest-mention stamp + message
# columns and the whitelisted-IP list white.tsv had no reader and went, with
# the tie rule and the line-number pre-pass that only served them).
# (The four SSH-LOGON files logon-*.tsv went with the BLUE status, 2026-09-27.)
#
# MAP-REDUCE (the bin/server/parse.sh pattern): the extraction work is CPU,
# not I/O, so NW workers each scan ONE line-aligned BYTE SLICE of the cache
# (bin/ranges.sh line_cuts + byte_feed; 2026-09-29, build speed — until then
# every worker read the WHOLE cache gated on FNR % NW == ID, six full reads:
# 71 CPU-s on production) and dump their LOCAL aggregates (per-name
# counts, per-name-per-day counts, the bounded logline rings) as small tagged
# files. ONE merge pass then sums the counts, re-inserts the ring entries
# through addline (the global top-10 is a subset of the per-worker top-10s),
# loads the known sets from ONE read of the transfer cache, and writes the
# five .rpt files + sidecars. Aggregation is exact: counts add and addline
# inserts by (timestamp, message) key regardless of arrival order; the per-day
# buckets are emitted date-sorted (they were in hash order, which follows the
# insertion history).
#
# Usage:
#   ./unknown-entities.sh    # reads input/*.csv (via the caches) + transfer _transfers.tsv
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib.sh"
source "$ROOT/bin/blacklist.sh"   # BLACKLIST_FILE + BLACKLIST_AWK — the ONE blacklist (input/blacklist.txt)
source "$ROOT/bin/renames.sh"    # RENAMES_FILE + RENAMES_AWK — fold a logged name to its CURRENT one
source "$ROOT/bin/ranges.sh"     # line_cuts + byte_feed: the workers' byte slices
mkdir -p "$REPORTS_DIR" "$UNKNOWN_DIR"

TCACHE="$TRANSFER_CACHE/_transfers.tsv"      # authoritative per-row entity lists (transfer parse cache)
CFG_HOSTS="$CONFIG_BASE/_hosts.tsv"          # configured outbound endpoints (partners.json host fields)
CFG_WHITE="$CONFIG_BASE/_white.tsv"          # whitelisted partner IPs (partners.json AllowIPxx fields)
# ($IP_HOSTS_FILE, the ip -> endpoint map of bin/ip.sh, is read below)

shopt -s nullglob
files=("$INPUT_DIR"/*.csv)
shopt -u nullglob
if [ ${#files[@]} -eq 0 ]; then
    echo "No files matching '*.csv' found in '$INPUT_DIR'" >&2
    rm -f "$REPORTS_DIR"/unknown-{sites,accounts,logins,hosts,whitelisting}.rpt
    exit 0
fi
if [ ! -f "$TCACHE" ]; then
    echo "Transfer parse cache not found: $TCACHE — run bin/transfer/parse.sh first." >&2
    exit 1
fi
[ -f "$CFG_HOSTS" ] || echo "No configured host list ($CFG_HOSTS) — unknown-hosts will be empty." >&2
[ -f "$CFG_WHITE" ] || echo "No whitelist ($CFG_WHITE) — unknown-whitelisting will be empty." >&2

echo "Found ${#files[@]} file(s) in '$INPUT_DIR', processing..." >&2

TMPD=$(mktemp -d "${TMPDIR:-/tmp}/unkent.XXXXXX")
trap 'rm -rf "$TMPD"' EXIT

# The address -> endpoint map for the whitelisting known set: "M ip name" per
# entry of input/ip/ip-hosts.tsv (bin/ip.sh — FORWARD DNS over the configured
# hosts; there is no reverse DNS). An IP is known when its mapped NAME appears
# as a transfer host (the out-side substitution replaced the IP by the name);
# mere presence in the map does NOT count. One read of the map file:
# "M <ip> <lowercased name>", empty fields skipped.
if [ -f "$IP_HOSTS_FILE" ]; then
    awk -F'\t' '$1 != "" && $2 != "" { print "M\t" $1 "\t" tolower($2) }' "$IP_HOSTS_FILE" > "$TMPD/known.map"
else
    : > "$TMPD/known.map"
fi

cfg_hosts_in="$CFG_HOSTS"; [ -f "$cfg_hosts_in" ] || cfg_hosts_in=/dev/null
cfg_white_in="$CFG_WHITE"; [ -f "$cfg_white_in" ] || cfg_white_in=/dev/null

# ---- THE KNOWN SETS, ONCE, BEFORE THE SCAN (2026-09-29, build speed round 3)
# Only UNKNOWN entities are ever reported, yet the workers counted, bucketed
# and ring-inserted every mention of every KNOWN name too (most mentions) and
# the merge threw them away — the per-mention bookkeeping was most of this
# report's 71 CPU-s on production. The known sets depend on the transfer
# cache, the blacklist and the configured lists only, so they are computed
# first — the merge's former rules, verbatim — and the workers skip a known
# name before any bookkeeping; the merge keeps its filter, reading this small
# file instead of the transfer cache. Exact: an unknown name's counts,
# buckets and ring are untouched, a known one never reached the output.
#   S name   a transfer-log subscription (the S rule matches prefixes of these)
#   A name   a transfer-log account, or a blacklisted one
#   L name   a transfer-log login, or a blacklisted one
#   H host   a CONFIGURED host (lowercase) that is also a transfer host
#   W ip     a whitelisted IP that is a transfer host, or maps to one
awk -F'\t' -v BLF="$BLACKLIST_FILE" "$BLACKLIST_AWK"'
    BEGIN { bl_load(BLF)
            for (blk in BL_DROP) { split(blk, blf_, SUBSEP)
                if (blf_[1] == "account") aknown[blf_[2]] = 1
                else if (blf_[1] == "login") lknown[blf_[2]] = 1 } }
    FILENAME ~ /known\.map$/ { if ($1 == "M") mip[$2] = $3; next }
    FILENAME ~ /_transfers\.tsv$/ {
        if ($6 != "" && !bl_blank("site", $6)) sknown[$6] = 1
        if ($4 != "") aknown[$4] = 1
        if ($5 != "") lknown[$5] = 1
        if ($16 != "") { hknown[tolower($16)] = 1; wH[$16] = 1 }
        next }
    FILENAME ~ /_hosts\.tsv$/ { if ($1 != "") CH[tolower($1)] = 1; next }
    FILENAME ~ /_white\.tsv$/ { if ($1 != "") CW[$1] = 1; next }
    END {
        for (k in sknown) print "S\t" k
        for (k in aknown) print "A\t" k
        for (k in lknown) print "L\t" k
        for (k in CH) if (k in hknown) print "H\t" k
        for (k in CW) if ((k in wH) || ((k in mip) && (mip[k] in hknown))) print "W\t" k
    }
' "$TMPD/known.map" "$TCACHE" "$cfg_hosts_in" "$cfg_white_in" > "$TMPD/known.tsv"

# ---- MAP: NW workers, each scanning one byte slice of the parse cache ------
# Extraction rules are copied VERBATIM from the five former scripts; all state
# is namespaced "T SUBSEP name" (T = S sites / A accounts / L logins / H hosts
# / W whitelisted IPs). A worker dumps its local aggregates tagged:
#   C t name count                    per-name mention count
#   D t name date count               per-name-per-day count (the buckets)
#   R t name sk logline               bounded logline-ring entries (<=10/name)
NW=$( (command -v sysctl >/dev/null 2>&1 && sysctl -n hw.ncpu) 2>/dev/null || echo 4 )
[ "$NW" -ge 1 ] 2>/dev/null || NW=4
line_cuts "$PARSED" "$NW" > "$TMPD/cuts"
wpids=(); id=0
while read -r lo hi; do
    ( byte_feed "$PARSED" "$lo" "$hi" | awk -F'\t' -v RNF="$RENAMES_FILE" "$LOGLINES_AWK$RENAMES_AWK"'
        BEGIN { rn_load(RNF) }
        # the KNOWN sets (the pre-pass above): a known name is skipped before
        # any bookkeeping, and the known configured hosts / whitelisted IPs
        # never enter cfg / white at all
        FILENAME ~ /known\.tsv$/ { if ($1 == "S") KS[$2] = 1; else if ($1 == "A") KA[$2] = 1; else if ($1 == "L") KL[$2] = 1
                                   else if ($1 == "H") KH[$2] = 1; else if ($1 == "W") KW[$2] = 1
                                   next }
        FILENAME ~ /_hosts\.tsv$/  { if ($1 != "" && !(tolower($1) in KH)) { if (!(tolower($1) in cfg)) HLS[++nhl] = tolower($1); cfg[tolower($1)] = $1; if (!index($1, ".")) hnodot = 1 } next }   # config spelling, matched lowercase (hnodot: the H fast path is off); HLS = the list
        FILENAME ~ /_white\.tsv$/  { if ($1 != "" && !($1 in KW)) white[$1] = 1; next }
        # an S token is known when a transfer-log subscription starts with it
        # (the server truncated the name) or it starts with one at a name-part
        # boundary (the token overran the name) — the merge rule, memoized
        function sunk(nm,   kk) {
            for (kk in KS) if (index(kk, nm) == 1) return 0
            for (kk in KS) if (index(nm, kk) == 1 && (length(nm) == length(kk) || substr(nm, length(kk) + 1, 1) ~ /[_-]/)) return 0
            return 1
        }
        {
            d = substr($1, 1, 10)
            sk = $1 " " $2
            delete mseen                             # one log line per entity per record (all types)
            # W: whitelisted partner IPs — ALL components (the report counts
            # every mention; only the TM sighting feeds the sidecar). (An
            # index() prefilter over the unknown IPs, like the H one below,
            # was SLOWER — a whitelist holds ~100 IPs; 2026-09-29.)
            if ($5 ~ /[0-9]\.[0-9]/) {
                s = $5
                while (match(s, /[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/)) {
                    ip = substr(s, RSTART, RLENGTH)
                    s = substr(s, RSTART + RLENGTH)
                    if (ip in white) {
                        k = "W" SUBSEP ip
                        cnt[k]++; cd[k SUBSEP d]++
                        if (!(k in mseen)) { mseen[k] = 1; addline(k, sk, lvlname($3) " " compname($4) "  " substr($5, 1, 200)) }
                    }
                }
            }
            if ($4 != "T") next                      # S/A/L/H: TM (Transfer Manager) messages only
            # S: UC<n>_ subscription tokens
            if ($5 ~ /UC[0-9]+_/) {
                s = $5
                while (match(s, /UC[0-9]+_[A-Za-z0-9_-]+/)) {    # hyphens are part of UC4/UC2 names
                    tk = substr(s, RSTART, RLENGTH)
                    # the fold below is a pure function of the token, and the
                    # same few names repeat on most lines: memoized (STK)
                    if (tk in STK) tk = STK[tk]
                    else { t0 = tk
                    sub(/_(SS?|C)CP_.*$|_[A-Za-z0-9]+_(SERVER|CLIENT)_.*$/, "", tk)                                        # canonical subscription name (drop the _SCP_ / _SSCP_ / _CCP_ tail)
                    p14 = index(tk, "_P14303_CFT01"); if (p14 > 0) tk = substr(tk, 1, p14 - 1)   # composite <site>_P14303_CFT01[_flow] identifiers
                    # RENAMES: a server line keeps the name that was current
                    # when it was written. Fold it here, where the token is
                    # formed, so the counts aggregate under the CURRENT name and
                    # the known-set test below compares like with like — without
                    # this, every renamed flow reads as an unknown subscription
                    # (2026-08).
                    # rn_canon_pfx, not rn_canon: the server truncates names,
                    # so a renamed flow arrives as a PREFIX of its old name.
                    tk = rn_canon_pfx(tk); STK[t0] = tk }
                    if (!(tk in SUN)) SUN[tk] = sunk(tk)
                    if (!SUN[tk]) { s = substr(s, RSTART + RLENGTH); continue }   # a known subscription
                    k = "S" SUBSEP tk
                    cnt[k]++; cd[k SUBSEP d]++
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
                    if (m != "" && !(m in KA)) {
                        k = "A" SUBSEP m
                        cnt[k]++; cd[k SUBSEP d]++
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
                    if (m != "" && !(m in KL)) {
                        k = "L" SUBSEP m
                        cnt[k]++; cd[k SUBSEP d]++
                            if (!(k in mseen)) { mseen[k] = 1; addline(k, sk, lvlname($3) " " compname($4) "  " substr($5, 1, 200)) }
                    }
                    s = substr(s, RSTART + RLENGTH)
                }
            }
            # H: configured endpoint tokens (dots kept so hostnames/IPs stay
            # one token; stray sentence dots trimmed — parse.sh'\''s entity scan)
            # THE DOTTED FAST PATH (2026-09-27, build-speed round 6; half of
            # this scan was lowercasing and splitting EVERY TM message): when
            # every configured host holds a dot, only a token run holding one
            # can match, so match() walks just those runs — leftmost-longest,
            # each is a whole maximal run of the token class, exactly a split
            # token — and a message without a dot has none. Same hits, same
            # counts; a dotless configured host (hnodot) keeps the full split.
            nh = 0
            # THE PREFILTER (2026-09-29, speed round 3): cfg holds only the
            # UNKNOWN configured hosts now, and a token the split below
            # matches is a substring of the lowercased message — so the split
            # (41 % of this scan) runs only on a message holding one of them
            # (production: 10 unknown hosts, 56 mentions in 11M lines). Exact.
            ph = 0
            if (nhl && (hnodot || index($5, "."))) { lm = tolower($5); for (ih = 1; ih <= nhl; ih++) if (index(lm, HLS[ih])) { ph = 1; break } }
            if (!ph) { }
            else if (!hnodot) {
                if (index($5, ".") && $5 ~ /[A-Za-z0-9][._-]/) {
                    n = split($5, tok, /[^A-Za-z0-9._-]+/)
                    for (i = 1; i <= n; i++) {
                        w = tok[i]; if (!index(w, ".")) continue
                        w = tolower(w)
                        if (substr(w, 1, 1) == "." || substr(w, length(w)) == ".") gsub(/^\.+|\.+$/, "", w)
                        if (w != "" && (w in cfg)) HW[++nh] = w
                    }
                }
            } else if ($5 ~ /[A-Za-z0-9][._-]/) {
                s2 = tolower($5)
                n = split(s2, tok, /[^a-z0-9._-]+/)
                for (i = 1; i <= n; i++) {
                    w = tok[i]; gsub(/^\.+|\.+$/, "", w)
                    if (w != "" && (w in cfg)) HW[++nh] = w
                }
            }
            if (nh) {
                for (i = 1; i <= nh; i++) {
                    w = HW[i]
                    k = "H" SUBSEP cfg[w]            # attribute under the config spelling
                    cnt[k]++; cd[k SUBSEP d]++
                    if (!(k in mseen)) { mseen[k] = 1; addline(k, sk, lvlname($3) " " compname($4) "  " substr($5, 1, 200)) }
                }
            }
        }
        END {
            for (k in cnt) { split(k, kp, SUBSEP)
                print "C\t" kp[1] "\t" kp[2] "\t" cnt[k]
                nl = (k in _LLi) ? split(loglist(k), le, _US) : 0   # (_LLi: the ring id map, bin/server/lib.sh)
                for (i = 1; i <= nl; i++) { split(le[i], lf, SUBSEP)
                    print "R\t" kp[1] "\t" kp[2] "\t" lf[1] "\t" lf[2] } }
            for (k in cd) { nd = split(k, kp, SUBSEP)
                print "D\t" kp[1] "\t" kp[2] "\t" kp[3] "\t" cd[k] }
        }
    ' "$TMPD/known.tsv" "$cfg_hosts_in" "$cfg_white_in" /dev/stdin > "$TMPD/part.$id" ) &
    wpids+=("$!")
    id=$((id + 1))
done < "$TMPD/cuts"
for p in ${wpids[@]+"${wpids[@]}"}; do wait "$p"; done

# ---- REDUCE: merge the worker aggregates, filter against the known sets -----
SIDE_S="$UNKNOWN_DIR/sites.tsv"; SIDE_A="$UNKNOWN_DIR/accounts.tsv"
SIDE_L="$UNKNOWN_DIR/logins.tsv"; SIDE_H="$UNKNOWN_DIR/hosts.tsv"
rm -f "$SIDE_S" "$SIDE_A" "$SIDE_L" "$SIDE_H"   # every run first deletes the sidecars
agg=$(awk -F'\t' -v side_s="$SIDE_S" -v side_a="$SIDE_A" -v side_l="$SIDE_L" \
        -v side_h="$SIDE_H" \
        "$LOGLINES_AWK"'
    # the KNOWN sets — the pre-pass file (see above): the blacklist seeding,
    # the transfer-cache read and the host / IP rules happened there; the
    # workers already dropped every known name, so this filter is a guard
    FILENAME ~ /known\.tsv$/ { if ($1 == "S") { sknown[$2] = 1; sbase[$2] = 1 }
                               else if ($1 == "A") aknown[$2] = 1; else if ($1 == "L") lknown[$2] = 1
                               else if ($1 == "H") hknown[$2] = 1; else if ($1 == "W") wkn[$2] = 1
                               next }
    # worker aggregate lines
    $1 == "C" { k = $2 SUBSEP $3; cnt[k] += $4; next }
    $1 == "D" { k = $2 SUBSEP $3; cd[k SUBSEP $4] += $5; next }
    $1 == "R" { addline($2 SUBSEP $3, $4, $5); next }
    # an IP is known when it appears as a transfer host itself, or when its
    # mapped endpoint name does (the pre-pass decided it)
    function wknown(ip2) { return (ip2 in wkn) }
    END {
        for (k in cd) { p = k; sub(SUBSEP "[^" SUBSEP "]*$", "", p)   # strip the trailing date
            nd = split(k, kp, SUBSEP)
            bk[p] = bk[p] (bk[p] ? "," : "") kp[nd] ":" cd[k] }
        # DATE-SORTED (2026-09-29): the for-in above follows the insertion
        # history, which the worker slicing sets; one date per entry, so a
        # plain string sort of "yyyy-mm-dd:count" is the date order
        for (p in bk) { nb = split(bk[p], BE, ","); for (i = 2; i <= nb; i++) { v = BE[i]; j = i - 1
                while (j >= 1 && BE[j] > v) { BE[j + 1] = BE[j]; j-- } BE[j + 1] = v }
            s9 = BE[1]; for (i = 2; i <= nb; i++) s9 = s9 "," BE[i]; bk[p] = s9 }
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
            if      (t == "S") print nm > side_s   # the sighting lists: the NAME is all their readers take
            else if (t == "A") print nm > side_a
            else if (t == "L") print nm > side_l
            else if (t == "H") print nm > side_h
        }
        # per-type totals for the five page headers, in a FIXED order (never a
        # for-in): each was a grep -c + an awk fork per report down in the shell
        ntg = split("S A L H W", TG, " ")
        for (i = 1; i <= ntg; i++) printf "TOT\t%s\t%d\t%d\n", TG[i], un[TG[i]]+0, um[TG[i]]+0
    }
' "$TMPD/known.tsv" "$TMPD"/part.*)
# for-in emits in hash order; the sidecars are data files, so sort them (name-sorted)
# a type with NO unknowns keeps an EMPTY sidecar (its readers expect one)
for sc in "$SIDE_S" "$SIDE_A" "$SIDE_L" "$SIDE_H"; do
    if [ -f "$sc" ]; then LC_ALL=C sort -o "$sc" "$sc"; else : > "$sc"; fi
done

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
# LAST DATE/TIME (2026-10-02, user request: "Add a column Last date/time"):
# the newest of the row's mentions — the stamp of the FIRST of its newest-
# first log lines (lastlines: "yyyy-mm-dd hh:mm:ss  Level …", \037-joined).
unknown_rows() {   # $1 = tag
    local count bucket name lines last
    while IFS=$'\t' read -r count bucket name lines; do
        [ -z "$name" ] && continue
        last=${lines%%$'\037'*}; last=${last:0:19}
        case $last in [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]\ [0-9][0-9]:[0-9][0-9]:[0-9][0-9]) ;; *) last="" ;; esac
        printf 'ROW\t%s\t%s\t%s\t@data:buckets=%s\t@data:loglines=%s\n' "$name" "$count" "$last" "$bucket" "$lines"
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
            printf 'TABLE\tSubscriptions in server logs, not in transfer logs\twide\n'
            printf 'HEAD\tSubscription (as logged by the server)\tServer-log mentions\tLast date/time\n' ;;
        A)  printf 'TITLE\tAccounts Missing from Transfer Logs\n'
            printf 'TABLE\tAccounts in server logs, not in transfer logs\n'
            printf 'HEAD\tAccount (as logged by the server)\tServer-log mentions\tLast date/time\n' ;;
        L)  printf 'TITLE\tLogins Missing from Transfer Logs\n'
            printf 'TABLE\tLogins in server logs, not in transfer logs\n'
            printf 'HEAD\tLogin (as logged by the server)\tServer-log mentions\tLast date/time\n' ;;
        H)  printf 'TITLE\tOutbound Hosts Missing from Transfer Logs\n'
            printf 'TABLE\tConfigured hosts in server logs, not in transfer logs\n'
            printf 'HEAD\tHost (as configured)\tServer-log mentions\tLast date/time\n' ;;
        W)  printf 'TITLE\tWhitelisted IPs Missing from Transfer Logs\n'
            printf 'TABLE\tWhitelisted IPs in server logs, not in transfer logs\n'
            printf 'HEAD\tIP address (whitelisted)\tServer-log mentions\tLast date/time\n' ;;
        esac
        # the value column's KIND is the ENTITY kind (2026-09-29, user request:
        # "have a link next to the entity value that goes to the detail page of
        # that entity"): every row drills to its log lines, so render_rpt keeps
        # the name plain (the drill's click) and puts the ↗ detail-page icon
        # after it — only for a name with a detail page (the slugmap; an
        # unconfigured or truncated name stays plain). A whitelisted IP has
        # no detail page type: mono, as before.
        case $tag in
            S) printf 'KIND\tsite\tnum\ttext\n' ;;
            A) printf 'KIND\tacct\tnum\ttext\n' ;;
            L) printf 'KIND\tlogin\tnum\ttext\n' ;;
            H) printf 'KIND\thost\tnum\ttext\n' ;;
            *) printf 'KIND\tmono\tnum\ttext\n' ;;
        esac
        # Last date/time is the full-period newest mention: kept as it is
        # under a narrowed From/To ("-")
        printf 'RECALC\t-\ts0\t-\n'
        unknown_rows "$tag"
        printf 'TOTAL\tTotal (%s %s(s))\t@{class=num}%s\t\n' "$n" "$unit" "$mentions"
        printf 'FOOT\n'
    } > "$REPORTS_DIR/$base.rpt.tmp" && mv "$REPORTS_DIR/$base.rpt.tmp" "$REPORTS_DIR/$base.rpt"
    echo "Data written to $REPORTS_DIR/$base.rpt ($n unknown $unit(s), $mentions mention(s))." >&2
}

write_unknown_rpt S unknown-sites        subscription
write_unknown_rpt A unknown-accounts     account
write_unknown_rpt L unknown-logins       login
write_unknown_rpt H unknown-hosts        host
write_unknown_rpt W unknown-whitelisting IP
