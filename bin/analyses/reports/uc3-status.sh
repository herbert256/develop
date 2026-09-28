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
#   not seen           orange: configured, never seen in the transfer log
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
# server reports do. Transfer Files join by the showseen rule — the configured
# name PREFIXES the logged _files.tsv value.
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
# result.sh's flip sidecar, applied by the per-hour walker so its last row
# matches the STATs: _redflip.tsv (green -> red on ring Error/Warn newer than
# the last transfer, or the cannot-connect red; name + evidence stamp). The
# clean-poll greens (_greenpoll.tsv) went 2026-09-28: a UC3 with no File is
# not seen, however it polls.
RFLIP="$DATA/colour/_redflip.tsv"
# The per-HOUR status sidecar for the dashboards Overview's UC3 status card.
# Written from THIS script because the classification lives here — the Overview
# must never re-derive it (cf. pesit-slots.tsv). One row per hour,
#   date <TAB> hour <TAB> ok <TAB> ok-error <TAB> error <TAB> not-seen
# i.e. the four statuses in STACK order, best at the bottom, ascending severity,
# "not seen" last. One hour divides 4/6/12/24 exactly, so the Overview can
# re-bucket to any of its resolutions by taking the LAST hour of each — a status
# is a STATE, not a flow, so it is carried forward, never summed.
SLOTS_OUT="$REPORTS_DIR/uc3-slots.tsv"
# sublink() prefixes an @{alink=subscriptions/<name>} UNCONDITIONALLY — the
# renderer resolves it through the details slugmap and drops the link when the
# name has no page, so a subscription with no transfer data still links.
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
[ -f "$RFLIP" ] || RFLIP=/dev/null   # first build: result.sh not run yet — no flips
echo "Found ${#files[@]} file(s) in '$INPUT_DIR', processing..." >&2

# One awk over three inputs: the configured UC3 roster, the transfer _files.tsv
# (the Files/OK/Error history) and the server cache (the poll signals). Emits
#   A <TAB> stc <TAB> <sub cell> <TAB> files <TAB> ok <TAB> err <TAB> last-file
#           <TAB> polls <TAB> empty <TAB> problems <TAB> last-log <TAB> loglines
#   TOT <TAB> n0..n3 <TAB> files <TAB> ok <TAB> err <TAB> polls <TAB> problems
# the DERIVED use case map (bin/flow-manager.sh): a subscription with no UC
# name prefix whose pattern + movement say UC3 (the production hybrid flows)
# is a UC3 flow here exactly like a UC3_-named one (2026-08-31 audit — the
# roster read the name alone and silently dropped them)
UCDF="$CONFIG_XREF/_subscriptions-ucderived.tsv"; [ -f "$UCDF" ] || UCDF=/dev/null
agg=$(awk -F'\t' -v sb="$SUBB" -v tf="$FILESC" -v rfv="$RFLIP" -v ucdf="$UCDF" -v SL="$SLOTS_OUT" "$LOGLINES_AWK$LINK_AWK"'
    BEGIN { while ((getline ucl < ucdf) > 0) { nuc = split(ucl, uca, "\t"); if (nuc >= 2 && uca[2] == "UC3") ucd[toupper(uca[1])] = 1 } close(ucdf) }
    # the logged site -> the clean subscription name (as the transfer parser does)
    function clean(s) { sub(/_(SS?|C)CP_.*$|_[A-Za-z0-9]+_(SERVER|CLIENT)_.*$/, "", s); return s }
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
        if (sig == "poll") { poll[k]++; if (found == 0) empty[k]++ }
        else if (sig == "prob") { prob[k]++ }
        # a server line widens the hours the per-HOUR sidecar walks
        if (d != "" && $2 ~ /^[0-9][0-9]:/)
            span(jdn(substr(d,1,4)+0, substr(d,6,2)+0, substr(d,9,2)+0) * 24 + int(substr($2,1,2)))
        # the drill keeps the problems apart: on a red flow that never
        # transferred they are the story, and thousands of routine poll lines
        # would otherwise crowd them out
        addline((sig == "prob" ? "E" : "L") SUBSEP k, $1 " " $2, lvlname($3) " " compname($4) "  " substr(m, 1, 200))
    }
    END {
        # statuses, worst first — the row sort is on this number
        #   0 error             red,  no OK File ever
        #   1 ok -> error       red,  OK Files before it went red
        #   2 ok                green
        #   3 not seen          neither green nor red (orange, or unfilled)
        for (i = 1; i <= nr; i++) {
            k = R[i]; r = res[k]
            if (r == "green")      stc = 2
            else if (r == "red")   stc = (ok[k]+0 > 0) ? 1 : 0
            else                   stc = 3
            n[stc]++
            tf_ += files[k]+0; tok += ok[k]+0; ter += err[k]+0; tpl += poll[k]+0; tpr += prob[k]+0
            # a red flow that never transferred drills its failures (the
            # cannot-connect red), anything else its recent lines
            dl = (stc == 0 && files[k]+0 == 0) ? lastlines("E" SUBSEP k) : lastlines("L" SUBSEP k)
            printf "A\t%d\t%s%s\t%d\t%d\t%d\t%s\t%d\t%d\t%d\t%s\t%s\n", stc, sublink(nm[k]), nm[k], \
                files[k]+0, ok[k]+0, err[k]+0, (k in lfd ? lfd[k] : "-"), \
                poll[k]+0, empty[k]+0, prob[k]+0, (k in llg ? llg[k] : "-"), dl
        }
        printf "TOT\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\n", \
            n[0]+0, n[1]+0, n[2]+0, n[3]+0, tf_+0, tok+0, ter+0, tpl+0, tpr+0
        # ---- the per-HOUR sidecar (the Overview UC3 status card) -------------
        # Walk the hours forward carrying each subscription\047s state, and count the
        # four statuses at every hour. The state rules mirror the snapshot above
        # exactly, with the result COLOUR re-derived from the evidence so far
        # (bin/build/result.sh\047s rule for a subscription: green/red by the LAST
        # transfer outcome — including the 2026-08 after-last-transfer red flip
        # and the cannot-connect red, read from the _redflip sidecar below —
        # orange = no File yet) — which is why the LAST hour
        # reproduces the n[] figures printed above. That equality is the
        # regression test.
        if (hmin != "" && SL != "") {
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
                    if (HF[k]) sc = LOK[k] ? 2 : (EOK[k] ? 1 : 0)
                    else       sc = 3   # no File yet: not seen, however it polls (2026-09-28)
                    # the red flip: ok -> "ok -> error"; a never-transferred flow
                    # (the cannot-connect rule) goes straight to error
                    if ((k in RFH) && h >= RFH[k]) { if (sc == 2) sc = 1; else if (sc == 3) sc = 0 }
                    cnt[sc]++
                }
                printf "%s\t%d\t%d\t%d\t%d\t%d\n", fromjdn(int(h/24)), h%24, \
                    cnt[2]+0, cnt[1]+0, cnt[0]+0, cnt[3]+0 > SL
            }
            close(SL)
        }
    }
