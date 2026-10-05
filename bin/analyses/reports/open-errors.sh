#!/usr/bin/env bash
#
# open-errors.sh — "Open Errors" (analyses/errors.html) AND the home page's
# Errors table: ONE row set, written once here and read by both (2026-10-05,
# user request: "the Errors table on the home page and this page must give the
# same data, only code once and reuse it"; the page was Failed Subscriptions,
# analyses/failed.html, rendered straight from failed.sh's lists, while the
# home merged those rows with the red hosts / logins itself).
#
#   open-errors.rpt      -> analyses/errors.html       the Open view (default)
#   open-errors-all.rpt  -> analyses/errors-all.html   the All view
#
# THE ROWS, newest first (Date/time desc, then the name):
#   - the Failed Subscriptions rows of bin/transfer/reports/failed.sh — the
#     Open view its still-failing list (failed.rpt), RED rows only (the home's
#     2026-09-29 rule: "show only the Errors (red) and not the warnings
#     (orange)"); the All view its every-subscription list (failed-sub-all.rpt,
#     the ones green again included). Copied as they are, columns and row
#     attributes, but an unpaged row's name gets its subscription detail page
#     as an explicit link (the slugmap), so a reader needs no lookup;
#   - PLUS every red host / login no UC1 / UC3 (host) resp. UC2 / UC4 (login)
#     red subscription row covers (err_entities below): Entity (its detail
#     page) · Date/time · Reason, the red-run and id columns blank.
# The first column reads "Entity" (2026-10-01: "Rename Subscriptions to
# Entity"). failed.rpt / failed-sub-all.rpt stay failed.sh's data files: the
# Entities Reason column (publish_lib.sh) reads failed-sub-all.rpt by position.
#
# READERS: bin/analyses/publish.sh renders the two pages;
# bin/build/publish.sh write_home_errors shows the Open view's first three
# columns beside the home per-day table.
#
# An ANALYSES report: bin/analyses/reports.sh runs it after the transfer
# reports, the server reports and failed.sh's Reason catch-up (bin/build.sh),
# so every input below is final.
#
# Usage:
#   ./open-errors.sh    # -> data/analyses/reports/open-errors*.rpt
#
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib.sh"

FR="$DATA/transfer/reports/failed.rpt"
FA="$DATA/transfer/reports/failed-sub-all.rpt"
OUT="$REPORTS_DIR/open-errors.rpt"
OUTA="$REPORTS_DIR/open-errors-all.rpt"
if [ ! -f "$FR" ] || [ ! -f "$FA" ]; then
    echo "open-errors: missing $FR or $FA (failed.sh has not run) — pages not published." >&2
    rm -f "$OUT" "$OUTA"
    exit 0
fi

