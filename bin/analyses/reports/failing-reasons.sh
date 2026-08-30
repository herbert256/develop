#!/usr/bin/env bash
#
# failing-reasons.sh — "Error reasons": every possible Reason of the Failed
# Subscriptions pages (Reason / Count / Last), on FOUR pages picked by the
# two-group selector row (injected by bin/analyses/publish.sh, the failed
# pages' undertabs pattern — UNIT first, SCOPE second):
#
#   UNIT   Subscriptions  count SUBSCRIPTIONS, one each (its newest failure's
#                         reason — the failed-sub-all rows)
#          Errors         count individual ERRORS — every failed File (and
#                         each server-failing subscription once) — the
#                         failed-all rows
#   SCOPE  Current        the still-failing estate: red subscriptions /
#                         the errors of still-failing subscriptions
#          History        everything ever: recovered flows included
#
#   subs x current   -> failing-reasons.html           (THE page, unchanged)
#   subs x history   -> failing-reasons-history.html
#   errors x current -> failing-reasons-errors.html
#   errors x history -> failing-reasons-errors-history.html
#
# The Errors group's second member.
#
# The ROW SET is every possible Reason, listed even when empty: the
# bin/flip-reason.awk vocabulary — PARSED FROM THE CLASSIFIER ITSELF (its
# `return "…"` strings, in classifier order), so a new verdict appears here
# on its own — plus the two chain extras One-legged and Failed
# Subtransmission, UNIONed with any reason actually present in the sources
# (a Subscriptions-in-boxes label on a server row, an unlisted raw status; a
# row with a blank Reason counts under "(none)"). A reason with no counted
# row keeps its row with Count and Last BLANK.
#
# SOURCES: failed-sub-all.rpt (the Subscriptions unit, both scopes — Current
# filters its rows to @data:res=red), failed-all-failing.rpt (Errors x
# Current) and failed-all-all.rpt (Errors x History) — so each view's Count
# is exactly a Failed Subscriptions view's row count, split by Reason.
#
# Each nonzero row opens its view's drill list (failing-reasons[-errors]
# [-history]-<slug>.html): the rows behind the count, copied from the source
# MINUS the Reason column — same links, so a row opens the same error page
# it opens on the Failed Subscriptions pages. The ERRORS drills are CAPPED
# at the newest 500 rows (Connection failures alone holds ~13k files; the
# searchable All views are the full lists), the cap stated in a NOTE. All
# the extra pages render through the failing-reasons-* drill loop in
# bin/analyses/publish.sh (group row + "failing-reasons" help slug and
# persistence key).
#
# An ANALYSES report (page in the Analyses Errors group) reading TRANSFER
# reports — analyses reports run after the transfer reports in bin/build.sh,
# so the sources are always this build's.
#
# Usage:
#   ./failing-reasons.sh    # -> data/<env>/analyses/reports/failing-reasons*.rpt
#
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib.sh"

SRC="$DATA/transfer/reports/failed-sub-all.rpt"
SRCEC="$DATA/transfer/reports/failed-all-failing.rpt"
SRCEH="$DATA/transfer/reports/failed-all-all.rpt"
OUT="$REPORTS_DIR/failing-reasons.rpt"
if [ ! -f "$SRC" ] || [ ! -f "$SRCEC" ] || [ ! -f "$SRCEH" ]; then
    echo "failing-reasons: missing failed-*.rpt source(s) (the transfer reports have not run) — pages not published." >&2
    rm -f "$OUT" "$REPORTS_DIR"/failing-reasons-*.rpt
    exit 0
fi
# a missing view page forces a rebuild — skip_if_fresh tests the one .rpt
for v in history errors errors-history; do
    [ -f "$REPORTS_DIR/failing-reasons-$v.rpt" ] || rm -f "$OUT"
done
skip_if_fresh "$OUT" "${BASH_SOURCE[0]}" "$SRC" "$SRCEC" "$SRCEH" "$LIB_DIR/../flip-reason.awk"

