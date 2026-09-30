#!/usr/bin/env bash
#
# unknown-transfers.sh — the UNKNOWN TRANSFERS list (2026-09-29, user request:
# "drop support for UCx on the complete site, give those the value Unknown
# for subscription, do not show Unknown rows in any subscription based table,
# add a new report named Unknown transfers in the Errors group that lists
# those"). Every File (CoreId) that carries an account but that NO attribution
# pass — config fallback, xref vote, flowdir, the session join, the
# inbound-leg tie-break — could place on a subscription: bin/transfer/parse.sh
# gives it subscription "Unknown" (the synthetic "UCx_<account>" until
# 2026-09-29). A routing gap to investigate: the transfers are real and count
# in every non-subscription figure, but no subscription table shows them.
#
# Table 1, one row per File, newest first (_files.tsv, col 12 == "Unknown"):
#   Date/time    col 4 + col 5, the File's start (the date filter reads it)
#   Account      col 3   Login col 14   Remote host col 15 (entity links)
#   Side         col 16, the connection side (in / out) — an Unknown File has
#                no movement (col 17 comes from the subscription config)
#   Legs         col 10
#   State        col 2: OK (Processed) / Error (Failed) / Waiting / Expired —
#                the words of the Files tables; opens the File's page
#                (files/<CoreId>.html) when it has one
#   Volume       col 8
#   CoreId       col 1 (report.js adds the File Tracking link + copy icon)
#   Filename     col 11
# Rows tint by the FILE colour (col 25: green / orange / red).
# Table 2, one row per account: Files, OK, Error (the outcome policy: Error =
# Failed or Expired), First / Last start.
#
# Runs in the transfer serial tail (bin/transfer/reports.sh, after the pool:
# the File-page sets errors/ + files/ exist) and again in bin/build.sh right
# after the failed.sh catch-up, which rewrites those sets (the page is
# re-rendered by bin/transfer/publish.sh catchup). No prose on the page (help
# page unknown-transfers).
#
# Usage:
#   ./unknown-transfers.sh   # -> data/transfer/reports/unknown-transfers.rpt
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib.sh"
mkdir -p "$REPORTS_DIR"
OUT="$REPORTS_DIR/unknown-transfers.rpt"

# the CoreIds that have a PUBLISHED File page (bin/transfer/filepages.sh)
pages=$(mktemp "${TMPDIR:-/tmp}/utpages.XXXXXX")
trap 'rm -f "$pages"' EXIT
: > "$pages"
[ -f "$CACHE_DIR/_filepages.tsv" ] && cut -f1 "$CACHE_DIR/_filepages.tsv" > "$pages"
FSRC="$FILES"; [ -f "$FSRC" ] || FSRC=/dev/null

