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
# A marker written "~text" matches CASE-INSENSITIVELY (text lowercase): for a
# consumer that lower-cases the message before matching, where a list of
# casings would miss any other one (its one user, connection-diagnostics'
# tolower(m) ~ /performs test connection/, went 2026-09-30 with the
# Connections page — no SPEC line uses it now).
#
# ONLY FOR RARE FAMILIES: round 2 also gave subsets to uc2/uc4-status,
# logon, ssh-crypto, auth-activity and inbound-connections (gone 2026-09-30) — but their
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
#   poll        the UC3 polling families — uc3-status, remote-poll,
#               no-remote-dir, no-remote-files (2026-09-30: ONE subset for the
#               former uc3 + remote-poll pair, 45 % of the cache each and 72
#               lines apart — every consumer acts only on lines holding one of
#               ITS markers, and those are all here)
#   event-queue event-queue (the PeSIT AgentEvent submit failures)
#   site-failures  site-failures.sh (the E-level "Connection failure while"
#               lines; the connection-diagnostics subset until 2026-09-30 —
#               its other three markers served the removed Connections page)
#   (MEASURED, NOT WORTH IT — 2026-09-30, single job on an 8x sample cache:
#   an "inbound" subset for the former inbound-connections ("had initiated a connection
#   over ", ~4-10 % of the cache) cost +1.0 CPU-s in this pass to save 0.3;
#   a "day" subset for bin/day/reports.sh day_srv's problem signals — twelve
#   short markers like "is locked" / "Login failed" in the gate — cost +2.6 to
#   save 1.1. The gate regex runs on every character of every line: only
#   long, rare markers pay.)
#   (deploy-errors keeps "Applying the search pattern": its UC3 poll-recovery
#   clear reads the poll lines, 2026-09-30 audit C-10 checked)
SPEC='uc1	Could not send file	An error occurred while sending	finished with error	Connection failure while 	listing files from partner
poll	Applying the search pattern	listing files from partner 	Connection failure while 	Remote folder of transfer site: 	Remote files pattern of transfer site	failure connecting to remote host 
ssh-sessions	Channel is not active	No registered SSH session with ID	No SSH connection with ID	Network stream read/write error	Ignoring message for not active session
site-failures	Connection failure while 
deploy-errors	Applying the search pattern	is used for incoming transfer	stop further route execution
routing-errors	Could not send file	while publishing the file	post client action	stop further route execution
event-queue	[Pesit Default] Unable to submit event AgentEvent'
# + TWO RULE SUBSETS (2026-09-29, speed round 3), outside the marker gate —
# (and, since 2026-09-30, the COUNTS table: counts.tsv, one line per
#   C <TAB> date <TAB> hour <TAB> level <TAB> component <TAB> count
#   T <TAB> date <TAB> first time <TAB> last time
# over EVERY cache line — the per-day / per-hour / level / component figures
# the server Top view (topview.sh) and the levels per component
# (errors-day.sh) each counted in a full pass of their own. date = field 1
# when it starts yyyy- (else "": the line counts for errors-day's totals
# only); hour = the first two characters of field 2 when they are digits,
# else "00"; T only for a valid date and a non-empty time, min / max as
# STRINGS (topview's rule).)
# every alternative in the gate regex is paid on every character of every
# line, and case-insensitive markers the most (they cost +40 % of this pass):
#   noninfo    every line whose level (field 3) is not I — ~2 % of the
#              production cache (199k of 11.3M) — for the reports that act on
#              Warning / Error lines only: top-messages ($3 == "I" -> next),
#              error-timing (W / E), error-reasons and failure-flows (E); a
#              LEVEL test (a marker cannot hold the TAB around the field)
#   io-errors  io-errors.sh's own regex, behind a plain index() of "rror"
#              (every line it can match holds one) — the case-insensitive
#              "io error" / "input/output error" as gate markers doubled the
#              gate's cost
SPEC_EXTRA='noninfo
io-errors'

SUBDIR="$CACHE_DIR/subsets"
rm -rf "$SUBDIR"; mkdir -p "$SUBDIR"
_t0=$(date +%s)

# the GATE: one regex over every marker — a line matching none (most of the
# cache) costs one test; the per-consumer regexes run only on the rest.
# Built here, metacharacters escaped (a "~" marker's letters as [xX] pairs),
# and handed over via ENVIRON (a -v value would have its backslashes eaten).
SUBSET_GATE=$(printf '%s\n' "$SPEC" | cut -f2- | tr '\t' '\n' | LC_ALL=C sort -u \
    | awk '{ ci = (substr($0, 1, 1) == "~"); s = ci ? substr($0, 2) : $0; o = ""
             for (i = 1; i <= length(s); i++) { c = substr(s, i, 1)
                 if (ci && c ~ /[A-Za-z]/) o = o "[" tolower(c) toupper(c) "]"
                 else if (index("][\\.^$*+?(){}|/", c)) o = o "\\" c
                 else o = o c }
             print o }' | paste -sd'|' -)
export SUBSET_GATE SUBSET_SPEC="$SPEC"

