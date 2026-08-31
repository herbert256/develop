#!/usr/bin/env bash
#
# uc3-status.sh — "UC3 status": every configured UC3 (we poll the partner and
# pull files) subscription in ONE of six statuses. The pull-side counterpart of
# the UC2 report uc2-status.sh, and the same idea: a complete partition, one row per
# subscription, the per-status counts as info boxes above the table.
#
#   ok                 the subscription is green   — its latest File is OK
#   error              it is red and has NEVER delivered an OK File
#   ok -> error         it is red but HAS delivered OK Files before — a regression
#   server - no files  blue, and its latest poll reports ZERO files found
#   server - error     blue, and the server log's latest word on it is that it
#                      cannot retrieve from the partner (connection failure, or
#                      a failing directory listing)
#   server - no result blue, and the poll is only ever PREPARED — no result line
#                      and no error line names it at all
#
# green/red/blue is the site-wide RESULT colour (data/flow-manager/base/
# _subscriptions.tsv, filled by bin/build/result.sh + bin/build/seen-in-server-log.sh):
# green/red = real transfer data, its LAST File OK / Failed-or-Expired; blue =
# seen in the SERVER log only, never once in the transfer log. So the first
# three statuses are the transfer-log verdict and the last three split the blue
# ones by WHAT the server log says about them — which is the only evidence a
# blue subscription has.
#
# The red split is computed from _files.tsv directly, not from the From green to
# red / Only red reports, and deliberately: those bucket by DAY (a day that
# ENDED on an OK File), so a subscription that fails at the end of every day yet
# delivers OK Files within them appears on neither. "Was green before" is a
# per-FILE question — right after any OK File the subscription WAS green — so
# the test here is simply whether an OK File exists at all. That covers every
# red subscription, with no third case.
#
# The blue split is decided by the LATEST DECISIVE line, not by which signals
# exist at all — 27 of acceptance's 71 blue subscriptions have both empty polls
# and failures, and for most of them the failures are a 0.1-8% blip on a flow
# that otherwise polls perfectly well and finds nothing (one polls 8,941 times
# and fails 24). Counting "any failure" as the status would call all 27 broken;
# counting the majority needs an arbitrary threshold. The most recent evidence
# wins instead, which is how every other current-state verdict on this site
# works (a subscription's colour is its LAST File's outcome). DECISIVE = a
# failure, or a poll result of ZERO files; a poll that DID find files says
# neither thing, so a subscription with nothing but those lands in
# "server - no result" like one with no result lines at all.
#
# The server signals, all TM lines (the same ones No remote files / No remote
# dir / Remote polls read):
#   poll result       "Applying the search pattern '<PAT>' for transfer site
#                     '<SITE>': N file(s) …"   — N == 0 on every poll = no files
#   listing failure   "Error occurred while listing files from partner <SITE>
#                     defined in account <ACC>. …"
#   connection failure "Connection failure while <SITE> tried to connect to
#                     remote host <HOST> …"
#   poll prepared     "Remote folder of transfer site: '<SITE>' evaluated to: …"
#                     "Remote files pattern of transfer site: '<SITE>' …"
#                     — the poll was set up; on its own it says nothing about
#                     the outcome, which is exactly "server - no result"
#
# The logged site carries a "_SCP_…"/"_SSCP_…"/"_CCP_…" suffix; it is truncated
# to the clean subscription name the way the transfer parser and the other
# server reports do. Transfer Files join by the showseen rule — the configured
# name PREFIXES the logged _files.tsv value.
#
# A seventh status, "not seen", catches a subscription whose result is neither
# green/red/blue (orange = configured but never seen anywhere, or an unfilled
# result). Both environments currently have none, so its box and its rows
# simply do not appear — but a subscription can never fall out of the table.
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
# server parse cache and writes data/<env>/server/reports/). It lives HERE
# because its page sits in the ANALYSES menu, in the Subscriptions group — the
# same arrangement as cross-reference.sh. bin/server/reports.sh still runs it.
source "$SCRIPT_DIR/../../server/lib.sh"
mkdir -p "$REPORTS_DIR"
OUT="$REPORTS_DIR/uc3-status.rpt"

