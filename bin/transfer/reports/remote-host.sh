#!/usr/bin/env bash
#
# remote-host.sh
#
# Per-remote-host report — Files per remote host (the OUTBOUND endpoint,
# _transfers.tsv col 16 — there is no reverse DNS). A remote host is a per-row attribute (the
# Inbound source host and the Outbound destination host differ), so a transfer
# is counted once per DISTINCT remote host it involves; the per-host counts can
# therefore sum to more than the number of distinct transfers. Failed /
# Processed is the transfer's delivered (final-row) outcome. ONE table, one
# ROW per remote host — the account.sh record (name · Files · Error · OK ·
# newest Error / OK File start; trimmed 2026-09-29 to what its readers use).
# NO PAGE of its own: the Entities pages render from entities.sh's grouped
# entities/remote-host.rpt (2026-09-13); this .rpt is read by showseen.sh,
# entity-search.sh and the server rosters (known_names: the ROW names). (The
# "Detail per Remote Host / Date" table went 2026-09-29: no reader.)
#
# Usage:
#   ./remote-host.sh    # reads input/*.csv (via the caches), writes data/remote-host.rpt
#
# Requirements: bash, awk (mawk/gawk/POSIX awk all work), sort.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib.sh"
mkdir -p "$REPORTS_DIR"
OUT="$REPORTS_DIR/remote-host.rpt"


shopt -s nullglob
files=("$INPUT_DIR"/*.csv)
shopt -u nullglob
if [ ${#files[@]} -eq 0 ]; then
    echo "No *.csv in $INPUT_DIR — building from the EMPTY caches (config-only estate)" >&2
fi
echo "Found ${#files[@]} file(s) in '$INPUT_DIR', processing..." >&2

# ---------------------------------------------------------------------------
# Two-pass join. Pass 1 (data/_files.tsv) loads per dated CoreId the logical
# outcome (2) and its start as "sortkey SUBSEP date time" (6, 4 5), and marks
# the Files that connect OUT (16). Pass 2 (data/_transfers.tsv) walks the rows;
# for each distinct (host, CoreId) pair — so a transfer is counted at most
# once per remote host — it counts the File into that host, split Error/OK by
# the delivered outcome, and keeps the newest Error / OK File start (see
# account.sh for the record). Rows with no host (blacklist-blanked internal
# nodes) or whose transfer has no valid date are skipped. Column 16 is the
# endpoint as parse.sh resolved it (the input/ip forward map — never reverse
# DNS).
# ---------------------------------------------------------------------------
LAST_AWK='
    function newest(k, v) { if (!(k in LT) || v > LT[k]) LT[k] = v }
    function lastts(k,   s, c) { if (!(k in LT)) return ""; s = LT[k]; s = substr(s, index(s, SUBSEP) + 1) "  "
        c = index(s, ","); if (c) s = substr(s, 1, c - 1); c = index(s, "  "); return c ? substr(s, 1, c - 1) : s }
'
agg=$(awk -F'\t' "$LAST_AWK"'
    FNR == 1 { fno++ }
    fno == 1 { if ($16 == "out") cout[$1] = 1
               if ($4 != "") { fe[$1] = ($2 == "Failed" || $2 == "Expired"); fk[$1] = $6 SUBSEP $4 " " $5 }; next }
    $16 == "" { next }
    # A HOST entity is an OUTBOUND endpoint only — the hosts we dial (the
    # partners.json hosts[] of Out accounts). The source addresses of INCOMING
    # connections are NOT hosts (they belong to the whitelist/incoming views:
    # the incoming-connections report and the detail pages 2.6 tables), so a
    # row whose File connects IN (or has no side) never attributes a host.
    !($1 in cout) { next }
    {
        e = $16; cid = $1; pk = e SUBSEP cid
        if (pk in pseen) next                         # count each transfer once per remote host
        pseen[pk] = 1
        if (!(cid in fk)) next                        # no valid date
        sc[e]++
        if (fe[cid]) { sfl[e]++; newest("F" SUBSEP e, fk[cid]) } else { spr[e]++; newest("P" SUBSEP e, fk[cid]) }
    }
    END { for (e in sc) printf "S|%s|%d|%d|%d|%s|%s\n", e, sc[e], sfl[e]+0, spr[e]+0, lastts("F" SUBSEP e), lastts("P" SUBSEP e) }
' "$FILES" "$PARSED")

# The rows, busiest first (by File count).
summary_rows=$({ printf '%s\n' "$agg" | grep '^S|' || true; } | sort -t'|' -k3,3nr | awk -F'|' '
    $2 == "" { next }
    { printf "ROW\t%s\t%s\t%s\t%s\t%s\t%s\n", $2, $3, $4, $5, $6, $7 }')

{
    printf 'TITLE\tHosts\n'   # the Entities › Hosts label; a data producer, its page renders from entities/remote-host.rpt
    printf 'TABLE\tSummary per Remote Host\n'
    printf 'HEAD\tRemote Host\tFiles\tError\tOK\tLast Error\tLast OK\n'
    [ -n "$summary_rows" ] && printf '%s\n' "$summary_rows"
    printf 'FOOT\n'
} > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"

echo "Data written to $OUT ($(printf '%s\n' "$summary_rows" | grep -c '^ROW' || true) host(s))." >&2
