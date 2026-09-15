#!/usr/bin/env bash
#
# failing-reasons.sh — "Error reasons": every possible error Reason (Reason /
# Count / Last) on ONE page counting every File in ERROR (2026-09-14, user
# request: no selector buttons, count all errors, not subscriptions), and one
# drill page per nonzero reason listing ALL those Files.
#
# SOURCE: data/transfer/reports/failed-files.rpt (bin/transfer/reports/
# failed-files.sh) — one row per File that ended Failed or Expired, with its
# subscription, start date/time, the reason failed.sh classified (Expired =
# "Expired (not collected)", "-" = no rule applied, counted as "(none)"), its
# CoreId, file name and the subscription's result tint. So the Total equals
# the Failed files list and the home page's Error total, and a busy flow
# counts as often as it failed.
#
# (Until 2026-09-14 the source was failed-all-all.rpt — failed Files plus one
# row per server-failing subscription — first on a four-page view grid, then
# on All / Subscription pages; the drills were capped at 500 rows.)
#
# The Errors group's second member.
#
# The ROW SET is every possible Reason, listed even when empty: the
# bin/flip-reason.awk vocabulary — PARSED FROM THE CLASSIFIER ITSELF (its
# `return "…"` strings, in classifier order), so a new verdict appears here
# on its own — plus the chain extras One-legged and Failed Subtransmission,
# UNIONed with any reason actually present in the source (Expired (not
# collected), an unlisted raw status, "(none)"). A reason with no counted
# File keeps its row with Count and Last BLANK.
#
# DRILL PAGES failing-reasons-<slug>.html (2026-09-14, user request): EVERY
# File of that reason, newest first, 500 per page — Subscription / Date/time /
# CoreId / Filename, rows tinted with the standard subscription colours
# (restint), the whole row opening the File's error page when it has one. The
# Date/time cells make the table date-aware, so the page carries the From/To
# fields (bin/analyses/publish.sh renders the drills with the transfer date
# list). The drills render through the failing-reasons-* loop there (group
# row + "failing-reasons" help slug and persistence key).
#
# An ANALYSES report reading a TRANSFER report — analyses reports run after the
# transfer reports in bin/build.sh, and again after the failed-files catch-up,
# so the source is always this build's.
#
# Usage:
#   ./failing-reasons.sh    # -> data/analyses/reports/failing-reasons*.rpt
#
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib.sh"

SRC="$DATA/transfer/reports/failed-files.rpt"
OUT="$REPORTS_DIR/failing-reasons.rpt"
if [ ! -f "$SRC" ]; then
    echo "failing-reasons: missing $SRC (the transfer reports have not run) — pages not published." >&2
    rm -f "$OUT" "$REPORTS_DIR"/failing-reasons-*.rpt
    exit 0
fi
skip_if_fresh "$OUT" "${BASH_SOURCE[0]}" "$SRC" "$LIB_DIR/../flip-reason.awk"

