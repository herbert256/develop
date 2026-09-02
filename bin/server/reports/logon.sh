#!/usr/bin/env bash
#
# logon.sh — the SSH LOGON story, both directions, two table tabs:
#
#   INCOMING — the logon funnel per login, from the TM "[Ssh Default]" lines:
#     [Ssh Default] Allowed user 'U' from address 'IP'          (Info)
#     [Ssh Default] User 'U', associated with account 'A',
#                   successfully authenticated over SSH ...     (Info)
#     [Ssh Default] Disallowed user "U" from address "IP" ,
#                   corresponding account "A"                   (Warning)
#     [Ssh Default] Unable to find account with username: U     (Warning)
#     [Ssh Default] Authentication failed because no certificate is
#                   found for user 'A@FE...' ... submitted key  (Info)
#     [Ssh Default] User FE... failed to login successfully N times
#                   by SSH Key authentication.                  (Info)
#     [Ssh Default] User 'U' is locked.                         (Info)
#   One row per logon user: Allowed (whitelist pass) -> Authenticated
#   (credentials pass), plus the failure modes Disallowed (whitelist
#   reject), No account (the username exists on no account — probing or
#   misconfiguration), Bad key (unknown certificate), Key failures (the
#   repeated-failure counter) and Locked (lockout). The quote style varies
#   per family (single vs double, or none), so the user token is read as
#   "whatever sits between the first quote character and its twin" where
#   quoted. Clicking any count drills to that CELL's 5 most recent log
#   lines (@data:drill-cell-<i>, like the Duration report).
#
#   OUTGOING — "Authentication failure connecting to remote host H:P as
#   user U: reason" (Error): this server failing to authenticate AT a
#   partner (expired password/key, TLS policy). One row per host/user
#   pair with the last-seen reason; click a row for its 10 most recent
#   log lines. (Merged in from the former failed-logins report.)
#
# Usage:
#   ./logon.sh    # reads input/*.csv (via the cache), writes data/logon.rpt
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib.sh"
source "$SCRIPT_DIR/../../logons.sh"   # ensure_logons(): the per-login logon summary
source "$SCRIPT_DIR/../../blacklist.sh"   # the platform-internal pseudo-logins stay out of the Incoming/door-knocker rows
mkdir -p "$REPORTS_DIR"
OUT="$REPORTS_DIR/logon.rpt"

# Entity cross-links (outbound table): known account / remote-host names from
# the transfer-side reports (ROW field 2 of each report's FIRST table). A user
# that matches a known account (exact, also @endpoint-stripped) or a host equal
# to a known host gets an @{alink=…} prefix on its cell; unresolved names stay
# plain text. Linking is skipped for a list whose transfer report is absent.
TDATA="$TRANSFER_REPORTS"
TACCT="$TDATA/account.rpt"
THOST="$TDATA/remote-host.rpt"
known_names() {   # $1 marker  $2 transfer .rpt — emits "marker<TAB>name" lines
    [ -f "$2" ] || return 0
    awk -F'\t' -v M="$1" '$1=="TABLE"{t++; if(t>1)exit} t==1&&$1=="ROW"{print M "\t" $2}' "$2"
}
# The configured logins (flow-manager base cache, written in build stage 1):
# the Door-knockers near-miss table checks each FE-namespace knocker name
# against this list — the striking rows are the ones that ARE configured in
# Flow Manager while the server says "not associated with any account".
LBASE="$CONFIG_BASE/_logins.tsv"
base_logins() {
    [ -f "$LBASE" ] || return 0
    awk -F'\t' '$1 != "" { print "KL\t" $1 }' "$LBASE"
}
LINK_AWK='
    function acctlink(t,   s) {
        if (t in kacct) return "@{alink=accounts/" t "}"
        s = t; sub(/@.*$/, "", s)
        if (s in kacct) return "@{alink=accounts/" s "}"
        return ""
    }
    function hostlink(t) { return (t in khost) ? "@{alink=hosts/" t "}" : "" }
'

