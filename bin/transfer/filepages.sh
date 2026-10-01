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
#     L   one of the LONGEST FILES (2026-09-30, user request: "Show 250 and
#         not 50 files, store all 250 files in /files/, show max 10 rows of
#         the same subscription"): the LONGEST_N (250) longest DELIVERED
#         Files (outcome Processed, dur_ms col 9 > 0) by wall-clock duration,
#         at most LONGEST_PER_SUB (10) per subscription (col 12; an empty one
#         is one group), ms descending, CoreId ascending on a tie — THE
#         selection: bin/transfer/reports/duration-longest.sh lists exactly
#         these rows, it does not select again
#     U   every dated File of the "Unknown" subscription (2026-10-01, user
#         request: "every row of unknown-transfers must have an entry in
#         /files/, the complete row must link to it") — the Unknown transfers
#         Files table lists exactly these (col 12 == "Unknown", col 4 set)
#     P   every ONE-LEGGED File of a real subscription (col 10 == 1, col 12
#         set and not "Unknown"; 2026-10-01, user request) — the rows of the
#         per-subscription One-legged pages transfer/pirates/<slug>.html
#         (pirates.sh), each opening its File page
#     R   every dated File with a RESUBMITTED leg (col 27 == "1", col 4 set;
#         2026-10-01, user request: "docs/resubmit/<day>.html — all rows must
#         have a file in /files/, the complete row must link to it") — the
#         rows of the Top view's day lists docs/resubmit/<date>.html
#         (topview.sh), whatever the File's outcome
#     A   the AUTOMATICALLY RECOVERED Files (an OK File — not Failed / Expired
#         — with a failed leg, col 26, and no resubmitted leg; the Top view's
#         Recovered › Automatic rule): the RECOVERED_PER_SUB (5) newest per
#         START DAY and subscription (col 4 + col 12, an empty subscription is
#         one group; sortkey descending, CoreId ascending on a tie — the order
#         of the page), 2026-10-01, user request: "docs/recovered/<day>.html —
#         the first 5 rows of every subscription must have a file in /files/"
#         — THE selection: topview.sh links exactly the listed rows, it does
#         not select again
#
# per _files.tsv col 12 value ("Unknown" included). This is the ONE list of
# the CoreIds that have a docs/files/<CoreId>.html page: bin/transfer/publish.sh
# renders exactly these (+ the subscription-named server-log error pages), and
# every writer that links a File page tests membership here — failed.sh's
# lists, failed-files, unknown-transfers, io-errors, patterns, Longest Files,
# the Expired / Waiting pages, the Top view's resubmit / recovered day lists,
# the all files search and (through render_rpt's data-fp row attribute) the
# drill cells. failed.sh still WRITES its evidence
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
LONGEST_N=250 LONGEST_PER_SUB=10   # kind L — the Longest Files page (see the header)
RECOVERED_PER_SUB=5                # kind A — the recovered day lists (see the header)
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
    # L: the Longest Files (ms descending, CoreId ascending on a tie — the
    # sort the page used; at most LONGEST_PER_SUB per subscription, the first
    # LONGEST_N after that cap)
    LC_ALL=C awk -F'\t' -v OFS='\t' '$2 == "Processed" && ($9 + 0) > 0 { print $9 + 0, $1, $12 }' "$FILES" \
        | LC_ALL=C sort -t"$(printf '\t')" -k1,1nr -k2,2 \
        | LC_ALL=C awk -F'\t' -v n="$LONGEST_N" -v per="$LONGEST_PER_SUB" 'k < n && ++c[$3] <= per { k++; print $2 "\tL\t" $3 }'
    # U: every dated Unknown File; P: every one-legged File of a real
    # subscription (see the header — a CoreId may carry two kinds; every
    # reader takes the CoreId column only)
    LC_ALL=C awk -F'\t' '$12 == "Unknown" && $4 != "" { print $1 "\tU\t" $12 }
        $10 == 1 && $12 != "" && $12 != "Unknown" { print $1 "\tP\t" $12 }' "$FILES"
    # R: every dated File with a resubmitted leg (any outcome)
    LC_ALL=C awk -F'\t' '$27 == "1" && $4 != "" { print $1 "\tR\t" $12 }' "$FILES"
    # A: the automatically recovered Files — the newest RECOVERED_PER_SUB per
    # start day and subscription (the order of the recovered/<date> page:
    # sortkey descending, CoreId ascending on a tie)
    LC_ALL=C awk -F'\t' -v OFS='\t' '$26 == "1" && $27 != "1" && $4 != "" && $2 != "Failed" && $2 != "Expired" { print $4, $12, $6, $1 }' "$FILES" \
        | LC_ALL=C sort -t"$(printf '\t')" -k1,1 -k2,2 -k3,3r -k4,4 \
        | LC_ALL=C awk -F'\t' -v per="$RECOVERED_PER_SUB" '++n[$1 FS $2] <= per { print $4 "\tA\t" $2 }'
} | LC_ALL=C sort -u > "$OUT.tmp"
mv "$OUT.tmp" "$OUT"
echo "filepages: $(awk -F'\t' '$2 == "O"' "$OUT" | wc -l | tr -d ' ') latest-OK + $(awk -F'\t' '$2 == "E"' "$OUT" | wc -l | tr -d ' ') error + $(awk -F'\t' '$2 == "L"' "$OUT" | wc -l | tr -d ' ') longest + $(awk -F'\t' '$2 == "U"' "$OUT" | wc -l | tr -d ' ') Unknown + $(awk -F'\t' '$2 == "P"' "$OUT" | wc -l | tr -d ' ') one-legged + $(awk -F'\t' '$2 == "R"' "$OUT" | wc -l | tr -d ' ') resubmitted + $(awk -F'\t' '$2 == "A"' "$OUT" | wc -l | tr -d ' ') recovered File page(s) ($(cut -f1 "$OUT" | LC_ALL=C sort -u | wc -l | tr -d ' ') CoreIds)." >&2
