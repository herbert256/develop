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
mkdir -p "$REPORTS_DIR"
OUT="$REPORTS_DIR/uc1-status.rpt"

SUBB="$CONFIG_BASE/_subscriptions.tsv"     # name <TAB> direction <TAB> result
FILESC="$TRANSFER_CACHE/_files.tsv"
# result.sh's red-flip sidecar: subscriptions flipped green -> red by ring
# Error/Warn evidence newer than their last transfer, with the evidence stamp.
# The per-hour walker applies the same flip so its last row matches the STATs.
RFLIP="$DATA/colour/_redflip.tsv"
# The per-HOUR status sidecar for the Overview's UC1 status card — written HERE
# because the classification lives here; the Overview must never re-derive it
# (cf. pesit-slots.tsv). date <TAB> hour <TAB> the FOUR statuses in STACK order:
#   ok, ok-error, error, not-seen
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
[ -f "$RFLIP" ] || RFLIP=/dev/null   # first build: result.sh not run yet — no flips
echo "Found ${#files[@]} file(s) in '$INPUT_DIR', processing..." >&2

# One awk over three inputs: the configured UC1 roster, the transfer _files.tsv
# (the Files/OK/Error history) and the server cache (the route signals). Emits
#   A <TAB> stc <TAB> <sub cell> <TAB> files <TAB> ok <TAB> err <TAB> last-file
#           <TAB> problems <TAB> last-log <TAB> loglines
#   TOT <TAB> n0..n3 <TAB> files <TAB> ok <TAB> err <TAB> problems
# the DERIVED use case map (bin/flow-manager.sh): a subscription with no UC
# name prefix whose pattern + movement say UC1 (the production hybrid flows)
# is a UC1 flow here exactly like a UC1_-named one (2026-08-31 audit — the
# roster read the name alone and silently dropped them)
UCDF="$CONFIG_XREF/_subscriptions-ucderived.tsv"; [ -f "$UCDF" ] || UCDF=/dev/null
agg=$(awk -F'\t' -v sb="$SUBB" -v tf="$FILESC" -v rfv="$RFLIP" -v ucdf="$UCDF" -v SL="$SLOTS_OUT" "$LOGLINES_AWK$LINK_AWK"'
    BEGIN { while ((getline ucl < ucdf) > 0) { nuc = split(ucl, uca, "\t"); if (nuc >= 2 && uca[2] == "UC1") ucd[toupper(uca[1])] = 1 } close(ucdf) }
    # the logged site -> the clean subscription name (as the transfer parser does)
    function clean(s) { sub(/_(SS?|C)CP_.*$|_[A-Za-z0-9]+_(SERVER|CLIENT)_.*$/, "", s); return s }
    function jdn(y,m,d,  a){ a=int((14-m)/12); y=y+4800-a; m=m+12*a-3; return d+int((153*m+2)/5)+365*y+int(y/4)-int(y/100)+int(y/400)-32045 }
    function fromjdn(j,   a,b,c,dd,e,mm,day,mon,yr) { a=j+32044; b=int((4*a+3)/146097); c=a-int(146097*b/4); dd=int((4*c+3)/1461); e=c-int(1461*dd/4); mm=int((5*e+2)/153); day=e-int((153*mm+2)/5)+1; mon=mm+3-12*int(mm/10); yr=100*b+dd-4800+int(mm/10); return sprintf("%04d-%02d-%02d", yr, mon, day) }
    function span(h) { if (hmin == "" || h < hmin) hmin = h; if (h > hmax) hmax = h }
    # the row drill: its problem lines (E) newest first, then its other lines
    # (L) newest first, 10 in all — so the failures a verdict classifies
    # (subscription-verdict.awk nextmove) always lead, on every row
    function drill(k,   e, l, ne, nl, a9, i9, s9) {
        e = lastlines("E" SUBSEP k); l = lastlines("L" SUBSEP k)
        if (e == "" || l == "") return e l
        ne = split(e, a9, _US); s9 = e; nl = split(l, a9, _US)
        for (i9 = 1; i9 <= nl && ne < 10; i9++) { s9 = s9 _US a9[i9]; ne++ }
        return s9
    }
    # a SERVER-LOG name -> the configured UC1 roster key. EXACT first — what
    # nearly every line actually is — then, purely defensively (the server
    # truncates long site names), the roster entry it prefixes or is prefixed
    # by, and ONLY when exactly one matches: an ambiguous truncation must
    # attribute to nothing rather than to whichever entry comes first.
    # _files.tsv never goes through this: its col 12 joins EXACTLY.
    function key(u,   i, hit, c) {
        if (u in res) return u
        if (u in memo) return memo[u]
        hit = ""; c = 0
        for (i = 1; i <= nr; i++) if (index(u, R[i]) == 1 || index(R[i], u) == 1) { hit = R[i]; c++ }
        return memo[u] = (c == 1) ? hit : ""
    }
    FILENAME == sb {                                         # the configured UC1 roster (UC1-named or derived)
        if ($1 == "" || ($1 !~ /^UC1/ && !(toupper($1) in ucd))) next
        u = toupper($1); res[u] = $3; nm[u] = $1; R[++nr] = u
        next
    }
    FILENAME == rfv { if ($1 != "" && $2 != "") rfd[toupper($1)] = ($3 != "") ? $3 : $2; next }   # red-flip sidecar: name -> RED SINCE (col 3; col 2 = the newest evidence)
    FILENAME == tf {                                         # transfer Files, joined EXACTLY (as result.sh)
        if ($12 == "") next
        k = toupper($12); if (!(k in res)) next
        files[k]++
        if ($2 == "Failed" || $2 == "Expired") err[k]++; else ok[k]++
        if ($6 > lsk[k]) { lsk[k] = $6; lfd[k] = $4 }        # col 6 sortkey, col 4 date
        # per-HOUR state for the sidecar: the outcome of the LATEST File in this
        # hour (by sortkey — the cache is CoreId-sorted, not chronological):
        # "F" Failed (red), "X" Expired (ORANGE — the result colour of an
        # Expired-last flow, not red), "" OK
        if ($5 ~ /^[0-9][0-9]:/) {
            hs = $7 * 24 + int(substr($5, 1, 2)); span(hs); hk = k SUBSEP hs
            if (!(hk in tsk) || $6 > tsk[hk]) { tsk[hk] = $6; tbad[hk] = ($2 == "Failed") ? "F" : ($2 == "Expired") ? "X" : "" }
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
        k = key(toupper(s)); if (k == "") next
        d = substr($1, 1, 10); if (d !~ /^[0-9][0-9][0-9][0-9]-/) d = ""
        if (d != "" && d > llg[k]) llg[k] = d
        prob[k]++                                            # every counted UC1 line is a problem
        # per-HOUR: a server line widens the walked span
        if (d != "" && $2 ~ /^[0-9][0-9]:/)
            span(jdn(substr(d,1,4)+0, substr(d,6,2)+0, substr(d,9,2)+0) * 24 + int(substr($2,1,2)))
        # the drill keeps the failures on their own key (E), ahead of any
        # other line (L — none for UC1 today; drill() below merges them)
        addline((sig == "prob" ? "E" : "L") SUBSEP k, $1 " " $2, lvlname($3) " " compname($4) "  " substr(m, 1, 200))
    }
    END {
        # statuses, worst first — the row sort is on this number
        #   0 error             red,  no OK File ever
        #   1 ok -> error       red,  OK Files before it went red
        #   2 ok                green
        #   3 not seen          orange (or unfilled) — never in the transfer log
        for (i = 1; i <= nr; i++) {
            k = R[i]; r = res[k]
            if (r == "green")      stc = 2
            else if (r == "red")   stc = (ok[k]+0 > 0) ? 1 : 0
            else                   stc = 3
            n[stc]++
            tf_ += files[k]+0; tok += ok[k]+0; ter += err[k]+0; tpr += prob[k]+0
            dl = drill(k)
            printf "A\t%d\t%s%s\t%d\t%d\t%d\t%s\t%d\t%s\t%s\n", stc, sublink(nm[k]), nm[k], \
                files[k]+0, ok[k]+0, err[k]+0, (k in lfd ? lfd[k] : "-"), \
                prob[k]+0, (k in llg ? llg[k] : "-"), dl
        }
        printf "TOT\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\n", \
            n[0]+0, n[1]+0, n[2]+0, n[3]+0, tf_+0, tok+0, ter+0, tpr+0
        # ---- the per-HOUR sidecar (the Overview UC1 status card) -------------
        # The hours walked forward carrying each subscription\047s state, counting the
        # four statuses at each. The rules mirror the snapshot above with the result
        # COLOUR re-derived from the evidence so far (result.sh\047s subscription rule:
        # green/red by the LAST transfer outcome — INCLUDING the 2026-08
        # after-last-transfer red flip, read from the _redflip sidecar below —
        # orange = nothing yet), so the LAST hour reproduces the n[] figures
        # printed above — that equality is the regression test.
        if (hmin != "" && SL != "") {
            # the result.sh RED FLIP (_redflip.tsv): a green-by-transfer flow
            # flipped red by ring Error/Warn evidence NEWER than its last
            # transfer. Applied from the hour it went red (the sidecar SINCE
            # column), clamped into the walked span, so the LAST row
            # reproduces the snapshot n[] exactly (the regression test). Hash
            # order here only FILLS a map.
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
                    if (hk in tsk) { HF[k] = 1; LST[k] = tbad[hk] }
                    if (hk in thok) EOK[k] = 1
                    # the COLOUR so far: an Expired last File is ORANGE, like
                    # the snapshot (result.sh), so it reads "not seen" too
                    col = !HF[k] ? "o" : (LST[k] == "") ? "g" : (LST[k] == "X") ? "o" : "r"
                    # the red flip: green or orange -> red from its hour on
                    if ((k in RFH) && h >= RFH[k]) col = "r"
                    sc = (col == "g") ? 2 : (col == "o") ? 3 : (EOK[k] ? 1 : 0)
                    cnt[sc]++
                }
                # the FOUR-column shape uc3/uc4 use, so ONE Overview chart kind
                # covers all three UC1/UC3/UC4 cards
                printf "%s\t%d\t%d\t%d\t%d\t%d\n", fromjdn(int(h/24)), h%24, \
                    cnt[2]+0, cnt[1]+0, cnt[0]+0, cnt[3]+0 > SL
            }
            close(SL)
        }
    }
