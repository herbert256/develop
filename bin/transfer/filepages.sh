#!/usr/bin/env bash
#
# filepages.sh — THE PUBLISHED FILE PAGES (2026-09-29, user request:
# "docs/files/ — store only the last OK of a subscription, store only the last
# 3 errors of a subscription"). Writes data/transfer/cache/_filepages.tsv:
#
#   CoreId <TAB> kind <TAB> subscription
#     O   the subscription's newest DELIVERED File (outcome Processed; newest
#         by its END, _files.tsv col 24, else its start — the "Latest OK" rule
#         of the detail pages)
#     E   one of the subscription's THREE newest FAILED Files (by the start
#         sortkey, col 6, newest first; Expired Files are pickup problems,
#         never paged)
#
# per _files.tsv col 12 value ("Unknown" included). This is the ONE list of
# the CoreIds that have a docs/files/<CoreId>.html page: bin/transfer/publish.sh
# renders exactly these (+ the subscription-named server-log error pages), and
# every writer that links a File page tests membership here — failed.sh's
# lists, failed-files, unknown-transfers, io-errors, patterns, Longest Files,
# the Expired / Waiting pages, the all files search and (through render_rpt's
# data-fp row attribute) the drill cells. failed.sh still WRITES its evidence
# pages for every File it classifies (the reasons read them); only this set
# is published. A pure function of _files.tsv — run by bin/build.sh right
# after bookend-ok, when the outcomes are final, before any reader.
#
# Usage:  bin/transfer/filepages.sh
#
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"
OUT="$CACHE_DIR/_filepages.tsv"
if [ ! -s "$FILES" ]; then : > "$OUT"; echo "filepages: no transfer cache — no File pages." >&2; exit 0; fi
{
    # O: the newest Processed File per subscription (strictly newer END wins,
    # the first one on a tie — failed.sh's former latest-OK list, verbatim)
    LC_ALL=C awk -F'\t' '$12 != "" && $2 == "Processed" {
            e = ($24 != "" ? $24 : $4 " " $5)
            if (!($12 in K) || e > K[$12]) { K[$12] = e; C[$12] = $1 } }
        END { for (s in K) print C[s] "\tO\t" s }' "$FILES"
    # E: the three newest Failed Files per subscription — the newest-first
    # order of failed.sh's list stream (a C-locale reverse sort of
    # sortkey<TAB>CoreId<TAB>…)
    LC_ALL=C awk -F'\t' -v OFS='\t' '$12 != "" && $2 == "Failed" { print $6, $1, $12 }' "$FILES" \
        | LC_ALL=C sort -r \
        | LC_ALL=C awk -F'\t' '++n[$3] <= 3 { print $2 "\tE\t" $3 }'
} | LC_ALL=C sort -u > "$OUT.tmp"
mv "$OUT.tmp" "$OUT"
echo "filepages: $(awk -F'\t' '$2 == "O"' "$OUT" | wc -l | tr -d ' ') latest-OK + $(awk -F'\t' '$2 == "E"' "$OUT" | wc -l | tr -d ' ') error File page(s)." >&2
