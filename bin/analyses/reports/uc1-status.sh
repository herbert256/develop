#!/usr/bin/env bash
#
# uc1-status.sh — "UC1 status": every configured UC1 (we are the client and
# SEND a file to the partner) subscription in ONE of six statuses. The push-side
# member of the trio with uc2-status.sh (the partner collects from us) and
# uc3-status.sh (we poll the partner and pull), same idea in all three: a
# complete partition, one row per subscription, the per-status counts as info
# boxes above the table.
#
#   ok                 the subscription is green   — its latest File is OK
#   error              it is red and has NEVER delivered an OK File
#   ok -> error         it is red but HAS delivered OK Files before — a regression
#   server - error     blue, and the server log says the send failed (could not
#                      send, an error while sending, a step that finished with
#                      an error, or it could not reach the partner at all)
#   server - no result blue, and nothing in the server log explains it — no
#                      failure names the subscription
#   not seen           configured, and never observed in EITHER log
#
# green/red/blue/orange is the site-wide RESULT colour (data/flow-manager/base/
# _subscriptions.tsv, filled by bin/build/result.sh + bin/build/seen-in-server-log.sh):
# green/red = real transfer data, its LAST File OK / Failed-or-Expired; blue =
# seen in the SERVER log only; orange = never seen anywhere.
#
# WHY THE STATUS SET DIFFERS from uc3-status.sh, in both directions:
#
#   * no "server - no files". UC3 polls, so "the poll worked and there was
#     nothing to fetch" is a real, common state with its own log line. UC1 is
#     triggered by a file APPEARING (uc-cases.sh: trigger "OpsWise" — a dir
#     scan), so no file simply means no route run and no log line. There is
#     nothing to report.
#   * "not seen" is a FIRST-CLASS status here, not the safety net it is in
#     uc3-status.sh. 97 of acceptance's 185 UC1 subscriptions are configured and
#     have never been observed in either log — more than half the report, and
#     the single biggest thing it has to say. (UC3 has none at all, so its box
#     stays hidden.)
#
# The blue split needs no "latest decisive line wins" rule either, and that too
# is a UC3 difference worth keeping straight: there, two rival explanations
# (empty polls vs failures) compete on the same subscription, so recency
# arbitrates. Here only one explanation is on offer — a failure — so a blue
# subscription either has one (server - error) or has none (server - no result).
#
# The server signals. Advanced Routing logs a UC1 push as
#   AR<n>: [<account>] [<route>]  <text>
# with the ROUTE — the subscription — in the SECOND bracket group:
#   route run    "Starting execution {…} of route: {…}."
#   failure      "Could not send file: {…} using transfer site …"
#                "An error occurred while sending the file …"     (ARSP<n>)
#                "Step {…} with id {…} finished with error…"
# plus the two client-side failures uc3-status.sh also reads, which UC1 hits
# whenever it cannot reach the partner at all:
#   "Connection failure while <SITE> tried to connect to remote host …"
#   "Error occurred while listing files from partner <SITE> defined in account …"
#
# The logged site carries a "_SCP_…"/"_SSCP_…"/"_CCP_…" suffix; it is truncated
# to the clean subscription name the way the transfer parser and the other
# server reports do. Transfer Files join by the showseen rule — the configured
# name PREFIXES the logged _files.tsv value.
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
# server parse cache and writes data/<env>/server/reports/). It lives HERE
# because its page sits in the ANALYSES menu, in the Subscriptions group — the
# same arrangement as cross-reference.sh. bin/server/reports.sh still runs it.
source "$SCRIPT_DIR/../../server/lib.sh"
mkdir -p "$REPORTS_DIR"
OUT="$REPORTS_DIR/uc1-status.rpt"

SUBB="$CONFIG_BASE/_subscriptions.tsv"     # name <TAB> direction <TAB> result
FILESC="$TRANSFER_CACHE/_files.tsv"
# result.sh's red-flip sidecar: subscriptions flipped green -> red by ring
# Error/Warn evidence newer than their last transfer, with the evidence stamp.
# The per-hour walker applies the same flip so its last row matches the STATs.
RFLIP="$DATA/blue/_redflip.tsv"
# The per-HOUR status sidecar for the Overview's UC1 status card — written HERE
# because the classification lives here; the Overview must never re-derive it
# (cf. pesit-slots.tsv). date <TAB> hour <TAB> the SIX statuses in STACK order:
#   ok, server-no-result, server-error, ok-error, error, not-seen
# One hour divides 4/6/12/24 exactly, so the Overview re-buckets by taking the
# LAST hour of each — a status is a STATE, carried forward, never summed.
SLOTS_OUT="$REPORTS_DIR/uc1-slots.tsv"        # the logical-transfer cache (col 12 = subscription, 2 = outcome)
# sublink() prefixes an @{alink=subscriptions/<name>} UNCONDITIONALLY — the
# renderer resolves it through the details slugmap and drops the link when the
# name has no page, so a never-seen subscription still links.
LINK_AWK='
    function sublink(s) { return (s != "") ? "@{alink=subscriptions/" s "}" : "" }
