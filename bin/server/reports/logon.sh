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
#     [Ssh Default] User 'U' locked due to too many failed login
#                   attempts.                                   (Info)
#   plus two SESSION-keyed families (2026-09-06, user request — the FE000508
#   finding): a RE-SCREEN is an Allowed line on a session (cache col 6) LATER
#   than that session's last authentication — a persistent connection re-keys
#   about hourly and the server logs "Start login process" + "Allowed user"
#   again with no new authentication; counted apart, NOT as Allowed, never
#   moving the row tint. (An Allowed that an authentication follows is a real
#   screening, whatever the session logged before.) SESSION ERRORS are the Error/Warning [Ssh Default] lines of no
#   counted family ("Stream read/write error. Exception message is: CMS
#   parsing has failed" …), attributed to the login of their session — NOT
#   the re-key bookkeeping W line "No session cycleId for file … SENT will
#   not get reported!" (2026-09-29 audit: 181 of 199 sample session errors;
#   a transfer-log matter, the RE-KEYED LEGS of bin/session-sites.sh, never
#   a logon problem; bin/logons.sh skips the same shape). Both need the
#   whole cache read first (a session's LAST authentication may come later
#   in the cache than its Allowed line), so every Allowed line is booked in
#   END.
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
# (known_names: bin/server/lib.sh since 2026-09-30)
# The configured logins (flow-manager base cache, written in build stage 1):
# the one key per configured login (klu) and the door-knocker test (a
# configured login is never a knocker). (The near-miss table that listed the
# FE-namespace knockers against this list went 2026-09-30, user request.)
LBASE="$CONFIG_BASE/_logins.tsv"
base_logins() {
    [ -f "$LBASE" ] || return 0
    awk -F'\t' '$1 != "" { print "KL\t" $1 }' "$LBASE"
}
LINK_AWK="$SRV_ACCTLINK_AWK$SRV_HOSTLINK_AWK"   # bin/server/lib.sh (2026-09-30)