shopt -s nullglob
files=("$INPUT_DIR"/*.csv)
shopt -u nullglob
if [ ${#files[@]} -eq 0 ]; then
    echo "No *.csv in $INPUT_DIR — building from the EMPTY caches (config-only estate)" >&2
fi
ensure_parsed
# the per-login logon summary (bin/logons.sh: LOGIN(upper) ⇥ first ⇥ last ⇥
# count ⇥ pattern) — joined onto the Incoming table as its last four columns.
# ensure_logons builds it here rather than trusting another step: the detail
# pages' consumer runs CONCURRENTLY in the build, so neither may rely on the
# other having written it (the write is atomic and cmp-guarded).
ensure_logons "$CACHE_DIR"
LOGONS_TSV="$CACHE_DIR/_logons.tsv"
skip_if_fresh "$OUT" "${BASH_SOURCE[0]}" "$TACCT" "$THOST" "$LBASE" "$LOGONS_TSV" "$BLACKLIST_FILE"
echo "Found ${#files[@]} file(s) in '$INPUT_DIR', processing..." >&2

# Emits TAB-separated:
#   R   <TAB> user <TAB> a t d n b k l <TAB> buckets <TAB> 7 drill fields <TAB> latest side (A T D N B K L) <TAB> its stamp
#   OUT <TAB> count <TAB> host <TAB> user <TAB> reason <TAB> buckets <TAB> first <TAB> last <TAB> loglines
#   KN  <TAB> name <TAB> count <TAB> nips <TAB> top-ip (n) <TAB> configured <TAB> first <TAB> last <TAB> buckets <TAB> loglines   (FE-namespace door knockers)
#   SC  <TAB> name <TAB> count <TAB> nips <TAB> ips (", "-joined, "-" = none) <TAB> first <TAB> last <TAB> buckets <TAB> loglines  (scanner door knockers)
#   DKT <TAB> total <TAB> nnames
#   TOT <TAB> a t d n b k l totals <TAB> outbound_total
# The drill fields are \x1f-joined "date time  Level Component  message"
# entries; empty middle fields use the "-" sentinel (the bash loop reads the
# TAB-separated line with `read`, and a TAB is IFS whitespace — empty fields
# would collapse and shift the columns, the CLAUDE.md gotcha).
agg=$(awk -F'\t' -v BLF="$BLACKLIST_FILE" "$LOGLINES_AWK$LINK_AWK$BLACKLIST_AWK"'
    BEGIN { bl_load(BLF) }
    # the quoted token right after the matched prefix: the quote character
    # itself varies (Allowed logs single quotes, Disallowed double)
    function qtok(rest,   q, p) {
        q = substr(rest, 1, 1)
        if (q != "\x27" && q != "\"") return ""
        p = index(substr(rest, 2), q)
        if (p <= 0) return ""
        return substr(rest, 2, p - 1)
    }
    # sortjoin(s): a SUBSEP-joined set as a ", "-separated SORTED list —
    # sorted so the output never depends on awk hash order (the scanner IPs
    # column, 2026-08-31, user request)
    function sortjoin(s,   n9, A9, i9, j9, v9, o9) {
        n9 = split(s, A9, SUBSEP)
        for (i9 = 2; i9 <= n9; i9++) { v9 = A9[i9]; j9 = i9 - 1; while (j9 >= 1 && A9[j9] > v9) { A9[j9+1] = A9[j9]; j9-- } A9[j9+1] = v9 }
        o9 = ""
        for (i9 = 1; i9 <= n9; i9++) o9 = o9 (o9 == "" ? "" : ", ") A9[i9]
        return o9
    }
    function last5(p,   s, a4, n, i, out) {
        s = lastlines(p); n = split(s, a4, _US); out = ""
        for (i = 1; i <= n && i <= 5; i++) out = out (out == "" ? "" : _US) a4[i]
        return out
    }
    $1 == "KA" { kacct[$2] = 1; next }                       # known-entity lists (first input)
    $1 == "KH" { khost[$2] = 1; next }
    $1 == "KL" { klog[$2] = 1; next }                        # configured logins (base cache)
    {
        m = $5
        # DOOR KNOCKERS (2026-08): the unconsumed Info family
        #   [Ssh Default] User "u" is not associated with any account. Remote address: ip
        # — the [Ssh Default] prefix is ABSENT on a minority of the lines
        # (other protocol stacks log the same shape), so the family is matched
        # on its body, before the [Ssh Default] gate below.
        if (m ~ /User "[^"]*" is not associated with any account\. Remote address: /) {
            # keep the Allowed-coverage window intact: a prefixed line is an
            # [Ssh Default] line and used to feed fss before this block existed
            if (index(m, "[Ssh Default]") > 0 && $1 ~ /^[0-9][0-9][0-9][0-9]-/ && (fss == "" || $1 < fss)) fss = $1
            u2 = ""
            if (match(m, /User "[^"]*"/)) u2 = substr(m, RSTART + 6, RLENGTH - 7)
            if (u2 == "") next
            # the platform logs *nobody (and kin) as its OWN placeholder for
            # an unusable client name — a blacklisted pseudo-login is not a
            # door knocker row (the probing evidence stays in the raw log)
            if (bl_blank("login", u2)) next
            ip2 = m; sub(/^.*Remote address: */, "", ip2); sub(/[. ]*$/, "", ip2); sub(/^\//, "", ip2)
            dkc[u2]++; dkT++
            if (!((u2 SUBSEP ip2) in dkip)) { dkip[u2 SUBSEP ip2] = 0; dkips[u2]++ }
            dkip[u2 SUBSEP ip2]++
            d2 = substr($1, 1, 10)
            if (d2 ~ /^[0-9][0-9][0-9][0-9]-/) { dkd[u2 SUBSEP d2]++
                if (dkf[u2] == "" || d2 < dkf[u2]) dkf[u2] = d2
                if (d2 > dkl[u2]) dkl[u2] = d2 }
            addline("DK" SUBSEP u2, $1 " " $2, lvlname($3) " " compname($4) "  " substr(m, 1, 200))
            next
        }
        # OUTGOING: us failing to authenticate at a partner
        if (m ~ /^Authentication failure connecting to remote host /) {
            r = m; sub(/^Authentication failure connecting to remote host /, "", r)   # "H:P as user U: reason"
            if (!match(r, /^[^:]+/)) next
            host = substr(r, RSTART, RLENGTH)
            if (!match(r, / as user [^:]+:/)) next
            ouser = substr(r, RSTART + 9, RLENGTH - 10)
            reason = substr(r, RSTART + RLENGTH); sub(/^ +/, "", reason)
            k = host SUBSEP ouser
            oc[k]++; ototal++
            # reason class: Password / Publickey / Certificate (the FTPS
            # 530 "Need certificate authentication" and 534 policy
            # refusals — the partner demands or rejects our TLS client
            # certificate) / Other (the residue, e.g. "530 User cannot
            # log in")
            cls = (reason ~ /^Password /) ? "p" : (reason ~ /^Publickey /) ? "k" : \
                  (reason ~ /^530 Need certificate/ || reason ~ /^534 /) ? "c" : "o"
            if (cls == "p") { opw[k]++; opwT++ } else if (cls == "k") { oky[k]++; okyT++ } \
            else if (cls == "c") { ocr[k]++; ocrT++ } else { oot[k]++; ootT++ }
            addline("O" SUBSEP k, $1 " " $2, lvlname($3) " " compname($4) "  " substr(m, 1, 200))
            # last-seen reason by TIMESTAMP, not cache order (the exports are
            # newest-first within a file, so cache row order is NOT chronological)
            osk = $1 " " $2
            if (!(k in orsk) || osk >= orsk[k]) { orsk[k] = osk; orsn[k] = substr(reason, 1, 80) }
            d = $1
            if (d ~ /^[0-9][0-9][0-9][0-9]-/) { ocd[k SUBSEP d]++; ocdc[k SUBSEP d SUBSEP cls]++
                if (!(k in ofst) || d < ofst[k]) ofst[k] = d
                if (!(k in olst) || d > olst[k]) olst[k] = d }
            next
        }
        # INCOMING: the [Ssh Default] logon-screening funnel
        if (index(m, "[Ssh Default]") == 0) next
        if ($1 ~ /^[0-9][0-9][0-9][0-9]-/ && (fss == "" || $1 < fss)) fss = $1   # first ssh-line date (the Allowed-coverage check)
        u = ""
        if (match(m, /\[Ssh Default\] Allowed user /))         { side = "A"; u = qtok(substr(m, RSTART + RLENGTH)); if ($1 ~ /^[0-9][0-9][0-9][0-9]-/ && (fad == "" || $1 < fad)) fad = $1 }
        else if (m ~ /successfully authenticated over SSH/ && match(m, /login name /)) {
            side = "T"; u = qtok(substr(m, RSTART + RLENGTH)) }
        else if (match(m, /\[Ssh Default\] Disallowed user /)) { side = "D"; u = qtok(substr(m, RSTART + RLENGTH)) }
        else if (match(m, /Unable to find account with username: [^ ]+/)) {
            # unquoted username token; strip a trailing sentence separator
            side = "N"; u = substr(m, RSTART + 38, RLENGTH - 38); sub(/[.,;]$/, "", u) }
        else if (match(m, /no certificate is found for user /)) {
            # "… for user \x27ACCOUNT@FE0000nn\x27 …" — key the row on the LOGIN part
            side = "B"; u = qtok(substr(m, RSTART + RLENGTH)); sub(/^.*@/, "", u) }
        else if (match(m, /\[Ssh Default\] User [A-Za-z0-9_.-]+ failed to login successfully/)) {
            # unquoted user token: "User FE0000nn failed to login successfully N times …"
            side = "K"; u = substr(m, RSTART + 19); sub(/ failed to login.*$/, "", u) }
        else if (match(m, /\[Ssh Default\] User /) && m ~ /is locked/) {
            side = "L"; u = qtok(substr(m, RSTART + RLENGTH))
            # the second locked family carries the name later in the line:
            # "[Ssh Default] User login is locked. Username: \"U\""
            if (u == "" && match(m, /Username: /)) u = qtok(substr(m, RSTART + RLENGTH)) }
        else next
        if (u == "") next
        # platform-internal pseudo-logins (blacklist, raw token) get no row
        if (bl_blank("login", u)) next
        users[u] = 1
        cnt[side SUBSEP u]++; tot[side]++
        d = $1
        if (d ~ /^[0-9][0-9][0-9][0-9]-/) { bk[u SUBSEP d SUBSEP side]++; days[u SUBSEP d] = 1
            # the newest stamp per side — the row tint (2026-09-02, user
            # request) is the LATEST screening outcome of the login, compared by
            # TIMESTAMP, never by cache order (the exports are newest-first
            # within a file)
            k2 = side SUBSEP u; ts = $1 " " $2
            if (!(k2 in lts) || ts > lts[k2]) lts[k2] = ts }
        addline(side SUBSEP u, $1 " " $2, lvlname($3) " " compname($4) "  " substr(m, 1, 200))
    }
    END {
        # column order — matches the HEAD/RECALC/drill-cell numbering below
        ns = split("A T D N B K L", S, " ")
        # per-user per-day buckets (entry order is hash order — report.js
        # consumes @data:buckets as a set, the one accepted variance)
        for (k in days) { split(k, a, SUBSEP)
            s2 = ""
            for (i = 1; i <= ns; i++) s2 = s2 ":" (bk[k SUBSEP S[i]]+0)
            b[a[1]] = b[a[1]] (b[a[1]] == "" ? "" : ",") a[2] s2 }
        for (u in users) {
            line = "R\t" u
            for (i = 1; i <= ns; i++) line = line "\t" (cnt[S[i] SUBSEP u]+0)
            line = line "\t" (b[u] == "" ? "-" : b[u])
            for (i = 1; i <= ns; i++) { dr = last5(S[i] SUBSEP u); line = line "\t" (dr == "" ? "-" : dr) }
            # the LATEST screening side + its stamp: the side whose newest
            # line is newest of all; an exact tie goes to Authenticated (the
            # Allowed line of the same logon precedes it by milliseconds).
            # The anonymous Auth-failed family needs no seat here: such a
            # line is attributed to an Allowed line no authentication
            # consumed, so that Allowed is already the newest event and the
            # verdict is red either way.
            lsd = ""; lst = ""
            for (i = 1; i <= ns; i++) { k2 = S[i] SUBSEP u
                if (!(k2 in lts)) continue
                if (lst == "" || lts[k2] > lst || (lts[k2] == lst && S[i] == "T")) { lst = lts[k2]; lsd = S[i] } }
            print line "\t" (lsd == "" ? "-" : lsd) "\t" (lst == "" ? "-" : lst)
        }
        # every CONFIGURED login the funnel never saw still gets a row
        # (2026-08, the seenrows convention): zero counts, no buckets, no
        # drills — the logon-summary join may still fill its four columns
        # (a PESIT-side authenticator never enters the SSH funnel). Hash
        # order is fine here: the shell sorts the whole R stream.
        for (u in klog) {
            if (u in users) continue
            line = "R\t" u
            for (i = 1; i <= ns; i++) line = line "\t0"
            line = line "\t-"
            for (i = 1; i <= ns; i++) line = line "\t-"
            print line "\t-\t-"
        }
        for (x in ocd) { split(x, a2, SUBSEP); kk = a2[1] SUBSEP a2[2]
            obk[kk] = obk[kk] (obk[kk] == "" ? "" : ",") a2[3] ":" ocd[x] ":" (ocdc[x SUBSEP "p"]+0) ":" (ocdc[x SUBSEP "k"]+0) ":" (ocdc[x SUBSEP "c"]+0) ":" (ocdc[x SUBSEP "o"]+0) }
        for (k in oc) { split(k, a, SUBSEP)
            printf "OUT\t%d\t%s%s\t%s%s\t%d\t%d\t%d\t%d\t%s\t%s\t%s\t%s\t%s\n", oc[k], hostlink(a[1]), a[1], acctlink(a[2]), a[2], \
                   opw[k]+0, oky[k]+0, ocr[k]+0, oot[k]+0, \
                   orsn[k], (obk[k] == "" ? "-" : obk[k]), ofst[k], olst[k], lastlines("O" SUBSEP k)
        }
        # ---- door knockers ----
        for (x in dkd) { split(x, a5, SUBSEP); dkb[a5[1]] = dkb[a5[1]] (dkb[a5[1]] == "" ? "" : ",") a5[2] ":" dkd[x] }
        # top source IP per FE-namespace name (ties break on the address)
        for (x in dkip) { split(x, a5, SUBSEP)
            if (a5[1] ~ /^FE[0-9]+$/ && (dkip[x] > tipn[a5[1]] || (dkip[x] == tipn[a5[1]] && a5[2] < tip[a5[1]]))) { tipn[a5[1]] = dkip[x]; tip[a5[1]] = a5[2] } }
        # the scanner names distinct source ADDRESSES, ", "-joined per name
        # (the IPs column — 2026-08-31, user request); collected here in hash
        # order, sortjoin() below makes the list deterministic
        for (x in dkip) { split(x, a5, SUBSEP)
            if (a5[1] !~ /^FE[0-9]+$/) scip[a5[1]] = scip[a5[1]] (scip[a5[1]] == "" ? "" : SUBSEP) a5[2] }
        nkn = 0
        for (u in dkc) { nkn++
            if (u ~ /^FE[0-9]+$/)
                printf "KN\t%s\t%d\t%d\t%s (%d)\t%s\t%s\t%s\t%s\t%s\n", u, dkc[u], dkips[u]+0, tip[u], tipn[u]+0, \
                    ((u in klog) ? "yes" : "no"), dkf[u], dkl[u], (dkb[u] == "" ? "-" : dkb[u]), lastlines("DK" SUBSEP u)
            else
                printf "SC\t%s\t%d\t%d\t%s\t%s\t%s\t%s\t%s\n", u, dkc[u], dkips[u]+0, (scip[u] == "" ? "-" : sortjoin(scip[u])), dkf[u], dkl[u], \
                    (dkb[u] == "" ? "-" : dkb[u]), lastlines("DK" SUBSEP u)
        }
        printf "DKT\t%d\t%d\n", dkT+0, nkn+0
        line = "TOT"
        for (i = 1; i <= ns; i++) line = line "\t" (tot[S[i]]+0)
        print line "\t" (ototal+0) "\t" (opwT+0) "\t" (okyT+0) "\t" (ocrT+0) "\t" (ootT+0)
        # Allowed-line coverage: its first date vs the window start — the
        # "Allowed user" line only exists from a mid-window logging change
        # (2026-07-06 in the acceptance window), so the funnel needs a warning
        print "COV\t" (fad == "" ? "-" : fad) "\t" (fss == "" ? "-" : fss)
    }
