#!/usr/bin/env bash
#
# pirates.sh — "Pirates": logical transfers (CoreIds) that have only ONE leg
# (one technical row in the transfer log). A complete transfer is normally
# store-and-forward — an Inbound leg (the partner → ST) AND an Outbound leg
# (ST → the partner), commonly 2–7 rows. A CoreId with a SINGLE leg is an
# incomplete transfer: one side was logged, the counterpart leg never happened,
# so the file never actually made the full crossing (it ends up Failed).
#
# The Details tab is a per-SUBSCRIPTION rollup — Subscription, One-legged
# Files, First date, Last date; the WHOLE row opens the subscription's
# One-legged Files page (2026-10-01, user request: "clicking a row must give a
# page transfer/pirates/<subscription>.html with the files" — a File drill
# to its 10 newest until then; the Subscription name keeps its detail-page
# link, like every rowlink table). The Per day tab counts them per day. Reads
# _files.tsv ($FILES, one row per CoreId; col 10 = leg/row count).
# (2026-09-30 audit: the _transfers.tsv join for the leg direction went —
# nothing read it; the Details count became "One-legged Files"; the Unknown
# subscription is skipped in Details like every subscription-keyed table, the
# Per day tab still counts it.)
#
# THE SUBSCRIPTION PAGES (2026-10-01, user request):
#   data/transfer/reports/pirates/<slug>.rpt -> transfer/pirates/<slug>.html
#     every one-legged File of the subscription (Unknown gets no page) —
#     Date/time · File name · CoreId · State (OK / Error / Waiting / Expired,
#     the Files-table words), newest first (sortkey descending, CoreId on a
#     tie), tinted by the File colour (col 25), a TOTAL row and a NAV row
#     back to One-legged; date-aware like the Details count it opens from.
#     EVERY row has a File page (bin/transfer/filepages.sh kind P = these
#     Files) and the WHOLE row opens it (rowlink + @data:href). The slug =
#     the site-wide slugof over the C-sorted names, numeric bump on a clash.
#     Rendered by bin/transfer/publish.sh.
#
# Usage:
#   ./pirates.sh   # reads input/*.csv (via the caches), writes data/pirates.rpt
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# TRANSFER lib, not the analyses one: this is a transfer-DATA report (it reads
# the transfer caches and writes data/transfer/reports/). It lives HERE
# because it reads the transfer caches (its page, if any, is placed by the one
# Reports menu — _report_groups). bin/transfer/reports.sh still runs it.
source "$SCRIPT_DIR/../lib.sh"
mkdir -p "$REPORTS_DIR"
OUT="$REPORTS_DIR/pirates.rpt"
PSUB="$REPORTS_DIR/pirates"
TMPD=$(mktemp -d "${TMPDIR:-/tmp}/axpir.XXXXXX")
trap 'rm -rf "$TMPD"' EXIT

