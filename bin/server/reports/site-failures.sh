#!/usr/bin/env bash
#
# site-failures.sh — CONNECTION FAILURES per subscription, from the server
# log's "Connection failure while <SITE> tried to connect ..." ERROR messages.
# Server messages truncate long site names, so each logged token is resolved
# against the transfer subscription roster (subscription.rpt): the renamed or
# truncated spelling of a flow folds to its current name; a token matching no
# roster name (or several) is left out.
#
# Writes ONE sidecar, data/server/reports/site-failures.tsv —
#   subscription <TAB> newest failure stamp ("YYYY-MM-DD HH:MM:SS.mmm")
# — read by the box-reason producer (bin/build/reason-boxes.sh, the
# "connection" box). NO .rpt since 2026-09-29: the page went 2026-09-28 and
# its report (two tables, per-day buckets, the log-line drills) had no other
# reader — about 90 % of it was never read.
#
# Usage:
#   ./site-failures.sh    # reads the server cache + subscription.rpt
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib.sh"
mkdir -p "$REPORTS_DIR"
OUT="$REPORTS_DIR/site-failures.tsv"

TSITE="$TRANSFER_REPORTS/subscription.rpt"   # authoritative subscription list

shopt -s nullglob
files=("$INPUT_DIR"/*.csv)
shopt -u nullglob
if [ ${#files[@]} -eq 0 ]; then
    echo "No files matching '*.csv' found in '$INPUT_DIR'" >&2
    : > "$OUT"   # no data for this ENV: an empty sidecar
    exit 0
fi
if [ ! -f "$TSITE" ]; then
    echo "Transfer-site list not found: $TSITE — run the transfer reports first." >&2
    exit 1
fi
echo "Found ${#files[@]} file(s) in '$INPUT_DIR', processing..." >&2

LC_ALL=C awk -F'\t' -v RNF="$RENAMES_FILE" "$RENAMES_AWK"'
    BEGIN { rn_load(RNF) }
    # the token -> the roster name it counts under, ONCE per token (a renamed
    # or server-truncated spelling of one flow resolves to the same name)
    function resolve(t,   c, k, hits, full) {
        if (t in RES) return RES[t]
        c = rn_canon_pfx(t)
        if (c in known) return (RES[t] = c)
        hits = 0; full = ""
        for (k in known) if (index(k, c) == 1) { hits++; full = k; if (hits > 1) break }
        return (RES[t] = (hits == 1) ? full : "")
    }
    NR == FNR { if ($1 == "ROW" && !($2 in known)) { known[$2] = 1 } next }
    $3 != "E" { next }
    $5 !~ /^Connection failure while / { next }
    $1 !~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$/ { next }
    {
        m = substr($5, 26)                       # after "Connection failure while "
        # the site name may CONTAIN spaces ("Clone - UC3_..."): capture up to
        # the " tried to " delimiter, falling back to the first space
        sp = index(m, " tried to "); if (sp <= 1) sp = index(m, " ")
        if (sp <= 1) next
        tk = substr(m, 1, sp - 1)
        sub(/_(SS?|C)CP_.*$|_[A-Za-z0-9]+_(SERVER|CLIENT)_.*$/, "", tk)   # canonical subscription name (drop the _SCP_ / _SSCP_ / _CCP_ tail)
        nm = resolve(tk); if (nm == "") next
        st = $1 " " $2
        if (!(nm in NEW) || st > NEW[nm]) NEW[nm] = st
    }
    END { for (nm in NEW) print nm "\t" NEW[nm] }
' "$TSITE" "$PARSED" | LC_ALL=C sort > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"

echo "Data written to $OUT ($(wc -l < "$OUT" | tr -d ' ') subscription(s) with connection failures)." >&2
