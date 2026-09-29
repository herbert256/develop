#!/usr/bin/env bash
#
# session-sites.sh — the SESSION JOIN learning step (stage 1, right after the
# two parses, before bin/expire-files.sh): learn the REAL subscription of the
# CoreId groups the attribution chain could not place (the synthetic
# "UCx_<account>" fake-subscription names) from the SERVER log, via the
# connection they ran over: _transfers.tsv col 24 carries each leg's session
# id and _parse.tsv col 6 the same id, so the route lines of the very
# connection that moved the file name the flow ST itself executed —
# "Initializing route: {UC4_SI_VPS_VDN}" and the ARRC/AR "[account] [route]"
# bracket tokens. That is the platform's own attribution, not a guess.
#
# Writes data/transfer/cache/_sessionsites.tsv (session <TAB>
# subscription) — the map bin/transfer/parse.sh's SESSION JOIN pass reads (the
# Z records of its fallback map). Rules, all refusal-shaped like the other
# fallbacks:
#   - a token only counts when, after the rename fold (rn_canon), it IS a
#     configured subscription name — a truncated server-log name that matches
#     nothing contributes nothing, and no entity is ever invented here;
#   - a session whose lines name TWO configured flows maps to NEITHER (the
#     same rule result.sh's ring attribution applies to its session votes);
#   - the derive adds its own guards on top: the group's mapped sessions must
#     be unanimous, and the flow must be configured for the group's account
#     when that account has a configured list at all.
#
# The map is a per-session VERDICT file: only the sessions of CURRENTLY-UCx
# rows are scanned, an ambiguous or evidence-less session gets no entry.
#
# THE RE-KEY MAP (2026-09-29, user report — a partner's pickups landing on
# UCx_<account> although their File was attributed): SecureTransport can lose
# a download's session cycleId mid-transfer ("No session cycleId for file
# /data/FlowManager/<account>@<login>/<file>. SENT will not get reported!").
# It then ends the SAME transfer twice — "error" under the File's own CoreId
# (the one the transfer STARTED under) and "ok" under a FRESH CoreId — and
# the transfer log keeps one row per transfer id, whichever end came last.
# When that is the ok one, the pickup leg sits alone under a CoreId no other
# leg carries, with no Transfer Site and no profile: nothing attributes it,
# it reads as a one-legged Failed File on UCx_<account>, and its real File
# stays Waiting. (When the error end comes last, the leg stays in its File
# as Failed — bin/bookend-ok.sh settles that one.) The JSON bookends join
# the two: the same "transferId" under both CoreIds. Written to
# data/transfer/cache/_rekeys.tsv (lone CoreId <TAB> transfer id <TAB>
# original CoreId) — the K records of the parse's fallback map, which move
# the leg back into its File. Refusal-shaped like the session map:
#   - only LONE legs are candidates (a CoreId group of one row);
#   - the bookends of that leg's transfer id must name EXACTLY two CoreIds —
#     the leg's own and one other;
#   - the other one must carry the transfer's "Transfer start logged." line
#     and the leg's own CoreId must not (the transfer began under the other);
#   - the derive adds its own guards: the original CoreId must be in the raw
#     transfer cache and must not already hold a row of that transfer id.
#
# Self-applying: when the map holds a verdict, this script re-runs the
# transfer parse DERIVE-ONLY (AXWAY_DERIVE_ONLY=1 — the raw cache is reused),
# so the new knowledge lands in _transfers.tsv/_files.tsv immediately.
# bin/build.sh runs this step after both parses (it reads the finished server
# cache), before bin/expire-files.sh.
#
# Usage:  bin/session-sites.sh
#
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$ROOT/bin/fastawk.sh"   # route unqualified `awk` to mawk when installed
source "$ROOT/bin/renames.sh"   # RENAMES_FILE + RENAMES_AWK (rn_canon: old name -> current)
source "$ROOT/bin/ranges.sh"    # rng_feed / rng_off: the byte-range split of the parallel scan (2026-09-27)

