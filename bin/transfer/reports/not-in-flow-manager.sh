#!/usr/bin/env bash
#
# not-in-flow-manager.sh — "Not in Flow Manager" (Failures & Retries group):
# one row for every entity VALUE that appears in the transfer log but is NOT in
# the current FlowManager configuration — all TEN entity lists checked:
#   Account      _files col 3   vs base/_accounts.tsv        (exact)
#   Subscription _files col 12  vs base/_subscriptions.tsv   (configured name PREFIXES the logged value — the showseen rule)
#   Login        _files col 14  vs base/_logins.tsv          (exact)
#   Host         _files col 15, connection col 16 == out, vs base/_hosts.tsv (exact; hosts are OUTBOUND endpoints)
#   Whitelist    _files col 15, connection col 16 == in,  vs base/_white.tsv (exact; the INCOMING source addresses)
#   Logical      _files col 13 resolved through the FlowID map vs base/_logicals.tsv
#                (an UNMAPPED profile value is NOT surfaced — the raw profile
#                stays parse-internal, so these rows are empty by construction)
#   Partner      _files col 20  vs base/_partners.tsv        (exact)
#   Application  _files col 18  vs base/_apps.tsv            (exact)
#   Domain       _files col 19  vs base/_domains.tsv        (exact)
# All matching is case-insensitive. Counts are Files (one logical transfer per
# CoreId). A missing base cache
# degrades to an empty configured list (everything logged shows), like showseen.
#
# Usage:
#   ./not-in-flow-manager.sh   # reads the caches, writes data/transfer/reports/not-in-flow-manager.rpt
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib.sh"
mkdir -p "$REPORTS_DIR"
OUT="$REPORTS_DIR/not-in-flow-manager.rpt"

