#!/usr/bin/env bash
#
# uc3-status.sh — "UC3 status": every configured UC3 (we poll the partner and
# pull files) subscription in ONE of four statuses. The pull-side counterpart of
# the UC2 report uc2-status.sh, and the same idea: a complete partition, one row per
# subscription, the per-status counts as info boxes above the table.
#
#   ok                 the subscription is green   — its latest File is OK (a
#                      flow that polls fine but never moved a file is NOT ok:
#                      it is orange, "not seen" — 2026-09-28, user rule)
#   error              it is red and has NEVER delivered an OK File
#   ok -> error        it is red but HAS delivered OK Files before — a regression
#   not seen           orange: configured, never seen in the transfer log (or
#                      its last File Expired — a pickup problem is orange)
#
# green/red/orange is the site-wide RESULT colour (data/flow-manager/base/
# _subscriptions.tsv, filled by bin/build/result.sh). The three server-log-only
# statuses (server - no files / server - error / server - no result) went with
# the blue result, 2026-09-27: those flows are "not seen" now. The server-log
# columns (Polls, Empty polls, Problems, Last log) stay — they still say
# whether a not-seen flow is polling at all.
#
# The red split is computed from _files.tsv directly, not from the From green to
# red / Only red reports, and deliberately: those bucket by DAY (a day that
# ENDED on an OK File), so a subscription that fails at the end of every day yet
# delivers OK Files within them appears on neither. "Was green before" is a
# per-FILE question — right after any OK File the subscription WAS green — so
# the test here is simply whether an OK File exists at all. That covers every
# red subscription, with no third case.
#
# The server signals, all TM lines (the same ones No remote files / No remote
# dir / the Polls by subscription table of the UC3 tab read):
#   poll result       "Applying the search pattern '<PAT>' for transfer site
#                     '<SITE>': N file(s) …"   — counted as Polls / Empty polls
#   listing failure   "Error occurred while listing files from partner <SITE>
#                     defined in account <ACC>. …"
#   connection failure "Connection failure while <SITE> tried to connect to
#                     remote host <HOST> …"  — both counted as Problems
#   poll prepared     "Remote folder of transfer site: '<SITE>' evaluated to: …"
#                     "Remote files pattern of transfer site: '<SITE>' …"
#                     — the poll was set up; counts toward Last log only
#
# The logged site carries a "_SCP_…"/"_SSCP_…"/"_CCP_…" suffix; it is truncated
# to the clean subscription name the way the transfer parser and the other
# server reports do. Transfer Files join EXACTLY (_files.tsv col 12 is the
# canonical subscription name since parse time — result.sh matches the same
# way); only a server-log token may resolve by prefix (the server truncates).
#
# Reads data/_parse.tsv + the transfer _files.tsv cache + base/_subscriptions.tsv;
# writes data/uc3-status.rpt. The subscription cell links to its detail page.
#
# Usage:
#   ./uc3-status.sh
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# SERVER lib, not the analyses one: this is a server-DATA report (it reads the
# server parse cache and writes data/server/reports/). It lives HERE
# because its page is an analyses/ page (the UC status report group of the one
# Reports menu, 2026-09-29) — the same arrangement as cross-reference.sh. bin/server/reports.sh still runs it.
source "$SCRIPT_DIR/../../server/lib.sh"
source "$SCRIPT_DIR/uc-status-lib.sh"   # the shared UC status skeleton (2026-09-30)
ucs_setup UC3
# (the clean-poll greens, _greenpoll.tsv, went 2026-09-28: a UC3 with no File
# is not seen, however it polls)