' "$SUBB" "$RFLIP" "$FILESC" "$(srv_subset uc1)")

IFS=$'\t' read -r _ n_err n_okerr n_ok n_notseen t_files t_ok t_er t_prob \
    <<< "$(printf '%s\n' "$agg" | grep $'^TOT\t')"
n_all=$(( n_err + n_okerr + n_ok + n_notseen ))
if [ "$n_all" -eq 0 ]; then
    echo "No UC1 subscriptions configured." >&2
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
    function z(v) { return (v + 0 == 0) ? "" : v }   # a count cell shows blank, never 0
    $3 == "" { next }          # no subscription (and the blank line an empty stream feeds in)
    {
        # ok -> error is RED like its row and its STAT box (2026-09-29 — the
        # amber warn class read as a third result colour)
        st = ($2 == 0) ? "@{class=failed}error" : \
             ($2 == 1) ? "@{class=failed}ok -> error" : \
             ($2 == 2) ? "@{class=processed}ok" : "not seen"
        # (the Route runs column went 2026-09-29: its "Starting execution"
        # line is dropped at tokenize time — AR0076 is on the NOISE list)
        printf "ROW\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t@data:loglines=%s\n", st, $3, z($4), z($5), z($6), \
            ($7 == "-" ? "—" : $7), z($8), ($9 == "-" ? "—" : $9), $10
    }