SRV="$PARSED"
SRVSZ=$(wc -c < "$SRV" | tr -d ' ')
NJ=${AXWAY_NJOBS:-$( (command -v nproc >/dev/null 2>&1 && nproc) || sysctl -n hw.ncpu 2>/dev/null || echo 4 )}
case $NJ in ""|*[!0-9]*) NJ=4 ;; esac
part() {   # $1 = part index: its range of line starts is [lo, hi)
    local lo hi
    lo=$(rng_lo "$SRVSZ" "$NJ" "$1"); hi=$(rng_hi "$SRVSZ" "$NJ" "$1")
    rng_feed "$SRV" "$lo" | awk -v OUTP="$SUBDIR/" -v PART="$1" -v RANGEF=/dev/stdin -v RLO="$lo" -v RHI="$hi" -v ROFF="$(rng_off "$lo")" '
        # per consumer ONE regex of its markers, built once (2026-09-30, lean
        # round 3b: the per-line loop of ~30 index() calls with two-key
        # lookups, plus a tolower($0) copy for the "~" marker, was 2/3 of this
        # pass) — the letters of a "~" marker as [xX] pairs, the rest escaped
        # with the set the GATE uses, so the regex of a consumer matches exactly
        # the lines one of its markers is in (ASCII case folding, as tolower did)
        function rex(m, ci,   o, k, c) { o = ""; for (k = 1; k <= length(m); k++) { c = substr(m, k, 1)
                if (ci && c ~ /[A-Za-z]/) o = o "[" tolower(c) toupper(c) "]"
                else if (index("][\\.^$*+?(){}|/", c)) o = o "\\" c
                else o = o c }
            return o }
        BEGIN { G = ENVIRON["SUBSET_GATE"]
            nc = split(ENVIRON["SUBSET_SPEC"], L, "\n")
            for (i = 1; i <= nc; i++) { nm = split(L[i], F, "\t"); C[i] = F[1]; CRE[i] = ""
                for (j = 2; j <= nm; j++) {
                    ci = (substr(F[j], 1, 1) == "~")
                    CRE[i] = CRE[i] (j > 2 ? "|" : "") rex(ci ? tolower(substr(F[j], 2)) : F[j], ci) } } }
        RANGEF != "" && FILENAME == RANGEF { if (!_rs) { _rs = 1; _off = ROFF + 0 } _lo = _off; _off += length($0) + 1; if (_lo < RLO + 0) next; if (_lo >= RHI + 0) exit }
        $0 ~ G {
            for (i = 1; i <= nc; i++) if ($0 ~ CRE[i]) {
                # through cat (2026-09-28, speed round 25): awk writes a regular
                # file in 4 KB chunks, ten parts at once; closed in END
                if (!(i in OC)) OC[i] = "cat > \"" OUTP C[i] ".p" PART "\""
                print | OC[i] }
        }
        # the RULE subsets (see SPEC_EXTRA), on every line
        {   # the four leading fields (date, time, level, component) from the
            # head of the line — the message may be long; a head that does
            # not reach the message falls back to the whole line
            n9 = split(substr($0, 1, 120), F9, "\t"); if (n9 < 5) split($0, F9, "\t")
            # COUNTS (see the header): date / hour / level / component
            d9 = substr(F9[1], 1, 10); if (d9 !~ /^[0-9][0-9][0-9][0-9]-/) { d9 = ""; h9 = "" }
            else { h9 = substr(F9[2], 1, 2); if (h9 !~ /^[0-9][0-9]$/) h9 = "00"
                   t9 = F9[2]; if (t9 != "") { if (!(d9 in TF) || t9 < TF[d9]) TF[d9] = t9; if (!(d9 in TL) || t9 > TL[d9]) TL[d9] = t9 } }
            CNT[d9 "\t" h9 "\t" F9[3] "\t" F9[4]]++
            # noninfo: field 3 is not "I"
            if (F9[3] != "I") { if (NIC == "") NIC = "cat > \"" OUTP "noninfo.p" PART "\""; print | NIC }
            # io-errors: its regex (io-errors.sh, on the message) over the line
            if (index($0, "rror") && $0 ~ /[Ii][Oo] [Ee]rror|[Ii]nput\/[Oo]utput [Ee]rror/) {
                if (IOC == "") IOC = "cat > \"" OUTP "io-errors.p" PART "\""; print | IOC }
        }
        END { for (i in OC) close(OC[i]); if (NIC != "") close(NIC); if (IOC != "") close(IOC)
              for (k in CNT) print "C\t" k "\t" CNT[k] > (OUTP "counts.p" PART)
              for (d in TF) print "T\t" d "\t" TF[d] "\t" TL[d] > (OUTP "counts.p" PART)
              close(OUTP "counts.p" PART) }' /dev/stdin
}
pids=()
for ((pi = 1; pi <= NJ; pi++)); do part "$pi" & pids+=("$!"); done
for p in "${pids[@]}"; do wait "$p"; done
# the COUNTS table: every part's counters summed, the first / last times
# folded (string min / max), sorted — no hash-order dependence
: > "$SUBDIR/counts.tsv.tmp"
for ((pi = 1; pi <= NJ; pi++)); do
    if [ -f "$SUBDIR/counts.p$pi" ]; then cat "$SUBDIR/counts.p$pi" >> "$SUBDIR/counts.tsv.tmp"; rm -f "$SUBDIR/counts.p$pi"; fi
done
LC_ALL=C awk -F'\t' -v OFS='\t' '
    $1 == "C" { k = $2 OFS $3 OFS $4 OFS $5; C[k] += $6; next }
    $1 == "T" { if (!($2 in TF) || ($3 "") < TF[$2]) TF[$2] = $3; if (!($2 in TL) || ($4 "") > TL[$2]) TL[$2] = $4 }
    END { for (k in C) print "C", k, C[k]; for (d in TF) print "T", d, TF[d], TL[d] }' "$SUBDIR/counts.tsv.tmp" \
    | LC_ALL=C sort > "$SUBDIR/counts.tsv"
rm -f "$SUBDIR/counts.tsv.tmp"
# stitch each consumer's parts in RANGE order (= cache order)
{ printf '%s\n' "$SPEC" | cut -f1; printf '%s\n' "$SPEC_EXTRA"; } | while IFS= read -r c; do
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
