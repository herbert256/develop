#!/usr/bin/env bash
#
# uc1-status.sh — "UC1 status": every configured UC1 (we are the client and
# SEND a file to the partner) subscription in ONE of four statuses. The push-side
# member of the trio with uc2-status.sh (the partner collects from us) and
# uc3-status.sh (we poll the partner and pull), same idea in all three: a
# complete partition, one row per subscription, the per-status counts as info
# boxes above the table.
#
#   ok                 the subscription is green   — its latest File is OK
#   error              it is red and has NEVER delivered an OK File
#   ok -> error        it is red but HAS delivered OK Files before — a regression
#   not seen           configured, and never seen in the transfer log
#
# green/red/orange is the site-wide RESULT colour (data/flow-manager/base/
# _subscriptions.tsv, filled by bin/build/result.sh): green = its LAST File OK;
# red = its last File Failed, or a server-log Error after it; orange = never
# seen, or its last File Expired (a pickup problem, not a failed delivery —
# an Expired-last flow is therefore "not seen" here). The two server-log-only
# statuses (server - error / server - no result) went with the blue result,
# 2026-09-27: those flows are "not seen" now, and the Problems / Last log
# columns still show what the server log says about them.
#
# No File means not seen here (and in uc3-status.sh since 2026-09-28): UC1 is
# triggered by a file APPEARING (uc-cases.sh: trigger "OpsWise" — a dir scan),
# so no file simply means no route run and no log line.
#
# The server signals. Advanced Routing logs a UC1 push as
#   AR<n>: [<account>] [<route>]  <text>
# with the ROUTE — the subscription — in the SECOND bracket group:
#   failure      "Could not send file: {…} using transfer site …"
#                "An error occurred while sending the file …"     (ARSP<n>)
#                "Step {…} with id {…} finished with error…"
# plus the two client-side failures uc3-status.sh also reads, which UC1 hits
# whenever it cannot reach the partner at all:
#   "Connection failure while <SITE> tried to connect to remote host …"
#   "Error occurred while listing files from partner <SITE> defined in account …"
# (The route-run line "Starting execution {…} of route: {…}." is AR0076, on
# the parse NOISE list — dropped at tokenize time, so no route run is counted.)
#
# The logged site carries a "_SCP_…"/"_SSCP_…"/"_CCP_…" suffix; it is truncated
# to the clean subscription name the way the transfer parser and the other
# server reports do. Transfer Files join EXACTLY (_files.tsv col 12 is the
# canonical subscription name since parse time — result.sh matches the same
# way); only a server-log token may resolve by prefix (the server truncates).
#
# Reads data/_parse.tsv + the transfer _files.tsv cache + base/_subscriptions.tsv;
# writes data/uc1-status.rpt. The subscription cell links to its detail page.
#
# Usage:
#   ./uc1-status.sh
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# SERVER lib, not the analyses one: this is a server-DATA report (it reads the
# server parse cache and writes data/server/reports/). It lives HERE
# because its page is an analyses/ page (the UC status report group of the one
# Reports menu, 2026-09-29) — the same arrangement as cross-reference.sh. bin/server/reports.sh still runs it.
source "$SCRIPT_DIR/../../server/lib.sh"
source "$SCRIPT_DIR/uc-status-lib.sh"   # the shared UC status skeleton (2026-09-30)
ucs_setup UC1

