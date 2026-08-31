#!/usr/bin/env bash
#
# tools/one-leg.sh — STANDALONE helper (2026-08-31, user request; split out
# of the former split-transfers.sh): from a raw SecureTransport transfer-log
# export (transferLog_*.csv, the files under input/<env>/transfer/) write
#
#   one_leg.csv   every CoreId that has exactly ONE leg (one record row);
#                 the output row is that single leg, verbatim.
#
# Runs under Git for Windows bash (plain bash + awk, no site libs, no GNU
# extensions); works the same on macOS/Linux. Handles quoted commas and CRLF
# line endings; the CoreId column is resolved BY HEADER NAME. The output gets
# the header row; several input files are treated as ONE data set. Written
# into the CURRENT directory, overwriting an existing one_leg.csv.
#
# Usage:
#   tools/one-leg.sh transferLog_06-23.csv [more.csv ...]
#
set -euo pipefail

if [ $# -lt 1 ]; then
    echo "usage: $(basename "$0") <transferLog.csv> [more.csv ...]" >&2
    exit 1
fi
for f in "$@"; do
    [ -f "$f" ] || { echo "$(basename "$0"): no such file: $f" >&2; exit 1; }
done

awk -v OUT="one_leg.csv" '
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
    {
        sub(/\r$/, "")                     # CRLF exports: strip the CR
        if (FNR == 1) {                    # every file carries a header row
            if (header == "") {
                header = $0
                n = split_csv($0)
                for (i = 1; i <= n; i++) if (trim(field[i]) == "CoreId") c_core = i
                if (!c_core) {
                    print "one-leg: header is missing CoreId" > "/dev/stderr"
                    exit 1
                }
            }
            next
        }
        if ($0 == "") next
        split_csv($0)
        core = trim(field[c_core])
        if (core == "" || core == "CoreId") next
        if (!(core in cnt)) { ord[++nc] = core; row[core] = $0 }
        cnt[core]++
    }
    END {
        print header > OUT
        n1 = 0
        for (i = 1; i <= nc; i++) { core = ord[i]
            if (cnt[core] == 1) { print row[core] > OUT; n1++ }
        }
        printf "one-leg: %d CoreId(s) in, %d -> one_leg.csv\n", nc, n1 > "/dev/stderr"
    }
' "$@"