DATA="$ROOT/data"
PARSED="$DATA/transfer/cache/_transfers.tsv"
SRV="$DATA/server/cache/_parse.tsv"
OUT="$DATA/transfer/cache/_sessionsites.tsv"
RKOUT="$DATA/transfer/cache/_rekeys.tsv"   # re-keyed lone leg -> its original CoreId (the re-key map)
BASE="$DATA/flow-manager/base"

if [ ! -s "$PARSED" ]; then
    echo "session-sites: no transfer cache ($PARSED) — nothing to attribute." >&2
    exit 0
fi
if [ ! -s "$SRV" ]; then
    echo "session-sites: no server cache ($SRV) — cannot see the route lines; no map written." >&2
    exit 0
fi
# the configured-subscription set: the pristine snapshot when present (the
# not-in-flow-manager rule — base/ is amended with discovered names, the UCx
# rows themselves included), else the base rows that carry a direction (a
# discovered append has none)
if [ -f "$BASE/.configured.tsv" ]; then CONFSRC="$BASE/.configured.tsv"
else CONFSRC="$BASE/_subscriptions.tsv"; fi
if [ ! -f "$CONFSRC" ]; then
    echo "session-sites: no configured-subscription list ($CONFSRC) — no map written." >&2
    exit 0
fi

tmp="$OUT.tmp.$$"
sess="$OUT.sess.$$"
cand="$OUT.cand.$$"
rktmp="$RKOUT.tmp.$$"
trap 'rm -f "$tmp" "$sess" "$cand" "$rktmp" "$tmp".part.* "$tmp".rk.*' EXIT
# the PREVIOUS verdicts (a second run — a build starts with none): an entry
# whose session is not rescanned now persists, so a rerun never undoes the
# rescues of the first (2026-09-28 fix: dropped with the incremental
# machinery, but it was never a freshness check). The re-key map the same:
# a moved leg is no lone leg any more, so a rerun keeps its entry.
OLDMAP="$OUT"; [ -f "$OUT" ] || OLDMAP=/dev/null
OLDRK="$RKOUT"; [ -f "$RKOUT" ] || OLDRK=/dev/null

# ONE pass over the transfer cache: the sessions to (re)scan — every session
# a currently-UCx leg ran over — and the RE-KEY candidates: the transfer id
# of every LONE leg (the cache is CoreId-sorted, so a group is a run of equal
# col 1 and a lone leg a run of one)
: > "$sess"
awk -F'\t' -v OFS='\t' -v SESSF="$sess" '
    $6 ~ /^UCx_/ && $24 != "" { print $24 > SESSF }
    $1 != pk { if (pn == 1 && pk != "" && pt != "") print pt, pk; pk = $1; pn = 0; pt = $23 }
    { pn++ }
    END { if (pn == 1 && pk != "" && pt != "") print pt, pk }
' "$PARSED" | LC_ALL=C sort -u > "$cand"
LC_ALL=C sort -u -o "$sess" "$sess"
if [ ! -s "$sess" ] && [ ! -s "$cand" ]; then
    echo "session-sites: no UCx rows and no lone legs — nothing to learn." >&2
    exit 0
fi

