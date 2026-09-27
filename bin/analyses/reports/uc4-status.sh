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
# _subscriptions.tsv, filled by bin/build/result.sh): green/red = real transfer
# data, its LAST File OK / Failed-or-Expired; orange = never seen. The three
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
# Transfer Files join by the showseen rule — the configured name PREFIXES the
# logged _files.tsv value.
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
# server parse cache and writes data/<env>/server/reports/). It lives HERE
# because its page sits in the ANALYSES menu, in the Subscriptions group — the
# same arrangement as cross-reference.sh. bin/server/reports.sh still runs it.
source "$SCRIPT_DIR/../../server/lib.sh"
mkdir -p "$REPORTS_DIR"
OUT="$REPORTS_DIR/uc4-status.rpt"

SUBB="$CONFIG_BASE/_subscriptions.tsv"            # name <TAB> direction <TAB> result
FILESC="$TRANSFER_CACHE/_files.tsv"
# result.sh's red-flip sidecar (green -> red on ring Error/Warn newer than the
# last transfer; name + evidence stamp). The per-hour walker applies the same
# flip so its last row matches the STATs.
RFLIP="$DATA/colour/_redflip.tsv"
# The per-HOUR status sidecar for the Overview's UC4 status card — written HERE
# because the classification lives here (cf. pesit-slots.tsv). date <TAB> hour
# <TAB> the FOUR statuses in STACK order: ok, ok-error, error, not-seen.
# One hour divides
# 4/6/12/24 exactly; the Overview re-buckets by taking the LAST hour of each,
# since a status is a STATE, carried forward, never summed.
SLOTS_OUT="$REPORTS_DIR/uc4-slots.tsv"               # col 12 = subscription, 2 = outcome
XREF="$CONFIG_XREF/_accounts-subscriptions.tsv"   # account -> its subscriptions
# the DERIVED use case map (bin/flow-manager.sh): a subscription with no UC
# name prefix whose pattern + movement say UC4 counts as a UC4 flow here
UCDF="$CONFIG_XREF/_subscriptions-ucderived.tsv"
# the MULTI-FE-ACCOUNT maps (2026-08-31, user report — see the awk BEGIN)
SLF="$CONFIG_XREF/_subscriptions-logins.tsv"; [ -f "$SLF" ] || SLF=/dev/null
ALF="$CONFIG_XREF/_accounts-logins.tsv";      [ -f "$ALF" ] || ALF=/dev/null
[ -f "$UCDF" ] || UCDF=/dev/null
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
skip_if_fresh "$OUT" "${BASH_SOURCE[0]}" "$FILESC" "$SUBB" "$XREF" "$RFLIP" "$UCDF"
[ -f "$RFLIP" ] || RFLIP=/dev/null   # first build: result.sh not run yet — no flips
echo "Found ${#files[@]} file(s) in '$INPUT_DIR', processing..." >&2