'

shopt -s nullglob
files=("$INPUT_DIR"/*.csv)
shopt -u nullglob
if [ ${#files[@]} -eq 0 ]; then
    echo "No *.csv in $INPUT_DIR — building from the EMPTY caches (config-only estate)" >&2
fi
ensure_parsed
ensure_config
[ -f "$SLOTS_OUT" ] || rm -f "$OUT"   # a missing sidecar must force a rebuild (skip_if_fresh checks $OUT only)
skip_if_fresh "$OUT" "${BASH_SOURCE[0]}" "$FILESC" "$SUBB" "$RFLIP"
[ -f "$RFLIP" ] || RFLIP=/dev/null   # first build: result.sh not run yet — no flips
echo "Found ${#files[@]} file(s) in '$INPUT_DIR', processing..." >&2

# One awk over three inputs: the configured UC1 roster, the transfer _files.tsv
# (the Files/OK/Error history) and the server cache (the route signals). Emits
#   A <TAB> stc <TAB> <sub cell> <TAB> files <TAB> ok <TAB> err <TAB> last-file
#           <TAB> runs <TAB> problems <TAB> last-log <TAB> loglines
#   TOT <TAB> n0..n5 <TAB> files <TAB> ok <TAB> err <TAB> runs <TAB> problems
agg=$(awk -F'\t' -v sb="$SUBB" -v tf="$FILESC" -v rfv="$RFLIP" -v SL="$SLOTS_OUT" "$LOGLINES_AWK$LINK_AWK"'
    # the logged site -> the clean subscription name (as the transfer parser does)
    function clean(s) { sub(/_(SS?|C)CP_.*$/, "", s); return s }
    function jdn(y,m,d,  a){ a=int((14-m)/12); y=y+4800-a; m=m+12*a-3; return d+int((153*m+2)/5)+365*y+int(y/4)-int(y/100)+int(y/400)-32045 }
    function fromjdn(j,   a,b,c,dd,e,mm,day,mon,yr) { a=j+32044; b=int((4*a+3)/146097); c=a-int(146097*b/4); dd=int((4*c+3)/1461); e=c-int(1461*dd/4); mm=int((5*e+2)/153); day=e-int((153*mm+2)/5)+1; mon=mm+3-12*int(mm/10); yr=100*b+dd-4800+int(mm/10); return sprintf("%04d-%02d-%02d", yr, mon, day) }
    function span(h) { if (hmin == "" || h < hmin) hmin = h; if (h > hmax) hmax = h }
    # a logged/configured name -> the configured UC1 roster key. EXACT first —
    # what every line in both caches actually is here — then, purely defensively
    # (the server truncates long site names), the roster entry it prefixes or is
    # prefixed by, and ONLY when exactly one matches: an ambiguous truncation
    # must attribute to nothing rather than to whichever entry comes first.
    function key(u,   i, hit, c) {
        if (u in res) return u
        if (u in memo) return memo[u]
        hit = ""; c = 0
        for (i = 1; i <= nr; i++) if (index(u, R[i]) == 1 || index(R[i], u) == 1) { hit = R[i]; c++ }
        return memo[u] = (c == 1) ? hit : ""
    }
    FILENAME == sb {                                         # the configured UC1 roster
        if ($1 !~ /^UC1/ || $1 == "") next
        u = toupper($1); res[u] = $3; nm[u] = $1; R[++nr] = u
        next
    }
    FILENAME == rfv { if ($1 != "" && $2 != "") rfd[toupper($1)] = $2; next }   # red-flip sidecar: name -> evidence stamp
    FILENAME == tf {                                         # transfer Files, joined by prefix
        if ($12 == "") next
        u = toupper($12); k = key(u); if (k == "") next
        files[k]++
        if ($2 == "Failed" || $2 == "Expired") err[k]++; else ok[k]++
        if ($6 > lsk[k]) { lsk[k] = $6; lfd[k] = $4 }        # col 6 sortkey, col 4 date
        # per-HOUR state for the sidecar: the outcome of the LATEST File in this
        # hour (by sortkey — the cache is CoreId-sorted, not chronological)
        if ($5 ~ /^[0-9][0-9]:/) {
            hs = $7 * 24 + int(substr($5, 1, 2)); span(hs); hk = k SUBSEP hs
            if (!(hk in tsk) || $6 > tsk[hk]) { tsk[hk] = $6; tbad[hk] = ($2 == "Failed" || $2 == "Expired") }
            if ($2 != "Failed" && $2 != "Expired") thok[hk] = 1
        }
        next
    }
    {                                                        # server _parse.tsv
        m = $5
        s = ""; sig = ""
        if (m ~ /^AR[A-Z]*[0-9]*: \[/) {                     # an Advanced Routing line
            # the ROUTE is the SECOND bracket group: "AR<n>: [<account>] [<route>]  …"
            p = index(m, "] ["); if (p == 0) next
            rest = substr(m, p + 3); q = index(rest, "]"); if (q == 0) next
            s = clean(substr(rest, 1, q - 1))
            body = substr(rest, q + 1)
            if (body ~ /Could not send file|An error occurred while sending|finished with error/) sig = "prob"
            else if (body ~ /Starting execution/) sig = "run"
            else next
        } else if (m ~ /^Connection failure while /) {
            s = clean(substr(m, 26)); sub(/ tried to connect.*$/, "", s); sig = "prob"
        } else if (m ~ /listing files from partner /) {
            s = substr(m, index(m, "listing files from partner ") + 27)
            sub(/ defined in account.*$/, "", s); sub(/\..*$/, "", s); s = clean(s); sig = "prob"
        } else next
        if (s == "") next
        k = key(toupper(s)); if (k == "") next
        d = substr($1, 1, 10); if (d !~ /^[0-9][0-9][0-9][0-9]-/) d = ""
        if (d != "" && d > llg[k]) llg[k] = d
        if (sig == "prob") prob[k]++; else run[k]++
        # per-HOUR: any line makes it server-visible, a failure names it
        if (d != "" && $2 ~ /^[0-9][0-9]:/) {
            hs = jdn(substr(d,1,4)+0, substr(d,6,2)+0, substr(d,9,2)+0) * 24 + int(substr($2,1,2))
            span(hs); hk = k SUBSEP hs
            if (sig == "prob") sprob[hk] = 1
        }
        # the drill carries the lines that DECIDE the status: failures on their
        # own key, so a problem row is not crowded out by routine route runs
        addline((sig == "prob" ? "E" : "L") SUBSEP k, $1 " " $2, lvlname($3) " " compname($4) "  " substr(m, 1, 200))
    }
    END {
        # statuses, worst first — the row sort is on this number
        #   0 error             red,  no OK File ever
        #   1 ok -> error        red,  OK Files before it went red
        #   2 server - error    blue, a failure names it
        #   3 server - no result blue, no failure does
        #   4 ok                green
        #   5 not seen          orange (or unfilled) — never observed at all
        for (i = 1; i <= nr; i++) {
            k = R[i]; r = res[k]
            if (r == "green")      stc = 4
            else if (r == "red")   stc = (ok[k]+0 > 0) ? 1 : 0
            else if (r == "blue")  stc = (prob[k]+0 > 0) ? 2 : 3
            else                   stc = 5
            n[stc]++
            tf_ += files[k]+0; tok += ok[k]+0; ter += err[k]+0; trn += run[k]+0; tpr += prob[k]+0
            dl = (stc == 2) ? lastlines("E" SUBSEP k) : lastlines("L" SUBSEP k)
            printf "A\t%d\t%s%s\t%d\t%d\t%d\t%s\t%d\t%d\t%s\t%s\n", stc, sublink(nm[k]), nm[k], \
                files[k]+0, ok[k]+0, err[k]+0, (k in lfd ? lfd[k] : "-"), \
                run[k]+0, prob[k]+0, (k in llg ? llg[k] : "-"), dl
        }
        printf "TOT\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\n", \
            n[0]+0, n[1]+0, n[2]+0, n[3]+0, n[4]+0, n[5]+0, tf_+0, tok+0, ter+0, trn+0, tpr+0
        # ---- the per-HOUR sidecar (the Overview UC1 status card) -------------
        # The hours walked forward carrying each subscription\047s state, counting the
        # six statuses at each. The rules mirror the snapshot above with the result
        # COLOUR re-derived from the evidence so far (result.sh\047s subscription rule:
        # green/red by the LAST transfer outcome — INCLUDING the 2026-08
        # after-last-transfer red flip, read from the _redflip sidecar below —
        # blue = server-log only, orange = nothing yet), so the LAST hour
        # reproduces the n[] figures printed above — that equality is the
        # regression test.
        if (hmin != "" && SL != "") {
            # SERVER-VISIBLE == in the CURATED blue set (res[] == "blue", from
            # bin/build/seen-in-server-log.sh) — NOT "this report\047s own patterns
            # matched a line", which is a different and wider set and made the last
            # hour disagree with the snapshot in both directions. Blue carries no
            # date (the gap first-seen.sh works around), so a blue flow counts as
            # server-visible for the WHOLE window; the per-hour signals below only
            # refine WHICH blue status it is.
            for (i = 1; i <= nr; i++) if (res[R[i]] == "blue") SV[R[i]] = 1
            # the result.sh RED FLIP (_redflip.tsv): a green-by-transfer flow
            # flipped red by ring Error/Warn evidence NEWER than its last
            # transfer. Applied from the evidence hour, clamped into the walked
            # span, so the LAST row reproduces the snapshot n[] exactly (the
            # regression test). Hash order here only FILLS a map.
            for (k9 in rfd) if (k9 in res) {
                fh = ""
                if (rfd[k9] ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:/)
                    fh = jdn(substr(rfd[k9],1,4)+0, substr(rfd[k9],6,2)+0, substr(rfd[k9],9,2)+0) * 24 + substr(rfd[k9],12,2) + 0
                if (fh == "") fh = hmax
                if (fh > hmax) fh = hmax
                if (fh < hmin) fh = hmin
                RFH[k9] = fh
            }
            for (h = hmin; h <= hmax; h++) {
                delete cnt
                for (i = 1; i <= nr; i++) {
                    k = R[i]; hk = k SUBSEP h
                    if (hk in tsk) { HF[k] = 1; LOK[k] = !tbad[hk] }
                    if (hk in thok) EOK[k] = 1
                    if (hk in sprob) SP[k] = 1
                    if (HF[k])      sc = LOK[k] ? 4 : (EOK[k] ? 1 : 0)
                    else if (SV[k]) sc = SP[k] ? 2 : 3
                    else            sc = 5
                    if (sc == 4 && (k in RFH) && h >= RFH[k]) sc = 1   # the red flip: ok -> "ok -> error"
                    cnt[sc]++
                }
                # the SEVEN-column shape uc3/uc4 use, so ONE Overview chart kind
                # covers all three UC1/UC3/UC4 cards: UC1 has no "no files"
                # status, so that column is a constant 0 here
                printf "%s\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\n", fromjdn(int(h/24)), h%24, \
                    cnt[4]+0, cnt[3]+0, 0, cnt[2]+0, cnt[1]+0, cnt[0]+0, cnt[5]+0 > SL
            }
            close(SL)
        }
    }
' "$SUBB" "$RFLIP" "$FILESC" "$PARSED")

IFS=$'\t' read -r _ n_err n_okerr n_serr n_snor n_ok n_notseen t_files t_ok t_er t_run t_prob \
    <<< "$(printf '%s\n' "$agg" | grep $'^TOT\t')"
n_all=$(( n_err + n_okerr + n_serr + n_snor + n_ok + n_notseen ))
if [ "$n_all" -eq 0 ]; then
    echo "No UC1 subscriptions configured." >&2
    rm -f "$OUT" "$SLOTS_OUT"   # no data for this ENV — page not published
    exit 0
fi

# Rows ordered by status (stc 0..5), within a status by Error desc, Files desc,
# then name — the noisiest subscription of a status first. The A lines reach
# sort(1) UNCHANGED: its last-resort compare is the WHOLE line, which is what
# breaks the remaining ties, so nothing may be added to or moved within them
# before the sort. ONE awk then turns each sorted A line into its ROW — the
# status label, an em-dash for an absent date, the loglines attribute — where a
# bash while-read used to fork a $(printf) per row into an O(n^2) append.
rows=$(awk -F'\t' '
    $3 == "" { next }          # no subscription (and the blank line an empty stream feeds in)
    {
        st = ($2 == 0) ? "@{class=failed}error" : \
             ($2 == 1) ? "@{class=warn}ok -> error" : \
             ($2 == 2) ? "@{class=failed}server - error" : \
             ($2 == 3) ? "@{class=warn}server - no result" : \
             ($2 == 4) ? "@{class=processed}ok" : "not seen"
        printf "ROW\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t@data:loglines=%s\n", st, $3, $4, $5, $6, \
            ($7 == "-" ? "—" : $7), $8, $9, ($10 == "-" ? "—" : $10), $11
    }
' <<< "$(printf '%s\n' "$agg" | grep $'^A\t' | sort -t$'\t' -k2,2n -k6,6nr -k4,4nr -k3,3)")
[ -n "$rows" ] && rows+=$'\n'   # put back the newline the command substitution stripped (the loop ended every row with one)

# A run with data but NO timestamped rows writes no sidecar at all, and the
# missing-sidecar guard above would then delete this .rpt on every build,
# for ever. An EMPTY sidecar is the valid "no per-hour data" answer (the
# unknown-* sidecars carry the same rule). Created only when absent, never
# touched — overview.rpt lists it as a dep and a bumped mtime would drag it.
[ -f "$SLOTS_OUT" ] || : > "$SLOTS_OUT"

{
    printf 'TITLE\tUC1 status\n'
    printf 'DESC\tEvery configured UC1 (we send a file to the partner) subscription in one of six statuses: healthy, failing, failing after a working history, a send the server log shows failing, no explanation at all, or never observed in either log.\n'
    printf 'INTRO\tEvery configured **UC1** (we are the client and SEND a file to the partner) subscription, in exactly one status. The first three are the **transfer-log** verdict: **ok** = green, its latest File was delivered; **error** = red and never once delivered an OK File; **ok -> error** = red now, but it HAS delivered before — a regression. Then the **blue** ones (seen in the server log, never in the transfer log): **server - error** = a failure names it — the send failed, or the partner could not be reached; **server - no result** = no failure names it (it can still be blue on a line attributed to its host or account, which its detail page shows). Last and largest, **not seen** = configured and never observed in EITHER log. Click a row for its most recent server-log lines.\n'

    printf 'STAT\twhite\t%s\tUC1 subscriptions\n' "$n_all"
    printf 'STAT\tgreen\t%s\tok\n' "$n_ok"
    printf 'STAT\tred\t%s\terror\n' "$n_err"
    printf 'STAT\torange\t%s\tok -> error\n' "$n_okerr"
    printf 'STAT\tred\t%s\tserver - error\n' "$n_serr"
    printf 'STAT\tblue\t%s\tserver - no result\n' "$n_snor"
    printf 'STAT\torange\t%s\tnot seen\n' "$n_notseen"

    printf 'TABLE\tUC1 subscriptions\twide\tnofilter\n'
    printf 'HEAD\tStatus\tSubscription\tFiles\tOK\tError\tLast file\tRoute runs\tProblems\tLast log\n'
    printf 'KIND\ttext\tmono\tnum\tnumprocessed\tnumfailed\ttext\tnum\tnumfailed\ttext\n'
    printf '%s\n' "$rows"   # %s\n: $rows already ends in one, so this is the blank line before TOTAL
    printf 'TOTAL\tTotal (%s subscription(s))\t\t@{class=num}%s\t@{class=num}%s\t@{class=num}%s\t\t@{class=num}%s\t@{class=num}%s\t\n' \
        "$n_all" "$t_files" "$t_ok" "$t_er" "$t_run" "$t_prob"
    printf 'NOTE\tEvery configured **UC1** subscription, classified. The colour is the site-wide **result**: green/red mean real transfer data (its LAST File OK / Failed-or-Expired), blue means the server log has seen it and the transfer log never has, and orange — **not seen** — means neither log ever has. **error** vs **ok -> error** is a per-FILE question: right after any OK File the subscription WAS green, so a red subscription with even one OK File in the window is a regression; that is finer than **From green to red**, which buckets by whole days. The server counts read the Advanced Routing lines, which carry the route in their second bracket: **Route runs** is "Starting execution of route", **Problems** is a send that could not be made ("Could not send file", "An error occurred while sending", a step "finished with error") or the partner being unreachable at all (a **Connection failure**, a failing directory listing). **Last log** is the newest line of either kind, so it answers "is this flow still running at all" and can be newer than the failures the drill shows. Unlike **UC3 status** there is no "no files" status: a UC1 push is triggered by a file APPEARING, so no file means no route run and no log line — nothing to report. Click a row for its most recent server-log lines; on a **server - error** row those are the failures.\n'

    printf 'KEYWORDS\tuc1, push, send, sendtopartner, advanced routing, status, green, red, blue, orange, regression, never worked, never seen, unused, connection failure, could not send, subscription health\n'
    printf 'SUMMARY\tok: %s  |  error: %s  |  ok -> error: %s  |  server - error: %s  |  server - no result: %s  |  not seen: %s\n' \
        "$n_ok" "$n_err" "$n_okerr" "$n_serr" "$n_snor" "$n_notseen"
    printf 'FOOT\tGenerated on %s from %s file(s)\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${#files[@]}"
} > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"

echo "Data written to $OUT ($n_all UC1 subscription(s): $n_ok ok, $n_err error, $n_okerr ok-error, $n_serr server-error, $n_snor server-no-result, $n_notseen not-seen)." >&2
