#!/usr/bin/env bash
#
# failing-reasons.sh — "Error reasons": every possible error Reason (Reason /
# Count / Last) on ONE page counting every File in ERROR (2026-09-14, user
# request: no selector buttons, count all errors, not subscriptions); a row
# opens the Failed files page searched on its reason (the per-reason drill
# pages went 2026-09-29).
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
# A member of the Failures group of the Reports menu.
#
# The ROW SET is every possible Reason, listed even when empty: the
# bin/flip-reason.awk vocabulary — PARSED FROM THE CLASSIFIER ITSELF (its
# `return "…"` strings, in classifier order), so a new verdict appears here
# on its own — plus the chain extras One-legged and Failed Subtransmission,
# UNIONed with any reason actually present in the source (Expired (not
# collected), an unlisted raw status, "(none)"). A reason with no counted
# File keeps its row with Count and Last BLANK.
#
# A ROW opens the Failed files page searched on its reason as a whole cell
# (2026-09-29: the per-reason drill pages failing-reasons-<slug>.html of
# 2026-09-14 held exactly those rows).
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
    rm -f "$OUT"
    exit 0
fi

GEN=$(date '+%Y-%m-%d %H:%M:%S')
TMP=$(mktemp -d "${TMPDIR:-/tmp}/axereas.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

# the classifier vocabulary, in classifier order, straight from the source
grep -o 'return "[^"]*"' "$LIB_DIR/../flip-reason.awk" \
    | sed -e 's/^return "//' -e 's/"$//' | awk 'NF' > "$TMP/vocab"
printf 'One-legged\nFailed Subtransmission\n' >> "$TMP/vocab"

LC_ALL=C awk -F'\t' -v VOC="$TMP/vocab" -v OUT="$OUT.tmp" -v TMPD="$TMP" -v gen="$GEN" '
    # the Failed files page searched on the reason as a WHOLE cell (quoted),
    # URL-encoded — the list the per-reason drill pages held until 2026-09-29
    function srch(r,   q) { q = r; gsub(/%/, "%25", q); gsub(/ /, "%20", q); gsub(/"/, "%22", q)
        gsub(/&/, "%26", q); gsub(/#/, "%23", q); gsub(/\+/, "%2B", q); gsub(/,/, "%2C", q)
        return "../transfer/failed-files.html?axway_search=%22" q "%22" }
    BEGIN { while ((getline l < VOC) > 0)
                if (l != "" && !(l in RIX)) { RN[++nr] = l; RIX[l] = nr }
            close(VOC) }
    # a failed-files row: 2 Subscription, 3 Date/time, 4 Error reason (an
    # @{href=../files/<CoreId>.html} prefix when the File has an error page),
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
        CN[r]++; tot++
        if ($3 > LS[r]) LS[r] = $3
        next
    }
    END {
        # the MAIN list
        f = OUT
        printf "TITLE\tError reasons\n" > f
        printf "DESC\tEvery error Reason that occurs — how many Files in error (Failed or Expired) carry it and the newest occurrence; a row opens the Failed files page filtered to it.\n" > f
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
            sl = (r == "(none)") ? "../transfer/failed-files.html" : srch(r)
            printf "ROW\t@{href=%s}%s\t@{href=%s,class=num}%d\t%s\t@data:href=%s\n", \
                   sl, r, sl, CN[r], LS[r], sl > f
        }
        printf "TOTAL\tTotal (%d reasons)\t%d\t\n", nz, tot + 0 > f
        printf "FOOT\tGenerated on %s\n", gen > f
        close(f)
    }
' "$SRC"

mv "$OUT.tmp" "$OUT"
n=$(command grep -c '^ROW' "$OUT" || true)
echo "Data written to $OUT ($n reason row(s))." >&2