SUBB="$CONFIG_BASE/_subscriptions.tsv"     # name <TAB> direction <TAB> result
FILESC="$TRANSFER_CACHE/_files.tsv"        # the logical-transfer cache (col 12 = subscription, 2 = outcome)
# result.sh's two flip sidecars, applied by the per-hour walker so its last
# row matches the STATs: _redflip.tsv (green -> red on ring Error/Warn newer
# than the last transfer; name + evidence stamp) and _greenpoll.tsv (the UC3
# clean-poll blues flipped green: polling fine, nothing to fetch).
RFLIP="$DATA/blue/_redflip.tsv"
GPOLL="$DATA/blue/_greenpoll.tsv"
# The per-HOUR status sidecar for the dashboards Overview's UC3 status card.
# Written from THIS script because the classification lives here — the Overview
# must never re-derive it (cf. pesit-slots.tsv). One row per hour,
#   date <TAB> hour <TAB> ok <TAB> no-result <TAB> no-files <TAB> server-error
#        <TAB> ok-error <TAB> error <TAB> not-seen
# i.e. the seven statuses in STACK order, best at the bottom, ascending severity,
# "not seen" last. One hour divides 4/6/12/24 exactly, so the Overview can
# re-bucket to any of its resolutions by taking the LAST hour of each — a status
# is a STATE, not a flow, so it is carried forward, never summed.
SLOTS_OUT="$REPORTS_DIR/uc3-slots.tsv"
# sublink() prefixes an @{alink=subscriptions/<name>} UNCONDITIONALLY — the
# renderer resolves it through the details slugmap and drops the link when the
# name has no page, so a blue subscription with no transfer data still links.
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
skip_if_fresh "$OUT" "${BASH_SOURCE[0]}" "$FILESC" "$SUBB" "$RFLIP" "$GPOLL"
[ -f "$RFLIP" ] || RFLIP=/dev/null   # first build: result.sh not run yet — no flips
[ -f "$GPOLL" ] || GPOLL=/dev/null
echo "Found ${#files[@]} file(s) in '$INPUT_DIR', processing..." >&2

