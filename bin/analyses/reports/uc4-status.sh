#!/usr/bin/env bash
#
# uc4-status.sh — "UC4 status": every configured UC4 (we are the server, the
# partner connects IN and DELIVERS a file to us) subscription in ONE of four
# statuses. The fourth of the set with uc1-status.sh (we push out),
# uc2-status.sh (the partner collects from us) and uc3-status.sh (we poll and
# pull); same idea in all four: a complete partition, one row per subscription,
# the per-status counts as info boxes above the table.
#
#   ok                 the subscription is green   — its latest File is OK
#   error              it is red and has NEVER delivered an OK File
#   ok -> error        it is red but HAS delivered OK Files before — a regression
#   not seen           configured, and never seen in the transfer log
#
# green/red/orange is the site-wide RESULT colour (data/flow-manager/base/
# _subscriptions.tsv, filled by bin/build/result.sh): green = its LAST File OK;
# red = its last File Failed, or a server-log Error after it; orange = never
# seen, or its last File Expired (a pickup problem — "not seen" here). The three
# server-log-only statuses (server - no files / server - error / server - no
# result) went with the blue result, 2026-09-27: those flows are "not seen"
# now, and the Logons / Arrivals / Problems columns still show a partner that
# logs in and never delivers, or is refused at the door.
#
# THE SIGNALS ARE ACCOUNT-KEYED, not subscription-keyed. A partner connects to an
# ACCOUNT; the subscription name barely appears in the server log (only the PeSIT
# sendFileConfirmation of the onward internal leg carries it). So the roster is
# joined to xref/_accounts-subscriptions.tsv. In acceptance that is 1:1 for UC4
# (142 accounts, 142 subscriptions); a hybrid PRODUCTION account serves several
# UC4 flows, and an account-level line then counts for EACH of them (union
# attribution, like partners — the logon and the refusal are facts about the
# connection every one of those flows uses; 2026-08-31 audit: a last-row-wins
# account -> subscription map had credited every line to one arbitrary flow and
# left its siblings "never observed"). The STAT totals count each LINE once.
#   logon      "[Ssh Default] User with login name '<x>', associated with
#              account '<y>', successfully authenticated over …" — ONE line
#              per successful SSH logon (2026-08; the *Allowed user* line is a
#              whitelist admission, can fire without successful auth, and only
#              exists from a mid-window logging change)
#   arrival    "ARRC<n>: […] […]  The file {…} will be submitted for processing."
#   refusal    "[Ssh Default] Disallowed user '<login>' … corresponding account …"
# The account token on all of them is NAME@FEnnn — the only such token on the
# line — so one [A-Za-z0-9_.-]+@FE[0-9]+ match isolates it, as in uc2-status.sh.
#
# Transfer Files join EXACTLY (_files.tsv col 12 is the canonical subscription
# name since parse time — result.sh matches the same way).
#
# Reads data/_parse.tsv + the transfer _files.tsv cache + base/_subscriptions.tsv
# + xref/_accounts-subscriptions.tsv; writes data/uc4-status.rpt. The
# subscription cell links to its detail page.
#
# Usage:
#   ./uc4-status.sh
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# SERVER lib, not the analyses one: this is a server-DATA report (it reads the
# server parse cache and writes data/server/reports/). It lives HERE
# because its page is an analyses/ page (the UC status report group of the one
# Reports menu, 2026-09-29) — the same arrangement as cross-reference.sh. bin/server/reports.sh still runs it.
source "$SCRIPT_DIR/../../server/lib.sh"
source "$SCRIPT_DIR/uc-status-lib.sh"   # the shared UC status skeleton (2026-09-30)
ucs_setup UC4
XREF="$CONFIG_XREF/_accounts-subscriptions.tsv"   # account -> its subscriptions
# the MULTI-FE-ACCOUNT maps (2026-08-31, user report — see the awk BEGIN)
SLF="$CONFIG_XREF/_subscriptions-logins.tsv"; [ -f "$SLF" ] || SLF=/dev/null
ALF="$CONFIG_XREF/_accounts-logins.tsv";      [ -f "$ALF" ] || ALF=/dev/null