# One awk over four inputs: the configured UC4 roster, the account->subscription
# map, the transfer _files.tsv (the Files/OK/Error history) and the server cache
# (the partner-side signals). Emits
#   A <TAB> stc <TAB> <sub cell> <TAB> files <TAB> ok <TAB> err <TAB> last-file
#           <TAB> logons <TAB> arrivals <TAB> problems <TAB> last-log <TAB> loglines
#   TOT <TAB> n0..n6 <TAB> files <TAB> ok <TAB> err <TAB> logons <TAB> arrivals <TAB> problems
agg=$(awk -F'\t' -v sb="$SUBB" -v xf="$XREF" -v tf="$FILESC" -v rfv="$RFLIP" -v ucdf="$UCDF" -v slf="$SLF" -v alf="$ALF" -v SL="$SLOTS_OUT" "$LOGLINES_AWK$LINK_AWK"'
    BEGIN { while ((getline ucl < ucdf) > 0) { nuc = split(ucl, uca, "\t"); if (nuc >= 2 && uca[2] == "UC4") ucd[toupper(uca[1])] = 1 } close(ucdf)
            # MULTI-FE ACCOUNTS (2026-08-31, user report): when the account
            # carries SEVERAL configured logins, a logon or refusal that NAMES
            # one is credited only to the flows configured for THAT login —
            # each login is a different partner credential, so its lines say
            # nothing about the other logins flows. Single-login accounts and
            # lines naming no login keep the account-wide union.
            while ((getline ucl < slf) > 0) { nuc = split(ucl, uca, "\t"); if (nuc >= 2 && uca[1] != "" && uca[2] != "") SUBL[toupper(uca[1])] = SUBL[toupper(uca[1])] SUBSEP toupper(uca[2]) } close(slf)
            while ((getline ucl < alf) > 0) { nuc = split(ucl, uca, "\t"); if (nuc >= 2 && uca[1] != "") aln[uca[1]]++ } close(alf) }
    function jdn(y,m,d,  a){ a=int((14-m)/12); y=y+4800-a; m=m+12*a-3; return d+int((153*m+2)/5)+365*y+int(y/4)-int(y/100)+int(y/400)-32045 }
    function fromjdn(j,   a,b,c,dd,e,mm,day,mon,yr) { a=j+32044; b=int((4*a+3)/146097); c=a-int(146097*b/4); dd=int((4*c+3)/1461); e=c-int(1461*dd/4); mm=int((5*e+2)/153); day=e-int((153*mm+2)/5)+1; mon=mm+3-12*int(mm/10); yr=100*b+dd-4800+int(mm/10); return sprintf("%04d-%02d-%02d", yr, mon, day) }
    function span(h) { if (hmin == "" || h < hmin) hmin = h; if (h > hmax) hmax = h }
    function acctof(m,   a) { a=""; if (match(m, /[A-Za-z0-9_.-]+@FE[0-9]+/)) { a=substr(m,RSTART,RLENGTH); sub(/@.*/,"",a) } return a }
    # a logged subscription name -> the roster key. EXACT first, then (purely
    # defensively) the roster entry it prefixes or is prefixed by, and ONLY when
    # exactly one matches — an ambiguous truncation attributes to nothing.
    function key(u,   i, hit, c) {
        if (u in res) return u
        if (u in memo) return memo[u]
        hit = ""; c = 0
        for (i = 1; i <= nr; i++) if (index(u, R[i]) == 1 || index(R[i], u) == 1) { hit = R[i]; c++ }
        return memo[u] = (c == 1) ? hit : ""
    }
    FILENAME == rfv { if ($1 != "" && $2 != "") rfd[toupper($1)] = $2; next }   # red-flip sidecar: name -> evidence stamp
    FILENAME == sb {                                         # the configured UC4 roster
        if ($1 == "" || ($1 !~ /^UC4/ && !(toupper($1) in ucd))) next
        u = toupper($1); res[u] = $3; nm[u] = $1; R[++nr] = u
        next
    }
    FILENAME == xf {                                         # account -> its UC4 subscription(s), ALL of them
        if (($2 ~ /^UC4/ || (toupper($2) in ucd)) && (toupper($2) in res)) asub[$1] = asub[$1] SUBSEP toupper($2)
        next
    }
    FILENAME == tf {                                         # transfer Files, joined by prefix
        if ($12 == "") next
        u = toupper($12); k = key(u); if (k == "") next
        files[k]++
        if ($2 == "Failed" || $2 == "Expired") err[k]++; else ok[k]++
        if ($6 > lsk[k]) { lsk[k] = $6; lfd[k] = $4 }        # col 6 sortkey, col 4 date
        if ($5 ~ /^[0-9][0-9]:/) {                           # per-HOUR state for the sidecar
            hs = $7 * 24 + int(substr($5, 1, 2)); span(hs); hk = k SUBSEP hs
            if (!(hk in tsk) || $6 > tsk[hk]) { tsk[hk] = $6; tbad[hk] = ($2 == "Failed" || $2 == "Expired") }
            if ($2 != "Failed" && $2 != "Expired") thok[hk] = 1
        }
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
        d = substr($1, 1, 10); if (d !~ /^[0-9][0-9][0-9][0-9]-/) d = ""
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
            if (d != "" && $2 ~ /^[0-9][0-9]:/)                  # a server line widens the walked span
                span(jdn(substr(d,1,4)+0, substr(d,6,2)+0, substr(d,9,2)+0) * 24 + int(substr($2,1,2)))
            # the drill keeps the refusals on their own key, so a refused flow
            # is not crowded out by routine logons
            addline((sig == "prob" ? "E" : "L") SUBSEP k, $1 " " $2, lvlname($3) " " compname($4) "  " substr(m, 1, 200))
        }
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
            tf_ += files[k]+0; tok += ok[k]+0; ter += err[k]+0
            tlg = tlgL + 0; tar = tarL + 0; tpr = tprL + 0   # per LINE, not per credited flow
            dl = (stc == 0 && files[k]+0 == 0) ? lastlines("E" SUBSEP k) : lastlines("L" SUBSEP k)
            printf "A\t%d\t%s%s\t%d\t%d\t%d\t%s\t%d\t%d\t%d\t%s\t%s\n", stc, sublink(nm[k]), nm[k], \
                files[k]+0, ok[k]+0, err[k]+0, (k in lfd ? lfd[k] : "-"), \
                logon[k]+0, arr[k]+0, prob[k]+0, (k in llg ? llg[k] : "-"), dl
        }
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
                    else       sc = 3
                    # the red flip: ok -> "ok -> error"; a never-transferred
                    # flow goes straight to error
                    if ((k in RFH) && h >= RFH[k]) { if (sc == 2) sc = 1; else if (sc == 3) sc = 0 }
                    cnt[sc]++
                }
                printf "%s\t%d\t%d\t%d\t%d\t%d\n", fromjdn(int(h/24)), h%24, \
                    cnt[2]+0, cnt[1]+0, cnt[0]+0, cnt[3]+0 > SL
            }
            close(SL)
        }
        printf "TOT\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\n", \
            n[0]+0, n[1]+0, n[2]+0, n[3]+0, \
            tf_+0, tok+0, ter+0, tlg+0, tar+0, tpr+0
    }