# One awk over three inputs: the configured UC3 roster, the transfer _files.tsv
# (the Files/OK/Error history) and the server cache (the poll signals). Emits
#   A <TAB> stc <TAB> <sub cell> <TAB> files <TAB> ok <TAB> err <TAB> last-file
#           <TAB> polls <TAB> empty <TAB> problems <TAB> last-log <TAB> loglines
#   TOT <TAB> n0..n6 <TAB> files <TAB> ok <TAB> err <TAB> polls <TAB> problems
# the DERIVED use case map (bin/flow-manager.sh): a subscription with no UC
# name prefix whose pattern + movement say UC3 (the production hybrid flows)
# is a UC3 flow here exactly like a UC3_-named one (2026-08-31 audit — the
# roster read the name alone and silently dropped them)
UCDF="$CONFIG_XREF/_subscriptions-ucderived.tsv"; [ -f "$UCDF" ] || UCDF=/dev/null
agg=$(awk -F'\t' -v sb="$SUBB" -v tf="$FILESC" -v rfv="$RFLIP" -v gpv="$GPOLL" -v ucdf="$UCDF" -v SL="$SLOTS_OUT" "$LOGLINES_AWK$LINK_AWK"'
    BEGIN { while ((getline ucl < ucdf) > 0) { nuc = split(ucl, uca, "\t"); if (nuc >= 2 && uca[2] == "UC3") ucd[toupper(uca[1])] = 1 } close(ucdf) }
    # the logged site -> the clean subscription name (as the transfer parser does)
    function clean(s) { sub(/_(SS?|C)CP_.*$/, "", s); return s }
    function jdn(y,m,d,  a){ a=int((14-m)/12); y=y+4800-a; m=m+12*a-3; return d+int((153*m+2)/5)+365*y+int(y/4)-int(y/100)+int(y/400)-32045 }
    function fromjdn(j,   a,b,c,dd,e,mm,day,mon,yr) { a=j+32044; b=int((4*a+3)/146097); c=a-int(146097*b/4); dd=int((4*c+3)/1461); e=c-int(1461*dd/4); mm=int((5*e+2)/153); day=e-int((153*mm+2)/5)+1; mon=mm+3-12*int(mm/10); yr=100*b+dd-4800+int(mm/10); return sprintf("%04d-%02d-%02d", yr, mon, day) }
    function span(h) { if (hmin == "" || h < hmin) hmin = h; if (h > hmax) hmax = h }
    # a logged/configured name -> the configured UC3 roster key. EXACT first —
    # which is what every line in both caches actually is here — then, purely
    # defensively (the server truncates long site names), the roster entry it
    # prefixes or is prefixed by, and ONLY when exactly one matches: an
    # ambiguous truncation must attribute to nothing rather than to whichever
    # entry the roster happens to list first. Memoized: the fallback is a scan.
    function key(u,   i, hit, c) {
        if (u in res) return u
        if (u in memo) return memo[u]
        hit = ""; c = 0
        for (i = 1; i <= nr; i++) if (index(u, R[i]) == 1 || index(R[i], u) == 1) { hit = R[i]; c++ }
        return memo[u] = (c == 1) ? hit : ""
    }
    FILENAME == rfv { if ($1 != "" && $2 != "") rfd[toupper($1)] = $2; next }   # red-flip sidecar: name -> evidence stamp
    FILENAME == gpv { if ($1 != "") gp9[toupper($1)] = 1; next }                # clean-poll greens
    FILENAME == sb {                                         # the configured UC3 roster (UC3-named or derived)
        if ($1 == "" || ($1 !~ /^UC3/ && !(toupper($1) in ucd))) next
        u = toupper($1); res[u] = $3; nm[u] = $1; R[++nr] = u
        next
    }
    FILENAME == tf {                                         # transfer Files, joined by prefix
        if ($12 == "") next
        u = toupper($12); k = key(u); if (k == "") next
        files[k]++
        if ($2 == "Failed" || $2 == "Expired") err[k]++; else ok[k]++
        if ($6 > lsk[k]) { lsk[k] = $6; lfd[k] = $4 }        # col 6 sortkey, col 4 date
        # per-HOUR state for the sidecar: the outcome of the LATEST File in this
        # hour (by sortkey — the cache is CoreId-sorted, not chronological) and
        # whether any OK landed in it
        if ($5 ~ /^[0-9][0-9]:/) {
            hs = $7 * 24 + int(substr($5, 1, 2)); span(hs)
            hk = k SUBSEP hs
            if (!(hk in tsk) || $6 > tsk[hk]) { tsk[hk] = $6; tbad[hk] = ($2 == "Failed" || $2 == "Expired") }
            if ($2 != "Failed" && $2 != "Expired") thok[hk] = 1
        }
        next
    }
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
        k = key(toupper(s)); if (k == "") next
        d = substr($1, 1, 10); if (d !~ /^[0-9][0-9][0-9][0-9]-/) d = ""
        if (d != "" && d > llg[k]) llg[k] = d
        if (sig == "poll") { poll[k]++; if (found > 0) hadfiles[k] = 1; else empty[k]++ }
        else if (sig == "prob") { prob[k]++ }
        # the DECISIVE line — a failure, or a poll that found nothing. The most
        # recent one names the status; a prepared poll and a poll that DID find
        # files decide nothing. Ordered on "date time", not arrival: the exports
        # are newest-first within a file, so cache order is not chronological.
        if (sig == "prob" || (sig == "poll" && found == 0)) {
            t = $1 " " $2
            if (t > lat[k]) { lat[k] = t; latsig[k] = sig }
        }
        # per-HOUR for the sidecar: ANY line makes the flow server-visible (that
        # is what separates "no result" from "not seen"), and the latest DECISIVE
        # line within the hour names the status. Ordered on "date time", not
        # arrival — the exports are newest-first within a file.
        if (d != "" && $2 ~ /^[0-9][0-9]:/) {
            hs = jdn(substr(d,1,4)+0, substr(d,6,2)+0, substr(d,9,2)+0) * 24 + int(substr($2,1,2))
            span(hs); hk = k SUBSEP hs
            if (sig == "prob" || (sig == "poll" && found == 0)) {
                t2 = d " " $2
                if (!(hk in slt) || t2 > slt[hk]) { slt[hk] = t2; ssig[hk] = sig }
            }
        }
        # the drill carries the lines that DECIDE the status: problems first —
        # a poll line would otherwise crowd out the failure among thousands
        addline((sig == "prob" ? "E" : "L") SUBSEP k, $1 " " $2, lvlname($3) " " compname($4) "  " substr(m, 1, 200))
    }
    END {
        # statuses, worst first — the row sort is on this number
        #   0 error             red,  no OK File ever
        #   1 ok -> error        red,  OK Files before it went red
        #   2 server - error    blue, its latest decisive line is a failure
        #   3 server - no files blue, its latest decisive line is an empty poll
        #   4 server - no result blue, no decisive line at all
        #   5 ok                green
        #   6 not seen          neither green/red/blue (orange, or unfilled)
        for (i = 1; i <= nr; i++) {
            k = R[i]; r = res[k]
            if (r == "green")      stc = 5
            else if (r == "red")   stc = (ok[k]+0 > 0) ? 1 : 0
            else if (r == "blue")  stc = (latsig[k] == "prob") ? 2 : (latsig[k] == "poll" ? 3 : 4)
            else                   stc = 6
            n[stc]++
            tf_ += files[k]+0; tok += ok[k]+0; ter += err[k]+0; tpl += poll[k]+0; tpr += prob[k]+0
            # a problem row drills its failures, anything else its recent lines
            dl = (stc == 2) ? lastlines("E" SUBSEP k) : lastlines("L" SUBSEP k)
            printf "A\t%d\t%s%s\t%d\t%d\t%d\t%s\t%d\t%d\t%d\t%s\t%s\n", stc, sublink(nm[k]), nm[k], \
                files[k]+0, ok[k]+0, err[k]+0, (k in lfd ? lfd[k] : "-"), \
                poll[k]+0, empty[k]+0, prob[k]+0, (k in llg ? llg[k] : "-"), dl
        }
        printf "TOT\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\n", \
            n[0]+0, n[1]+0, n[2]+0, n[3]+0, n[4]+0, n[5]+0, n[6]+0, tf_+0, tok+0, ter+0, tpl+0, tpr+0
        # ---- the per-HOUR sidecar (the Overview UC3 status card) -------------
        # Walk the hours forward carrying each subscription\047s state, and count the
        # seven statuses at every hour. The state rules mirror the snapshot above
        # exactly, with the result COLOUR re-derived from the evidence so far
        # (bin/build/result.sh\047s rule for a subscription: green/red by the LAST
        # transfer outcome — including the 2026-08 after-last-transfer red flip
        # and the UC3 clean-poll green flip, read from the _redflip/_greenpoll
        # sidecars below — blue = server-log only, orange = nothing yet) — which
        # is why the LAST hour reproduces the n[] figures printed above. That
        # equality is the regression test.
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
                    if (hk in ssig) LSG[k] = ssig[hk]
                    if (HF[k])                 sc = LOK[k] ? 5 : (EOK[k] ? 1 : 0)
                    else if (LSG[k] == "prob") sc = 2
                    else if (LSG[k] == "poll") sc = 3
                    else if (SV[k])            sc = 4
                    else                       sc = 6
                    if (sc == 5 && (k in RFH) && h >= RFH[k]) sc = 1   # the red flip: ok -> "ok -> error"
                    if (sc == 3 && (k in gp9)) sc = 5   # the clean-poll flip: "server - no files" -> ok (polling fine, nothing to fetch)
                    cnt[sc]++
                }
                printf "%s\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\n", fromjdn(int(h/24)), h%24, \
                    cnt[5]+0, cnt[4]+0, cnt[3]+0, cnt[2]+0, cnt[1]+0, cnt[0]+0, cnt[6]+0 > SL
            }
            close(SL)
        }
    }