GEN=$(date '+%Y-%m-%d %H:%M:%S')
DCAP=500            # the Errors drills show at most this many newest rows
TMP=$(mktemp -d "${TMPDIR:-/tmp}/axereas.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

# the classifier vocabulary, in classifier order, straight from the source
grep -o 'return "[^"]*"' "$LIB_DIR/../flip-reason.awk" \
    | sed -e 's/^return "//' -e 's/"$//' | awk 'NF' > "$TMP/vocab"
printf 'One-legged\nFailed Subtransmission\n' >> "$TMP/vocab"

LC_ALL=C awk -F'\t' -v VOC="$TMP/vocab" -v OUT="$OUT.tmp" -v TMPD="$TMP" -v gen="$GEN" -v DCAP="$DCAP" \
    -v F1="$SRC" -v F2="$SRCEC" -v F3="$SRCEH" '
    function slug9(n,   s) { s = tolower(n); gsub(/[^a-z0-9]+/, "-", s)
        sub(/^-+/, "", s); sub(/-+$/, "", s); return s }
    # one view MAIN list: f = the output, pfx = the drill-page prefix,
    # CN/LS = the view count/last maps, ttl = the total counted, scope =
    # the DESC/NOTE phrase for what a count counts
    function mainlist(f, pfx, CN, LS, ttl, scope,   i, r, sl) {
        printf "TITLE\tError reasons\n" > f
        printf "DESC\tEvery possible Reason of the Failed Subscriptions pages — how many %s carry it and the newest occurrence; a nonzero row opens the rows behind it.\n", scope > f
        printf "KEYWORDS\terror,reason,cause,failed,failing,red,count,history,vocabulary,classifier\n" > f
        # a snapshot per reason, so no date semantics: nofilter keeps the
        # From/To machinery off this table
        printf "TABLE\t\tnofilter\tnosearch\trowlink\n" > f
        printf "HEAD\tReason\tCount\tLast\n" > f
        printf "KIND\ttext\tnum\ttext\n" > f
        for (i = 1; i <= nr; i++) {
            r = RN[i]
            if (CN[r] + 0 > 0) {
                sl = pfx slug9(r)
                printf "ROW\t@{href=%s.html}%s\t@{href=%s.html,class=num}%d\t%s\t@data:href=%s.html\n", \
                       sl, r, sl, CN[r], LS[r], sl > f
            } else
                printf "ROW\t%s\t\t\n", r > f
        }
        printf "TOTAL\tTotal (%d reasons)\t%d\t\n", nr, ttl + 0 > f
    }
    # one view DRILL set: DN = how many buffered (capped), CN = the true
    # count, DRW = the buffered rows, back = the main page to link back to
    function drills(pfx, CN, DN, DRW, back, scope,   i, r, f) {
        for (i = 1; i <= nr; i++) {
            r = RN[i]
            if (CN[r] + 0 == 0) continue
            f = TMPD "/" pfx slug9(r) ".rpt"
            printf "TITLE\tError reason: %s\n", r > f
            printf "DESC\tThe %d %s whose Reason is %s — each row opening its own error page.\n", CN[r], scope, r > f
            printf "INTRO\tThe %s whose Reason is **%s**, newest first. Each row is listed exactly as on the Failed Subscriptions pages, and opens the same error page.\n", scope, r > f
            printf "TABLE\t\twide\tsort=1:-1\trowlink\trestint\n" > f
            printf "HEAD\tSubscription\tDate/time\n" > f
            printf "KIND\tsite\ttext\n" > f
            printf "%s", DRW[r] > f
            printf "TOTAL\tTotal (%d rows)\t\n", DN[r] + 0 > f
            if (CN[r] + 0 > DN[r] + 0)
                printf "NOTE\tOnly the newest **%d** of the **%d** rows are shown — the **All** views of Failed Subscriptions hold the full lists (their newest 10,000).\n", DN[r] + 0, CN[r] > f
            printf "LINK\t%s\tBack to Error reasons\n", back > f
            printf "FOOT\tGenerated on %s\n", gen > f
            close(f)
        }
    }
    # count one source row into a view: CN/LS/DN/DRW its maps, cap the
    # drill-buffer ceiling (0 = uncapped)
    function tally(r, dt, row9, CN, LS, DN, DRW, cap) {
        CN[r]++
        if (dt > LS[r]) LS[r] = dt
        if (cap + 0 == 0 || DN[r] + 0 < cap + 0) { DN[r]++; DRW[r] = DRW[r] row9 "\n" }
    }
    BEGIN { while ((getline l < VOC) > 0)
                if (l != "" && !(l in RIX)) { RN[++nr] = l; RIX[l] = nr }
            close(VOC) }
    FNR == 1 { nf++ }
    $1 == "ROW" {
        red = 0; for (i = 2; i <= NF; i++) if ($i == "@data:res=red") red = 1
        r = ($4 != "") ? $4 : "(none)"
        if (!(r in RIX)) { RN[++nr] = r; RIX[r] = nr }   # a dynamic straggler
        # the drill row: the source row (Subscription / Date/time) minus its
        # (constant) Reason column, the trailing @data cells riding along —
        # same links, same tint, so a drill row opens the same error page
        row9 = "ROW\t" $2 "\t" $3
        for (i = 5; i <= NF; i++) row9 = row9 "\t" $i
        if (nf == 1) {                     # failed-sub-all: Subscriptions x Current
            if (red) { tally(r, $3, row9, CNT, LAST, CD, DR, 0); tot++ }
        } else if (nf == 2) {              # failed-all-failing: Errors x Current
            tally(r, $3, row9, EC, EL, ED9, ED, DCAP); etot++
        } else {                           # failed-all-all: Errors x History
            tally(r, $3, row9, XC, XL, XD9, XD, DCAP); xtot++
            # + Subscriptions x History (2026-08): per reason, EVERY
            # subscription that EVER failed with it — one flow counts under
            # each fault class that ever hit it (counting only newest-failure
            # reasons left a class blank though it plainly occurred). The
            # drill row per (reason, flow) is the newest occurrence OF THAT
            # REASON; the stream is newest-first except the appended server
            # rows, so the max-dt compare picks it exactly.
            site9 = $2; sub(/^@\{[^}]*\}/, "", site9)
            k9 = r SUBSEP toupper(site9)
            if (!(k9 in HDT)) { HC[r]++; htot++
                HKN[r]++; HKL[r, HKN[r]] = k9 }
            if (!(k9 in HDT) || $3 > HDT[k9]) { HDT[k9] = $3; HRW[k9] = row9 }
            if ($3 > HL[r]) HL[r] = $3
        }
        next
    }
    END {
        # assemble the Subscriptions x History drill buffers (one row per
        # (reason, flow) pair, in first-seen order — sort=1:-1 orders the
        # rendered page by date anyway)
        for (i = 1; i <= nr; i++) { r = RN[i]
            for (j = 1; j <= HKN[r] + 0; j++) HD[r] = HD[r] HRW[HKL[r, j]] "\n"
            HD9[r] = HKN[r] + 0 }
        mainlist(OUT, "failing-reasons-", CNT, LAST, tot, "currently RED subscriptions")
        printf "NOTE\tThe row set is **every Reason the Failed Subscriptions pages can show** — the shared classifier vocabulary (bin/flip-reason.awk, in classifier order), **One-legged**, the raw last-leg status, plus whatever a server row carries — a reason with **nothing counted stays listed with blank Count and Last**, so a fault class disappearing from the estate is visible as an emptied row. The button rows above pick the view: **Subscriptions** counts flows once each (their newest failure or server verdict), **Errors** counts every individual failed File; **Current** keeps to the still-failing estate, **History** includes the recovered. This view: RED subscriptions only, one each — the same rows the default Failed Subscriptions view lists. A nonzero row opens the list behind the count.\n" > OUT
        printf "FOOT\tGenerated on %s\n", gen > OUT
        close(OUT)
        f2 = TMPD "/failing-reasons-history.rpt"
        mainlist(f2, "failing-reasons-history-", HC, HL, htot, "subscriptions that ever failed with it")
        printf "NOTE\tSee the Current view'"'"'s note for the row set and the buttons. This view counts, per reason, **every subscription that EVER failed with it** — so one flow counts under each fault class that ever hit it, and the Total can exceed the number of flows. The drill lists each flow once, at its newest occurrence OF THAT reason, tinted **red** = still failing, **green** = recovered since.\n" > f2
        printf "FOOT\tGenerated on %s\n", gen > f2
        close(f2)
        f3 = TMPD "/failing-reasons-errors.rpt"
        mainlist(f3, "failing-reasons-errors-", EC, EL, etot, "individual errors of the still-failing subscriptions")
        printf "NOTE\tSee the Subscriptions x Current view'"'"'s note for the row set and the buttons. This view counts **individual ERRORS**: every failed File of the still-failing subscriptions (and each server-failing subscription once) — the Failed Subscriptions All x Still-failing rows, so one busy flow counts as many times as it failed.\n" > f3
        printf "FOOT\tGenerated on %s\n", gen > f3
        close(f3)
        f4 = TMPD "/failing-reasons-errors-history.rpt"
        mainlist(f4, "failing-reasons-errors-history-", XC, XL, xtot, "individual errors in the data")
        printf "NOTE\tSee the Subscriptions x Current view'"'"'s note for the row set and the buttons. This view counts **individual ERRORS across the whole data**: every failed File (and each server-failing subscription once) — the Failed Subscriptions All x All rows — recovered flows included, so one busy flow counts as many times as it ever failed.\n" > f4
        printf "FOOT\tGenerated on %s\n", gen > f4
        close(f4)
        drills("failing-reasons-",                CNT, CD,  DR, "failing-reasons.html",                "currently **red** subscriptions")
        drills("failing-reasons-history-",        HC,  HD9, HD, "failing-reasons-history.html",        "subscriptions that **ever failed** with it")
        drills("failing-reasons-errors-",         EC,  ED9, ED, "failing-reasons-errors.html",         "individual errors of the **still-failing** subscriptions")
        drills("failing-reasons-errors-history-", XC,  XD9, XD, "failing-reasons-errors-history.html", "individual errors in the **whole data**")
    }
' "$SRC" "$SRCEC" "$SRCEH"

# publish: the drill set + the view mains first, the Current main LAST — a
# killed run leaves the old complete main (a stale mtime, so skip_if_fresh
# rebuilds) rather than a fresh list linking missing pages
rm -f "$REPORTS_DIR"/failing-reasons-*.rpt
shopt -s nullglob
for f in "$TMP"/failing-reasons-*.rpt; do mv "$f" "$REPORTS_DIR/${f##*/}"; done
shopt -u nullglob
mv "$OUT.tmp" "$OUT"
n=$(command grep -c '^ROW' "$OUT" || true)
echo "Data written to $OUT + 3 view variants ($n reason row(s))." >&2
