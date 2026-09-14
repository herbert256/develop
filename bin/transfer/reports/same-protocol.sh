#!/usr/bin/env bash
#
# same-protocol.sh — "Inbound and Outbound same Protocol" (2026-09-14, user
# request): the Files (CoreIds) whose FIRST inbound leg used the SAME protocol
# as their LAST outbound leg — e.g. an SFTP upload that also left over SFTP
# instead of going on to the CFT (a delivery collected back by a partner).
#
#   first inbound  the File's Inbound leg with the EARLIEST start (_transfers.tsv
#                  col 2 Inbound, col 13 sort key), its protocol col 10
#   last outbound  the File's Outbound leg with the LATEST start
#   listed when both exist and the two protocols are equal (as logged: ssh,
#   ftp, pesit, routing)
#
# EXCLUDED and deliberately NOT mentioned on the page or its help (user
# request): subscriptions of use case UC5, UC6, UC7 or UC8 — by the name
# prefix, else the derived use case (xref/_subscriptions-ucderived.tsv) — whose
# partner-to-partner relays carry one protocol on both sides by design.
#
# Two tables: per subscription and protocol (Files, OK, Error, first and last
# day — whole-window figures, so nofilter) and every File, newest first, 500
# per page: Subscription, Date/time (the File start — the date filter reads
# it), Protocol, First inbound and Last outbound (their start times), Legs,
# Outcome, CoreId, Filename. Rows tint by the subscription's result colour
# (base/_subscriptions.tsv col 3). No prose on the page (help page
# same-protocol).
#
# Usage:
#   ./same-protocol.sh   # reads the transfer caches, writes data/transfer/reports/same-protocol.rpt
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib.sh"
mkdir -p "$REPORTS_DIR"
OUT="$REPORTS_DIR/same-protocol.rpt"
UCDF="$CONFIG_XREF/_subscriptions-ucderived.tsv"   # subscription <TAB> derived UC
SUBRES="$CONFIG_BASE/_subscriptions.tsv"           # subscription <TAB> ... <TAB> result colour (col 3)

