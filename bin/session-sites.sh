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
# Writes data/<env>/transfer/cache/_sessionsites.tsv (session <TAB>
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
# The map is a per-session VERDICT file, not a rescan-everything product: only
# the sessions of CURRENTLY-UCx rows are (re)scanned each run — a rescued
# group's session keeps its entry (which is what keeps the rescue standing on
# the next full derive), an ambiguous or evidence-less session gets none, and
# an entry whose session is rescanned takes the fresh verdict. So the file
# only changes when the server log actually teaches us something new, and the
# cmp-guard below keeps its mtime still otherwise — the mtime is what triggers
# the (expensive) re-derive.
#
# Self-applying: when the map changed, this script re-runs the transfer parse
# (derive only — the tokenize manifest is untouched) with AXWAY_SKIP_SESSIONS=1
# so the new knowledge lands in _transfers.tsv/_files.tsv immediately and the
# re-run cannot recurse back here. parse.sh's own tail calls this script the
# same way expire-files.sh is called, so a manual parse stays complete;
# bin/build.sh suppresses that call on its first parse (the server cache is
# mid-rewrite beside it) and runs this step itself after the parse barrier.
#
# Usage:  bin/session-sites.sh
#
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$ROOT/bin/fastawk.sh"   # route unqualified `awk` to mawk when installed
source "$ROOT/bin/renames.sh"   # RENAMES_FILE + RENAMES_AWK (rn_canon: old name -> current)

DATA="$ROOT/data"
PARSED="$DATA/transfer/cache/_transfers.tsv"
SRV="$DATA/server/cache/_parse.tsv"
OUT="$DATA/transfer/cache/_sessionsites.tsv"
BASE="$DATA/flow-manager/base"

if [ ! -s "$PARSED" ]; then
    echo "session-sites: no transfer cache ($PARSED) — nothing to attribute." >&2
    exit 0
fi
if [ ! -s "$SRV" ]; then
    echo "session-sites: no server cache ($SRV) — cannot see the route lines; keeping the map as-is." >&2
    exit 0
fi
# the configured-subscription set: the pristine snapshot when present (the
# not-in-flow-manager rule — base/ is amended with discovered names, the UCx
# rows themselves included), else the base rows that carry a direction (a
# discovered append has none)
if [ -f "$BASE/.configured.tsv" ]; then CONFSRC="$BASE/.configured.tsv"
else CONFSRC="$BASE/_subscriptions.tsv"; fi
if [ ! -f "$CONFSRC" ]; then
    echo "session-sites: no configured-subscription list ($CONFSRC) — keeping the map as-is." >&2
    exit 0
fi

tmp="$OUT.tmp.$$"
sess="$OUT.sess.$$"
trap 'rm -f "$tmp" "$sess" "$tmp".part.*' EXIT
OLDMAP="$OUT"; [ -f "$OUT" ] || OLDMAP=/dev/null

# the sessions to (re)scan: every session a currently-UCx leg ran over
awk -F'\t' '$6 ~ /^UCx_/ && $24 != "" { print $24 }' "$PARSED" | LC_ALL=C sort -u > "$sess"
if [ ! -s "$sess" ]; then
    echo "session-sites: no UCx rows — nothing to learn (map kept)." >&2
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
    awk -v RANGEF="$SRV" -v RLO="$lo" -v RHI="$hi" -F'\t' -v OFS='\t' -v RNF="$RENAMES_FILE" "$RENAMES_AWK"'
    # THE PREFIX GATE (2026-09-27): a token can name a configured flow only when
    # its first 3 characters, upper-cased, open a configured name or an old
    # name of the rename map (the tail strip and the rename fold both keep the
    # token prefix) — exact, and off when a name is shorter than 3 characters
    BEGIN { rn_load(RNF); for (rk in RN_S) { CP3[substr(rk, 1, 3)] = 1; if (length(rk) < 3) GATE_OFF = 1 } }
    FILENAME ~ /\.configured\.tsv$/   { if ($1 == "_subscriptions") { conf[toupper($2)] = $2; CP3[toupper(substr($2, 1, 3))] = 1; if (length($2) < 3) GATE_OFF = 1 }; next }
    FILENAME ~ /_subscriptions\.tsv$/ { if ($2 != "") { conf[toupper($1)] = $1; CP3[toupper(substr($1, 1, 3))] = 1; if (length($1) < 3) GATE_OFF = 1 }; next }
    FILENAME ~ /\.sess\./             { scan[$1] = 1; next }
    FILENAME ~ /_sessionsites\.tsv$/  { old[$1] = $2; next }
    RANGEF != "" && FILENAME == RANGEF { _lo = _off; _off += length($0) + 1; if (_lo < RLO + 0) next; if (_lo >= RHI + 0) exit }
    {   # _parse.tsv: col 5 = message, col 6 = session
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
    ' "$CONFSRC" "$sess" /dev/null "$SRV" > "$tmp.part.$1"
}
pids=()
for ((pi = 1; pi <= NJ; pi++)); do scan_part "$pi" & pids+=("$!"); done
for p in "${pids[@]}"; do wait "$p"; done
awk -F'\t' -v OFS='\t' '
    FILENAME ~ /\.sess\./            { scan[$1] = 1; next }
    FILENAME ~ /_sessionsites\.tsv$/  { old[$1] = $2; next }
    { if (!($1 in seen) || seen[$1] == "") seen[$1] = $2; else if (seen[$1] != $2) seen[$1] = "-" }
    END {
        # scanned sessions take the fresh verdict (or lose their entry);
        # unscanned entries persist — they are what keeps a rescued group
        # attributed on the next full derive
        for (s in scan) if (seen[s] != "" && seen[s] != "-") nv[s] = seen[s]
        for (s in old)  if (!(s in scan)) nv[s] = old[s]
        for (s in nv) print s, nv[s]
    }
' "$sess" "$OLDMAP" "$tmp".part.* | LC_ALL=C sort > "$tmp"
rm -f "$tmp".part.*
printf "TIME %5ds  session-sites: server log scan (%d jobs)\n" "$(( $(date +%s) - _ss0 ))" "$NJ" >&2

n_scan=$(wc -l < "$sess" | tr -d ' ')
n_map=$(wc -l < "$tmp" | tr -d ' ')
if [ ! -s "$tmp" ] && [ ! -f "$OUT" ]; then
    echo "session-sites: $n_scan UCx session(s) scanned, none attributable — no map written." >&2
    exit 0
fi
if [ -f "$OUT" ] && cmp -s "$tmp" "$OUT"; then
    echo "session-sites: $n_scan UCx session(s) scanned, map unchanged ($n_map entry/-ies)." >&2
    exit 0
fi
mv "$tmp" "$OUT"
echo "session-sites: $n_scan UCx session(s) scanned, map now $n_map entry/-ies — re-deriving the transfer caches." >&2
# apply immediately: derive-only re-run (the manifest is untouched); the guard
# stops it re-entering this script, so one extra derive is the ceiling
AXWAY_SKIP_SESSIONS=1 "$ROOT/bin/transfer/parse.sh"