shopt -s nullglob
files=("$INPUT_DIR"/*.csv)
shopt -u nullglob
if [ ${#files[@]} -eq 0 ]; then
    echo "No *.csv in $INPUT_DIR — building from the EMPTY caches (config-only estate)" >&2
fi
echo "Found ${#files[@]} file(s) in '$INPUT_DIR', processing..." >&2

# Per single-leg CoreId, tab-separated:
#   date  time  site  sortkey  coreid  colour  outcome  file
agg=$(awk -F'\t' '
    $10 == 1 {                 # _files.tsv: exactly one leg
        printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", $4, $5, $12, $6, $1, $25, $2, $11
    }
' "$FILES")

n_total=$(printf '%s\n' "$agg" | grep -c . || true)

# the subscription slugs of the pages (Unknown and siteless Files: no page)
printf '%s\n' "$agg" | awk -F'\t' '$3 != "" && $3 != "Unknown" { print $3 }' | LC_ALL=C sort -u | awk "$AWKLIB"'
    { base = slugof($0); if (base == "") base = "subscription"
      slug = base; n = 1
      while (slug in used) { n++; slug = base "-" n }
      used[slug] = 1
      printf "%s\t%s\n", $0, slug }' > "$TMPD/slugs"
# the CoreIds with a PUBLISHED File page (bin/transfer/filepages.sh; kind P
# covers every row below — the test keeps a row without one plain)
: > "$TMPD/pages"
[ -f "$CACHE_DIR/_filepages.tsv" ] && cut -f1 "$CACHE_DIR/_filepages.tsv" > "$TMPD/pages"

# ---- the subscription pages (see the header), staged in pirates.new/ ----
rm -rf "$PSUB.new"; mkdir -p "$PSUB.new"
printf '%s\n' "$agg" | awk -F'\t' '$3 != "" && $3 != "Unknown"' | LC_ALL=C sort -t$'\t' -k3,3 -k4,4r -k5,5 | awk -F'\t' \
    -v slugs="$TMPD/slugs" -v pages="$TMPD/pages" -v dir="$PSUB.new" "$AWKLIB"'
    BEGIN { while ((getline l < slugs) > 0) { split(l, a, "\t"); SL[a[1]] = a[2] } close(slugs)
            while ((getline l < pages) > 0) if (l != "") PG[l] = 1
            close(pages) }
    function clean(s) { gsub(/[\t\r]/, " ", s); return s }
    function finish() { if (out == "") return; printf "TOTAL\tTotal (%d Files)\t\t\t\n", nr > out; printf "FOOT\n" > out; close(out) }
    ($3 "") != cur {
        finish(); cur = $3; nr = 0; out = dir "/" SL[$3] ".rpt"
        printf "TITLE\tOne-legged Files: %s\n", $3 > out
        printf "INTRO\tThe Files of subscription [[subscriptions/%s]] with only ONE leg in the transfer log — the counterpart leg never happened, so the File never made the full crossing. Newest first; a row opens its File page.\n", $3 > out
        printf "NAV\t0|One-legged|../pirates-details.html\n" > out
        printf "TABLE\tOne-legged Files\twide\tsort=0:-1\tpager=25\trestint\trowlink\n" > out
        printf "HEAD\tDate/time\tFile name\tCoreId\tState\n" > out
        printf "KIND\ttext\tmono\tmono\ttext\n" > out
    }
    {
        st = ($7 == "Processed") ? "OK" : ($7 == "Failed") ? "Error" : $7
        res = ($6 == "green" || $6 == "orange" || $6 == "red") ? "\t@data:res=" $6 : ""
        if ($5 in PG) res = res "\t@data:href=../../files/" $5 ".html"   # the whole row opens the File page
        printf "ROW\t%s\t%s\t%s\t%s%s\n", ($1 != "" ? $1 " " substr($2, 1, 8) : ""), lit(clean($8)), $5, st, res > out
        nr++
    }
    END { finish() }'
rm -rf "$PSUB"; mv "$PSUB.new" "$PSUB"

# Per-day counts for the "Per day" tab: date -> the count. Deterministic (sort
# by date), newest first.
pd=$(printf '%s\n' "$agg" | awk -F'\t' '
        { d = $1; if (d == "") next
          c[d]++ }
        END { for (d in c) printf "%s\t%d\n", d, c[d] }' \
    | LC_ALL=C sort -t$'\t' -k1,1r)

{
    printf 'TITLE\tOne-legged\n'   # = its Reports menu label (2026-09-29)

    # ---- tab 1: Details — per-subscription rollup of the single-leg transfers ----
    if [ "$n_total" -eq 0 ]; then
        printf 'TABLE\tDetails\tnofilter\tnosort\n'
        printf 'HEAD\tSubscription\tOne-legged Files\tFirst date\tLast date\n'
        printf 'KIND\tsite\tnumfailed\ttext\ttext\n'
        printf 'ROW\t(none)\t\t\t\n'
    else
        # DATE-AWARE (2026-09-30, user request: every Errors-group page gets
        # the From/To selection; the audit T-03 nofilter of the same morning
        # went): each row carries its per-day counts (@data:buckets) and
        # One-legged Files re-sums for the range (RECALC s0); a subscription
        # with none in the range hides; First / Last date stay full-period (the
        # site rule). The WHOLE row opens the subscription page (rowlink +
        # @data:href, 2026-10-01 — the File drill went)
        printf 'TABLE\tDetails\trowlink\n'
        printf 'HEAD\tSubscription\tOne-legged Files\tFirst date\tLast date\n'
        printf 'KIND\tsite\tnumfailed\ttext\ttext\n'
        printf 'RECALC\t-\ts0\t-\t-\n'
        # most one-legged Files first, subscription name as the tiebreaker.
        # "Unknown" = no subscription: skipped here (the Unknown transfers
        # report lists those Files)
        printf '%s\n' "$agg" | awk -F'\t' '
                $3 == "" || $3 == "Unknown" { next }
                { s = $3; d = $1
                  c[s]++
                  if (d != "") { if (f[s] == "" || d < f[s]) f[s] = d; if (d > l[s]) l[s] = d
                                 if (!((s SUBSEP d) in BC)) BD[s] = BD[s] SUBSEP d; BC[s SUBSEP d]++ } }
                # the per-day counts in the DATED bucket form (date:count, date order)
                function bkt(s,   n, D, i, j, v, o) {
                    n = split(substr(BD[s], 2), D, SUBSEP)
                    for (i = 2; i <= n; i++) { v = D[i]; j = i - 1; while (j >= 1 && D[j] > v) { D[j + 1] = D[j]; j-- } D[j + 1] = v }
                    o = ""; for (i = 1; i <= n; i++) o = o (i > 1 ? "," : "") D[i] ":" BC[s SUBSEP D[i]]
                    return o }
                END { for (s in c) printf "%d\t%s\t%s\t%s\t%s\n", c[s], s, f[s], l[s], bkt(s) }' \
            | LC_ALL=C sort -t$'\t' -k1,1rn -k2,2 \
            | awk -F'\t' -v slugs="$TMPD/slugs" '
                BEGIN { while ((getline l < slugs) > 0) { split(l, a, "\t"); SL[a[1]] = a[2] } close(slugs) }
                { printf "ROW\t%s\t%s\t%s\t%s\t@data:buckets=%s%s\n", $2, $1, $3, $4, $5, (($2 in SL) ? "\t@data:href=pirates/" SL[$2] ".html" : ""); t += $1 }
                END { printf "TOTAL\tTotal (%d subscription(s))\t@{class=num failed}%d\t\t\n", NR, t }'
    fi

    # ---- tab 2: Per day — the one-legged Files per day ("Top view" until
    # 2026-09-30) ----
    # (2026-09-29 audit: "Single-leg transfers" + Error / OK columns — the
    # count is FILES, and a lone leg is Failed by the outcome rule, so Error
    # always equalled the count and OK was always empty: one column now)
    if [ -z "$pd" ]; then
        printf 'TABLE\tOne-legged Files per day\tnofilter\tnosort\n'
        printf 'HEAD\tDate\tOne-legged Files\n'
        printf 'KIND\ttext\tnumfailed\n'
        printf 'ROW\t(none)\t\n'
    else
        printf 'TABLE\tOne-legged Files per day\n'
        printf 'HEAD\tDate\tOne-legged Files\n'
        printf 'KIND\ttext\tnumfailed\n'
        printf '%s\n' "$pd" | awk -F'\t' '
            { printf "ROW\t%s\t%s\n", $1, $2; t += $2 }
            END { printf "TOTAL\tTotal (%d day(s))\t@{class=num failed}%d\n", NR, t }'
    fi

    printf 'SUMMARY\tOne-legged Files: %s\n' "$n_total"
    printf 'FOOT\n'
} > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"
# the ENTITY row tint (2026-09-30 audit A2-03: every row tints by its entity
# result colour — bin/rpt-tint.awk, base cache col 3)
awk -F'\t' -v TABLES="Details" -v BASE="$CONFIG_BASE/_subscriptions.tsv" -v COL=2 -f "$ROOT/bin/rpt-tint.awk" "$OUT" > "$OUT.tint" && mv "$OUT.tint" "$OUT"

echo "Data written to $OUT ($n_total one-legged File(s); $(ls "$PSUB" | grep -c "\.rpt$" || true) subscription page(s))." >&2