TMP=$(mktemp -d "${TMPDIR:-/tmp}/axoperr.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

# THE RED HOSTS AND LOGINS (2026-10-01, user request — the home Errors
# table until 2026-10-05, see the header; moved here from bin/build/publish.sh): every row of the Entities Remote hosts /
# Logins Error views (base/_hosts.tsv / _logins.tsv col 3 = red) EXCEPT a host
# that is the endpoint of a UC1 or UC3 subscription — a login the user of a
# UC2 or UC4 subscription — that already has its row in the table (a red row
# of failed.rpt). A subscription's use case: its name prefix UC1..UC4, else
# the derived one (xref/_subscriptions-ucderived.tsv — the Partners in / out
# rule). "Connected" = the colour rollup's own pairs (bin/build/result.sh):
# the configured xref/_<kind>-subscriptions.tsv plus the observed ones
# (colour/_observed-<kind>.tsv) — for a host also every subscription whose
# OUT-connection File went through it (colour/_hostlegs.tsv col 4), so a
# discovered host is matched to the flows it served.
# The row: the name, linking its detail page (details/<kind>/<slug>.html —
# the table is an index table, so the WHOLE row opens it), and the NEWEST
# piece of the evidence that made it red, the stamp and its reason:
#   - the E-level server-log line attributable to no flow that the entity's
#     own ring kept (colour/_ringorphan.tsv — result.sh orphan_red), its
#     reason classified from the ring line (bin/flip-reason.awk; "Server log
#     error" when nothing matches);
#   - a HOST with no configured subscription: its last OUT-connection File
#     when that one Failed (result.sh host_own_unpaired), the reason of
#     failed-files.rpt for it;
#   - a connected RED subscription whose use case did not exclude the row:
#     that subscription's newest red failed.rpt row (stamp and reason).
# Same five-field lines as the subscription rows: stamp, name, href, reason,
# colour.
err_entities() {   # $1 = the data root
    local d=$1 kind tab pairs uc red evid
    local fr="$d/transfer/reports/failed.rpt" ff="$d/transfer/reports/failed-files.rpt"
    local ucd="$d/flow-manager/xref/_subscriptions-ucderived.tsv" legs="$d/colour/_hostlegs.tsv"
    local orph="$d/colour/_ringorphan.tsv" iph="input/ip/ip-hosts.tsv"
    [ -f "$fr" ] || return 0
    [ -f "$ff" ] || ff=/dev/null; [ -f "$ucd" ] || ucd=/dev/null; [ -f "$legs" ] || legs=/dev/null
    [ -f "$orph" ] || orph=/dev/null; [ -f "$iph" ] || iph=/dev/null
    for kind in hosts logins; do
        [ -f "$d/flow-manager/base/_$kind.tsv" ] || continue
        case $kind in hosts) uc="UC1 UC3" ;; logins) uc="UC2 UC4" ;; esac
        pairs="$d/flow-manager/xref/_$kind-subscriptions.tsv"; [ -f "$pairs" ] || pairs=/dev/null
        local obs="$d/colour/_observed-$kind.tsv"; [ -f "$obs" ] || obs=/dev/null
        local smap="$d/transfer/reports/details/$kind/_slugmap.tsv"; [ -f "$smap" ] || smap=/dev/null
        local klegs=/dev/null; [ "$kind" = hosts ] && klegs=$legs
        LC_ALL=C awk -F'\t' -v KIND="$kind" -v UCS="$uc" -v FR="$fr" -v FF="$ff" -v UCD="$ucd" \
            -v PAIRS="$pairs" -v OBS="$obs" -v LEGS="$klegs" -v ORPH="$orph" -v IPH="$iph" -v SMAP="$smap" \
            -v RINGS="$d/server/cache/$kind" "$(cat bin/flip-reason.awk)"'
            function uco(s,   u) { u = toupper(s); if (u ~ /^UC[1-4][-_]/) return substr(u, 1, 3); return (u in UD) ? UD[u] : "" }
            function strip(c) { sub(/^@\{[^}]*\}/, "", c); return c }
            function cand(t, st, why) { if (st > EST[k] || !(k in EST)) { EST[k] = st; EWH[k] = why } }
            BEGIN {
                n = split(UCS, a, " "); for (i = 1; i <= n; i++) WANT[a[i]] = 1
                while ((getline l < UCD) > 0) { split(l, a, "\t"); if (a[1] != "") UD[toupper(a[1])] = a[2] } close(UCD)
                # the subscriptions IN the table (the red failed.rpt rows) and
                # the newest red row of each: its stamp and reason
                while ((getline l < FR) > 0) { m = split(l, a, "\t")
                    if (a[1] == "TABLE") tb++
                    if (tb != 1 || a[1] != "ROW") continue
                    r = 0; for (i = 3; i <= m; i++) if (a[i] == "@data:res=red") r = 1
                    if (!r) continue
                    u = toupper(strip(a[2])); INT[u] = 1
                    if (!(u in SST) || a[3] > SST[u]) { SST[u] = a[3]; SWH[u] = a[4] } }
                close(FR)
                while ((getline l < SMAP) > 0) { split(l, a, "\t"); if (a[1] != "" && !(toupper(a[1]) in SLG)) SLG[toupper(a[1])] = a[2] } close(SMAP)
            }
            FILENAME == ARGV[1] { if ($3 == "red") { RED[toupper($1)] = $1 } next }            # base/_<kind>.tsv
            FILENAME == ARGV[2] || FILENAME == ARGV[3] {                                      # configured + observed pairs
                k = toupper($1); if (!(k in RED) || $2 == "") next
                if (FILENAME == ARGV[2]) CONF[k] = 1
                PS[k, toupper($2)] = 1; next }
            FILENAME == ARGV[4] {                                                             # hosts: the leg pairs + the last OUT File
                k = toupper($1); if (!(k in RED)) next
                if ($4 != "") PS[k, toupper($4)] = 1
                if ($2 >= LSK[k]) { LSK[k] = $2; LOC[k] = $3; LSU[k] = $4 }
                next }
            END {
                for (k in RED) {
                    # EXCLUDED: connected to a subscription of the wanted use
                    # cases that already has its row in the table
                    skip = 0
                    for (p in PS) { split(p, q, SUBSEP); if (q[1] != k) continue
                        if ((q[2] in INT) && (uco(q[2]) in WANT)) { skip = 1; break }
                        if ((q[2] in INT) && (!(k in SEV) || SST[q[2]] > SEV[k])) { SEV[k] = SST[q[2]]; SRW[k] = SWH[q[2]] } }
                    if (skip) continue
                    KEEP[k] = 1
                    if (k in SEV) cand(k, SEV[k], SRW[k])
                    # a host with no configured subscription whose last OUT File failed
                    if (KIND == "hosts" && !(k in CONF) && LOC[k] == "Failed") {
                        st = substr(LSK[k], 1, 4) "-" substr(LSK[k], 5, 2) "-" substr(LSK[k], 7, 2) " " substr(LSK[k], 9)
                        NEEDF[toupper(LSU[k]) SUBSEP st] = k; FST[k] = st }
                }
                # the reason of that File (failed-files.rpt: Subscription,
                # Date/time, Error reason — the File start to the millisecond)
                if (length(NEEDF) > 0) {
                    while ((getline l < FF) > 0) { split(l, a, "\t"); if (a[1] != "ROW") continue
                        key = toupper(strip(a[2])) SUBSEP a[3]; if (key in NEEDF) FRS[NEEDF[key]] = strip(a[4]) }
                    close(FF) }
                for (k in FST) cand(k, FST[k], ((k in FRS) && FRS[k] != "" && FRS[k] != "-") ? FRS[k] : "Failed File")
                # the orphan server-log line (result.sh orphan_red): its stamp,
                # the reason classified from the ring line itself — the
                # endpoint ring itself or the ring of one of its forward addresses
                kk = (KIND == "hosts") ? "hosts" : "logins"
                while ((getline l < ORPH) > 0) { split(l, a, "\t"); if (a[1] == kk && (toupper(a[2]) in KEEP)) OST[toupper(a[2])] = a[3] } close(ORPH)
                if (KIND == "hosts") { while ((getline l < IPH) > 0) { split(l, a, "\t"); if (a[1] != "" && (toupper(a[2]) in OST)) ALT[toupper(a[2])] = ALT[toupper(a[2])] " " a[1] } close(IPH) }
                for (k in OST) {
                    why = ""; n = split(RED[k] ALT[k], F, " ")
                    for (i = 1; i <= n && why == ""; i++) { f = RINGS "/" F[i] "_err_warn.tsv"
                        while ((getline l < f) > 0) { split(l, a, "\t"); if (a[3] == "E" && a[1] " " a[2] == OST[k]) { why = flip_reason(a[5]); if (why == "") why = "Server log error"; break } }
                        close(f) }
                    cand(k, OST[k], (why != "") ? why : "Server log error") }
                for (k in KEEP) {
                    h = (k in SLG) ? "details/" KIND "/" SLG[k] ".html" : ""
                    printf "%s\t%s\t%s\t%s\tred\n", ((k in EST) ? EST[k] : ""), RED[k], h, ((k in EWH) ? EWH[k] : "") }
            }' "$d/flow-manager/base/_$kind.tsv" "$pairs" "$obs" "$klegs"
    done
}