' "$RFLIP" "$GPOLL" "$SUBB" "$FILESC" "$PARSED")

IFS=$'\t' read -r _ n_err n_okerr n_serr n_snof n_snor n_ok n_notseen t_files t_ok t_er t_poll t_prob \
    <<< "$(printf '%s\n' "$agg" | grep $'^TOT\t')"
n_all=$(( n_err + n_okerr + n_serr + n_snof + n_snor + n_ok + n_notseen ))
if [ "$n_all" -eq 0 ]; then
    echo "No UC3 subscriptions configured." >&2
    rm -f "$OUT" "$SLOTS_OUT"   # no data for this ENV — page not published
    exit 0
fi

# Rows ordered by status (stc 0..6), within a status by Error desc, Files desc,
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
             ($2 == 3) ? "@{class=warn}server - no files" : \
             ($2 == 4) ? "@{class=warn}server - no result" : \
             ($2 == 5) ? "@{class=processed}ok" : "not seen"
        printf "ROW\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t@data:loglines=%s\n", st, $3, $4, $5, $6, \
            ($7 == "-" ? "—" : $7), $8, $9, $10, ($11 == "-" ? "—" : $11), $12
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
    printf 'TITLE\tUC3 status\n'
    printf 'DESC\tEvery configured UC3 (we poll the partner) subscription in one of six statuses: healthy, failing, failing after a working history, or — for the ones only the server log has ever seen — no files to fetch, a retrieval problem, or no poll result at all.\n'
    printf 'INTRO\tEvery configured **UC3** (we poll the partner and pull files) subscription, in exactly one status. The first three are the **transfer-log** verdict: **ok** = green, its latest File was delivered; **error** = red and never once delivered an OK File; **ok -> error** = red now, but it HAS delivered before — a regression. The other three split the **blue** subscriptions (seen in the server log, never in the transfer log) by the log'"'"'s **latest word** on them: **server - no files** = its last poll found zero files; **server - error** = it could not retrieve from the partner (a connection failure, or a failing directory listing); **server - no result** = the poll is only ever prepared, with no result line and no error naming it. Click a row for its most recent server-log lines.\n'

    printf 'STAT\twhite\t%s\tUC3 subscriptions\n' "$n_all"
    printf 'STAT\tgreen\t%s\tok\n' "$n_ok"
    printf 'STAT\tred\t%s\terror\n' "$n_err"
    printf 'STAT\torange\t%s\tok -> error\n' "$n_okerr"
    printf 'STAT\tblue\t%s\tserver - no files\n' "$n_snof"
    printf 'STAT\tred\t%s\tserver - error\n' "$n_serr"
    printf 'STAT\tblue\t%s\tserver - no result\n' "$n_snor"
    # only when it happens: no environment currently has one, and an always-shown
    # 0 box would advertise a state that is not part of the six
    [ "$n_notseen" -gt 0 ] && printf 'STAT\torange\t%s\tnot seen\n' "$n_notseen"

    printf 'TABLE\tUC3 subscriptions\twide\tnofilter\n'
    printf 'HEAD\tStatus\tSubscription\tFiles\tOK\tError\tLast file\tPolls\tEmpty polls\tProblems\tLast log\n'
    printf 'KIND\ttext\tmono\tnum\tnumprocessed\tnumfailed\ttext\tnum\tnum\tnumfailed\ttext\n'
    printf '%s\n' "$rows"   # %s\n: $rows already ends in one, so this is the blank line before TOTAL
    printf 'TOTAL\tTotal (%s subscription(s))\t\t@{class=num}%s\t@{class=num}%s\t@{class=num}%s\t\t@{class=num}%s\t\t@{class=num}%s\t\n' \
        "$n_all" "$t_files" "$t_ok" "$t_er" "$t_poll" "$t_prob"
    printf 'NOTE\tEvery configured **UC3** subscription, classified. The colour is the site-wide **result**: green/red mean real transfer data (its LAST File OK / Failed-or-Expired), blue means the server log has seen it and the transfer log never has. **error** vs **ok -> error** is a per-FILE question — right after any OK File the subscription WAS green — so a red subscription with even one OK File in the window is a regression; that is finer than **From green to red**, which buckets by whole days and so misses a flow that fails at the end of every day. The blue split reads the TM poll lines and takes the **most recent decisive one** — a poll RESULT of zero files (**server - no files**, the No remote files report), or a **Connection failure** / failing **directory listing** (**server - error**, the No remote dir and Remote polls reports); with neither, only the "Remote folder … evaluated to" lines that merely PREPARE a poll, it is **server - no result**. Latest-wins matters because most subscriptions carrying both signals are polling flows with an occasional blip — one polls 8,941 times and fails 24 — so "any failure" would call them all broken, while the newest line is simply where the flow stands now, the same rule the green/red colour follows. **Files/OK/Error** are logical transfers from the transfer cache; **Polls/Empty polls/Problems** are server-log line counts. **Last log** is the newest line of ANY counted kind, the ones that merely PREPARE a poll included — so it answers "is this flow still running at all", and on a **server - error** row it can be newer than the failures themselves (the flow still polls; it last failed earlier). Click a row for its most recent server-log lines — on a problem row those are the failures, which thousands of routine poll lines would otherwise bury.\n'

    printf 'KEYWORDS\tuc3, poll, pull, remote poll, status, green, red, blue, regression, never worked, no files, retrieval, connection failure, listing, subscription health\n'
    printf 'SUMMARY\tok: %s  |  error: %s  |  ok -> error: %s  |  server - no files: %s  |  server - error: %s  |  server - no result: %s%s\n' \
        "$n_ok" "$n_err" "$n_okerr" "$n_snof" "$n_serr" "$n_snor" \
        "$( [ "$n_notseen" -gt 0 ] && printf '  |  not seen: %s' "$n_notseen" )"
    printf 'FOOT\tGenerated on %s from %s file(s)\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${#files[@]}"
} > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"

echo "Data written to $OUT ($n_all UC3 subscription(s): $n_ok ok, $n_err error, $n_okerr ok-error, $n_snof server-no-files, $n_serr server-error, $n_snor server-no-result, $n_notseen not-seen)." >&2
