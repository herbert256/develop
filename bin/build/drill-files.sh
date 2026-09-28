#!/usr/bin/env bash
#
# drill-files.sh — the FIRST CoreId of every RED or ORANGE drill cell
# (2026-09-21, user request): a count cell that expands to its newest Files
# (the click-to-expand drill, report.js bindDrill) links the FIRST File of the
# list to that File's own page, docs/files/<coreid>.html, whenever the cell is
# red or orange — so that page has to exist. This step collects those CoreIds
# from the transfer .rpt tree into ONE sidecar, and failed.sh — the writer of
# every File page — unions it with its Transfer patterns / Longest Files /
# latest-OK lists (tag D, no back link).
#
# A drill list counts when the CELL it opens under is — or can turn — red or
# orange:
#   @data:coreids-failed                     the Error cell of the row (red)
#   @data:coreids-retry / -resubmit          the Retry / Resubmit cells (orange)
#   @data:coreids-<key>, the table's drillcols=<key>:<col> modifier
#   @data:drill-cell-<col>                   (the Duration per-day tables)
#       -> the class of the row's cell at <col>: its column KIND (failed,
#          numfailed, numerr = red; numwarn = orange) plus the cell's own
#          @{class=…} (failed, errc, warn, dur-m, dur-h) — and ANY cell of a
#          Duration percentile column (RECALC token P…), which report.js
#          retints green / amber / red for the selected date range
# Never: a table whose drill unit is not the File (the `drill=transfer` leg
# tables — their lists carry TRANSFER ids, no page is keyed by one), the OK
# lists (coreids-processed), the whole-ROW lists (coreids — a
# row, not a cell), the server reports' log-line drills — and the nine CLASSIC
# entity writers (<name>.rpt beside entities/<name>.rpt): they stay on disk as
# DATA producers but render no page, so a File only THEY list first would get
# a page nothing links.
#
# The rule is a SUPERSET of what the browser links (it decides by the cell's
# class at click time), so a linked first File always has its page. The drill
# lists are full-period — a date range never changes them — so the first
# entry of a list is fixed at build time.
#
# Runs in bin/build.sh right BEFORE the failed.sh catch-up: every report of
# the build is on disk by then (the detail-pages catch-up after it re-reads
# the same _files.tsv, so its lists do not move).
#
# Reads   data/transfer/reports/**/*.rpt   (not errors/ + files/: those ARE the pages)
# Writes  data/transfer/reports/_drill-files.tsv   one CoreId per line, sorted
#
# Usage:
#   bin/build/drill-files.sh
#
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../transfer/lib.sh"
OUT="$REPORTS_DIR/_drill-files.tsv"

# the classic entity writers: every top-level <name>.rpt that has a grouped
# entities/<name>.rpt twin (the published one) — skipped by path below
CLASSIC=""
for _e in "$REPORTS_DIR"/entities/*.rpt; do
    [ -f "$_e" ] && CLASSIC="$CLASSIC $REPORTS_DIR/${_e##*/}"
done

find "$REPORTS_DIR" -name '*.rpt' -not -path "$REPORTS_DIR/errors/*" -not -path "$REPORTS_DIR/files/*" -print0 2>/dev/null \
    | LC_ALL=C xargs -0 awk -v CLASSIC="$CLASSIC" -F'\t' '
    BEGIN { US = sprintf("%c", 31)
            nc9 = split(CLASSIC, c9, " "); for (i = 1; i <= nc9; i++) if (c9[i] != "") SKIPP[c9[i]] = 1
            # the UUID shape (8-4-4-4-12 hex), spelled out — no interval
            # expressions, they are not portable across awks
            H4 = "[0-9a-f][0-9a-f][0-9a-f][0-9a-f]"
            UUID = H4 H4 "-" H4 "-" H4 "-" H4 "-" H4 H4 H4 }
    # the first CoreId of a drill list: its first entry (sep = the list
    # separator), the first UUID in it
    function first(v, sep,   p) {
        p = index(v, sep); if (p > 0) v = substr(v, 1, p - 1)
        return match(v, UUID) ? substr(v, RSTART, RLENGTH) : "" }
    # is the row cell at BUILT column c (0-based) red or orange — or a
    # Duration percentile cell, which the date filter retints
    function redorange(c,   k, cell, cl, p) {
        if (c < 0) return 0
        if ((c in RC) && RC[c] ~ /^P/) return 1
        k = (c in KD) ? KD[c] : ""
        if (k == "failed" || k == "numfailed" || k == "numerr" || k == "numwarn") return 1
        cell = $(c + 2)
        if (substr(cell, 1, 2) != "@{") return 0
        p = index(cell, "}"); if (p == 0) return 0
        cl = " " substr(cell, 3, p - 3) " "; gsub(/,/, " ", cl); sub(/ class=/, " ", cl)
        return (cl ~ / (failed|errc|warn|dur-m|dur-h) /) }
    FNR == 1 { SKIPF = (FILENAME in SKIPP) }
    SKIPF { next }
    FNR == 1 || $1 == "TABLE" { split("", KD); split("", RC); split("", DC); LEGT = 0 }
    $1 == "TABLE" {
        # drill=<unit>: anything but the File (default) lists ids that are no CoreIds
        for (i = 2; i <= NF; i++) if (index($i, "drill=") == 1 && substr($i, 7) != "" && substr($i, 7) != "File") LEGT = 1
        for (i = 2; i <= NF; i++) if (index($i, "drillcols=") == 1) {
            n = split(substr($i, 11), a, ",")
            for (j = 1; j <= n; j++) { m = split(a[j], b, ":"); if (m >= 2 && b[1] != "") DC[b[1]] = b[2] + 0 } }
        next }
    $1 == "KIND"   { for (i = 2; i <= NF; i++) KD[i - 2] = $i; next }
    $1 == "RECALC" { for (i = 2; i <= NF; i++) RC[i - 2] = $i; next }
    $1 != "ROW" || LEGT { next }
    {   for (i = 2; i <= NF; i++) {
            if (index($i, "@data:coreids-") == 1) {
                p = index($i, "="); if (p == 0) continue
                key = substr($i, 15, p - 15); v = substr($i, p + 1)
                if (v == "" || v == "-" || key == "processed") continue
                if (key == "failed" || key == "retry" || key == "resubmit" || ((key in DC) && redorange(DC[key]))) {
                    c = first(v, ","); if (c != "") print c }
            } else if (index($i, "@data:drill-cell-") == 1) {
                p = index($i, "="); if (p == 0) continue
                col = substr($i, 18, p - 18); v = substr($i, p + 1)
                if (v != "" && col ~ /^[0-9]+$/ && redorange(col + 0)) { c = first(v, US); if (c != "") print c }
            }
        }
    }' | LC_ALL=C sort -u > "$OUT.tmp" || true

mv "$OUT.tmp" "$OUT"
echo "drill-files: $(wc -l < "$OUT" | tr -d ' ') first File(s) of the red / orange drill cells listed in $OUT." >&2