# One awk over the configured UC1 roster, the red-flip sidecar, the transfer
# _files.tsv (the Files/OK/Error history) and the server cache (the route
# signals). Emits
#   A <TAB> stc <TAB> <sub cell> <TAB> files <TAB> ok <TAB> err <TAB> last-file
#           <TAB> problems <TAB> last-log <TAB> loglines
#   TOT <TAB> n0..n3 <TAB> files <TAB> ok <TAB> err <TAB> problems
agg=$(awk -F'\t' -v UC=UC1 -v sb="$SUBB" -v tf="$FILESC" -v rfv="$RFLIP" -v ucdf="$UCDF" -v SL="$SLOTS_OUT" -v RNF="$RENAMES_FILE" "$LOGLINES_AWK$RENAMES_AWK$LINK_AWK$AWKLIB$UCS_AWK"'
    BEGIN { rn_load(RNF) }
    {                                                        # server _parse.tsv
        m = $5
        s = ""; sig = ""
        if (m ~ /^AR[A-Z]*[0-9]*: \[/) {                     # an Advanced Routing line
            # the ROUTE is the SECOND bracket group: "AR<n>: [<account>] [<route>]  …"
            p = index(m, "] ["); if (p == 0) next
            rest = substr(m, p + 3); q = index(rest, "]"); if (q == 0) next
            s = clean(substr(rest, 1, q - 1))
            body = substr(rest, q + 1)
            # (the route-run line "Starting execution" is noise-filtered at
            # tokenize time — AR0076 — so a failure is the only AR signal)
            if (body ~ /Could not send file|An error occurred while sending|finished with error/) sig = "prob"
            else next
        } else if (m ~ /^Connection failure while /) {
            s = clean(substr(m, 26)); sub(/ tried to connect.*$/, "", s); sig = "prob"
        } else if (m ~ /listing files from partner /) {
            s = substr(m, index(m, "listing files from partner ") + 27)
            sub(/ defined in account.*$/, "", s); sub(/\..*$/, "", s); s = clean(s); sig = "prob"
        } else next
        if (s == "") next
        k = key(toupper(rn_canon_pfx(s))); if (k == "") next   # a RENAMED flow logs its old name (2026-09-29 audit; uc3-status.sh)
        d = ucs_day()
        if (d != "" && d > llg[k]) llg[k] = d
        prob[k]++                                            # every counted UC1 line is a problem
        ucs_span(d)
        # the drill keeps the failures on their own key (E), ahead of any
        # other line (L — none for UC1 today; drill() merges them)
        addline((sig == "prob" ? "E" : "L") SUBSEP k, $1 " " $2, lvlname($3) " " compname($4) "  " substr(m, 1, 200))
    }
    END {
        for (i = 1; i <= nr; i++) {
            k = R[i]; stc = ucs_stc(k)
            n[stc]++
            tf_ += files[k]+0; tok += ok[k]+0; ter += err[k]+0; tpr += prob[k]+0
            dl = drill(k)
            printf "A\t%d\t%s%s\t%d\t%d\t%d\t%s\t%d\t%s\t%s\n", stc, sublink(nm[k]), nm[k], \
                files[k]+0, ok[k]+0, err[k]+0, (k in lfd ? lfd[k] : "-"), \
                prob[k]+0, (k in llg ? llg[k] : "-"), dl
        }
        printf "TOT\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\n", \
            n[0]+0, n[1]+0, n[2]+0, n[3]+0, tf_+0, tok+0, ter+0, tpr+0
        ucs_walk()
    }
' "$SUBB" "$RFLIP" "$FILESC" "$(srv_subset uc1)")

IFS=$'\t' read -r _ n_err n_okerr n_ok n_notseen t_files t_ok t_er t_prob \
    <<< "$(printf '%s\n' "$agg" | grep $'^TOT\t')"
n_all=$(( n_err + n_okerr + n_ok + n_notseen ))
if [ "$n_all" -eq 0 ]; then ucs_none UC1; exit 0; fi

# (the Route runs column went 2026-09-29: its "Starting execution" line is
# dropped at tokenize time — AR0076 is on the NOISE list)
rows=$(printf '%s\n' "$agg" | ucs_rows 1)

# A run with data but NO timestamped rows writes no sidecar at all; an EMPTY
# sidecar is the valid "no per-hour data" answer for its readers (the
# dashboards overview), so one is created when absent.
[ -f "$SLOTS_OUT" ] || : > "$SLOTS_OUT"

{
    printf 'TITLE\tUC1 status\n'
    ucs_stats UC1

    printf 'TABLE\tUC1 subscriptions\twide\tnofilter\n'
    printf 'HEAD\tStatus\tSubscription\tFiles\tOK\tError\tLast file\tProblems\tLast log\n'
    printf 'KIND\ttext\tmono\tnum\tnumprocessed\tnumfailed\ttext\tnumfailed\ttext\n'
    [ -z "$rows" ] || printf '%s\n' "$rows"   # (no blank line before TOTAL, 2026-09-29 audit)
    # the OK / Error / Problems totals keep their column tint (2026-09-29)
    printf 'TOTAL\tTotal (%s subscription(s))\t\t@{class=num}%s\t@{class=num processed}%s\t@{class=num failed}%s\t\t@{class=num failed}%s\t\n' \
        "$n_all" "$(nz0 "$t_files")" "$(nz0 "$t_ok")" "$(nz0 "$t_er")" "$(nz0 "$t_prob")"

    printf 'FOOT\n'
} > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"

echo "Data written to $OUT ($n_all UC1 subscription(s): $n_ok ok, $n_err error, $n_okerr ok-error, $n_notseen not-seen)." >&2