# One awk over the red-flip sidecar, the configured UC4 roster, the
# account->subscription map, the transfer _files.tsv (the Files/OK/Error
# history) and the server cache (the partner-side signals). Emits
#   A <TAB> stc <TAB> <sub cell> <TAB> files <TAB> ok <TAB> err <TAB> last-file
#           <TAB> logons <TAB> arrivals <TAB> problems <TAB> last-log <TAB> loglines
#   TOT <TAB> n0..n3 <TAB> files <TAB> ok <TAB> err <TAB> logons <TAB> arrivals <TAB> problems
agg=$(awk -F'\t' -v UC=UC4 -v sb="$SUBB" -v xf="$XREF" -v tf="$FILESC" -v rfv="$RFLIP" -v ucdf="$UCDF" -v slf="$SLF" -v alf="$ALF" -v SL="$SLOTS_OUT" "$LOGLINES_AWK$LINK_AWK$AWKLIB$UCS_AWK$(cat "$ROOT/bin/ssh-family.awk")"'
    # MULTI-FE ACCOUNTS (2026-08-31, user report): when the account carries
    # SEVERAL configured logins, a logon or refusal that NAMES one is credited
    # only to the flows configured for THAT login — each login is a different
    # partner credential, so its lines say nothing about the other logins
    # flows. Single-login accounts and lines naming no login keep the
    # account-wide union.
    BEGIN { while ((getline ucl < slf) > 0) { nuc = split(ucl, uca, "\t"); if (nuc >= 2 && uca[1] != "" && uca[2] != "") SUBL[toupper(uca[1])] = SUBL[toupper(uca[1])] SUBSEP toupper(uca[2]) } close(slf)
            while ((getline ucl < alf) > 0) { nuc = split(ucl, uca, "\t"); if (nuc >= 2 && uca[1] != "") aln[uca[1]]++ } close(alf) }
    # (acctof — the account of the "ACCOUNT@FE<digits>" token — comes from
    # bin/ssh-family.awk since 2026-09-30: an exact index()-based twin of the
    # regex this script and uc4-status.sh each carried)
    # (the server lines are ACCOUNT-keyed here — no key() name matching)
    FILENAME == xf {                                         # account -> its UC4 subscription(s), ALL of them
        if (($2 ~ /^UC4/ || (toupper($2) in ucd)) && (toupper($2) in res)) asub[$1] = asub[$1] SUBSEP toupper($2)
        next
    }
    {                                                        # server _parse.tsv
        m = $5
        # ONLY the "successfully authenticated" line counts (2026-08): it is
        # exactly one per SSH logon over the whole window. The "Allowed user …
        # corresponding account" line only exists from a mid-window logging
        # change (matching both double-counted every logon after it) and is a
        # whitelist ADMISSION that can fire without successful authentication.
        if (m ~ /\[Ssh Default\] User with login name/ && m ~ /successfully authenticated/) sig = "logon"
        else if (m ~ /will be submitted for processing/) sig = "arr"
        else if (m ~ /Disallowed user/) sig = "prob"
        else next
        a = acctof(m); if (a == "" || !(a in asub)) next
        d = ucs_day()
        # the STAT totals count the line ONCE; the per-flow columns credit
        # every UC4 flow of the account (see the header)
        if (sig == "logon") tlgL++; else if (sig == "arr") tarL++; else tprL++
        # the login the line names (the multi-FE gate below): the logon line
        # quotes it after "login name", the refusal after "Disallowed user"
        lg9 = ""
        if (sig == "logon" && match(m, /login name ["\x27][^"\x27]*["\x27]/))     lg9 = toupper(substr(m, RSTART + 12, RLENGTH - 13))
        else if (sig == "prob" && match(m, /Disallowed user ["\x27][^"\x27]*["\x27]/)) lg9 = toupper(substr(m, RSTART + 17, RLENGTH - 18))
        nk9 = split(substr(asub[a], 2), KS9, SUBSEP)
        for (i9 = 1; i9 <= nk9; i9++) { k = KS9[i9]
            if (lg9 != "" && aln[a] + 0 >= 2 && SUBL[k] != "" && index(SUBL[k] SUBSEP, SUBSEP lg9 SUBSEP) == 0) continue   # not this flow login
            if (d != "" && d > llg[k]) llg[k] = d
            if (sig == "logon") logon[k]++; else if (sig == "arr") arr[k]++; else prob[k]++
            ucs_span(d)
            # the drill keeps the refusals on their own key (E, shown first —
            # drill()), so a refused flow is not crowded out by routine logons
            addline((sig == "prob" ? "E" : "L") SUBSEP k, $1 " " $2, lvlname($3) " " compname($4) "  " substr(m, 1, 200))
        }
    }
    END {
        for (i = 1; i <= nr; i++) {
            k = R[i]; stc = ucs_stc(k)
            n[stc]++
            tf_ += files[k]+0; tok += ok[k]+0; ter += err[k]+0
            tlg = tlgL + 0; tar = tarL + 0; tpr = tprL + 0   # per LINE, not per credited flow
            dl = drill(k)                                     # refusals first, then the recent lines
            printf "A\t%d\t%s%s\t%d\t%d\t%d\t%s\t%d\t%d\t%d\t%s\t%s\n", stc, sublink(nm[k]), nm[k], \
                files[k]+0, ok[k]+0, err[k]+0, (k in lfd ? lfd[k] : "-"), \
                logon[k]+0, arr[k]+0, prob[k]+0, (k in llg ? llg[k] : "-"), dl
        }
        ucs_walk()
        printf "TOT\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\n", \
            n[0]+0, n[1]+0, n[2]+0, n[3]+0, \
            tf_+0, tok+0, ter+0, tlg+0, tar+0, tpr+0
    }
' "$RFLIP" "$SUBB" "$XREF" "$FILESC" "$PARSED")

IFS=$'\t' read -r _ n_err n_okerr n_ok n_notseen t_files t_ok t_er t_lg t_ar t_prob \
    <<< "$(printf '%s\n' "$agg" | grep $'^TOT\t')"
n_all=$(( n_err + n_okerr + n_ok + n_notseen ))
if [ "$n_all" -eq 0 ]; then ucs_none UC4; exit 0; fi

rows=$(printf '%s\n' "$agg" | ucs_rows 3)

# A run with data but NO timestamped rows writes no sidecar at all; an EMPTY
# sidecar is the valid "no per-hour data" answer for its readers (the
# dashboards overview), so one is created when absent.
[ -f "$SLOTS_OUT" ] || : > "$SLOTS_OUT"

{
    printf 'TITLE\tUC4 status\n'
    ucs_stats UC4

    # noagg=6,7,8: Logons / Arrivals / Problems are ACCOUNT-keyed lines
    # credited to every UC4 flow of the account (the TOTAL counts each line
    # once) — a search must not re-sum them (2026-09-29)
    printf 'TABLE\tUC4 subscriptions\twide\tnofilter\tnoagg=6,7,8\n'
    printf 'HEAD\tStatus\tSubscription\tFiles\tOK\tError\tLast file\tLogons\tArrivals\tProblems\tLast log\n'
    printf 'KIND\ttext\tmono\tnum\tnumprocessed\tnumfailed\ttext\tnum\tnum\tnumfailed\ttext\n'
    [ -z "$rows" ] || printf '%s\n' "$rows"   # (no blank line before TOTAL, 2026-09-29 audit)
    printf 'TOTAL\tTotal (%s subscription(s))\t\t@{class=num}%s\t@{class=num processed}%s\t@{class=num failed}%s\t\t@{class=num}%s\t@{class=num}%s\t@{class=num failed}%s\t\n' \
        "$n_all" "$(nz0 "$t_files")" "$(nz0 "$t_ok")" "$(nz0 "$t_er")" "$(nz0 "$t_lg")" "$(nz0 "$t_ar")" "$(nz0 "$t_prob")"

    printf 'FOOT\n'
} > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"

echo "Data written to $OUT ($n_all UC4 subscription(s): $n_ok ok, $n_err error, $n_okerr ok-error, $n_notseen not-seen)." >&2