shopt -s nullglob
files=("$INPUT_DIR"/*.csv)
shopt -u nullglob
ensure_config
ensure_parsed
DEPS=("${BASH_SOURCE[0]}")
[ -f "$UCDF" ] && DEPS+=("$UCDF")
[ -f "$SUBRES" ] && DEPS+=("$SUBRES")
skip_if_fresh "$OUT" "${BASH_SOURCE[0]}" "${DEPS[@]}"
echo "Found ${#files[@]} file(s) in '$INPUT_DIR', processing..." >&2
[ -f "$UCDF" ] || UCDF=/dev/null
[ -f "$SUBRES" ] || SUBRES=/dev/null

TMP=$(mktemp -d "${TMPDIR:-/tmp}/sameproto.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
TAB=$(printf '\t')

# ONE awk: the legs (first inbound / last outbound per CoreId), then the Files
# (outcome, subscription, name, start) — emits the File rows and the
# per-subscription figures, each behind a sort prefix
LC_ALL=C awk -F'\t' -v UCDF="$UCDF" -v SUBRES="$SUBRES" -v LEGS="$PARSED" -v FILEROWS="$TMP/files" -v SUBROWS="$TMP/subs" '
    BEGIN {
        while ((getline l < UCDF) > 0) { n = split(l, a, "\t"); if (n >= 2 && a[1] != "" && a[2] != "") UCD[toupper(a[1])] = toupper(a[2]) }
        close(UCDF)
        while ((getline l < SUBRES) > 0) { n = split(l, a, "\t"); if (n >= 3 && a[1] != "") SRES[toupper(a[1])] = a[3] }
        close(SUBRES)
    }
    FILENAME == LEGS {
        c = $1; NL[c]++
        if ($2 == "Inbound")       { if (!(c in IK) || $13 < IK[c]) { IK[c] = $13; IP[c] = $10; IT[c] = $11 " " $12 } }
        else if ($2 == "Outbound") { if (!(c in OK) || $13 > OK[c]) { OK[c] = $13; OP[c] = $10; OT[c] = $11 " " $12 } }
        next
    }
    {   # _files.tsv: 1 CoreId, 2 outcome, 4/5 start, 6 sort key, 11 file, 12 subscription
        c = $1
        if (!(c in IP) || !(c in OP) || IP[c] != OP[c] || IP[c] == "") next
        s = $12; su = toupper(s); u = ""
        if (match(su, /^UC[0-9]+/)) u = substr(su, 1, RLENGTH); else if (su in UCD) u = UCD[su]
        if (u ~ /^UC[5-8]$/) next
        res = (su in SRES) ? SRES[su] : ""
        tint = (res == "green" || res == "orange" || res == "red" || res == "blue") ? "\t@data:res=" res : ""
        bad = ($2 == "Failed" || $2 == "Expired")
        oc = bad ? "@{class=failed}" $2 : ($2 == "Processed" ? "@{class=processed}" $2 : $2)
        printf "%s\tROW\t%s\t%s %s\t%s\t%s\t%s\t%d\t%s\t@{class=mono}%s\t%s%s\n", $6, s, $4, $5, IP[c], IT[c], OT[c], NL[c], oc, c, $11, tint > FILEROWS
        k = s SUBSEP IP[c]
        FN[k]++; if (bad) FE[k]++; else FO[k]++
        if (!(k in FF) || $4 < FF[k]) FF[k] = $4
        if (!(k in FL) || $4 > FL[k]) FL[k] = $4
        TT[k] = tint
    }
    END {
        for (k in FN) { split(k, a, SUBSEP)
            printf "%d\tROW\t%s\t%s\t%d\t%d\t%d\t%s\t%s%s\n", FN[k], a[1], a[2], FN[k], FO[k] + 0, FE[k] + 0, FF[k], FL[k], TT[k] > SUBROWS }
    }
' "$PARSED" "$FILES"
touch "$TMP/files" "$TMP/subs"
nf=$(wc -l < "$TMP/files" | tr -d ' ')

{
    printf 'TITLE\tInbound and Outbound same Protocol\n'
    printf 'DESC\tFiles whose first inbound leg used the same protocol as their last outbound leg (for example an SFTP upload that also left over SFTP instead of going on to the CFT): per subscription and File by File.\n'
    printf 'KEYWORDS\tsame protocol,inbound,outbound,first inbound,last outbound,protocol,ssh,sftp,ftp,pesit,collected back,pattern,legs\n'
    printf 'TABLE\tPer subscription\twide\tnofilter\trestint\n'
    printf 'HEAD\tSubscription\tProtocol\tFiles\tOK\tError\tFirst\tLast\n'
    printf 'KIND\tsite\ttext\tnum\tnumprocessed\tnumfailed\ttext\ttext\n'
    LC_ALL=C sort -t"$TAB" -k1,1nr -k3,3 "$TMP/subs" | cut -f2- | awk -F'\t' '{ print; n++; f += $4; o += $5; e += $6 }
        END { printf "TOTAL\tTotal (%d subscription(s))\t\t@{class=num}%d\t@{class=num processed}%d\t@{class=num failed}%d\t\t\n", n + 0, f + 0, o + 0, e + 0 }'
    printf 'TABLE\tFiles\twide\tpager=500\tsort=1:-1\trestint\n'
    printf 'HEAD\tSubscription\tDate/time\tProtocol\tFirst inbound\tLast outbound\tLegs\tOutcome\tCoreId\tFilename\n'
    printf 'KIND\tsite\ttext\ttext\ttext\ttext\tnum\ttext\ttext\ttext\n'
    LC_ALL=C sort -t"$TAB" -k1,1r "$TMP/files" | cut -f2-
    printf 'SUMMARY\tFiles with the same inbound and outbound protocol: %s\n' "${nf:-0}"
    printf 'FOOT\tGenerated on %s from %s file(s)\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${#files[@]}"
} > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"

echo "Data written to $OUT (${nf:-0} File(s) with the same inbound and outbound protocol)." >&2
