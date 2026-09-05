#!/usr/bin/env bash
#
# merge-duration-dwell.sh — MERGED report "Duration distribution & Store-and-
# forward" (2026-09-05, user request): the two clocks on the same Files on ONE
# page, their histograms SIDE BY SIDE — the wall-clock duration distribution
# (the whole trip, OK/All switch) on the left, the store-and-forward dwell
# distribution (the wait between the inbound and the outbound leg, one piece
# of that trip) on the right — then the dwell's other tables (by subscription,
# gap per day) below. The component .rpt files (duration-distribution.rpt,
# dwell-time.rpt) stay on disk as unpublished intermediates, like the other
# merged reports (bin/merge_rpt.sh) — but this merge REORDERS: the histograms
# must be adjacent with no NOTE between them (a NOTE block ends a side-by-side
# row in bin/render_rpt.awk), so each component's table NOTEs follow the pair.
#
#   TITLE/DESC/INTRO   composed here; the components' own INTRO texts (they
#                      carry the live figures) follow as two more paragraphs
#   the pair           duration-distribution's two switch tables + dwell-time's
#                      first table, each given the sxs modifier — the switch
#                      siblings share one column (render_rpt.awk, 2026-09-05)
#   the notes          duration-distribution's, then the dwell histogram's
#   the rest           dwell-time's remaining blocks in their own order
#                      (Dwell by subscription + note, the Gap-per-day INTRO +
#                      table + note), its SUMMARY, a fresh FOOT
#
# Usage:
#   ./merge-duration-dwell.sh   # -> data/<env>/transfer/reports/duration-dwell.rpt
#
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib.sh"
OUT="$REPORTS_DIR/duration-dwell.rpt"
DD="$REPORTS_DIR/duration-distribution.rpt"
DW="$REPORTS_DIR/dwell-time.rpt"
if [ ! -f "$DD" ] || [ ! -f "$DW" ]; then
    rm -f "$OUT"; echo "merge-duration-dwell: a component is missing ($DD / $DW) — skipped." >&2; exit 0
fi
skip_if_fresh "$OUT" "${BASH_SOURCE[0]}" "$DD" "$DW"

awk -F'\t' -v OFS='\t' -v now="$(date '+%Y-%m-%d %H:%M:%S')" '
    # Each component is read into blocks: intro[f] (the header INTRO), then per
    # table t: tab[f,t] (its TABLE line + body up to the next block), note[f,t]
    # (the NOTE lines that follow it), pre[f,t] (an INTRO paragraph placed
    # BEFORE table t — the dwell Gap-per-day section intro); summary[f].
    FNR == 1 { f++; t = 0 }
    $1 == "TITLE" || $1 == "DESC" || $1 == "KEYWORDS" || $1 == "FOOT" || $1 == "META" || $1 == "NAV" { next }
    $1 == "INTRO"   { if (t == 0) intro[f] = intro[f] (intro[f] == "" ? "" : "\n") $0; else pre[f, t + 1] = pre[f, t + 1] (pre[f, t + 1] == "" ? "" : "\n") $0; next }
    $1 == "SUMMARY" { summary[f] = $0; next }
    $1 == "TABLE"   { t++; ntab[f] = t; tab[f, t] = $0; next }
    $1 == "NOTE"    { if (t > 0) note[f, t] = note[f, t] (note[f, t] == "" ? "" : "\n") $0; next }
    t > 0           { tab[f, t] = tab[f, t] "\n" $0; next }
    { next }
    function sxs(block,   nl, first, rest, n2, A, i2, s2) {   # add the sxs modifier to the TABLE line of a table block (after the title cell)
        nl = index(block, "\n"); first = (nl ? substr(block, 1, nl - 1) : block); rest = (nl ? substr(block, nl) : "")
        n2 = split(first, A, "\t"); s2 = A[1] "\t" A[2] "\tsxs"
        for (i2 = 3; i2 <= n2; i2++) s2 = s2 "\t" A[i2]
        return s2 rest
    }
    function lcfirst(s,   body) { body = substr(s, index(s, "\t") + 1); return tolower(substr(body, 1, 1)) substr(body, 2) }
    END {
        print "TITLE", "Duration distribution & Store-and-forward"
        print "DESC", "Two clocks on the same Files, side by side: how long the whole trip takes (the wall-clock duration histogram) and how long a file waits inside SecureTransport between its inbound and outbound leg (the store-and-forward dwell), with the dwell per subscription and per day below."
        print "KEYWORDS", "duration,distribution,histogram,bands,buckets,dwell,store-and-forward,queue,latency,gap,wall-clock"
        print "INTRO", "Two clocks on the same Files. **Duration distribution** (left) is the whole trip: " lcfirst(intro[1])
        print "INTRO", "**Store-and-forward** (right) is one piece of that trip — the wait inside SecureTransport between the inbound leg completing and the outbound leg starting, which no other report measures: " lcfirst(intro[2])
        # the pair: the duration switch tables, then the dwell histogram
        for (i = 1; i <= ntab[1]; i++) print sxs(tab[1, i])
        print sxs(tab[2, 1])
        # their notes, below the pair
        for (i = 1; i <= ntab[1]; i++) if (note[1, i] != "") print note[1, i]
        if (note[2, 1] != "") print note[2, 1]
        # the rest of the dwell report as it was
        for (i = 2; i <= ntab[2]; i++) {
            if (pre[2, i] != "") print pre[2, i]
            print tab[2, i]
            if (note[2, i] != "") print note[2, i]
        }
        if (summary[2] != "") print summary[2]
        print "FOOT", "Generated on " now " from 2 component report(s)"
    }
' "$DD" "$DW" > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"
echo "Data written to $OUT ($(command grep -c '^TABLE' "$OUT") table(s))." >&2