# One awk over the red-flip sidecar, the configured UC3 roster, the transfer
# _files.tsv (the Files/OK/Error history) and the poll subset (the poll
# signals). Emits
#   A <TAB> stc <TAB> <sub cell> <TAB> files <TAB> ok <TAB> err <TAB> last-file
#           <TAB> polls <TAB> empty <TAB> problems <TAB> last-log <TAB> loglines
#   TOT <TAB> n0..n3 <TAB> files <TAB> ok <TAB> err <TAB> polls <TAB> problems <TAB> empty
agg=$(awk -F'\t' -v UC=UC3 -v sb="$SUBB" -v tf="$FILESC" -v rfv="$RFLIP" -v ucdf="$UCDF" -v SL="$SLOTS_OUT" -v RNF="$RENAMES_FILE" "$LOGLINES_AWK$RENAMES_AWK$LINK_AWK$AWKLIB$UCS_AWK"'
    BEGIN { rn_load(RNF) }
    {                                                        # server _parse.tsv
        m = $5
        sig = ""
        if (m ~ /Applying the search pattern .* for transfer site /) {
            if (!match(m, /for transfer site '\''[^'\'']*'\''/)) next
            s = clean(substr(m, RSTART + 19, RLENGTH - 20)); sig = "poll"
            tail = substr(m, RSTART + RLENGTH)
            if (!match(tail, /[0-9]+ file\(s\)/)) next
            found = substr(tail, RSTART, RLENGTH - 8) + 0     # " file(s)" = 8 chars
        } else if (m ~ /listing files from partner /) {
            s = substr(m, index(m, "listing files from partner ") + 27)
            sub(/ defined in account.*$/, "", s); sub(/\..*$/, "", s); s = clean(s); sig = "prob"
        } else if (m ~ /^Connection failure while /) {
            s = clean(substr(m, 26)); sub(/ tried to connect.*$/, "", s); sig = "prob"
        } else if (m ~ /^Remote (folder|files pattern) of transfer site: /) {
            if (!match(m, /'\''[^'\'']*'\''/)) next
            s = clean(substr(m, RSTART + 1, RLENGTH - 2)); sig = "prep"
        } else next
        if (s == "") next
        # a RENAMED flow logs its polls under the name current when written
        # (2026-09-29 audit: UC3_AB_NAS2_GLOBEX -> UC3_AB_NAS_GLOBEX lost 1352
        # polls here while the Polling page counted them) — fold it first,
        # the way remote-poll.sh sitecanon does
        k = key(toupper(rn_canon_pfx(s))); if (k == "") next
        d = ucs_day()
        if (d != "" && d > llg[k]) llg[k] = d
        if (sig == "poll") { poll[k]++; if (found == 0) empty[k]++ }
        else if (sig == "prob") { prob[k]++ }
        ucs_span(d)
        # the drill keeps the problems apart (E, shown first — drill()): on a
        # red flow they are the story, and thousands of routine poll lines
        # would otherwise crowd them out
        addline((sig == "prob" ? "E" : "L") SUBSEP k, $1 " " $2, lvlname($3) " " compname($4) "  " substr(m, 1, 200))
    }
    END {
        for (i = 1; i <= nr; i++) {
            k = R[i]; stc = ucs_stc(k)
            n[stc]++
            tf_ += files[k]+0; tok += ok[k]+0; ter += err[k]+0; tpl += poll[k]+0; tpr += prob[k]+0; tem += empty[k]+0
            dl = drill(k)                                     # problems first, then the recent lines
            printf "A\t%d\t%s%s\t%d\t%d\t%d\t%s\t%d\t%d\t%d\t%s\t%s\n", stc, sublink(nm[k]), nm[k], \
                files[k]+0, ok[k]+0, err[k]+0, (k in lfd ? lfd[k] : "-"), \
                poll[k]+0, empty[k]+0, prob[k]+0, (k in llg ? llg[k] : "-"), dl
        }
        printf "TOT\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\n", \
            n[0]+0, n[1]+0, n[2]+0, n[3]+0, tf_+0, tok+0, ter+0, tpl+0, tpr+0, tem+0
        # (the cannot-connect red rides the same _redflip sidecar ucs_walk() reads)
        ucs_walk()
    }
' "$RFLIP" "$SUBB" "$FILESC" "$(srv_subset poll)")

IFS=$'\t' read -r _ n_err n_okerr n_ok n_notseen t_files t_ok t_er t_poll t_prob t_empty \
    <<< "$(printf '%s\n' "$agg" | grep $'^TOT\t')"
n_all=$(( n_err + n_okerr + n_ok + n_notseen ))
if [ "$n_all" -eq 0 ]; then ucs_none UC3; exit 0; fi

rows=$(printf '%s\n' "$agg" | ucs_rows 3)

# A run with data but NO timestamped rows writes no sidecar at all; an EMPTY
# sidecar is the valid "no per-hour data" answer for its readers (the
# dashboards overview), so one is created when absent.
[ -f "$SLOTS_OUT" ] || : > "$SLOTS_OUT"

{
    printf 'TITLE\tUC3 status\n'
    ucs_stats UC3

    printf 'TABLE\tUC3 subscriptions\twide\tnofilter\ttab=uc3\n'   # tab=uc3: uc3-polling.sh's tables stack under this one on the UC3 tab page (2026-09-05)
    printf 'HEAD\tStatus\tSubscription\tFiles\tOK\tError\tLast file\tPolls\tEmpty polls\tProblems\tLast log\n'
    printf 'KIND\ttext\tmono\tnum\tnumprocessed\tnumfailed\ttext\tnum\tnum\tnumfailed\ttext\n'
    [ -z "$rows" ] || printf '%s\n' "$rows"   # (no blank line before TOTAL, 2026-09-29 audit)
    printf 'TOTAL\tTotal (%s subscription(s))\t\t@{class=num}%s\t@{class=num processed}%s\t@{class=num failed}%s\t\t@{class=num}%s\t@{class=num}%s\t@{class=num failed}%s\t\n' \
        "$n_all" "$(nz0 "$t_files")" "$(nz0 "$t_ok")" "$(nz0 "$t_er")" "$(nz0 "$t_poll")" "$(nz0 "$t_empty")" "$(nz0 "$t_prob")"

    printf 'FOOT\n'
} > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"

echo "Data written to $OUT ($n_all UC3 subscription(s): $n_ok ok, $n_err error, $n_okerr ok-error, $n_notseen not-seen)." >&2
