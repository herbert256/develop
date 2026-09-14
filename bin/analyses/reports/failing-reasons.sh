#!/usr/bin/env bash
#
# failing-reasons.sh — "Error reasons": every possible Reason of the Failed
# Subscriptions pages (Reason / Count / Last) on ONE page counting every
# failed File in the data (2026-09-14, user request: no selector buttons,
# count all errors, not subscriptions). The source is failed-all-all.rpt —
# every failed File, recovered flows included, plus each server-failing
# subscription once — so the Total equals failed-all-all.html's row count and
# one busy flow counts as often as it failed.
#
# (Until 2026-09-14 first a Subscriptions/Errors x Current/History grid of
# four pages, then the two All / Subscription pages the same day.)
#
# The Errors group's second member.
#
# The ROW SET is every possible Reason, listed even when empty: the
# bin/flip-reason.awk vocabulary — PARSED FROM THE CLASSIFIER ITSELF (its
# `return "…"` strings, in classifier order), so a new verdict appears here
# on its own — plus the two chain extras One-legged and Failed
# Subtransmission, UNIONed with any reason actually present in the source
# (a Subscriptions-in-boxes label on a server row, an unlisted raw status; a
# row with a blank Reason counts under "(none)"). A reason with no counted
# row keeps its row with Count and Last BLANK.
#
# Each nonzero row opens its drill list (failing-reasons-<slug>.html): the
# rows behind the count, copied from the source MINUS the Reason column —
# same links and tints, so a row opens the same error page it opens on the
# Failed Subscriptions pages. The drills are CAPPED at the newest 500 rows
# (Connection failures alone can hold thousands of files; failed-all-all.html
# is the full, searchable list), the cap stated in a NOTE. The drills render
# through the failing-reasons-* loop in bin/analyses/publish.sh (group row +
# "failing-reasons" help slug and persistence key).
#
# An ANALYSES report (page in the Analyses Errors group) reading a TRANSFER
# report — analyses reports run after the transfer reports in bin/build.sh,
# and again after the failed.sh catch-up, so the source is always this build's.
#
# Usage:
#   ./failing-reasons.sh    # -> data/analyses/reports/failing-reasons*.rpt
#
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib.sh"

SRC="$DATA/transfer/reports/failed-all-all.rpt"
OUT="$REPORTS_DIR/failing-reasons.rpt"
if [ ! -f "$SRC" ]; then
    echo "failing-reasons: missing $SRC (the transfer reports have not run) — pages not published." >&2
    rm -f "$OUT" "$REPORTS_DIR"/failing-reasons-*.rpt
    exit 0
fi
skip_if_fresh "$OUT" "${BASH_SOURCE[0]}" "$SRC" "$LIB_DIR/../flip-reason.awk"