' <(known_names KA "$TACCT"; known_names KH "$THOST"; base_logins) "$PARSED")

if [ -z "$agg" ]; then
    echo "No usable records found." >&2
    rm -f "$OUT"   # no data for this ENV — page not published (an env-split legitimate state)
    exit 0
fi

IFS=$'\t' read -r _ atot ttot dtot ntot btot ktot ltot ototal opwt okyt ocrt oott <<< "$(printf '%s\n' "$agg" | grep $'^TOT\t')"
IFS=$'\t' read -r _ cov_fad cov_fss <<< "$(printf '%s\n' "$agg" | grep $'^COV\t')"

# Both row writers print STRAIGHT to stdout inside the page block below — a
# `rows+=$(printf …)` per row forks a subshell per row for nothing. Their row
# counters (nrows / nnames / n_pairs) reach the TOTAL and SUMMARY lines because
# that block is a brace group, not a subshell. The "-" sentinels stay: a TAB is
# IFS whitespace, so an empty middle field would collapse and shift the columns
# — the tests that swap them back are shell builtins, not forks.
nrows=0
nnames=0
# most rejections first, then no-account, bad keys, lockouts, key failures
lgtot=0; aftot=0
rows() {
    while IFS=$'\t' read -r _ user a t d n b k l bkt d1 d2 d3 d4 d5 d6 d7 lside lstamp af9 lgf lgl lgn lgp; do
        [ -n "$user" ] || continue
        [ "$bkt" = "-" ] && bkt=""
        [ "$d1" = "-" ] && d1=""; [ "$d2" = "-" ] && d2=""; [ "$d3" = "-" ] && d3=""; [ "$d4" = "-" ] && d4=""
        [ "$d5" = "-" ] && d5=""; [ "$d6" = "-" ] && d6=""; [ "$d7" = "-" ] && d7=""
        [ "$af9" = "-" ] && af9=""
        # SEEN = any funnel activity at all, the anonymous Auth-failed count
        # included (before the 0-blanking below); a zero-everything row is a
        # configured login the funnel never saw
        local sn9=0; [ $((a + t + d + n + b + k + l + ${af9:-0})) -gt 0 ] && sn9=1
        # THE ROW TINT (2026-09-02, user request) — @data:res on a restint
        # table: ORANGE = never seen (every funnel column empty); GREEN = the
        # login's LATEST screening line is a successful authentication; RED =
        # its latest line is anything else (a refusal, a failure, or an
        # Allowed that no authentication followed). A full-period verdict,
        # like the logon-summary columns: a date range does not move it. The
        # problem cells keep their own red/amber (the restint CSS).
        local res9=red
        if [ "$sn9" = 0 ]; then res9=orange; elif [ "$lside" = "T" ]; then res9=green; fi
        [ "$k" = "0" ] && k=""; [ "$l" = "0" ] && l=""   # blank the 0s at source too (render_rpt z-blanks warn zeros as well since 2026-08 — this keeps the raw .rpt readable)
        [ "${n:-0}" -gt 0 ] && nnames=$((nnames + 1))
        nrows=$((nrows + 1))
        [ "$lgn" = "-" ] && lgn=""
        [ -n "$lgn" ] && lgtot=$((lgtot + lgn))
        [ -n "$af9" ] && aftot=$((aftot + af9))
        # column order Allowed, Disallowed, Authenticated (the 2026-07 swap): the
        # cells, their drill payloads and the RECALC tokens below all follow it.
        # Auth failed sits AFTER Locked: drill-cell-<i> binds cells 1-7
        # positionally, so the funnel block must not shift.
        printf 'ROW\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t@data:seen=%s\t@data:res=%s\t@data:buckets=%s\t@data:drill-cell-1=%s\t@data:drill-cell-2=%s\t@data:drill-cell-3=%s\t@data:drill-cell-4=%s\t@data:drill-cell-5=%s\t@data:drill-cell-6=%s\t@data:drill-cell-7=%s\n' \
            "$user" "$a" "$d" "$t" "$n" "$b" "$k" "$l" "$af9" "$lgf" "$lgl" "$lgn" "$lgp" "$sn9" "$res9" "$bkt" "$d1" "$d3" "$d2" "$d4" "$d5" "$d6" "$d7"
    done <<< "$(printf '%s\n' "$agg" | grep $'^R\t' | LC_ALL=C sort -t"$(printf '\t')" -k5,5nr -k6,6nr -k7,7nr -k9,9nr -k8,8nr -k3,3nr -k2,2 \
        | awk -F'\t' -v OFS='\t' -v LG="$LOGONS_TSV" '
            # the per-login logon summary join (details.sh _logons.tsv): four
            # fields appended to every R row — stamps at display precision, a
            # login with no successful authentication reads em dash / 0-blank /
            # Never (matching its detail page)
            BEGIN { while ((getline l9 < LG) > 0) { n9 = split(l9, A9, "\t")
                        if (n9 >= 5) { F9[A9[1]] = substr(A9[2], 1, 19); L9[A9[1]] = substr(A9[3], 1, 19); N9[A9[1]] = A9[4]; P9[A9[1]] = A9[5] }
                        if (n9 >= 13) AF9[A9[1]] = A9[13] }
                    close(LG) }
            # "-" sentinel, not "": a TAB is IFS whitespace, an empty middle
            # field would collapse in the read and shift the columns. A
            # funnel-only sidecar row (count 0) renders like an absent one —
            # except its anonymous-failure count (sidecar field 13), which is
            # exactly the FE000260 story this join exists to show.
            { u9 = toupper($2)
              af9 = ((u9 in AF9) && AF9[u9] + 0 > 0) ? AF9[u9] : "-"
              if ((u9 in N9) && N9[u9] + 0 > 0) print $0, af9, F9[u9], L9[u9], N9[u9], P9[u9]
              else          print $0, af9, "\342\200\224", "\342\200\224", "-", "Never" }')"
}