# "F <sortkey> <ROW…>" per File, "A <account> <ROW…>" per account, "~N <n>"
agg=$(LC_ALL=C awk -F'\t' -v PAGES="$pages" '
    BEGIN { while ((getline l < PAGES) > 0) if (l != "") PG[l] = 1
            close(PAGES) }
    function human(b,   u, i, v) { split("B KB MB GB TB PB", u, " "); i = 1; v = b + 0
        while (v >= 1024 && i < 6) { v /= 1024; i++ }
        return sprintf("%.0f %s", v, u[i]) }
    function nz(x) { return (x + 0 == 0) ? "" : x + 0 }
    function clean(s) { gsub(/[\t\r]/, " ", s); return s }
    # lit(): a raw name starting with @ would read as renderer metadata; the empty block @{} keeps it literal (audit 2026-09-29 F07)
    function lit(s) { return (substr(s, 1, 1) == "@") ? "@{}" s : s }
    $12 == "Unknown" && $4 != "" {
        cid = $1; n++
        st = ($2 == "Processed") ? "OK" : ($2 == "Failed") ? "Error" : $2
        if (cid in PG) st = "@{href=../files/" cid ".html}" st
        side = ($16 == "in" || $16 == "out") ? $16 : ""   # lowercase like every in / out value (2026-09-30: "In" / "Out" before)
        res = $25; tint = (res == "green" || res == "orange" || res == "red") ? "\t@data:res=" res : ""
        printf "F\t%s\tROW\t%s %s\t%s\t%s\t%s\t%s\t%s\t%s\t@{sortval=%d}%s\t@{class=mono}%s\t%s%s\n", \
            $6, $4, $5, clean($3), clean($14), clean($15), side, $10 + 0, st, $8 + 0, human($8), cid, lit(clean($11)), tint
        a = $3; err = ($2 == "Failed" || $2 == "Expired")
        if (!(a in AF)) AO[++na] = a
        AF[a]++; if (err) { AE[a]++; te++ } else { AK[a]++; tk++ }
        tl += $10; tv += $8
        t = $4 " " substr($5, 1, 8)
        if (!(a in FT) || t < FT[a]) FT[a] = t
        if (!(a in LT) || t > LT[a]) LT[a] = t
    }
    END {
        for (i = 1; i <= na; i++) { a = AO[i]
            printf "A\t%s\tROW\t%s\t%d\t%s\t%s\t%s\t%s\n", a, clean(a), AF[a], nz(AK[a]), nz(AE[a]), FT[a], LT[a] }
        # the totals of the additive columns (2026-09-29 audit: the TOTAL rows
        # left Legs, Volume, OK and Error blank)
        printf "~N\t%d\t%d\t%d\t%s\t%s\t%s\n", n + 0, na + 0, tl + 0, (tv > 0 ? human(tv) : ""), nz(tk), nz(te)
    }' "$FSRC")
rm -f "$pages"
nf=$(printf '%s\n' "$agg" | awk -F'\t' '$1 == "~N" { print $2 }')
na=$(printf '%s\n' "$agg" | awk -F'\t' '$1 == "~N" { print $3 }')
# ("|", not TAB: TAB is IFS whitespace, so an empty field would collapse)
IFS='|' read -r tlegs tvol tok terr <<< "$(printf '%s\n' "$agg" | awk -F'\t' '$1 == "~N" { printf "%s|%s|%s|%s", ($4 > 0 ? $4 : ""), $5, $6, $7 }')"
T=$(printf '\t')

{
    printf 'TITLE\tUnknown transfers\n'
    printf 'DESC\tEvery File no subscription could be found for (subscription Unknown), newest first: account, login, remote host, side, legs, state, volume, CoreId and file name, plus a per-account summary. A routing gap to investigate; subscription tables leave these Files out.\n'
    printf 'TABLE\tFiles\twide\tsort=1:-1\tpager=500\trestint\n'
    printf 'HEAD\tDate/time\tAccount\tLogin\tRemote host\tSide\tLegs\tState\tVolume\tCoreId\tFilename\n'
    printf 'KIND\ttext\tacct\tlogin\thost\ttext\tnum\ttext\tnum\ttext\ttext\n'
    if [ "${nf:-0}" -gt 0 ]; then
        printf '%s\n' "$agg" | awk -F'\t' '$1 == "F"' | LC_ALL=C sort -t"$T" -k2,2r | cut -f3- || true
    else
        printf 'ROW\t@{colspan=10}No unknown transfers in this data window.\n'
    fi
    printf 'TOTAL\tTotal (%s Files)\t\t\t\t\t@{class=num}%s\t\t@{class=num}%s\t\t\n' "${nf:-0}" "${tlegs:-}" "${tvol:-}"
    printf 'TABLE\tPer account\tnofilter\tsort=2:-1\n'
    printf 'HEAD\tAccount\tFiles\tOK\tError\tFirst\tLast\n'
    printf 'KIND\tacct\tnum\tnumprocessed\tnumfailed\ttext\ttext\n'
    if [ "${na:-0}" -gt 0 ]; then
        printf '%s\n' "$agg" | awk -F'\t' '$1 == "A"' | LC_ALL=C sort -t"$T" -k2,2 | cut -f3- || true
    else
        printf 'ROW\t@{colspan=6}No unknown transfers in this data window.\n'
    fi
    printf 'TOTAL\tTotal (%s account(s))\t@{class=num}%s\t@{class=num processed}%s\t@{class=num failed}%s\t\t\n' "${na:-0}" "${nf:-0}" "${tok:-}" "${terr:-}"
    printf 'FOOT\n'
} > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"

echo "Data written to $OUT (${nf:-0} unknown transfer(s), ${na:-0} account(s))." >&2