' <<< "$(printf '%s\n' "$agg" | grep $'^A\t' | LC_ALL=C sort -t$'\t' -k2,2n -k6,6nr -k4,4nr -k3,3)")

# A run with data but NO timestamped rows writes no sidecar at all; an EMPTY
# sidecar is the valid "no per-hour data" answer for its readers (the
# dashboards overview), so one is created when absent.
[ -f "$SLOTS_OUT" ] || : > "$SLOTS_OUT"

nz0() { [ "${1:-0}" = 0 ] || printf '%s' "$1"; }   # a count cell shows blank, never 0

{
    printf 'TITLE\tUC1 status\n'

    printf 'STAT\twhite\t%s\tUC1 subscriptions\n' "$n_all"
    printf 'STAT\tgreen\t%s\tok\n' "$n_ok"
    printf 'STAT\tred\t%s\terror\n' "$n_err"
    printf 'STAT\tred\t%s\tok -> error\n' "$n_okerr"   # red like its rows (the result colour), 2026-09-29
    printf 'STAT\torange\t%s\tnot seen\n' "$n_notseen"

    printf 'TABLE\tUC1 subscriptions\twide\tnofilter\n'
    printf 'HEAD\tStatus\tSubscription\tFiles\tOK\tError\tLast file\tProblems\tLast log\n'
    printf 'KIND\ttext\tmono\tnum\tnumprocessed\tnumfailed\ttext\tnumfailed\ttext\n'
    [ -z "$rows" ] || printf '%s\n' "$rows"   # (no blank line before TOTAL, 2026-09-29 audit)
    # the OK / Error / Problems totals keep their column tint (2026-09-29)
    printf 'TOTAL\tTotal (%s subscription(s))\t\t@{class=num}%s\t@{class=num processed}%s\t@{class=num failed}%s\t\t@{class=num failed}%s\t\n' \
        "$n_all" "$(nz0 "$t_files")" "$(nz0 "$t_ok")" "$(nz0 "$t_er")" "$(nz0 "$t_prob")"

    printf 'KEYWORDS\tuc1, push, send, sendtopartner, advanced routing, status, green, red, orange, regression, never worked, never seen, unused, connection failure, could not send, subscription health\n'
    printf 'FOOT\n'
} > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"

echo "Data written to $OUT ($n_all UC1 subscription(s): $n_ok ok, $n_err error, $n_okerr ok-error, $n_notseen not-seen)." >&2