GEN=$(date '+%Y-%m-%d %H:%M:%S')
DCAP=500            # the drills show at most this many newest rows
TMP=$(mktemp -d "${TMPDIR:-/tmp}/axereas.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

# the classifier vocabulary, in classifier order, straight from the source
grep -o 'return "[^"]*"' "$LIB_DIR/../flip-reason.awk" \
    | sed -e 's/^return "//' -e 's/"$//' | awk 'NF' > "$TMP/vocab"
printf 'One-legged\nFailed Subtransmission\n' >> "$TMP/vocab"

LC_ALL=C awk -F'\t' -v VOC="$TMP/vocab" -v OUT="$OUT.tmp" -v TMPD="$TMP" -v gen="$GEN" -v DCAP="$DCAP" '
    function slug9(n,   s) { s = tolower(n); gsub(/[^a-z0-9]+/, "-", s)
        sub(/^-+/, "", s); sub(/-+$/, "", s); return s }
    BEGIN { while ((getline l < VOC) > 0)
                if (l != "" && !(l in RIX)) { RN[++nr] = l; RIX[l] = nr }
            close(VOC) }
    $1 == "ROW" {
        r = ($4 != "") ? $4 : "(none)"
        if (!(r in RIX)) { RN[++nr] = r; RIX[r] = nr }   # a dynamic straggler
        # the drill row: the source row (Subscription / Date/time) minus its
        # (constant) Reason column, the trailing @data cells riding along —
        # same links, same tint, so a drill row opens the same error page
        row9 = "ROW\t" $2 "\t" $3
        for (i = 5; i <= NF; i++) row9 = row9 "\t" $i
        CN[r]++; tot++
        if ($3 > LS[r]) LS[r] = $3
        if (DN[r] + 0 < DCAP + 0) { DN[r]++; DRW[r] = DRW[r] row9 "\n" }
        next
    }
    END {
        # the MAIN list
        f = OUT
        printf "TITLE\tError reasons\n" > f
        printf "DESC\tEvery possible Reason of the Failed Subscriptions pages — how many failed Files carry it and the newest occurrence; a nonzero row opens the failed Files behind it.\n" > f
        printf "KEYWORDS\terror,reason,cause,failed,failing,errors,count,files,vocabulary,classifier\n" > f
        # a snapshot per reason, so no date semantics: nofilter keeps the
        # From/To machinery off this table
        printf "TABLE\t\tnofilter\tnosearch\trowlink\n" > f
        printf "HEAD\tReason\tCount\tLast\n" > f
        printf "KIND\ttext\tnum\ttext\n" > f
        for (i = 1; i <= nr; i++) {
            r = RN[i]
            if (CN[r] + 0 > 0) {
                sl = "failing-reasons-" slug9(r)
                printf "ROW\t@{href=%s.html}%s\t@{href=%s.html,class=num}%d\t%s\t@data:href=%s.html\n", \
                       sl, r, sl, CN[r], LS[r], sl > f
            } else
                printf "ROW\t%s\t\t\n", r > f
        }
        printf "TOTAL\tTotal (%d reasons)\t%d\t\n", nr, tot + 0 > f
        printf "NOTE\tThe row set is **every Reason the Failed Subscriptions pages can show** — the shared classifier vocabulary (bin/flip-reason.awk, in classifier order), **One-legged**, the raw last-leg status, plus whatever a server row carries — a reason with **nothing counted stays listed with blank Count and Last**. Count = **every failed File** in the data (and each server-failing subscription once) — the Failed Subscriptions All x All rows — recovered flows included, so one busy flow counts as often as it failed. A nonzero row opens the list behind the count.\n" > f
        printf "FOOT\tGenerated on %s\n", gen > f
        close(f)
        # the DRILL pages, one per nonzero reason
        for (i = 1; i <= nr; i++) {
            r = RN[i]
            if (CN[r] + 0 == 0) continue
            f = TMPD "/failing-reasons-" slug9(r) ".rpt"
            printf "TITLE\tError reason: %s\n", r > f
            printf "DESC\tThe %d failed Files whose Reason is %s — each row opening its own error page.\n", CN[r], r > f
            printf "INTRO\tThe failed Files whose Reason is **%s**, newest first. Each row is listed exactly as on the Failed Subscriptions pages, and opens the same error page.\n", r > f
            printf "TABLE\t\twide\tsort=1:-1\trowlink\trestint\n" > f
            printf "HEAD\tSubscription\tDate/time\n" > f
            printf "KIND\tsite\ttext\n" > f
            printf "%s", DRW[r] > f
            printf "TOTAL\tTotal (%d rows)\t\n", DN[r] + 0 > f
            if (CN[r] + 0 > DN[r] + 0)
                printf "NOTE\tOnly the newest **%d** of the **%d** rows are shown — the Failed Subscriptions All x All view holds the full list.\n", DN[r] + 0, CN[r] > f
            printf "LINK\tfailing-reasons.html\tBack to Error reasons\n" > f
            printf "FOOT\tGenerated on %s\n", gen > f
            close(f)
        }
    }
' "$SRC"

# publish: the drill set first, the main LAST — a killed run leaves the old
# complete main (a stale mtime, so skip_if_fresh rebuilds) rather than a fresh
# list linking missing pages. The sweep also removes the retired view pages
# (failing-reasons-errors-history*, -history*, -errors*).
rm -f "$REPORTS_DIR"/failing-reasons-*.rpt
shopt -s nullglob
for f in "$TMP"/failing-reasons-*.rpt; do mv "$f" "$REPORTS_DIR/${f##*/}"; done
shopt -u nullglob
mv "$OUT.tmp" "$OUT"
n=$(command grep -c '^ROW' "$OUT" || true)
echo "Data written to $OUT ($n reason row(s))." >&2
