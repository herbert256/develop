#!/usr/bin/env bash
#
# ssh-sessions.sh — session lifecycle problems: the platform using a session or
# channel that isn't in its registry any more, and sessions dying mid-stream.
# Five messages, distinct from authentication failures (those are Failed Logins /
# SSH Key Auth) — these all happen AFTER a session is established:
#   Channel not active       "Channel is not active." (TM)
#   No registered SSH session "No registered SSH session with ID: <id>" (SSHD)
#   No SSH connection         "No SSH connection with ID: <id>" (SSHD)
#   Stream abort             "[Ssh Default] Network stream read/write error.
#                             Possible reasons are: 1)Client stopped transfer;
#                             2)Client error (unexpected exit); 3)Network …" —
#                             the partner (or the network) dying mid-transfer (TM)
#   Inactive-session message "Ignoring message for not active session …" — an
#                             internal message arriving after teardown (TM/PESITD)
#
# The session IDs are opaque, so there is nothing to group by beyond the message
# type; one table with the per-day drill. A rising count means sessions are being
# torn down (or lost) while something still holds a reference — worth watching if
# it climbs. Reads data/_parse.tsv. Writes data/ssh-sessions.rpt.
#
# Usage:
#   ./ssh-sessions.sh    # reads input/*.csv (via the cache), writes data/ssh-sessions.rpt
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib.sh"
mkdir -p "$REPORTS_DIR"
OUT="$REPORTS_DIR/ssh-sessions.rpt"