' "$RFLIP" "$SUBB" "$FILESC" "$(srv_subset uc3)")

IFS=$'\t' read -r _ n_err n_okerr n_ok n_notseen t_files t_ok t_er t_poll t_prob \
    <<< "$(printf '%s\n' "$agg" | grep $'^TOT\t')"
n_all=$(( n_err + n_okerr + n_ok + n_notseen ))
if [ "$n_all" -eq 0 ]; then
    echo "No UC3 subscriptions configured." >&2
    rm -f "$OUT" "$SLOTS_OUT"   # no data for this ENV — page not published
    exit 0
fi

# Rows ordered by status (stc 0..3), within a status by Error desc, Files desc,
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
             ($2 == 2) ? "@{class=processed}ok" : "not seen"
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
    printf 'DESC\tEvery configured UC3 (we poll the partner) subscription in one of four statuses: healthy, failing, failing after a working history, or not seen in the transfer log — with its poll counts from the server log.\n'
    printf 'INTRO\tEvery configured **UC3** (we poll the partner and pull files) subscription, in exactly one status: **ok** = green, its latest File was delivered (or it polls cleanly with nothing to fetch); **error** = red and never once delivered an OK File; **ok -> error** = red now, but it HAS delivered before — a regression; **not seen** = configured, never seen in the transfer log. Click a row for its most recent server-log lines.\n'

    printf 'STAT\twhite\t%s\tUC3 subscriptions\n' "$n_all"
    printf 'STAT\tgreen\t%s\tok\n' "$n_ok"
    printf 'STAT\tred\t%s\terror\n' "$n_err"
    printf 'STAT\torange\t%s\tok -> error\n' "$n_okerr"
    printf 'STAT\torange\t%s\tnot seen\n' "$n_notseen"

    printf 'TABLE\tUC3 subscriptions\twide\tnofilter\ttab=uc3\n'   # tab=uc3: uc3-polling.sh's tables stack under this one on the UC3 tab page (2026-09-05)
    printf 'HEAD\tStatus\tSubscription\tFiles\tOK\tError\tLast file\tPolls\tEmpty polls\tProblems\tLast log\n'
    printf 'KIND\ttext\tmono\tnum\tnumprocessed\tnumfailed\ttext\tnum\tnum\tnumfailed\ttext\n'
    printf '%s\n' "$rows"   # %s\n: $rows already ends in one, so this is the blank line before TOTAL
    printf 'TOTAL\tTotal (%s subscription(s))\t\t@{class=num}%s\t@{class=num}%s\t@{class=num}%s\t\t@{class=num}%s\t\t@{class=num}%s\t\n' \
        "$n_all" "$t_files" "$t_ok" "$t_er" "$t_poll" "$t_prob"
    printf 'NOTE\tEvery configured **UC3** subscription, classified. The colour is the site-wide **result**: green/red mean real transfer data (its LAST File OK / Failed-or-Expired), orange means the transfer log has never seen it. **error** vs **ok -> error** is a per-FILE question — right after any OK File the subscription WAS green — so a red subscription with even one OK File in the window is a regression; that is finer than **From green to red**, which buckets by whole days and so misses a flow that fails at the end of every day. **Files/OK/Error** are logical transfers from the transfer cache; **Polls/Empty polls/Problems** are server-log line counts (a poll result; a Connection failure or failing directory listing). **Last log** is the newest line of ANY counted kind, the ones that merely PREPARE a poll included — so it answers "is this flow still running at all". Click a row for its most recent server-log lines.\n'

    printf 'KEYWORDS\tuc3, poll, pull, remote poll, status, green, red, regression, never worked, not seen, connection failure, listing, subscription health\n'
    printf 'SUMMARY\tok: %s  |  error: %s  |  ok -> error: %s  |  not seen: %s\n' \
        "$n_ok" "$n_err" "$n_okerr" "$n_notseen"
    printf 'FOOT\tGenerated on %s from %s file(s)\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${#files[@]}"
} > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"

echo "Data written to $OUT ($n_all UC3 subscription(s): $n_ok ok, $n_err error, $n_okerr ok-error, $n_notseen not-seen)." >&2