shopt -s nullglob
files=("$INPUT_DIR"/*.csv)
shopt -u nullglob
if [ ${#files[@]} -eq 0 ]; then
    echo "No *.csv in $INPUT_DIR — building from the EMPTY caches (config-only estate)" >&2
fi
# the per-login logon summary (bin/logons.sh: LOGIN(upper) ⇥ first ⇥ last ⇥
# count ⇥ pattern) — joined onto the Incoming table as its four logon-summary
# columns (First logon · Last logon · Logons · Pattern, before the Re-screens
# column that closes the table since 2026-09-08).
# ensure_logons builds it here rather than trusting another step: the detail
# pages' consumer runs CONCURRENTLY in the build, so neither may rely on the
# other having written it (the write is atomic).
ensure_logons "$CACHE_DIR"
LOGONS_TSV="$CACHE_DIR/_logons.tsv"
echo "Found ${#files[@]} file(s) in '$INPUT_DIR', processing..." >&2

# Emits TAB-separated:
#   R   <TAB> user <TAB> a t d n b k l r x <TAB> buckets <TAB> 9 drill fields <TAB> latest side (A T D N B K L) <TAB> its stamp
#   OUT <TAB> count <TAB> host <TAB> user <TAB> pw key cert other <TAB> reason <TAB> buckets <TAB> first <TAB> last <TAB> sessions (\037) <TAB> loglines
#   SC  <TAB> name <TAB> count <TAB> nips <TAB> ips (", "-joined, "-" = none) <TAB> first <TAB> last <TAB> buckets <TAB> loglines  (scanner door knockers)
#   DKT <TAB> total <TAB> nnames
#   TOT <TAB> a t d n b k l totals <TAB> outbound_total
# The drill fields are \x1f-joined "date time  Level Component  message"
# entries; empty middle fields use the "-" sentinel (the bash loop reads the
# TAB-separated line with `read`, and a TAB is IFS whitespace — empty fields
# would collapse and shift the columns, the CLAUDE.md gotcha).
# qtok() and the family classifier ssh_family() come from bin/ssh-family.awk,
# the ONE copy bin/logons.sh (the logon summary) shares (2026-09-30)
agg=$(awk -F'\t' -v BLF="$BLACKLIST_FILE" "$LOGLINES_AWK$LINK_AWK$BLACKLIST_AWK$(cat "$ROOT/bin/ssh-family.awk")"'
    BEGIN { bl_load(BLF) }
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
    # one funnel event, booked: the counts, the per-day bucket, the
    # newest stamp per family (the row tint — compared by TIMESTAMP, never by
    # cache order, so no reader depends on how the cache is sorted) and the drill
    function book(side9, u9, d9, ts9, txt9,   k9) {
        cnt[side9 SUBSEP u9]++; tot[side9]++
        if (d9 ~ /^[0-9][0-9][0-9][0-9]-/) { bk[u9 SUBSEP d9 SUBSEP side9]++; days[u9 SUBSEP d9] = 1
            k9 = side9 SUBSEP u9
            if (!(k9 in lts) || ts9 > lts[k9]) lts[k9] = ts9 }
        addline(side9 SUBSEP u9, ts9, txt9)
    }
    $1 == "KA" { kacct[$2] = 1; next }                       # known-entity lists (first input)
    $1 == "KH" { khost[$2] = 1; next }
    $1 == "KL" { klog[$2] = 1; klu[toupper($2)] = $2; next }   # configured logins (base cache)
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
            # the connection (session) of the failed attempt — joined to the
            # transfer legs of that session for the Subscription column
            # (2026-09-30, user request; see out_subs below)
            if ($6 != "" && !((k SUBSEP $6) in osx)) { osx[k SUBSEP $6] = 1; oss[k] = oss[k] "\037" $6 }
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
            # last-seen reason by TIMESTAMP, not cache order (robust whatever
            # the cache order — it is chronological since the sorted parse)
            osk = $1 " " $2
            # "-" for an EMPTY reason (a line ending at "as user U:"): the row
            # travels TAB-separated through a bash read, which collapses an
            # empty field and shifted every later column (2026-09-28 fix)
            if (!(k in orsk) || osk >= orsk[k]) { orsk[k] = osk; orsn[k] = (reason == "") ? "-" : substr(reason, 1, 80) }
            d = $1
            if (d ~ /^[0-9][0-9][0-9][0-9]-/) { ocd[k SUBSEP d]++; ocdc[k SUBSEP d SUBSEP cls]++
                if (!(k in ofst) || d < ofst[k]) ofst[k] = d
                if (!(k in olst) || d > olst[k]) olst[k] = d }
            next
        }
        # INCOMING: the [Ssh Default] logon-screening funnel
        if (index(m, "[Ssh Default]") == 0) next
        if ($1 ~ /^[0-9][0-9][0-9][0-9]-/ && (fss == "" || $1 < fss)) fss = $1   # first ssh-line date (the Allowed-coverage check)
        # the family (A Allowed · T Authenticated · D Disallowed · N No
        # account · B Bad key · K Key failures · L Locked) and the username
        # it names — bin/ssh-family.awk, the ONE classifier (the lockout line
        # itself counts too since 2026-09-28)
        side = ssh_family(m); u = SSH_U
        if (side == "A" && $1 ~ /^[0-9][0-9][0-9][0-9]-/ && (fad == "" || $1 < fad)) fad = $1
        if (side == "") {
            # SESSION ERRORS (2026-09-06, user request): an Error/Warning
            # [Ssh Default] line of no counted family, on a session — kept
            # for END, which attributes it to the login of the session once the
            # whole cache has built the session -> login map. NOT the
            # anonymous "Authentication failed using local." line: the logon
            # summary (bin/logons.sh) counts it as Auth failed, and as a
            # session error too it was counted twice (2026-09-28 fix)
            if (index(m, "[Ssh Default] Authentication failed using local.") > 0) next
            # ... nor the re-key bookkeeping "No session cycleId for file …
            # SENT will not get reported!" (see the header; = bin/logons.sh)
            if (index(m, "No session cycleId for file") > 0) next
            if ($3 != "I" && $6 != "") { nxs++; XSs[nxs] = $6; XSd[nxs] = $1; XSt[nxs] = $1 " " $2; XSl[nxs] = lvlname($3) " " compname($4) "  " substr(m, 1, 200) }
            next
        }
        if (u == "") next
        # platform-internal pseudo-logins (blacklist, raw token) get no row
        if (bl_blank("login", u)) next
        # ONE key per CONFIGURED login whatever case it was typed in: the
        # configured spelling (2026-09-28 fix: "fe0001" and "FE0001" were two
        # rows, and partners-in, joining on the upper-cased name, kept only
        # one of them). A name nothing configures keeps its typed spelling —
        # a door-knocker tried exactly that.
        if (toupper(u) in klu) u = klu[toupper(u)]
        users[u] = 1
        # the session -> login map and the LAST SSH authentication of the
        # session (cache col 6; the re-screen test and the session-error
        # attribution, both in END). An authenticated line names the login of
        # the session for sure; any other funnel line only when nothing named
        # it yet.
        if ($6 != "") {
            if (side == "T" || !($6 in slog)) slog[$6] = u
            if (side == "T") { ts = $1 " " $2; if (!($6 in sat) || ts > sat[$6]) sat[$6] = ts }
        }
        if (side == "A") {
            # DEFERRED: a genuine screening or a RE-SCREEN (the line is LATER
            # than the last authentication of its session — the hourly re-key
            # of a persistent connection logs the screening pair again and
            # never authenticates anew, FE000508 2026-09-06; an Allowed that
            # an authentication follows is a real screening whatever came
            # before it) is decided in END, when the last authentication of
            # the session is known
            nrs++; RSu[nrs] = u; RSd[nrs] = $1; RSt[nrs] = $1 " " $2; RSs[nrs] = $6; RSl[nrs] = lvlname($3) " " compname($4) "  " substr(m, 1, 200)
            next
        }
        if (side == "N") {
            # a No-account line of a name Flow Manager does not configure is
            # door-knocker evidence logged with the funnel wording (2026-09-04,
            # user request): its source address and drill line are kept so
            # END can move such a name into the knocker tables
            ipn = ""
            if (match(m, /Remote address: *[^ ]+/)) { ipn = substr(m, RSTART, RLENGTH); sub(/^Remote address: */, "", ipn); sub(/[. ]*$/, "", ipn); sub(/^\//, "", ipn) }
            else if (match(m, /[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/)) ipn = substr(m, RSTART, RLENGTH)
            if (ipn != "") nip[u SUBSEP ipn]++
            addline("DK" SUBSEP u, $1 " " $2, lvlname($3) " " compname($4) "  " substr(m, 1, 200))
        }
        book(side, u, $1, $1 " " $2, lvlname($3) " " compname($4) "  " substr(m, 1, 200))
    }
    END {
        # ---- the deferred Allowed lines: a genuine screening (A), or a ----
        # re-screen (R) when the line is later than the last authentication
        # of its session
        for (i = 1; i <= nrs; i++) {
            s = RSs[i]
            book((s != "" && (s in sat) && sat[s] < RSt[i]) ? "R" : "A", RSu[i], RSd[i], RSt[i], RSl[i])
        }
        # ---- the session errors (X): to the login of their session; a ----
        # session no funnel line named stays unattributed
        for (i = 1; i <= nxs; i++) if (XSs[i] in slog) book("X", slog[XSs[i]], XSd[i], XSt[i], XSl[i])
        # column order — matches the HEAD/RECALC/drill-cell numbering below;
        # the first SEVEN are the screening funnel (the row-tint verdict), R
        # and X ride behind them (2026-09-06)
        ns = split("A T D N B K L R X", S, " ")
        nsv = 7
        # an UNCONFIGURED name whose only funnel evidence is No account is a
        # door knocker the server logged with the funnel wording ("Unable to
        # find account with username"), not a login of ours (2026-09-04, user
        # request — it sat on Incoming as the one row without a detail page):
        # no Incoming row, its count leaves the No account total, and it
        # joins the knocker tables, folded with any "not associated" lines
        # of the same name (its drill lines already sit under the DK key)
        for (u in users) {
            if (u in klog) continue
            if ((cnt["N" SUBSEP u] + 0) == 0) continue
            only = 1
            for (i = 1; i <= ns; i++) if (S[i] != "N" && S[i] != "X" && (cnt[S[i] SUBSEP u] + 0) > 0) { only = 0; break }
            if (!only) continue
            moved[u] = 1
            tot["N"] -= cnt["N" SUBSEP u]
            tot["X"] -= cnt["X" SUBSEP u] + 0   # the session errors of a knocker leave with it
            dkc[u] += cnt["N" SUBSEP u]; dkT += cnt["N" SUBSEP u]
        }
        for (x in nip) { split(x, a6, SUBSEP)
            if (!(a6[1] in moved)) continue
            if (!(x in dkip)) { dkip[x] = 0; dkips[a6[1]]++ }
            dkip[x] += nip[x] }
        for (k in days) { split(k, a6, SUBSEP)
            if (!(a6[1] in moved)) continue
            n6 = bk[k SUBSEP "N"] + 0
            if (n6 == 0) continue
            dkd[k] += n6
            if (dkf[a6[1]] == "" || a6[2] < dkf[a6[1]]) dkf[a6[1]] = a6[2]
            if (a6[2] > dkl[a6[1]]) dkl[a6[1]] = a6[2] }
        # per-user per-day buckets (entry order is hash order — report.js
        # consumes @data:buckets as a set, the one accepted variance)
        for (k in days) { split(k, a, SUBSEP)
            s2 = ""
            for (i = 1; i <= ns; i++) s2 = s2 ":" (bk[k SUBSEP S[i]]+0)
            b[a[1]] = b[a[1]] (b[a[1]] == "" ? "" : ",") a[2] s2 }
        for (u in users) {
            if (u in moved) continue            # a door knocker now (above)
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
            for (i = 1; i <= nsv; i++) { k2 = S[i] SUBSEP u
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
            printf "OUT\t%d\t%s%s\t%s%s\t%d\t%d\t%d\t%d\t%s\t%s\t%s\t%s\t%s\t%s\n", oc[k], hostlink(a[1]), a[1], acctlink(a[2]), a[2], \
                   opw[k]+0, oky[k]+0, ocr[k]+0, oot[k]+0, \
                   orsn[k], (obk[k] == "" ? "-" : obk[k]), ofst[k], olst[k], (oss[k] == "" ? "-" : substr(oss[k], 2)), lastlines("O" SUBSEP k)
        }
        # ---- door knockers ----
        for (x in dkd) { split(x, a5, SUBSEP); dkb[a5[1]] = dkb[a5[1]] (dkb[a5[1]] == "" ? "" : ",") a5[2] ":" dkd[x] }
        # the scanner names distinct source ADDRESSES, ", "-joined per name
        # (the IPs column — 2026-08-31, user request); collected here in hash
        # order, sortjoin() below makes the list deterministic
        for (x in dkip) { split(x, a5, SUBSEP)
            if (a5[1] !~ /^FE[0-9]+$/) scip[a5[1]] = scip[a5[1]] (scip[a5[1]] == "" ? "" : SUBSEP) a5[2] }
        nkn = 0
        # (the FE-namespace knockers had their own near-miss table until
        # 2026-09-30, user request — they stay out of Incoming, listed nowhere)
        for (u in dkc) { nkn++
            if (u !~ /^FE[0-9]+$/)
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

IFS=$'\t' read -r _ atot ttot dtot ntot btot ktot ltot rtot xtot ototal opwt okyt ocrt oott <<< "$(printf '%s\n' "$agg" | grep $'^TOT\t')"
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
# (the per-login problem-counts sidecar _logon-problems.tsv, 2026-09-04..09-29,
# fed fe-overview.sh's "Logon problems" column — which went 2026-09-29: the
# FE overview page is retired and Partners - Incoming shows the funnel's own
# columns)
rows() {
    while IFS=$'\t' read -r _ user a t d n b k l r x bkt d1 d2 d3 d4 d5 d6 d7 d8 d9 lside lstamp af9 lgf lgl lgn lgp; do
        [ -n "$user" ] || continue
        [ "$bkt" = "-" ] && bkt=""
        [ "$d1" = "-" ] && d1=""; [ "$d2" = "-" ] && d2=""; [ "$d3" = "-" ] && d3=""; [ "$d4" = "-" ] && d4=""
        [ "$d5" = "-" ] && d5=""; [ "$d6" = "-" ] && d6=""; [ "$d7" = "-" ] && d7=""
        [ "$d8" = "-" ] && d8=""; [ "$d9" = "-" ] && d9=""
        [ "$af9" = "-" ] && af9=""
        # SEEN = any funnel activity at all, the anonymous Auth-failed count
        # included (before the 0-blanking below); a zero-everything row is a
        # configured login the funnel never saw
        local sn9=0; [ $((a + t + d + n + b + k + l + r + x + ${af9:-0})) -gt 0 ] && sn9=1
        # THE ROW TINT (2026-09-02, user request) — @data:res on a restint
        # table: ORANGE = never seen (every funnel column empty); GREEN = the
        # login's LATEST screening line is a successful authentication; RED =
        # its latest line is anything else (a refusal, a failure, or an
        # Allowed that no authentication followed). A full-period verdict,
        # like the logon-summary columns: a date range does not move it. The
        # problem cells keep their own red/amber (the restint CSS).
        local res9=red
        if [ "$sn9" = 0 ]; then res9=orange; elif [ "$lside" = "T" ]; then res9=green; fi
        [ "$k" = "0" ] && k=""; [ "$l" = "0" ] && l=""; [ "$r" = "0" ] && r=""   # blank the 0s at source too (render_rpt z-blanks warn zeros as well since 2026-08 — this keeps the raw .rpt readable)
        [ "${n:-0}" -gt 0 ] && nnames=$((nnames + 1))
        nrows=$((nrows + 1))
        [ "$lgn" = "-" ] && lgn=""
        [ -n "$lgn" ] && lgtot=$((lgtot + lgn))
        [ -n "$af9" ] && aftot=$((aftot + af9))
        # column order Allowed, Disallowed, Authenticated (the 2026-07 swap): the
        # cells, their drill payloads and the RECALC tokens below all follow it.
        # Session errors sits after Auth failed (2026-09-06); Re-screens is the
        # LAST column (2026-09-08, user request — it sat right after Allowed
        # for two days, which also shifted the cells reason-boxes.sh reads
        # by POSITION for its "login in" box: $4/$7/$8/$9 = Disallowed / Bad
        # key / Key failures / Locked are back in place). drill-cell-<i> binds
        # cells positionally — 1 Allowed, 2 Disallowed, 3 Authenticated, 4 No
        # account, 5 Bad key, 6 Key failures, 7 Locked, (8 Auth failed: no
        # drill), 9 Session errors, 14 Re-screens — so the block must not shift.
        printf 'ROW\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t@data:seen=%s\t@data:res=%s\t@data:buckets=%s\t@data:drill-cell-1=%s\t@data:drill-cell-2=%s\t@data:drill-cell-3=%s\t@data:drill-cell-4=%s\t@data:drill-cell-5=%s\t@data:drill-cell-6=%s\t@data:drill-cell-7=%s\t@data:drill-cell-9=%s\t@data:drill-cell-14=%s\n' \
            "$user" "$a" "$d" "$t" "$n" "$b" "$k" "$l" "$af9" "$x" "$lgf" "$lgl" "$lgn" "$lgp" "$r" "$sn9" "$res9" "$bkt" "$d1" "$d3" "$d2" "$d4" "$d5" "$d6" "$d7" "$d9" "$d8"
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
# The SUBSCRIPTION of an Outgoing pair (2026-09-30, user request): the
# sessions of its failed attempts joined to the transfer legs of the same
# connection (_transfers.tsv col 24 -> col 6, the site's session join) — the
# failed outbound attempt is logged as a leg of the flow that tried it. A
# session whose legs name two flows names neither (the site rule); "Unknown"
# is no subscription. The pair's distinct subscriptions, sorted, as ONE
# @{alist=subscriptions} cell (each name links its detail page); blank when
# no session resolves. Replaces field 13 (the sessions) of the OUT line.
out_subs() {
    # (the OUT lines arrive on stdin; FILENAME, not FNR == NR, tells the two
    # inputs apart — with NO Outgoing rows FNR == NR would hold for the legs)
    { printf '%s\n' "$agg" | grep $'^OUT\t' || true; } | awk -F'\t' -v OFS='\t' -v TRF="$TRANSFER_CACHE/_transfers.tsv" '
        FILENAME != TRF { if ($0 == "") next; L[++n] = $0; m = split($13, S, "\037"); for (i = 1; i <= m; i++) if (S[i] != "" && S[i] != "-") want[S[i]] = 1; next }
        ($24 in want) && $6 != "" && $6 != "Unknown" { if (!($24 in ss)) ss[$24] = $6; else if (ss[$24] != $6) ss[$24] = "\001" }
        END {
            for (i = 1; i <= n; i++) {
                split(L[i], F, "\t"); m = split(F[13], S, "\037"); c = 0; delete got
                for (j = 1; j <= m; j++) { s = S[j]; if ((s in ss) && ss[s] != "\001" && !(ss[s] in got)) { got[ss[s]] = 1; U[++c] = ss[s] } }
                for (a = 2; a <= c; a++) { v = U[a]; b = a - 1; while (b >= 1 && U[b] > v) { U[b + 1] = U[b]; b-- } U[b + 1] = v }
                cell = ""; for (a = 1; a <= c; a++) cell = cell (a > 1 ? ", " : "") U[a]
                F[13] = (cell == "") ? "-" : "@{alist=subscriptions}" cell
                line = F[1]; for (a = 2; a <= 14; a++) line = line OFS F[a]
                print line
            }
        }' - "$TRANSFER_CACHE/_transfers.tsv"
}
out_rows() {
    while IFS=$'\t' read -r _ count host ouser pw ky cr ot reason bkt fst lst subs lines; do
        [ -n "$host" ] || continue
        [ "$bkt" = "-" ] && bkt=""
        [ "$subs" = "-" ] && subs=""
        n_pairs=$((n_pairs + 1))
        printf 'ROW\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t@data:buckets=%s\t@data:loglines=%s\n' \
            "$host" "$ouser" "$subs" "$count" "$pw" "$ky" "$cr" "$ot" "$reason" "$fst" "$lst" "$bkt" "$lines"
    done <<< "$(out_subs | LC_ALL=C sort -t"$(printf '\t')" -k2,2nr)"
}

{
    printf 'TITLE\tLogon\n'
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
    # bucket slots (the R-line order A T D N B K L R X): s7 = Re-screens, s8 =
    # Session errors
    printf 'HEAD\tLogin\tAllowed\tDisallowed\tAuthenticated\tNo account\tBad key\tKey failures\tLocked\tAuth failed\tSession errors\tFirst logon\tLast logon\tLogons\tPattern\tRe-screens\n'
    printf 'KIND\tlogin\tnumprocessed\tnumfailed\tnumprocessed\tnumfailed\tnumfailed\tnumwarn\tnumwarn\tnumfailed\tnumfailed\ttext\ttext\tnum\ttext\tnum\n'
    printf 'RECALC\t-\ts0\ts2\ts1\ts3\ts4\ts5\ts6\tk\ts8\tk\tk\tk\tk\ts7\n'
    rows
    [ "$aftot" -gt 0 ] || aftot=""
    [ "${rtot:-0}" -gt 0 ] || rtot=""
    printf 'TOTAL\tTotal (%s logins)\t@{class=num processed}%s\t@{class=num failed}%s\t@{class=num processed}%s\t@{class=num failed}%s\t@{class=num failed}%s\t@{class=num warn}%s\t@{class=num warn}%s\t@{class=num failed}%s\t@{class=num failed}%s\t\t\t@{class=num}%s\t\t@{class=num}%s\n' \
        "$nrows" "$atot" "$dtot" "$ttot" "$ntot" "$btot" "$ktot" "$ltot" "$aftot" "$xtot" "$lgtot" "$rtot"

    printf 'TABLE\tOutgoing\twide\tdrill=log line\n'
    printf 'HEAD\tRemote host\tUser\tSubscription\tFailures\tPassword\tKey\tCertificate\tOther\tReason (last seen)\tFirst\tLast\n'
    printf 'KIND\thost\tmono\ttext\tnumfailed\tnumfailed\tnumfailed\tnumfailed\tnumfailed\ttext\ttext\ttext\n'
    printf 'RECALC\t-\t-\t-\ts0\ts1\ts2\ts3\ts4\t-\t-\t-\n'
    out_rows
    printf 'TOTAL\t@{colspan=3}Total (%s pair(s))\t@{class=num failed}%s\t@{class=num failed}%s\t@{class=num failed}%s\t@{class=num failed}%s\t@{class=num failed}%s\t\t\t\n' "$n_pairs" "$ototal" "$opwt" "$okyt" "$ocrt" "$oott"


    # ---- door knockers: the scanner top 25 (2026-08; the near-miss table went
    # 2026-09-30, user request)
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

    printf 'FOOT\n'
} > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"

echo "Data written to $OUT ($nrows login(s): $atot allowed, ${rtot:-0} re-screen(s), $ttot authenticated, $dtot disallowed, $ntot no-account, $btot bad-key, $ktot key-failure, $ltot locked, $xtot session error(s); $ototal outbound failure(s))." >&2