shopt -s nullglob
files=("$INPUT_DIR"/*.csv)
shopt -u nullglob
if [ ${#files[@]} -eq 0 ]; then
    echo "No files matching '*.csv' found in '$INPUT_DIR'" >&2
    rm -f "$OUT"   # no data for this ENV — page not published (an env-split legitimate state)
    exit 0
fi
ensure_parsed
skip_if_fresh "$OUT" "${BASH_SOURCE[0]}"
echo "Found ${#files[@]} file(s) in '$INPUT_DIR', processing..." >&2

# One pass. Emits: S <TAB> signal <TAB> count <TAB> component <TAB> buckets(date:count) <TAB> first <TAB> last <TAB> loglines ; TOT <TAB> total <TAB> ncats
agg=$(awk -F'\t' "$LOGLINES_AWK"'
    {
        m = $5
        cat = ""
        if      (m ~ /Channel is not active/)         cat = "Channel not active"
        else if (m ~ /No registered SSH session with ID/) cat = "No registered SSH session"
        else if (m ~ /No SSH connection with ID/)     cat = "No SSH connection"
        else if (m ~ /Network stream read\/write error/) cat = "Stream abort (client/network)"
        else if (m ~ /Ignoring message for not active session/) cat = "Message for inactive session"
        if (cat == "") next
        d = substr($1, 1, 10); if (d !~ /^[0-9][0-9][0-9][0-9]-/) d = ""
        cnt[cat]++; tot++
        cn = compname($4)
        if (!index("/" comp[cat] "/", "/" cn "/")) comp[cat] = comp[cat] (comp[cat] ? "/" : "") cn
        if (d != "") { cd[cat SUBSEP d]++
            if (!((cat SUBSEP d) in dseen)) { dseen[cat SUBSEP d]=1; dlist[cat] = dlist[cat] (dlist[cat]?",":"") d }
            if (!(cat in fst) || d < fst[cat]) fst[cat]=d
            if (!(cat in lst) || d > lst[cat]) lst[cat]=d }
        addline("S" SUBSEP cat, $1 " " $2, lvlname($3) " " compname($4) "  " substr(m, 1, 200))
    }
    END {
        nc=0
        for (c in cnt) { nc++
            no=split(dlist[c], dz, ","); bk=""
            for (i=1;i<=no;i++){ dd=dz[i]; bk=bk (bk?",":"") dd ":" cd[c SUBSEP dd] }
            printf "S\t%s\t%d\t%s\t%s\t%s\t%s\t%s\n", c, cnt[c], comp[c], bk, fst[c], lst[c], lastlines("S" SUBSEP c)
        }
        printf "TOT\t%d\t%d\n", tot+0, nc
    }
' "$PARSED")

IFS=$'\t' read -r _ t_tot n_cats <<< "$(printf '%s\n' "$agg" | grep $'^TOT\t')"
if [ "${t_tot:-0}" -eq 0 ]; then
    # No session-registry messages in this log window — write an EMPTY-STATE page
    # (so the report still renders and its group-nav link never 404s) and exit 0,
    # rather than aborting the whole build. Mirrors av-scan's empty-state row.
    echo "No session-lifecycle messages found — writing an empty report." >&2
    {
        printf 'TITLE\tSSH Session Problems\n'
        printf 'DESC\tSession lifecycle problems — sessions and channels referenced after teardown, and streams aborted mid-transfer by the client or the network. Distinct from authentication failures.\n'
    printf 'KEYWORDS\tstream abort, client stopped transfer, inactive session, channel not active, registry, network error\n'
        printf 'INTRO\tNo session-lifecycle problem messages in this log window.\n'
        printf 'TABLE\tSession-lifecycle problems\twide\n'
        printf 'HEAD\tSignal\tOccurrences\tComponent\tFirst\tLast\n'
        printf 'KIND\ttext\tnumwarn\ttext\ttext\ttext\n'
        printf 'ROW\t@{colspan=5}No session-lifecycle problem messages in this data window.\n'
        printf 'SUMMARY\tSession-lifecycle problems: 0\n'
        printf 'FOOT\tGenerated on %s from %s file(s)\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${#files[@]}"
    } > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"
    exit 0
fi

# The row writer prints STRAIGHT to stdout inside the page block below — a
# `rows+=$(printf …)` per row forks a subshell per row for nothing.
rows() {
    while IFS=$'\t' read -r _ sig count comp bk fst lst lines; do
        [ -z "$sig" ] && continue
        printf 'ROW\t%s\t%s\t%s\t%s\t%s\t@data:buckets=%s\t@data:loglines=%s\n' "$sig" "$count" "$comp" "$fst" "$lst" "$bk" "$lines"
    done <<< "$(printf '%s\n' "$agg" | grep $'^S\t' | sort -t"$(printf '\t')" -k3,3nr)"
}

{
    printf 'TITLE\tSSH Session Problems\n'
    printf 'DESC\tSession lifecycle problems — sessions and channels referenced after teardown, and streams aborted mid-transfer by the client or the network. Distinct from authentication failures.\n'
    printf 'KEYWORDS\tstream abort, client stopped transfer, inactive session, channel not active, registry, network error\n'
    printf 'INTRO\t**%s** session-lifecycle problem message(s) across **%s** type(s). These all happen AFTER a session is established: the registry signals (a channel or session ID used past its teardown) are lifecycle/race/cleanup issues; the **stream aborts** are the partner or the network dying mid-transfer; the inactive-session messages are internal traffic arriving after teardown. None are auth failures (see Logon and SSH Key Auth for those). Worth watching if a count climbs. Click a row for its 10 most recent messages.\n' \
        "$t_tot" "$n_cats"

    printf 'TABLE\tSession-lifecycle problems\twide\n'
    printf 'HEAD\tSignal\tOccurrences\tComponent\tFirst\tLast\n'
    printf 'KIND\ttext\tnumwarn\ttext\ttext\ttext\n'
    printf 'RECALC\t-\ts0\t-\t-\t-\n'
    rows
    printf 'TOTAL\tTotal (%s type(s))\t@{class=num warn}%s\t\t\t\n' "$n_cats" "$t_tot"
    printf 'NOTE\tThe session IDs are opaque, so there is nothing to group by beyond the message type. The stream-abort line does not name the culprit — the drill lines carry the session context. Occurrences are additive and re-total under the date filter. Click a signal for its 10 most recent messages.\n'

    printf 'SUMMARY\tSession-lifecycle problems: %s across %s type(s)\n' "$t_tot" "$n_cats"
    printf 'FOOT\tGenerated on %s from %s file(s)\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${#files[@]}"
} > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"

echo "Data written to $OUT ($t_tot message(s), $n_cats type(s))." >&2
