#!/usr/bin/env bash
#
# subsets.sh — the SERVER-CACHE SUBSETS (2026-09-27, build-speed round 2).
#
# Several server reports each read the whole server cache (_parse.tsv, 3 GB
# in production) to act on a few RARE message families only, and spent most
# of their time skipping the rest. This
# step reads the cache ONCE, in parallel byte ranges (bin/ranges.sh), and
# copies every line that carries one of a consumer's MARKER strings into
# data/server/cache/subsets/<consumer>.tsv, verbatim and in cache order. The
# consumer then reads its subset instead of the cache (srv_subset in
# bin/server/lib.sh — which falls back to the whole cache when the subsets
# are missing).
#
# THE RULE THAT MAKES IT EXACT: a consumer's markers must be FIXED strings
# such that every cache line its awk acts on contains at least one of them
# (each is a literal piece of the regexes the consumer matches). A line
# without any is one the consumer skips without side effects, so dropping it
# changes nothing — the consumer's own tests still run on every kept line.
# CHANGE A CONSUMER'S MESSAGE PATTERNS -> CHANGE ITS MARKERS HERE. The
# markers are matched against the WHOLE line (a superset of the message).
#
# ONLY FOR RARE FAMILIES: round 2 also gave subsets to uc2/uc4-status,
# logon, ssh-crypto, auth-activity and inbound-connections — but their
# families (the SSH logon lines above all) are 20-45% of the production
# cache, so the step wrote 5 GB and cost as much CPU as it saved; those six
# read the whole cache again. A subset pays when it is a few % of the cache.
#
# Run by bin/server/reports.sh before its pool. No arguments.
#
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"
source "$SCRIPT_DIR/../ranges.sh"

# consumer <TAB> marker <TAB> marker ... (one consumer per line)
SPEC='uc1	Could not send file	An error occurred while sending	finished with error	Starting execution	Connection failure while 	listing files from partner
uc3	Applying the search pattern	listing files from partner 	Connection failure while 	Remote folder of transfer site: 	Remote files pattern of transfer site:
ssh-key-auth	no certificate is found for user	locked due to too many failed login	Publickey authentication
ssh-sessions	Channel is not active	No registered SSH session with ID	No SSH connection with ID	Network stream read/write error	Ignoring message for not active session
connection-diagnostics	Connection failure while 	could not be established	Error during test connection	Wrong server fingerprint: got	erforms test connection	ERFORMS TEST CONNECTION	erforms Test Connection
remote-poll	Applying the search pattern	listing files from partner 	Remote files pattern of transfer site	Connection failure while 	failure connecting to remote host '

SUBDIR="$CACHE_DIR/subsets"
rm -rf "$SUBDIR"; mkdir -p "$SUBDIR"
_t0=$(date +%s)

# the GATE: one regex over every marker — a line matching none (most of the
# cache) costs one test; the per-consumer index() checks run only on the rest.
# Built here, metacharacters escaped, and handed over via ENVIRON (a -v value
# would have its backslashes eaten).
SUBSET_GATE=$(printf '%s\n' "$SPEC" | cut -f2- | tr '\t' '\n' | LC_ALL=C sort -u \
    | sed 's/[][\\.^$*+?(){}|/]/\\&/g' | paste -sd'|' -)
export SUBSET_GATE SUBSET_SPEC="$SPEC"

SRV="$PARSED"
SRVSZ=$(wc -c < "$SRV" | tr -d ' ')
NJ=${AXWAY_NJOBS:-$( (command -v nproc >/dev/null 2>&1 && nproc) || sysctl -n hw.ncpu 2>/dev/null || echo 4 )}
case $NJ in ""|*[!0-9]*) NJ=4 ;; esac
part() {   # $1 = part index: its range of line starts is [lo, hi)
    local lo hi
    lo=$(rng_lo "$SRVSZ" "$NJ" "$1"); hi=$(rng_hi "$SRVSZ" "$NJ" "$1")
    rng_feed "$SRV" "$lo" | awk -v OUTP="$SUBDIR/" -v PART="$1" -v RANGEF=/dev/stdin -v RLO="$lo" -v RHI="$hi" -v ROFF="$(rng_off "$lo")" '
        BEGIN { G = ENVIRON["SUBSET_GATE"]
            nc = split(ENVIRON["SUBSET_SPEC"], L, "\n")
            for (i = 1; i <= nc; i++) { nm = split(L[i], F, "\t"); C[i] = F[1]; NM[i] = nm - 1
                for (j = 2; j <= nm; j++) MK[i, j - 1] = F[j] } }
        RANGEF != "" && FILENAME == RANGEF { if (!_rs) { _rs = 1; _off = ROFF + 0 } _lo = _off; _off += length($0) + 1; if (_lo < RLO + 0) next; if (_lo >= RHI + 0) exit }
        $0 ~ G {
            for (i = 1; i <= nc; i++) for (j = 1; j <= NM[i]; j++) if (index($0, MK[i, j])) {
                # through cat (2026-09-28, speed round 25): awk writes a regular
                # file in 4 KB chunks, ten parts at once; closed in END
                if (!(i in OC)) OC[i] = "cat > \"" OUTP C[i] ".p" PART "\""
                print | OC[i]; break }
        }
        END { for (i in OC) close(OC[i]) }' /dev/stdin
}
pids=()
for ((pi = 1; pi <= NJ; pi++)); do part "$pi" & pids+=("$!"); done
for p in "${pids[@]}"; do wait "$p"; done
# stitch each consumer's parts in RANGE order (= cache order)
printf '%s\n' "$SPEC" | cut -f1 | while IFS= read -r c; do
    : > "$SUBDIR/$c.tsv"
    for ((pi = 1; pi <= NJ; pi++)); do
        # an if, not `[ -f ] && …`: a part with no line for this consumer (the
        # LAST one — a config-only estate, a quiet tail range) made the loop
        # return 1 and set -e aborted the server reports (2026-09-28 fix)
        if [ -f "$SUBDIR/$c.p$pi" ]; then cat "$SUBDIR/$c.p$pi" >> "$SUBDIR/$c.tsv"; rm -f "$SUBDIR/$c.p$pi"; fi
    done
done
: > "$SUBDIR/.done"   # the set is complete (srv_subset reads it only then)
printf 'TIME %5ds  %s\n' "$(( $(date +%s) - _t0 ))" "server-cache subsets ($NJ jobs)" >&2
