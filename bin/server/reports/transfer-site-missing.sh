#!/usr/bin/env bash
#
# transfer-site-missing.sh — "Transfer site missing": the server-log warning
#
#   Transfer site ID is not present in environment.
#   Using host, port and user: <host>:<port>:<user>
#
# SecureTransport ran a transfer with NO transfer site in its environment and
# fell back to the raw host, port and user of the communication profile. The
# flow still moves — the fallback works — but nothing ties the connection to a
# configured subscription, which is why this line can be attributed to no flow:
# it says in so many words that the transfer carried no site. That is also what
# makes it worth its own page. It is a CONFIGURATION gap (a route or profile
# that lost its transfer-site reference), not a runtime failure, and it is
# invisible everywhere else: the message reaches no other report, it only sits
# in the host rings, where it used to redden every subscription of the endpoint.
#
# ROWS ARE HOSTS, because that is all the message names.
#
# UNRESOLVED ONLY: a host that has moved a file OK SINCE its newest such
# message is dropped — a later OK transfer through the same endpoint says the
# gap is closed, the same "recovered since" test bin/build/result.sh applies to
# an unattributable ring Error (orphan_red) and deploy-errors applies to a
# configuration defect. The intro says how many were cleared that way.
#
# Sources — no log parsing of its own beyond the cache:
#   $PARSED                    the server parse cache (1=date 2=time 3=level
#                              5=message 6=session)
#   $TRANSFER_CACHE/_files.tsv the OK-since test: col 15 host, col 16 the
#                              connection side, col 2 the outcome, cols 4+5 the
#                              stamp — the OUT-side population the remote-host
#                              report counts.
#
# Usage:
#   ./transfer-site-missing.sh   # -> data/<env>/server/reports/transfer-site-missing.rpt
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib.sh"
mkdir -p "$REPORTS_DIR"
OUT="$REPORTS_DIR/transfer-site-missing.rpt"

FILES_TSV="$TRANSFER_CACHE/_files.tsv"
[ -f "$FILES_TSV" ] || FILES_TSV=/dev/null

