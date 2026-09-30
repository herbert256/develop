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
#   Account      col 3   Login col 14   Remote host col 15 (entity links; a
#                raw IPv4 — the in-side source address the parse keeps —
#                opens its incoming connection page, like failed.sh hostcell,
#                2026-09-30 audit A2-01)
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
# The account rows tint by the ACCOUNT's result colour (base/_accounts.tsv
# col 3; restint — 2026-09-30 audit A2-03). Default sorts: table 1 on
# Date/time (column 0), table 2 on Files (column 1), descending (audit A2-02:
# they pointed at Account and OK).
#
# Runs ONCE, in the transfer serial tail (bin/transfer/reports.sh, after the
# pool). Its File-page links test _filepages.tsv — the published set,
# final before phase 1 — and it reads _files.tsv only, so the build's former
# re-run after the failed.sh catch-up (and its catch-up re-render) went
# 2026-09-30: it came out identical. No prose on the page (help page
# unknown-transfers).
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
ACCB="$CONFIG_BASE/_accounts.tsv"; [ -f "$ACCB" ] || ACCB=/dev/null

# "F <sortkey> <ROW…>" per File, "A <account> <ROW…>" per account, "~N <n>"
agg=$(LC_ALL=C awk -F'\t' -v PAGES="$pages" -v ACCB="$ACCB" "$AWKLIB"'
    BEGIN { while ((getline l < PAGES) > 0) if (l != "") PG[l] = 1
            close(PAGES)
            # the account result colours (the Per account row tint)
            while ((getline l < ACCB) > 0) { split(l, a9, "\t"); if (a9[1] != "" && (a9[3] == "green" || a9[3] == "orange" || a9[3] == "red")) ARES[a9[1]] = a9[3] }
            close(ACCB) }
    function nz(x) { return (x + 0 == 0) ? "" : x + 0 }
    function clean(s) { gsub(/[\t\r]/, " ", s); return s }
    # the per-day counts of an account in the DATED bucket form
    # (date:Files:OK:Error, date order)
    function bkt(a,   n, D, i, j, v, o, k) {
        n = split(substr(BD[a], 2), D, SUBSEP)
        for (i = 2; i <= n; i++) { v = D[i]; j = i - 1; while (j >= 1 && D[j] > v) { D[j + 1] = D[j]; j-- } D[j + 1] = v }
        o = ""; for (i = 1; i <= n; i++) { k = a SUBSEP D[i]; o = o (i > 1 ? "," : "") D[i] ":" BF[k] ":" (BK[k] + 0) ":" (BE[k] + 0) }
        return o
    }
    # (lit() — a raw name kept literal, audit 2026-09-29 F07 — comes from bin/fmt.awk via $AWKLIB)
    $12 == "Unknown" && $4 != "" {
        cid = $1; n++
        st = ($2 == "Processed") ? "OK" : ($2 == "Failed") ? "Error" : $2
        if (cid in PG) st = "@{href=../files/" cid ".html}" st
        side = ($16 == "in" || $16 == "out") ? $16 : ""   # lowercase like every in / out value (2026-09-30: "In" / "Out" before)
        # the remote host: a raw IPv4 opens its incoming connection page (no
        # page = the renderer leaves it plain), a name keeps KIND host
        hc = clean($15); if (hc ~ /^[0-9]+[.][0-9]+[.][0-9]+[.][0-9]+$/) hc = "@{alink=incoming_connections/" hc "}" hc
        res = $25; tint = (res == "green" || res == "orange" || res == "red") ? "\t@data:res=" res : ""
        printf "F\t%s\tROW\t%s %s\t%s\t%s\t%s\t%s\t%s\t%s\t@{sortval=%d}%s\t@{class=mono}%s\t%s%s\n", \
            $6, $4, $5, clean($3), clean($14), hc, side, $10 + 0, st, $8 + 0, hbytes0($8), cid, lit(clean($11)), tint
        a = $3; err = ($2 == "Failed" || $2 == "Expired")
        if (!(a in AF)) AO[++na] = a
        AF[a]++; if (err) { AE[a]++; te++ } else { AK[a]++; tk++ }
        # the per-day Files / OK / Error of the account (the Per account
        # table re-counts for the From/To range, RECALC s0 s1 s2 — 2026-09-30)
        if (!((a SUBSEP $4) in BF)) BD[a] = BD[a] SUBSEP $4
        BF[a SUBSEP $4]++; if (err) BE[a SUBSEP $4]++; else BK[a SUBSEP $4]++
        tl += $10; tv += $8
        t = $4 " " substr($5, 1, 8)
        if (!(a in FT) || t < FT[a]) FT[a] = t
        if (!(a in LT) || t > LT[a]) LT[a] = t
    }
    END {
        for (i = 1; i <= na; i++) { a = AO[i]
            printf "A\t%s\tROW\t%s\t%d\t%s\t%s\t%s\t%s\t@data:buckets=%s%s\n", a, clean(a), AF[a], nz(AK[a]), nz(AE[a]), FT[a], LT[a], bkt(a), ((a in ARES) ? "\t@data:res=" ARES[a] : "") }
        # the totals of the additive columns (2026-09-29 audit: the TOTAL rows
        # left Legs, Volume, OK and Error blank)
        printf "~N\t%d\t%d\t%d\t%s\t%s\t%s\n", n + 0, na + 0, tl + 0, (tv > 0 ? hbytes0(tv) : ""), nz(tk), nz(te)
    }' "$FSRC")
rm -f "$pages"
nf=$(printf '%s\n' "$agg" | awk -F'\t' '$1 == "~N" { print $2 }')
na=$(printf '%s\n' "$agg" | awk -F'\t' '$1 == "~N" { print $3 }')
# ("|", not TAB: TAB is IFS whitespace, so an empty field would collapse)
IFS='|' read -r tlegs tvol tok terr <<< "$(printf '%s\n' "$agg" | awk -F'\t' '$1 == "~N" { printf "%s|%s|%s|%s", ($4 > 0 ? $4 : ""), $5, $6, $7 }')"
T=$(printf '\t')

{
    printf 'TITLE\tUnknown transfers\n'
    printf 'TABLE\tFiles\twide\tsort=0:-1\tpager=500\trestint\n'
    printf 'HEAD\tDate/time\tAccount\tLogin\tRemote host\tSide\tLegs\tState\tVolume\tCoreId\tFilename\n'
    printf 'KIND\ttext\tacct\tlogin\thost\ttext\tnum\ttext\tnum\ttext\ttext\n'
    if [ "${nf:-0}" -gt 0 ]; then
        printf '%s\n' "$agg" | awk -F'\t' '$1 == "F"' | LC_ALL=C sort -t"$T" -k2,2r | cut -f3- || true
    else
        printf 'ROW\t@{colspan=10}No unknown transfers in this data window.\n'
    fi
    printf 'TOTAL\tTotal (%s Files)\t\t\t\t\t@{class=num}%s\t\t@{class=num}%s\t\t\n' "${nf:-0}" "${tlegs:-}" "${tvol:-}"
    # DATE-AWARE since 2026-09-30 (user request: every Errors-group page gets
    # the From/To selection): Files / OK / Error re-count for the range from
    # the per-day buckets; an account with none in the range hides; First /
    # Last stay full-period (the site rule)
    if [ "${na:-0}" -gt 0 ]; then printf 'TABLE\tPer account\tsort=1:-1\trestint\n'; else printf 'TABLE\tPer account\tnofilter\tsort=1:-1\n'; fi
    printf 'HEAD\tAccount\tFiles\tOK\tError\tFirst\tLast\n'
    printf 'KIND\tacct\tnum\tnumprocessed\tnumfailed\ttext\ttext\n'
    printf 'RECALC\t-\ts0\ts1\ts2\t-\t-\n'
    if [ "${na:-0}" -gt 0 ]; then
        printf '%s\n' "$agg" | awk -F'\t' '$1 == "A"' | LC_ALL=C sort -t"$T" -k2,2 | cut -f3- || true
    else
        printf 'ROW\t@{colspan=6}No unknown transfers in this data window.\n'
    fi
    printf 'TOTAL\tTotal (%s account(s))\t@{class=num}%s\t@{class=num processed}%s\t@{class=num failed}%s\t\t\n' "${na:-0}" "${nf:-0}" "${tok:-}" "${terr:-}"
    printf 'FOOT\n'
} > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"

echo "Data written to $OUT (${nf:-0} unknown transfer(s), ${na:-0} account(s))." >&2