shopt -s nullglob
files=("$INPUT_DIR"/*.csv)
shopt -u nullglob
if [ ${#files[@]} -eq 0 ]; then
    echo "No *.csv in $INPUT_DIR — building from the EMPTY caches (config-only estate)" >&2
fi
ensure_parsed
skip_if_fresh "$OUT" "${BASH_SOURCE[0]}" "$FM_INPUT_DIR/partners.json" "$FM_INPUT_DIR/subscriptions.json"
echo "Found ${#files[@]} file(s) in '$INPUT_DIR', processing..." >&2

B="$CONFIG_BASE"
for _b in _accounts _subscriptions _logins _hosts _white _logicals _partners _apps _domains _bl; do
    eval "f$_b=\"$B/$_b.tsv\""
done
# The base caches are AMENDED after flow-manager wrote them: result.sh
# discover_logged appends every logged-but-unconfigured subscription/host (the
# "UCx_" synthetic names included) and seen-in-server-log.sh appends its blue
# discoveries — so by report time "not in the base cache" no longer means "not
# in Flow Manager", and reading base would silently empty this report. The
# pristine per-type snapshot flow-manager takes BEFORE either append step
# (.configured.tsv) is the real configured list (2026-08); the base caches
# stay the fallback for a tree whose flow-manager run predates the snapshot.
if [ -f "$B/.configured.tsv" ]; then
    TMP=$(mktemp -d "${TMPDIR:-/tmp}/axnifm.XXXXXX")
    trap 'rm -rf "$TMP"' EXIT
    for _b in _accounts _subscriptions _logins _hosts _white _logicals _partners _apps _domains _bl; do
        awk -F'\t' -v t="$_b" '$1 == t { print $2 }' "$B/.configured.tsv" > "$TMP/$_b.tsv"
        eval "f$_b=\"$TMP/$_b.tsv\""
    done
fi

# Pass 1: aggregate the unconfigured (type, value) pairs from $FILES —
# TAB lines "tidx  files  name  failed  processed  bytes  first  last  buckets"
# — then sort by type order / Files desc / name and format the .rpt.
awk -F'\t' \
    -v ACC="$f_accounts" -v SUB="$f_subscriptions" -v LOG="$f_logins" -v HST="$f_hosts" \
    -v WHT="$f_white" -v LGC="$f_logicals" -v PTN="$f_partners" -v APP="$f_apps" -v DOM="$f_domains" -v BLB="$f_bl" \
    -v PLM="$CONFIG_XREF/_profiles-logicals.tsv" -v SBLM="$CONFIG_XREF/_subscriptions-bl.tsv" '
    function load(t, f,   l, a) {
        while ((getline l < f) > 0) { split(l, a, "\t"); if (a[1] != "") cfg[t SUBSEP toupper(a[1])] = 1 }
        close(f)
    }
    BEGIN {
        load(1, ACC); load(3, LOG); load(4, HST); load(5, WHT)
        load(6, LGC); load(7, PTN); load(8, APP); load(9, DOM); load(10, BLB)
        while ((getline l < PLM) > 0) { split(l, a, "\t"); if (a[1] != "" && a[2] != "") PL[toupper(a[1])] = a[2] }
        close(PLM)
        while ((getline l < SBLM) > 0) { split(l, a, "\t"); if (a[1] != "" && a[2] != "") SBL[toupper(a[1])] = SBL[toupper(a[1])] "\037" a[2] }
        close(SBLM)
        # configured subscription names as a LIST (prefix matching)
        while ((getline l < SUB) > 0) { split(l, a, "\t"); if (a[1] != "") SN[++ns] = toupper(a[1]) }
        close(SUB)
    }
    # is the logged site value covered by a configured subscription (prefix rule)?
    function subcfg(v,   u, i) {
        u = toupper(v)
        if (u in PFC) return PFC[u]
        for (i = 1; i <= ns; i++) if (index(u, SN[i]) == 1) { PFC[u] = 1; return 1 }
        PFC[u] = 0; return 0
    }
    function add(t, v,   k) {
        k = t SUBSEP toupper(v)
        if (!(k in n)) { disp[k] = v; ord[++nk] = k }
        n[k]++; vol[k] += size; if (pr) p[k]++; else fl[k]++
        if (first[k] == "" || sk < firstk[k]) { firstk[k] = sk; first[k] = dt " " tm }
        if (last[k] == ""  || sk > lastk[k])  { lastk[k]  = sk; last[k]  = dt " " tm }
        db = k SUBSEP date
        if (!(db in bn)) { bord[k] = bord[k] SUBSEP date }
        bn[db]++; bv[db] += size; if (pr) bp[db]++; else bf[db]++
    }
    {
        date = $4; if (date == "") next
        dt = $4; tm = $5; sk = $6; size = $8 + 0; pr = ($2 != "Failed" && $2 != "Expired")
        if ($3  != "" && !((1 SUBSEP toupper($3))  in cfg)) add(1, $3)
        if ($12 != "" && !subcfg($12))                      add(2, $12)
        if ($14 != "" && !((3 SUBSEP toupper($14)) in cfg)) add(3, $14)
        if ($15 != "" && $16 == "out" && !((4 SUBSEP toupper($15)) in cfg)) add(4, $15)
        if ($15 != "" && $16 == "in"  && !((5 SUBSEP toupper($15)) in cfg)) add(5, $15)
        if ($13 != "" && (toupper($13) in PL)) { lg9 = PL[toupper($13)]
            if (!((6 SUBSEP toupper(lg9)) in cfg)) add(6, lg9) }
        if ($20 != "" && !((7 SUBSEP toupper($20)) in cfg)) add(7, $20)
        if ($18 != "" && !((8 SUBSEP toupper($18)) in cfg)) add(8, $18)
        if ($19 != "" && !((9 SUBSEP toupper($19)) in cfg)) add(9, $19)
        if ($12 != "" && (toupper($12) in SBL)) { nb9 = split(substr(SBL[toupper($12)], 2), B9, "\037")
            for (ib9 = 1; ib9 <= nb9; ib9++) if (!((10 SUBSEP toupper(B9[ib9])) in cfg)) add(10, B9[ib9]) }
    }
    END {
        for (i = 1; i <= nk; i++) { k = ord[i]
            split(k, K, SUBSEP)
            bk = ""
            m = split(substr(bord[k], 2), D, SUBSEP)
            for (j = 1; j <= m; j++) { db = k SUBSEP D[j]
                bk = bk (bk == "" ? "" : ",") D[j] ":" bn[db] ":" (bf[db]+0) ":" (bp[db]+0) ":" (bv[db]+0) }
            printf "%s\t%d\t%s\t%d\t%d\t%d\t%s\t%s\t%s\n", K[1], n[k], disp[k], fl[k]+0, p[k]+0, vol[k], first[k], last[k], bk
        }
    }
' "$FILES" \
| LC_ALL=C sort -t$'\t' -k1,1n -k2,2nr -k3,3 \
| awk -F'\t' -v nfiles="${#files[@]}" -v now="$(date '+%Y-%m-%d %H:%M:%S')" '
    function human(b,   u, i, v) {
        split("B KB MB GB TB PB", u, " ")
        i = 1; v = b + 0
        while (v >= 1024 && i < 6) { v /= 1024; i++ }
        if (i == 1) return sprintf("%d %s", v, u[i])
        return sprintf("%.2f %s", v, u[i])
    }
    BEGIN {
        split("Account|Subscription|Login|Host|Whitelist|Logical|Partner|Application|Domain|BL", TL, "|")
        split("accounts|subscriptions|logins|hosts||logicals|partners|applications|domains|bl", SD, "|")
        printf "TITLE\tNot in Flow Manager\n"
        printf "DESC\tEvery entity value seen in the transfer logs that the current FlowManager configuration does not know — all ten entity lists checked.\n"
        printf "INTRO\tEvery entity VALUE that appears in the transfer logs but is **not in the current FlowManager configuration** — checked against all ten configured lists (accounts, subscriptions, logins, hosts, whitelist, logical flows, partners, applications, domains, BL tags). These are the flows running outside the configuration: test uploads, renamed or deleted config objects, or unlisted partner addresses.\n"
        printf "TABLE\tLogged but not configured\twide\tgroup\n"
        printf "HEAD\tType\tName\tFiles\tError\tOK\tVolume\tFirst seen\tLast seen\n"
        printf "KIND\ttext\ttext\tnum\tnumfailed\tnumprocessed\tnum\ttext\ttext\n"
        printf "RECALC\t-\t-\ts0\ts1\ts2\th3\t-\t-\n"
    }
    {
        t = $1 + 0
        nm = $3
        cell = (SD[t] != "") ? "@{alink=" SD[t] "/" nm "}" nm : nm
        printf "ROW\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t@data:buckets=%s\n", TL[t], cell, $2, $4, $5, human($6), $7, $8, $9
        rows++; tf += $2; te += $4; to += $5; tb += $6
    }
    END {
        printf "TOTAL\tTotal (%d rows)\t\t@{class=num}%d\t@{class=num failed}%d\t@{class=num processed}%d\t@{class=num}%s\t\t\n", rows+0, tf+0, te+0, to+0, human(tb+0)
        printf "NOTE\tCounts Files — one logical transfer each. Matching is case-insensitive; a logged subscription value counts as configured when a configured subscription name **prefixes** it (the site-wide rule). **Host** rows are outbound endpoints we dialed that partners.json does not list; **Whitelist** rows are incoming source addresses that no AllowIP whitelist entry covers. A missing FlowManager export makes every logged value of that type appear here.\n"
        printf "NOTE\tThese are the same values that render UNTINTED (no status color) on the Entities pages — FlowManager has no result for them.\n"
        printf "SUMMARY\tUnconfigured values: %d  |  Files touched: %d  |  Volume: %s\n", rows+0, tf+0, human(tb+0)
        printf "FOOT\tGenerated on %s from %s file(s)\n", now, nfiles
    }
' > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"

echo "Data written to $OUT." >&2
