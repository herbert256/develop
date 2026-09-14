#!/usr/bin/env bash
#
# failed-files.sh — the FAILED FILES list (2026-09-14, user request): every
# File (CoreId) that ended in error, one row each, newest first — exactly the
# Files the home page's per-day Error cells and the Top view's Files/Error
# column count (outcome Failed or Expired, on the File's START day), so a
# home Error cell opens this page narrowed to its day (?axway_date) and the
# visible row count equals the cell.
#
#   Subscription   _files.tsv col 12 (links its detail page)
#   Date/time      col 4 + col 5, the File's start (the date filter reads it)
#   Error reason   Failed: the reason failed.sh classified for the CoreId
#                  (_failed-reasons.tsv, bin/flip-reason.awk — the same text as
#                  the Failed subscriptions lists and the error page title),
#                  "-" when no rule applied; Expired: "Expired (not collected)".
#                  Opens the File's error page (errors/<CoreId>.html) when it
#                  has one.
#   CoreId         col 1 (report.js adds the File Tracking link + copy icon)
#   Filename       col 11
#
# Rows tint by the SUBSCRIPTION's result colour (2026-09-14, user request: the
# standard subscription colours) — restint + @data:res from base/
# _subscriptions.tsv col 3 (green / orange / red / blue), the failed.sh rule;
# a name the configuration lacks stays untinted.
#
# Runs after the transfer pool (bin/transfer/reports.sh, serial tail — the
# pool's failed.sh has finished) and again in bin/build.sh right after the
# failed.sh catch-up, whose reasons it needs; skip_if_fresh on the reasons
# sidecar and the error-page tree. No prose on the page (help page
# failed-files).
#
# Usage:
#   ./failed-files.sh   # -> data/transfer/reports/failed-files.rpt
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib.sh"
mkdir -p "$REPORTS_DIR"
OUT="$REPORTS_DIR/failed-files.rpt"
REAS="$REPORTS_DIR/_failed-reasons.tsv"
ERRDIR="$REPORTS_DIR/errors"

shopt -s nullglob
files=("$INPUT_DIR"/*.csv)
shopt -u nullglob
ensure_parsed
DEPS=("${BASH_SOURCE[0]}")
[ -f "$REAS" ] && DEPS+=("$REAS")
[ -d "$ERRDIR" ] && DEPS+=("$ERRDIR")
SUBRES="$CONFIG_BASE/_subscriptions.tsv"   # name <TAB> ... <TAB> result colour (col 3)
[ -f "$SUBRES" ] && DEPS+=("$SUBRES")
skip_if_fresh "$OUT" "${DEPS[@]}"

# the CoreIds that have an error page (their errors/<CoreId>.rpt)
pages=$(mktemp "${TMPDIR:-/tmp}/ffpages.XXXXXX")
if [ -d "$ERRDIR" ]; then
    find "$ERRDIR" -maxdepth 1 -type f -name '*.rpt' 2>/dev/null | sed 's#.*/##; s#\.rpt$##' > "$pages" || : > "$pages"
else
    : > "$pages"
fi
[ -f "$REAS" ] || REAS=/dev/null
[ -f "$SUBRES" ] || SUBRES=/dev/null

# one "sortkey TAB ROW..." line per failed File, plus the "~N TAB count" line
agg=$(LC_ALL=C awk -F'\t' -v REAS="$REAS" -v PAGES="$pages" -v SUBRES="$SUBRES" '
    BEGIN {
        while ((getline l < SUBRES) > 0) { n9 = split(l, a9, "\t"); if (n9 >= 3 && a9[1] != "") SRES[toupper(a9[1])] = a9[3] }
        close(SUBRES)
        while ((getline l < REAS) > 0) { p = index(l, "\t"); if (p > 0) RE[substr(l, 1, p - 1)] = substr(l, p + 1) }
        close(REAS)
        while ((getline l < PAGES) > 0) if (l != "") PG[l] = 1
        close(PAGES)
    }
    ($2 == "Failed" || $2 == "Expired") && $4 != "" {
        cid = $1
        r = ($2 == "Expired") ? "Expired (not collected)" : ((cid in RE) ? RE[cid] : "")
        if (r == "") r = "-"
        if (cid in PG) r = "@{href=../errors/" cid ".html}" r
        res = SRES[toupper($12)]
        tint = (res == "green" || res == "orange" || res == "red" || res == "blue") ? "\t@data:res=" res : ""
        printf "%s\tROW\t%s\t%s %s\t%s\t@{class=mono}%s\t%s%s\n", $6, $12, $4, $5, r, cid, $11, tint
        n++
    }
    END { printf "~N\t%d\n", n + 0 }' "$FILES")
rm -f "$pages"
nff=$(printf '%s\n' "$agg" | awk -F'\t' '$1 == "~N" { print $2 }')

{
    printf 'TITLE\tFailed files\n'
    printf 'DESC\tEvery File that ended in error (Failed or Expired), newest first: its subscription, start date/time, error reason, CoreId and file name. The Files the home page Error cells count; a cell opens this page narrowed to its day.\n'
    printf 'KEYWORDS\tfailed, failed files, error, errors, error reason, reason, expired, coreid, file name, filename, per day, home error\n'
    printf 'TABLE\t\twide\tsort=1:-1\tpager=500\trestint\n'
    printf 'HEAD\tSubscription\tDate/time\tError reason\tCoreId\tFilename\n'
    printf 'KIND\tsite\ttext\ttext\ttext\ttext\n'
    printf '%s\n' "$agg" | awk -F'\t' '$1 != "~N" && $1 != ""' | LC_ALL=C sort -t"$(printf '\t')" -k1,1r | cut -f2- || true
    printf 'FOOT\tGenerated on %s from %s file(s)\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${#files[@]}"
} > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"

echo "Data written to $OUT (${nff:-0} failed file(s))." >&2