# THE SCAN RUNS IN PARALLEL (2026-09-27): one job per core, each over its own
# contiguous byte range of the server cache (every job computes the same line
# offsets, so the ranges partition the lines). A session verdict does not
# depend on line order — the one configured flow it names, or "-" once it names
# a second — so the part verdicts merge exactly (the merge below).
_ss0=$(date +%s)
NJ=$( (command -v nproc >/dev/null 2>&1 && nproc) || sysctl -n hw.ncpu 2>/dev/null || echo 2 )
case $NJ in ""|*[!0-9]*) NJ=2 ;; esac
SRVSZ=$(wc -c < "$SRV" | tr -d " ")
scan_part() {   # $1 = part index: its range of line starts is [lo, hi)
    local lo=$(( ($1 - 1) * SRVSZ / NJ )) hi
    if [ "$1" -eq "$NJ" ]; then hi=$((SRVSZ + 1)); else hi=$(( $1 * SRVSZ / NJ )); fi
    : > "$tmp.rk.$1"
    rng_feed "$SRV" "$lo" | awk -v RANGEF=/dev/stdin -v RLO="$lo" -v RHI="$hi" -v ROFF="$(rng_off "$lo")" -F'\t' -v OFS='\t' -v RNF="$RENAMES_FILE" -v RKF="$tmp.rk.$1" "$RENAMES_AWK"'
    # the JSON value of key k in message m ("" when absent) — the reader
    # bin/bookend-ok.sh uses: the tokenizer flattened the multi-line record
    # to one line and unquoted the CSV doubling, so it reads "k":"v" with
    # optional blanks around the colon
    function jval(m, k,   p, s) {
        p = index(m, "\"" k "\""); if (p == 0) return ""
        s = substr(m, p + length(k) + 2); sub(/^[ \t]*:[ \t]*"/, "", s)
        if (substr(s, 1, 1) == "\"" ) return ""      # not a string value
        sub(/".*$/, "", s); return s
    }
    # THE PREFIX GATE (2026-09-27): a token can name a configured flow only when
    # its first 3 characters, upper-cased, open a configured name or an old
    # name of the rename map (the tail strip and the rename fold both keep the
    # token prefix) — exact, and off when a name is shorter than 3 characters
    BEGIN { rn_load(RNF); for (rk in RN_S) { CP3[substr(rk, 1, 3)] = 1; if (length(rk) < 3) GATE_OFF = 1 } }
    FILENAME ~ /\.configured\.tsv$/   { if ($1 == "_subscriptions") { conf[toupper($2)] = $2; CP3[toupper(substr($2, 1, 3))] = 1; if (length($2) < 3) GATE_OFF = 1 }; next }
    FILENAME ~ /_subscriptions\.tsv$/ { if ($2 != "") { conf[toupper($1)] = $1; CP3[toupper(substr($1, 1, 3))] = 1; if (length($1) < 3) GATE_OFF = 1 }; next }
    FILENAME ~ /\.sess\./             { scan[$1] = 1; next }
    FILENAME ~ /\.cand\./             { cand[$1] = 1; ncand = 1; next }
    RANGEF != "" && FILENAME == RANGEF { if (!_rs) { _rs = 1; _off = ROFF + 0 } _lo = _off; _off += length($0) + 1; if (_lo < RLO + 0) next; if (_lo >= RHI + 0) exit }
    {   # _parse.tsv: col 5 = message, col 6 = session
        # THE RE-KEY EVIDENCE: a JSON transfer bookend of a lone leg transfer
        # id — the CoreId it names, S = the transfer STARTED under it. Falls
        # through: the session verdict below reads every line as before.
        if (ncand && index($5, "{\"message\":\"Transfer ") == 1) {
            t = jval($5, "transferId")
            if (t != "" && (t in cand)) {
                c = jval($5, "coreId")
                if (c != "") print t, c, (index($5, "{\"message\":\"Transfer start logged.\"") == 1 ? "S" : "E") > RKF
            }
        }
        if (!($6 in scan)) next
        # a session that already named two flows keeps "-" whatever it logs
        # next (2026-09-27: a busy shared session ran the token loop below on
        # every one of its lines)
        if (seen[$6] == "-") next
        m = $5
        # every name-shaped token, not only UC-prefixed ones (2026-08-31
        # audit): the production hybrid flows carry no UC prefix, so the
        # former UC[0-9]+_ pre-filter made this step blind to exactly the
        # groups it exists to rescue. The configured-set test below is the
        # real guard; the shape only bounds the scan. A logged _SCP_ tail is
        # stripped first, as the transfer parse does.
        while (match(m, /[A-Za-z][A-Za-z0-9_-]*[_-][A-Za-z0-9_-]+/)) {
            t = substr(m, RSTART, RLENGTH); m = substr(m, RSTART + RLENGTH)
            if (!GATE_OFF && !(toupper(substr(t, 1, 3)) in CP3)) continue
            sub(/_(SS?|C)CP_.*$|_[A-Za-z0-9]+_(SERVER|CLIENT)_.*$/, "", t)
            t = rn_canon(t)
            if (toupper(t) in conf) {
                t = conf[toupper(t)]                       # the export own spelling
                if (seen[$6] == "") seen[$6] = t
                else if (seen[$6] != t) seen[$6] = "-"     # two flows -> no verdict
            }
        }
    }
    END { for (s in seen) if (seen[s] != "") print s, seen[s] }
    ' "$CONFSRC" "$sess" "$cand" /dev/stdin > "$tmp.part.$1"
}
pids=()
for ((pi = 1; pi <= NJ; pi++)); do scan_part "$pi" & pids+=("$!"); done
for p in "${pids[@]}"; do wait "$p"; done
awk -F'\t' -v OFS='\t' -v OLDF="$OLDMAP" '
    FILENAME ~ /\.sess\./            { scan[$1] = 1; next }
    FILENAME == OLDF                  { old[$1] = $2; next }
    { if (!($1 in seen) || seen[$1] == "") seen[$1] = $2; else if (seen[$1] != $2) seen[$1] = "-" }
    END {
        # scanned sessions take the fresh verdict (or lose their entry);
        # unscanned entries of an earlier run persist
        for (s in scan) if (seen[s] != "" && seen[s] != "-") nv[s] = seen[s]
        for (s in old)  if (!(s in scan)) nv[s] = old[s]
        for (s in nv) print s, nv[s]
    }
' "$sess" "$OLDMAP" "$tmp".part.* | LC_ALL=C sort > "$tmp"
rm -f "$tmp".part.*
# the RE-KEY verdicts (the rules in the header): per candidate transfer id,
# the CoreIds its bookends name — exactly two, the lone leg's own (B) and one
# other (A), the transfer started under A and not under B
LC_ALL=C sort -u "$tmp".rk.* | awk -F'\t' -v OFS='\t' -v CANDF="$cand" -v OLDF="$OLDRK" '
    FILENAME == CANDF { lone[$1] = $2; next }
    FILENAME == OLDF  { old[$1 SUBSEP $2] = $3; next }
    {   # tid, coreId, S|E (sort -u: one line per distinct triple)
        if (!(($1, $2) in seen)) { seen[$1, $2] = 1; n[$1]++; cc[$1, n[$1]] = $2 }
        if ($3 == "S") st[$1, $2] = 1
    }
    END {
        for (t in n) {
            if (n[t] != 2 || !(t in lone)) continue
            b = lone[t]
            if (cc[t, 1] == b) a = cc[t, 2]; else if (cc[t, 2] == b) a = cc[t, 1]; else continue
            if (((t, a) in st) && !((t, b) in st)) nv[b SUBSEP t] = a
        }
        # an entry of an earlier run whose transfer id is no lone leg now
        # (its leg was moved back) persists
        for (k in old) { split(k, kk, SUBSEP); if (!(kk[2] in lone)) nv[k] = old[k] }
        for (k in nv) { split(k, kk, SUBSEP); print kk[1], kk[2], nv[k] }
    }
' "$cand" "$OLDRK" - | LC_ALL=C sort > "$rktmp"
rm -f "$tmp".rk.*
printf "TIME %5ds  session-sites: server log scan (%d jobs)\n" "$(( $(date +%s) - _ss0 ))" "$NJ" >&2

n_scan=$(wc -l < "$sess" | tr -d ' ')
n_map=$(wc -l < "$tmp" | tr -d ' ')
n_lone=$(wc -l < "$cand" | tr -d ' ')
n_rk=$(wc -l < "$rktmp" | tr -d ' ')
if [ -s "$rktmp" ]; then mv "$rktmp" "$RKOUT"; else rm -f "$RKOUT"; fi
if [ ! -s "$tmp" ] && [ "$n_rk" -eq 0 ]; then
    echo "session-sites: $n_scan UCx session(s) scanned, none attributable; $n_lone lone leg(s), none re-keyed — no map written." >&2
    exit 0
fi
if [ -s "$tmp" ]; then mv "$tmp" "$OUT"; fi
echo "session-sites: $n_scan UCx session(s) scanned, map now $n_map entry/-ies; $n_lone lone leg(s), $n_rk re-keyed — re-deriving the transfer caches." >&2
# apply immediately: the derive-only re-run
AXWAY_DERIVE_ONLY=1 "$ROOT/bin/transfer/parse.sh"