# ---- door knockers (2026-08): the two new tables' row writers. Near-miss ----
# rows red-tint whole-row via restint/@data:res; the scanner table is capped
# at 25 rows (awk NR guard, never head) and totals the SHOWN rows only, per
# the top-N convention. Both tables are emitted UNCONDITIONALLY (placeholder
# when the family is absent): logon is a merged-component of Logons, whose
# tab bar enumerates tables, so the TABLE count must not vary per env.
IFS=$'\t' read -r _ dk_tot dk_names <<< "$(printf '%s\n' "$agg" | grep $'^DKT\t' || printf 'DKT\t0\t0\n')"
n_near=0; near_att=0
near_rows() {
    while IFS=$'\t' read -r _ name count nips topip conf fst lst bkt lines; do
        [ -n "$name" ] || continue
        [ "$bkt" = "-" ] && bkt=""
        n_near=$((n_near + 1)); near_att=$((near_att + count))
        if [ "$conf" = "yes" ]; then confcell="yes — no account attached"; else confcell="no"; fi
        printf 'ROW\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t@data:res=red\t@data:buckets=%s\t@data:loglines=%s\n' \
            "$name" "$count" "$nips" "$topip" "$confcell" "$fst" "$lst" "$bkt" "$lines"
    done <<< "$(printf '%s\n' "$agg" | grep $'^KN\t' | LC_ALL=C sort -t"$(printf '\t')" -k3,3nr -k2,2)"
}
n_scan=0; scan_att=0
scan_rows() {
    while IFS=$'\t' read -r _ name count nips ips fst lst bkt lines; do
        [ -n "$name" ] || continue
        [ "$bkt" = "-" ] && bkt=""
        [ "$ips" = "-" ] && ips=""
        n_scan=$((n_scan + 1)); scan_att=$((scan_att + count))
        printf 'ROW\t%s\t%s\t%s\t%s\t%s\t%s\t@data:buckets=%s\t@data:loglines=%s\n' \
            "$name" "$count" "$nips" "$ips" "$fst" "$lst" "$bkt" "$lines"
    done <<< "$(printf '%s\n' "$agg" | grep $'^SC\t' | LC_ALL=C sort -t"$(printf '\t')" -k3,3nr -k2,2 | awk 'NR <= 25')"
}

