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
# Usage:  bin/session-sites.sh      (env from $AXWAY_ENV, default production)
#
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$ROOT/bin/fastawk.sh"   # route unqualified `awk` to mawk when installed
source "$ROOT/bin/env.sh"       # resolve $AXWAY_ENV (acceptance|production, default production)
source "$ROOT/bin/renames.sh"   # RENAMES_FILE + RENAMES_AWK (rn_canon: old name -> current)

DATA="$ROOT/data/$AXWAY_ENV"
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
trap 'rm -f "$tmp" "$sess"' EXIT
OLDMAP="$OUT"; [ -f "$OUT" ] || OLDMAP=/dev/null

# the sessions to (re)scan: every session a currently-UCx leg ran over
awk -F'\t' '$6 ~ /^UCx_/ && $24 != "" { print $24 }' "$PARSED" | LC_ALL=C sort -u > "$sess"
if [ ! -s "$sess" ]; then
    echo "session-sites: no UCx rows — nothing to learn (map kept)." >&2
    exit 0
fi

awk -F'\t' -v OFS='\t' -v RNF="$RENAMES_FILE" "$RENAMES_AWK"'
    BEGIN { rn_load(RNF) }
    FILENAME ~ /\.configured\.tsv$/   { if ($1 == "_subscriptions") conf[toupper($2)] = $2; next }
    FILENAME ~ /_subscriptions\.tsv$/ { if ($2 != "") conf[toupper($1)] = $1; next }
    FILENAME ~ /\.sess\./             { scan[$1] = 1; next }
    FILENAME ~ /_sessionsites\.tsv$/  { old[$1] = $2; next }
    {   # _parse.tsv: col 5 = message, col 6 = session
        if (!($6 in scan)) next
        m = $5
        # every name-shaped token, not only UC-prefixed ones (2026-08-31
        # audit): the production hybrid flows carry no UC prefix, so the
        # former UC[0-9]+_ pre-filter made this step blind to exactly the
        # groups it exists to rescue. The configured-set test below is the
        # real guard; the shape only bounds the scan. A logged _SCP_ tail is
        # stripped first, as the transfer parse does.
        while (match(m, /[A-Za-z][A-Za-z0-9_-]*[_-][A-Za-z0-9_-]+/)) {
            t = substr(m, RSTART, RLENGTH); m = substr(m, RSTART + RLENGTH)
            sub(/_(SS?|C)CP_.*$/, "", t)
            t = rn_canon(t)
            if (toupper(t) in conf) {
                t = conf[toupper(t)]                       # the export own spelling
                if (seen[$6] == "") seen[$6] = t
                else if (seen[$6] != t) seen[$6] = "-"     # two flows -> no verdict
            }
        }
    }
    END {
        # scanned sessions take the fresh verdict (or lose their entry);
        # unscanned entries persist — they are what keeps a rescued group
        # attributed on the next full derive
        for (s in scan) if (seen[s] != "" && seen[s] != "-") nv[s] = seen[s]
        for (s in old)  if (!(s in scan)) nv[s] = old[s]
        for (s in nv) print s, nv[s]
    }
' "$CONFSRC" "$sess" "$OLDMAP" "$SRV" | LC_ALL=C sort > "$tmp"

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