GEN=$(date '+%Y-%m-%d %H:%M:%S')
TMP=$(mktemp -d "${TMPDIR:-/tmp}/axereas.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

# the classifier vocabulary, in classifier order, straight from the source
grep -o 'return "[^"]*"' "$LIB_DIR/../flip-reason.awk" \
    | sed -e 's/^return "//' -e 's/"$//' | awk 'NF' > "$TMP/vocab"
printf 'One-legged\nFailed Subtransmission\n' >> "$TMP/vocab"

LC_ALL=C awk -F'\t' -v VOC="$TMP/vocab" -v OUT="$OUT.tmp" -v TMPD="$TMP" -v gen="$GEN" '
    function slug9(n,   s) { s = tolower(n); gsub(/[^a-z0-9]+/, "-", s)
        sub(/^-+/, "", s); sub(/-+$/, "", s); return s }
    BEGIN { while ((getline l < VOC) > 0)
                if (l != "" && !(l in RIX)) { RN[++nr] = l; RIX[l] = nr }
            close(VOC) }
    # a failed-files row: 2 Subscription, 3 Date/time, 4 Error reason (an
    # @{href=../errors/<CoreId>.html} prefix when the File has an error page),
    # 5 @{class=mono}CoreId, 6 Filename, then @data cells (res = the tint)
    $1 == "ROW" {
        rc = $4; href = ""
        if (substr(rc, 1, 2) == "@{") {
            p = index(rc, "}"); at = substr(rc, 3, p - 3); rc = substr(rc, p + 1)
            if (index(at, "href=") == 1) href = substr(at, 6)
        }
        r = (rc == "" || rc == "-") ? "(none)" : rc
        if (!(r in RIX)) { RN[++nr] = r; RIX[r] = nr }   # a reason outside the vocabulary
        cid = $5; sub(/^@\{[^}]*\}/, "", cid)
        res = ""; for (i = 7; i <= NF; i++) if ($i ~ /^@data:res=/) res = $i
        row9 = "ROW\t" $2 "\t" $3 "\t@{class=mono}" cid "\t" $6 (href != "" ? "\t@data:href=" href : "") (res != "" ? "\t" res : "")
        CN[r]++; tot++
        if ($3 > LS[r]) LS[r] = $3
        DRW[r] = DRW[r] row9 "\n"
        next
    }
    END {
        # the MAIN list
        f = OUT
        printf "TITLE\tError reasons\n" > f
        printf "DESC\tEvery error Reason that occurs — how many Files in error (Failed or Expired) carry it and the newest occurrence; a row opens every File behind it.\n" > f
        printf "KEYWORDS\terror,reason,cause,failed,failing,errors,expired,count,files,vocabulary,classifier\n" > f
        # a snapshot per reason, so no date semantics: nofilter keeps the
        # From/To machinery off this table
        # sort=2:-1 (2026-09-14, user request): Last (the newest occurrence)
        # descending. 2026-09-15 (user request): reasons with nothing counted
        # get no row, and the Total row sits at the bottom again (no totaltop)
        printf "TABLE\t\tnofilter\tnosearch\trowlink\tsort=2:-1\n" > f
        printf "HEAD\tReason\tCount\tLast\n" > f
        printf "KIND\ttext\tnum\ttext\n" > f
        for (i = 1; i <= nr; i++) {
            r = RN[i]
            if (CN[r] + 0 == 0) continue
            nz++
            sl = "failing-reasons-" slug9(r)
            printf "ROW\t@{href=%s.html}%s\t@{href=%s.html,class=num}%d\t%s\t@data:href=%s.html\n", \
                   sl, r, sl, CN[r], LS[r], sl > f
        }
        printf "TOTAL\tTotal (%d reasons)\t%d\t\n", nz, tot + 0 > f
        printf "FOOT\tGenerated on %s\n", gen > f
        close(f)
        # the DRILL pages, one per nonzero reason: every File, newest first
        for (i = 1; i <= nr; i++) {
            r = RN[i]
            if (CN[r] + 0 == 0) continue
            f = TMPD "/failing-reasons-" slug9(r) ".rpt"
            printf "TITLE\tError reason: %s\n", r > f
            printf "DESC\tThe %d Files in error whose Reason is %s: subscription, date/time, CoreId and file name.\n", CN[r], r > f
            printf "TABLE\t\twide\tsort=1:-1\tpager=500\trowlink\trestint\n" > f
            printf "HEAD\tSubscription\tDate/time\tCoreId\tFilename\n" > f
            printf "KIND\tsite\ttext\ttext\ttext\n" > f
            printf "%s", DRW[r] > f
            printf "LINK\tfailing-reasons.html\tBack to Error reasons\n" > f
            printf "FOOT\tGenerated on %s\n", gen > f
            close(f)
        }
    }
' "$SRC"

# publish: the drill set first, the main LAST — a killed run leaves the old
# complete main (a stale mtime, so skip_if_fresh rebuilds) rather than a fresh
# list linking missing pages. The sweep also removes retired view pages.
rm -f "$REPORTS_DIR"/failing-reasons-*.rpt
shopt -s nullglob
for f in "$TMP"/failing-reasons-*.rpt; do mv "$f" "$REPORTS_DIR/${f##*/}"; done
shopt -u nullglob
mv "$OUT.tmp" "$OUT"
n=$(command grep -c '^ROW' "$OUT" || true)
echo "Data written to $OUT ($n reason row(s))." >&2