err_entities "$DATA" > "$TMP/ent"

SMAP="$DATA/transfer/reports/details/subscriptions/_slugmap.tsv"; [ -f "$SMAP" ] || SMAP=/dev/null
# write_view LIST OUT VIEW — one page report: LIST = failed.sh's list, VIEW =
# open (red rows only) | all
write_view() {
    local list=$1 out=$2 view=$3 n
    LC_ALL=C awk -F'\t' -v OFS='\t' -v SMAP="$SMAP" -v VIEW="$view" '
        BEGIN { while ((getline l < SMAP) > 0) { split(l, m, "\t"); if (m[1] != "") { SL[m[1]] = m[2]; if (!(toupper(m[1]) in SU)) SU[toupper(m[1])] = m[2] } } close(SMAP) }
        FNR == 1 { f++ }
        f == 1 && $1 == "TABLE" { tb++ }
        f == 1 && (tb != 1 || $1 != "ROW") { next }
        f == 1 {   # a Failed Subscriptions row
            res = ""; for (i = 3; i <= NF; i++) if (substr($i, 1, 10) == "@data:res=") res = substr($i, 11)
            if (VIEW == "open" && res != "red") next
            nm = $2
            if (substr(nm, 1, 2) == "@{") nm = substr(nm, index(nm, "}") + 1)
            else { sg = (nm in SL) ? SL[nm] : ((toupper(nm) in SU) ? SU[toupper(nm)] : ""); if (sg != "") $2 = "@{href=../details/subscriptions/" sg ".html}" nm }
            print $3, nm, $0; next }
        {   # a host / login row: stamp, name, href, reason, colour
            if ($3 != "") row = "ROW\t@{href=../" $3 ",nolink=1}" $2 "\t" $1 "\t" $4 "\t\t\t\t\t@data:href=../" $3 "\t@data:res=" $5
            else          row = "ROW\t@{nolink=1}" $2 "\t" $1 "\t" $4 "\t\t\t\t\t@data:res=" $5
            print $1, $2, row }' "$list" "$TMP/ent" \
    | LC_ALL=C sort -t$'\t' -k1,1r -k2,2 | cut -f3- > "$TMP/rows"
    n=$(wc -l < "$TMP/rows" | tr -d ' ')
    {
        printf 'TITLE\tOpen Errors\n'
        # the failed.sh lists' table: newest first by default, sortable,
        # whole-row links (rowlink + @data:href), the row tinted by its colour
        printf 'TABLE\t\twide\tsort=1:-1\trowlink\trestint\tnosearch\n'
        printf 'HEAD\tEntity\tDate/time\tReason\tLast green day\tDays red\tFailures in a row\tCoreId / SessionId\n'
        printf 'KIND\tsite\ttext\ttext\ttext\tnum\tnum\tmono\n'
        cat "$TMP/rows"
        printf 'TOTAL\tTotal (%d rows)\t\t\t\t\t\t\n' "$n"
        printf 'FOOT\n'
    } > "$out.tmp"
    mv "$out.tmp" "$out"
}
write_view "$FR" "$OUT" open
write_view "$FA" "$OUTA" all

echo "Data written to $OUT ($(grep -c '^ROW' "$OUT" || true) row(s)) + $OUTA ($(grep -c '^ROW' "$OUTA" || true) row(s))." >&2