' "$RFLIP" "$SUBB" "$XREF" "$FILESC" "$PARSED")

IFS=$'\t' read -r _ n_err n_okerr n_ok n_notseen t_files t_ok t_er t_lg t_ar t_prob \
    <<< "$(printf '%s\n' "$agg" | grep $'^TOT\t')"
n_all=$(( n_err + n_okerr + n_ok + n_notseen ))
if [ "$n_all" -eq 0 ]; then
    echo "No UC4 subscriptions configured." >&2
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
    printf 'TITLE\tUC4 status\n'
    printf 'DESC\tEvery configured UC4 (the partner connects in and delivers a file to us) subscription in one of four statuses: healthy, failing, failing after a working history, or not seen in the transfer log — with its logons, arrivals and refusals from the server log.\n'
    printf 'INTRO\tEvery configured **UC4** (we are the server; the partner connects IN and DELIVERS a file to us) subscription, in exactly one status: **ok** = green, its latest File arrived; **error** = red and never once received an OK File; **ok -> error** = red now, but it HAS received before — a regression; **not seen** = configured and never seen in the transfer log. Click a row for its most recent server-log lines.\n'

    printf 'STAT\twhite\t%s\tUC4 subscriptions\n' "$n_all"
    printf 'STAT\tgreen\t%s\tok\n' "$n_ok"
    printf 'STAT\tred\t%s\terror\n' "$n_err"
    printf 'STAT\torange\t%s\tok -> error\n' "$n_okerr"
    printf 'STAT\torange\t%s\tnot seen\n' "$n_notseen"

    printf 'TABLE\tUC4 subscriptions\twide\tnofilter\n'
    printf 'HEAD\tStatus\tSubscription\tFiles\tOK\tError\tLast file\tLogons\tArrivals\tProblems\tLast log\n'
    printf 'KIND\ttext\tmono\tnum\tnumprocessed\tnumfailed\ttext\tnum\tnum\tnumfailed\ttext\n'
    printf '%s\n' "$rows"   # %s\n: $rows already ends in one, so this is the blank line before TOTAL
    printf 'TOTAL\tTotal (%s subscription(s))\t\t@{class=num}%s\t@{class=num}%s\t@{class=num}%s\t\t@{class=num}%s\t@{class=num}%s\t@{class=num}%s\t\n' \
        "$n_all" "$t_files" "$t_ok" "$t_er" "$t_lg" "$t_ar" "$t_prob"
    printf 'NOTE\tEvery configured **UC4** subscription, classified. The colour is the site-wide **result**: green/red mean real transfer data (its LAST File OK / Failed-or-Expired), and orange — **not seen** — means the transfer log never has. **error** vs **ok -> error** is a per-FILE question: right after any OK File the subscription WAS green, so a red subscription with even one OK File in the window is a regression; that is finer than **From green to red**, which buckets by whole days. The server counts are **account-keyed**, because a partner connects to an account and the subscription name barely reaches the log — the join is 1:1 for UC4. **Logons** counts the "successfully authenticated" server-log line — one per successful SSH logon (an "Allowed user" whitelist admission that then fails authentication does not count). **Arrivals** is a file actually handed over ("will be submitted for processing"), **Problems** a logon the account whitelist **refused**. A **not seen** row with Logons but no Arrivals is a partner that gets in and never delivers; one with only Problems is a partner turned away at the door. Click a row for its most recent server-log lines.\n'

    printf 'KEYWORDS\tuc4, inbound, partner delivers, upload, receive, status, green, red, orange, regression, never worked, never seen, unused, logon, whitelist, refused, disallowed, no files, subscription health\n'
    printf 'SUMMARY\tok: %s  |  error: %s  |  ok -> error: %s  |  not seen: %s\n' \
        "$n_ok" "$n_err" "$n_okerr" "$n_notseen"
    printf 'FOOT\tGenerated on %s from %s file(s)\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${#files[@]}"
} > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"

echo "Data written to $OUT ($n_all UC4 subscription(s): $n_ok ok, $n_err error, $n_okerr ok-error, $n_notseen not-seen)." >&2