n_pairs=0
out_rows() {
    while IFS=$'\t' read -r _ count host ouser pw ky cr ot reason bkt fst lst lines; do
        [ -n "$host" ] || continue
        [ "$bkt" = "-" ] && bkt=""
        n_pairs=$((n_pairs + 1))
        printf 'ROW\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t@data:buckets=%s\t@data:loglines=%s\n' \
            "$host" "$ouser" "$count" "$pw" "$ky" "$cr" "$ot" "$reason" "$fst" "$lst" "$bkt" "$lines"
    done <<< "$(printf '%s\n' "$agg" | grep $'^OUT\t' | LC_ALL=C sort -t"$(printf '\t')" -k2,2nr)"
}

{
    printf 'TITLE\tLogon\n'
    printf 'DESC\tThe SSH logon story, both directions: the incoming screening funnel per login, and our outbound authentication failures at partners.\n'
    printf 'INTRO\t**Incoming**: every SSH logon is screened by the server ("[Ssh Default] ..." TM lines), the columns following the logon funnel — **Allowed** = the source address passed the account whitelist; **Disallowed** = the address was rejected by the AllowIP whitelist; **Authenticated** = successful authentications (logged for every account, whitelisted or not, so it can exceed Allowed); **No account** = the username exists on no account (probing or misconfiguration); **Bad key** = a submitted key matching no certificate; **Key failures** = the repeated-key-failure counter that precedes a lockout; **Locked** = attempts blocked because the user is locked. **Auth failed** = the platform'\''s ANONYMOUS failure line ("Authentication failed using local.", no username, no address — a client that passed the whitelist and then failed without presenting an evaluable credential), attributed by TIMING: it counts for the login whose Allowed line it follows within one second, and a window holding two different logins'\'' Allowed lines counts for neither. **Every configured login is listed**, and **the row colour is the login'\''s LATEST screening outcome**: **green** when its newest funnel line is a successful authentication, **red** when the newest line is anything else — a refusal, a failure, or an Allowed that no authentication followed — and **orange** when the login is configured but never appeared in the SSH funnel (every funnel column empty; its logon-summary columns can still be filled by a login that authenticates over another protocol). The colour is a full-period verdict — a selected date range re-aggregates the counts but does not move it — and the problem cells keep their own red or amber inside a green row. The last four columns are the login'\''s **logon summary** (the detail pages'\'' Logons table): first and last successful authentication, the raw count and the typical spacing — counted over ANY protocol, so Logons can exceed the SSH-only Authenticated; a login that never authenticated reads **Never**, and these four keep their full-period values when a date range is selected. **Outgoing**: this server failing to authenticate AT a partner (expired passwords/keys, TLS policy). **Click a count** (Incoming) or **a row** (Outgoing) for the most recent log lines.\n'
    if [ "$cov_fss" != "-" ] && [ "$cov_fad" = "-" ]; then
        # the FULLY-blind case — SSH screening lines exist but not one Allowed
        # line in the whole window: the maximum undercount keeps its warning.
        # (The partial case — Allowed only appearing mid-window after the
        # server logging change — no longer warns, 2026-08: the banner said
        # the same thing on every visit while the window start ages out.)
        printf 'WARN\tNo "Allowed user" screening line appears anywhere in this log window (which starts %s). The Allowed column is blind for the WHOLE period while Authenticated covers it, so funnel comparisons undercount the screening stage throughout.\n' "$cov_fss"
    fi
    # seenrows keeps every row on the page under a date range (never hidden);
    # restint paints each row its @data:res verdict (2026-09-02) — the CSS
    # lets it beat the seenrows green/red, so the colour stays full-period
    printf 'TABLE\tIncoming\twide\tseenrows\trestint\tdrill=log line\n'
    printf 'HEAD\tLogin\tAllowed\tDisallowed\tAuthenticated\tNo account\tBad key\tKey failures\tLocked\tAuth failed\tFirst logon\tLast logon\tLogons\tPattern\n'
    printf 'KIND\tlogin\tnumprocessed\tnumfailed\tnumprocessed\tnumfailed\tnumfailed\tnumwarn\tnumwarn\tnumfailed\ttext\ttext\tnum\ttext\n'
    printf 'RECALC\t-\ts0\ts2\ts1\ts3\ts4\ts5\ts6\tk\tk\tk\tk\tk\n'
    rows
    [ "$aftot" -gt 0 ] || aftot=""
    printf 'TOTAL\tTotal (%s logins)\t@{class=num processed}%s\t@{class=num failed}%s\t@{class=num processed}%s\t@{class=num failed}%s\t@{class=num failed}%s\t@{class=num warn}%s\t@{class=num warn}%s\t@{class=num failed}%s\t\t\t@{class=num}%s\t\n' \
        "$nrows" "$atot" "$dtot" "$ttot" "$ntot" "$btot" "$ktot" "$ltot" "$aftot" "$lgtot"

    printf 'TABLE\tOutgoing\twide\tdrill=log line\n'
    printf 'HEAD\tRemote host\tUser\tFailures\tPassword\tKey\tCertificate\tOther\tReason (last seen)\tFirst\tLast\n'
    printf 'KIND\tmono\tmono\tnumfailed\tnumfailed\tnumfailed\tnumfailed\tnumfailed\ttext\ttext\ttext\n'
    printf 'RECALC\t-\t-\ts0\ts1\ts2\ts3\ts4\t-\t-\t-\n'
    out_rows
    printf 'TOTAL\t@{colspan=2}Total (%s pair(s))\t@{class=num failed}%s\t@{class=num failed}%s\t@{class=num failed}%s\t@{class=num failed}%s\t@{class=num failed}%s\t\t\t\n' "$n_pairs" "$ototal" "$opwt" "$okyt" "$ocrt" "$oott"

    printf 'NOTE\tCounts are LOG LINES (one per screened logon / failed attempt), not transfers. Incoming logins link to their detail page when one exists; an Outgoing host or user known from the transfer logs links too. A persistent Outgoing failure usually means an expired password or key for that partner. The Failures total splits into **Password** (wrong/expired password), **Key** (publickey refused), **Certificate** (the FTPS refusals "530 Need certificate authentication" and "534 Policy requires valid SSL Client certificate" — the partner demands or rejects our TLS client certificate) and **Other** (the residue, e.g. "530 User cannot log in"); a 0 renders empty.\n'

    # ---- door knockers: near misses first (the actionable table), then ----
    # the scanner top 25 (2026-08)
    if [ "${dk_tot:-0}" -gt 0 ]; then
        printf 'TABLE\tDoor knockers — near misses\twide\trestint\tnoagg=2\tdrill=log line\n'
    else
        printf 'TABLE\tDoor knockers — near misses\tnofilter\tnosort\n'
    fi
    printf 'HEAD\tLogin\tAttempts\tSource IPs\tTop source\tConfigured login\tFirst\tLast\n'
    printf 'KIND\tlogin\tnumfailed\tnum\tmono\ttext\ttext\ttext\n'
    printf 'RECALC\t-\ts0\t-\t-\t-\t-\t-\n'
    if [ "${dk_tot:-0}" -gt 0 ]; then
        near_rows
    else
        printf 'ROW\t@{colspan=7}No door-knocker lines in this data window.\n'
    fi
    printf 'TOTAL\tTotal (%s name(s))\t@{class=num failed}%s\t\t\t\t\t\n' "$n_near" "$near_att"
    printf 'NOTE\tThe unconsumed screening family (User "u" is not associated with any account. Remote address: ip), RESTRICTED to names matching the configured **FE-number namespace** (`FE` + digits) — someone knocking with names that look exactly like this platform'\''s real logins, from a HANDFUL of addresses (compare the scanner table below). **Configured login = yes** is the alarming case: the name IS defined in Flow Manager, yet the server maps it to no account — either a provisioning gap (login configured, account association missing) or a partner using a decommissioned name. Rows are red-tinted; Source IPs stays full-period under a date filter. Click a row for its 10 most recent lines.\n'

    if [ "${dk_tot:-0}" -gt 0 ]; then
        printf 'TABLE\tDoor knockers — scanner names\twide\tnoagg=2,3\tdrill=log line\n'
    else
        printf 'TABLE\tDoor knockers — scanner names\tnofilter\tnosort\n'
    fi
    printf 'HEAD\tUsername\tAttempts\tSource IPs\tIPs\tFirst\tLast\n'
    printf 'KIND\tmono\tnumfailed\tnum\ttext\ttext\ttext\n'
    printf 'RECALC\t-\ts0\t-\t-\t-\t-\n'
    if [ "${dk_tot:-0}" -gt 0 ]; then
        scan_rows
    else
        printf 'ROW\t@{colspan=6}No door-knocker lines in this data window.\n'
    fi
    printf 'TOTAL\tTotal (top %s of %s name(s))\t@{class=num failed}%s\t\t\t\t\n' "$n_scan" "${dk_names:-0}" "$scan_att"
    printf 'NOTE\tThe same "not associated with any account" family for every OTHER name — the internet background noise (root, admin, user, test, …) probing over many source addresses. The **IPs** column lists that name'\''s distinct source addresses (full period, like the Source IPs count). The 25 most-tried names are shown of **%s** distinct name(s) and **%s** attempt(s) in all; the total row sums the SHOWN rows only. These names never get past the account lookup, so they appear in no other logon column.\n' "${dk_names:-0}" "${dk_tot:-0}"

    printf 'SUMMARY\tLogins: %s  |  Allowed: %s  |  Authenticated: %s  |  Disallowed: %s  |  No account: %s names (%s attempts)  |  Bad key: %s  |  Key failures: %s  |  Locked: %s  |  Outbound auth failures: %s (%s pairs)  |  Door knockers: %s attempts (%s names, %s near-miss)\n' \
        "$nrows" "$atot" "$ttot" "$dtot" "$nnames" "$ntot" "$btot" "$ktot" "$ltot" "$ototal" "$n_pairs" "${dk_tot:-0}" "${dk_names:-0}" "$n_near"
    printf 'FOOT\tGenerated on %s from %s file(s)\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${#files[@]}"
} > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"

echo "Data written to $OUT ($nrows login(s): $atot allowed, $ttot authenticated, $dtot disallowed, $ntot no-account, $btot bad-key, $ktot key-failure, $ltot locked; $ototal outbound failure(s))." >&2
