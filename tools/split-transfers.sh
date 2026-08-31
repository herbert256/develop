#!/usr/bin/env bash
#
# tools/split-transfers.sh — STANDALONE helper (2026-08-31, user request):
# split a raw SecureTransport transfer-log export (transferLog_*.csv, the
# same files that live under input/<env>/transfer/) into two CSVs, one row
# per CoreId, each output row being the COMPLETE input row:
#
#   one_leg.csv       every CoreId that has exactly ONE leg (one record row);
#                     the output row is that single leg.
#   uc2_waiting.csv   every CoreId whose LAST leg (by Start Time) is an
#                     Outbound leg with protocol 'routing'; the output row is
#                     that last leg.
#
# Runs under Git for Windows bash (plain bash + awk + sort, no site libs, no
# GNU extensions); works the same on macOS/Linux. Handles quoted commas and
# CRLF line endings; columns are resolved BY HEADER NAME (CoreId, Direction,
# Protocol, Start Time), so column reshuffles in the export do not break it.
# Both outputs get the header row and keep the input's row text verbatim
# (minus a trailing CR).
#
# Usage:
#   tools/split-transfers.sh transferLog_06-23.csv [more.csv ...]
#
# Several input files are treated as ONE data set (an export split over days
# still yields one row per CoreId). The two CSVs are written into the
# CURRENT directory, overwriting existing ones.
#
set -euo pipefail

if [ $# -lt 1 ]; then
    echo "usage: $(basename "$0") <transferLog.csv> [more.csv ...]" >&2
    exit 1
fi
for f in "$@"; do
    [ -f "$f" ] || { echo "$(basename "$0"): no such file: $f" >&2; exit 1; }
done

awk -v ONE="one_leg.csv" -v UC2="uc2_waiting.csv" '
    # ---- CSV field splitter (quoted commas, "" escapes) — the same logic
    # the site parser uses, so both read an export identically -------------
    function split_csv(line,    n, i, c, inquotes, cur) {
        delete field
        n = 0; cur = ""; inquotes = 0
        for (i = 1; i <= length(line); i++) {
            c = substr(line, i, 1)
            if (inquotes) {
                if (c == "\"") { if (substr(line, i+1, 1) == "\"") { cur = cur "\""; i++ } else inquotes = 0 }
                else cur = cur c
            } else {
                if (c == "\"") inquotes = 1
                else if (c == ",") { n++; field[n] = cur; cur = "" }
                else cur = cur c
            }
        }
        n++; field[n] = cur
        return n
    }
    function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
    # "MM/DD/YYYY HH:MM:SS.mmm" -> "YYYYMMDD HH:MM:SS.mmm" (string-sortable);
    # an unparsable stamp sorts first, so a real one always beats it
    function timekey(s,    d, t, p) {
        split(trim(s), p, " "); d = p[1]; t = (2 in p) ? p[2] : ""
        if (split(d, D, "/") != 3) return ""
        return sprintf("%04d%02d%02d %s", D[3], D[1], D[2], t)
    }
    {
        sub(/\r$/, "")                     # CRLF exports: strip the CR
        if (FNR == 1) {                    # every file carries a header row
            if (header == "") {
                header = $0
                n = split_csv($0)
                for (i = 1; i <= n; i++) {
                    h = trim(field[i])
                    if      (h == "CoreId")     c_core = i
                    else if (h == "Direction")  c_dir  = i
                    else if (h == "Protocol")   c_prot = i
                    else if (h == "Start Time") c_time = i
                }
                if (!c_core || !c_dir || !c_prot || !c_time) {
                    print "split-transfers: header is missing CoreId / Direction / Protocol / Start Time" > "/dev/stderr"
                    exit 1
                }
            }
            next
        }
        if ($0 == "") next
        n = split_csv($0)
        core = trim(field[c_core])
        if (core == "" || core == "CoreId") next
        cnt[core]++
        if (!(core in ord)) { ord[++nc] = core }
        # the LAST leg by Start Time (ties: the first row seen at that time)
        k = timekey(field[c_time])
        if (!(core in bestk) || k > bestk[core]) {
            bestk[core] = k
            lastrow[core]  = $0
            lastdir[core]  = trim(field[c_dir])
            lastprot[core] = trim(field[c_prot])
        }
    }
    END {
        print header > ONE
        print header > UC2
        n1 = 0; n2 = 0
        for (i = 1; i <= nc; i++) { core = ord[i]
            if (cnt[core] == 1) { print lastrow[core] > ONE; n1++ }
            if (tolower(lastdir[core]) == "outbound" && tolower(lastprot[core]) == "routing") {
                print lastrow[core] > UC2; n2++
            }
        }
        printf "split-transfers: %d CoreId(s) in, %d -> one_leg.csv, %d -> uc2_waiting.csv\n", nc, n1, n2 > "/dev/stderr"
    }
' "$@"