shopt -s nullglob
files=("$INPUT_DIR"/*.csv)
shopt -u nullglob
if [ ${#files[@]} -eq 0 ]; then
    echo "No server input for this env — page not published." >&2
    rm -f "$OUT"
    exit 0
fi
ensure_parsed
# The transfer cache is a cross-area DEP: the "recovered since" test reads it,
# so a new OK File must be able to clear a host from this page.
skip_if_fresh "$OUT" "${BASH_SOURCE[0]}" "$FILES_TSV"
echo "Scanning the server cache for transfer-site-missing warnings..." >&2

GEN=$(date '+%Y-%m-%d %H:%M:%S')

# ONE pass: the warnings per host (with the users seen and the per-day buckets),
# then the transfer cache for the last OK file per OUT-side host.
agg=$(LC_ALL=C awk -F'\t' "$LOGLINES_AWK"'
    function nz(v) { return v == "" ? "-" : v }
    FILENAME == ARGV[1] {                       # the last OK file per OUT-side host
        if ($16 == "out" && $15 != "" && $2 != "Failed" && $2 != "Expired") {
            h = tolower($15); t = $4 " " $5
            if (t > ok[h]) ok[h] = t }
        next
    }
    index($5, "Transfer site ID is not present in environment") != 1 { next }
    {
        # "… Using host, port and user: <host>:<port>:<user>"
        p = index($5, "Using host, port and user: ")
        if (p == 0) next
        rest = substr($5, p + 27)
        n1 = index(rest, ":"); if (n1 <= 1) next
        h = tolower(substr(rest, 1, n1 - 1))
        r2 = substr(rest, n1 + 1)
        n2 = index(r2, ":")
        port = (n2 > 1) ? substr(r2, 1, n2 - 1) : ""
        usr  = (n2 > 0) ? substr(r2, n2 + 1) : ""
        sub(/[[:space:]].*$/, "", usr); sub(/\.$/, "", usr)
        cnt[h]++
        cd[h SUBSEP $1]++
        if (port != "" && !((h SUBSEP port) in pseen)) { pseen[h SUBSEP port] = 1; ports[h] = ports[h] (ports[h] ? ", " : "") port }
        if (usr  != "" && !((h SUBSEP usr) in useen))  { useen[h SUBSEP usr] = 1;  users[h] = users[h] (users[h] ? ", " : "") usr }
        sk = $1 " " $2
        if (fst[h] == "" || sk < fst[h]) fst[h] = sk
        if (sk > lst[h]) lst[h] = sk
        addline(h, sk, lvlname($3) " " compname($4) "  " substr($5, 1, 200))
        tot++
    }
    END {
        for (h in cnt) {
            # RECOVERED: an OK file through this endpoint AFTER the newest
            # warning closes it — the row is dropped, not shown greyed
            if ((h in ok) && ok[h] > lst[h]) { cleared++; clines += cnt[h]; continue }
            bk = ""
            for (k in cd) { split(k, a, SUBSEP)
                if (a[1] == h) bk = bk (bk ? "," : "") a[2] ":" cd[k] }
            printf "R\t%s\t%d\t%s\t%s\t%s\t%s\t%s\n", h, cnt[h], nz(users[h]), nz(ports[h]), fst[h], lst[h], lastlines(h)
            shown++; slines += cnt[h]
        }
        printf "TOT\t%d\t%d\t%d\t%d\t%d\n", tot + 0, shown + 0, slines + 0, cleared + 0, clines + 0
    }
' "$FILES_TSV" "$PARSED")

# `|| true` on both: an env with no such warning (production) makes grep exit
# 1, which set -e + pipefail would turn into an aborted BUILD — the empty-grep
# trap, the same reason the codebase caps top-N lists with awk and never `head`.
IFS=$'\t' read -r _t tot_lines n_host n_lines n_clear n_clines <<< "$(printf '%s\n' "$agg" | { grep $'^TOT\t' || true; })"
rows=$(printf '%s\n' "$agg" | { grep $'^R\t' || true; } | LC_ALL=C sort -t"$(printf '\t')" -k3,3nr \
       | awk -F'\t' -v OFS='\t' '{ print "ROW", $2, $3, $4, $5, $6, $7, "@data:loglines=" $8 }')

{
    printf 'TITLE\tTransfer site missing\n'
    printf 'DESC\tServer-log warnings where a transfer ran with no transfer site in its environment and fell back to the raw host, port and user — per endpoint, hosts that have delivered OK since excluded.\n'
    printf 'KEYWORDS\ttransfer site,site id,not present,environment,fallback,host port user,configuration,missing,profile,route\n'
    printf 'INTRO\t**"Transfer site ID is not present in environment. Using host, port and user: …"** — SecureTransport ran a transfer with **no transfer site** in its environment and fell back to the communication profile'"'"'s raw **host, port and user**. The transfer still moves, so this is a **configuration gap** rather than a runtime failure: a route or profile that lost its transfer-site reference. It is the one server-log message that names NO flow — it says the transfer carried no site — so the rows here are **endpoints**, not subscriptions.\n'
    printf 'INTRO\t**%s warning(s)** in the log window. Hosts that have moved a file OK **since** their newest warning are **not listed**: a later OK transfer through the same endpoint says the gap is closed. %s\n' \
        "$(printf '%s' "${tot_lines:-0}")" \
        "$( [ "${n_clear:-0}" -gt 0 ] && printf 'That cleared **%s** host(s) carrying **%s** warning(s).' "$n_clear" "$n_clines" || printf 'No host cleared that way this run.' )"
    if [ "${n_host:-0}" -eq 0 ]; then
        printf 'TABLE\tEndpoints without a transfer site\tnosort\tnofilter\n'
        printf 'HEAD\tHost\tWarnings\tUsers\tPorts\tFirst\tLast\n'
        printf 'KIND\thost\tnumwarn\ttext\ttext\ttext\ttext\n'
        printf 'ROW\t(none)\t\t\t\t\t\n'
    else
        printf 'TABLE\tEndpoints without a transfer site\twide\tnofilter\n'
        printf 'HEAD\tHost\tWarnings\tUsers\tPorts\tFirst\tLast\n'
        printf 'KIND\thost\tnumwarn\ttext\ttext\ttext\ttext\n'
        printf '%s\n' "$rows"
        printf 'TOTAL\tTotal (%s host(s))\t@{class=num warn}%s\t\t\t\t\n' "$n_host" "$n_lines"
    fi
    printf 'NOTE\tThe host, port and user are the values the fallback used, read from the message itself. A host appears once however many flows use it: the message names none of them, which is the point — with no transfer site there is nothing to attribute it to. Click a row to expand its 10 most recent warnings.\n'
    printf 'NOTE\tWhy it matters: the connection is made on profile values alone, so nothing about it is governed by the subscription — no site-level routing, no site-level limits. It also leaves the endpoint carrying evidence no flow can own, which is why **bin/build/result.sh** reddens a host on unattributable ERRORS only and leaves these warnings to this page.\n'
    printf 'FOOT\tGenerated on %s from %s file(s)\n' "$GEN" "${#files[@]}"
} > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"

echo "Data written to $OUT (${n_host:-0} host(s) listed of ${tot_lines:-0} warning(s); ${n_clear:-0} host(s) cleared by a later OK transfer)." >&2
