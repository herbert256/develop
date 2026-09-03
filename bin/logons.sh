# bin/logons.sh — SOURCED. ensure_logons builds the per-login logon summary
# from the server parse cache: one row per login with ANY logon activity,
#   LOGIN(upper) ⇥ first stamp ⇥ last stamp ⇥ raw count ⇥ pattern
#     ⇥ allowed ⇥ disallowed ⇥ authenticated ⇥ no-account ⇥ bad-key
#     ⇥ key-failures ⇥ locked
#     ⇥ auth-failed-anonymous
#     ⇥ last-allowed ⇥ last-disallowed ⇥ last-authenticated ⇥ last-no-account
#     ⇥ last-bad-key ⇥ last-key-failures ⇥ last-locked ⇥ last-auth-failed
# Fields 2-5 come from the server log's own logon signal ("User with login
# name X … successfully authenticated", any protocol daemon; the same line
# uc2-status.sh counts pickups by); a login with funnel activity but no
# successful authentication carries "-" stamps, count 0 and pattern
# "Never". The pattern is uc2-status.sh's pickup-pattern logic verbatim —
# median gap over the distinct logon minutes, bursts collapsed into visits
# when the median visit span is short — so the Logons and Pickup
# information tables speak one vocabulary. Fields 6-12 are the [Ssh
# Default] screening-funnel counts, logon.sh's matching REPLICATED exactly
# (qtok and all) — the report's Incoming columns and the detail pages' rows
# must show the same numbers, so a change to either matcher belongs in
# both.
#
# Field 13 (2026-08) is the ANONYMOUS-failure attribution: the platform
# logs "[Ssh Default] Authentication failed using local." with NO username
# — a client that passed the whitelist and then failed authentication
# without presenting an evaluable credential (FE000260: 2 Allowed, then
# nothing, files expiring — invisible in every named family). Such a line
# is attributed to the login whose "Allowed user" screening it follows
# within ONE second; a window holding Allowed lines of TWO different
# logins attributes to neither (the site rule: a line that identifies
# nothing accuses nothing).
#
# Fields 14-21 (2026-08) are the LAST stamp per family, in the field 6-13
# order — the detail pages' Logons table shows them as its Last column;
# "-" where the family never fired.
#
# A SECOND file, _logons-hosts.tsv (2026-08), carries the same story per
# client ADDRESS — the auth line's "Remote address:" and the screening
# lines' "from address" — for the HOST detail pages' Logons table. Only
# the families that carry an address exist there:
#   ADDR ⇥ first ⇥ last ⇥ count ⇥ pattern ⇥ allowed ⇥ disallowed
#        ⇥ last-allowed ⇥ last-disallowed
#        ⇥ out-count ⇥ out-first ⇥ out-last ⇥ out-pattern
#        ⇥ outfail-count ⇥ outfail-last
#        ⇥ pw ⇥ last-pw ⇥ key ⇥ last-key ⇥ cert ⇥ last-cert ⇥ other ⇥ last-other
#        ⇥ 7 connection-error class pairs (count ⇥ last each)
# Fields 16-23 (2026-08) split the outbound failures by class — logon.sh's
# Outgoing classifier verbatim (Password / Publickey / Certificate /
# Other), each with its last stamp. Fields 24-37 (2026-08) classify the
# "Connection failure while … tried to connect to remote host H" lines,
# keyed by the lowercased target (hostname or address, the one key space),
# seven (count, last) pairs in this order:
#   Timeouts (timed out / Time out / "response on time"), SSH errors (the
#   opaque com.maverick SshException), Network errors (310-Network
#   incident, refused, closed without indication, EOF, "Error while
#   connecting" + the residue), TLS handshake (bad_certificate,
#   handshake_failure, certificate_unknown), Too many connections (the
#   PeSIT 309), SSH negotiation (algorithms, rejected host key), Proxy
#   errors (the SOCKS families).
# Fields 10-15 are the OUTBOUND side — an endpoint like secureftp.pondres.nl
# is one WE connect to, so its page would otherwise show nothing: the "had
# initiated a connection over …" lines count our connections per target
# address (fields 10-13, same cadence), and the "Authentication failure
# connecting to remote host H:P" errors count our failures per target
# HOSTNAME (fields 14-15 — those rows key on the lowercased hostname, in
# the same key space; the writer looks pages up by name AND addresses).
# The host blacklist keeps the cluster's own addresses out; the login
# blacklist deliberately does NOT apply — the address's activity is real
# whichever credential it carried.
#
# Two consumers, which the build runs CONCURRENTLY (details.sh in the
# background beside the server reports): transfer details.sh (the Logons
# table on the LOGIN pages) and server logon.sh (the Incoming table's last
# four columns). Each calls ensure_logons itself, so neither depends on the
# other having run: the write is atomic (unique tmp + mv) and cmp-guarded —
# two concurrent builders produce identical bytes, and identical content
# keeps its mtime so downstream freshness checks stay quiet.
_LOGONS_SH="${BASH_SOURCE[0]}"
# the platform-internal pseudo-logins (SECURETRANSPORT, the cluster CFT
# credentials, *nobody, …) must not get rows here either — the sidecar feeds
# a report join and the detail pages, and the blacklist's contract is that
# no report or page ever counts them
source "$(dirname "$_LOGONS_SH")/blacklist.sh"

ensure_logons() {   # $1 = the server cache dir; writes $1/_logons.tsv + $1/_logons-hosts.tsv
    local _lg_cache="$1" _lg_out="$1/_logons.tsv" _lg_hout="$1/_logons-hosts.tsv" _lg_parse="$1/_parse.tsv" _lg_tmp _lg_htmp
    # fresh when newer than the parse cache, this script and the blacklist (a
    # missing parse cache still gets an EMPTY summary written once)
    if [ -f "$_lg_out" ] && [ -f "$_lg_hout" ] && [ ! "$_lg_parse" -nt "$_lg_out" ] && [ ! "$_LOGONS_SH" -nt "$_lg_out" ] \
        && [ ! "$BLACKLIST_FILE" -nt "$_lg_out" ]; then return 0; fi
    mkdir -p "$_lg_cache"
    _lg_tmp="$_lg_out.tmp.$$"
    _lg_htmp="$_lg_hout.tmp.$$"
    : > "$_lg_tmp"; : > "$_lg_htmp"
    if [ -s "$_lg_parse" ]; then
        awk -F'\t' -v BLF="$BLACKLIST_FILE" -v HOUT="$_lg_htmp" "$BLACKLIST_AWK"'
            BEGIN { bl_load(BLF) }
            # the quoted token right after the matched prefix (logon.sh
            # verbatim): the quote character varies per family
            function qtok(rest,   q, p) {
                q = substr(rest, 1, 1)
                if (q != "\x27" && q != "\"") return ""
                p = index(substr(rest, 2), q)
                if (p <= 0) return ""
                return substr(rest, 2, p - 1)
            }
            # the client address after "Remote address: " — up to the first
            # space, a trailing sentence dot stripped
            function addrof(m9,   p9, a9) {
                p9 = index(m9, "Remote address: ")
                if (p9 == 0) return ""
                a9 = substr(m9, p9 + 16)
                sub(/ .*$/, "", a9)
                sub(/[.,;]$/, "", a9)
                return a9
            }
            function jdn(y,m,d,  a){ a=int((14-m)/12); y=y+4800-a; m=m+12*a-3; return d+int((153*m+2)/5)+365*y+int(y/4)-int(y/100)+int(y/400)-32045 }
            function minof(d, t) { return jdn(substr(d,1,4)+0, substr(d,6,2)+0, substr(d,9,2)+0) * 1440 + substr(t,1,2) * 60 + substr(t,4,2) + 0 }
            # second-of-era with the millisecond fraction (the anon-failure
            # window is sub-second work; a double carries this exactly)
            function secof(d, t) { return jdn(substr(d,1,4)+0, substr(d,6,2)+0, substr(d,9,2)+0) * 86400 + substr(t,1,2) * 3600 + substr(t,4,2) * 60 + substr(t,7) + 0 }
            function patron(m,   n) {
                if (m <= 0)   return "Rarely"
                if (m <= 2)   return "Continuous"
                if (m < 58)   { n = int((m + 2.5) / 5) * 5; if (n < 5) n = 5; return "Every " n " minutes" }
                if (m <= 75)  return "Hourly"
                if (m < 1320) { n = int((m + 30) / 60); return (n <= 1) ? "Hourly" : "Every " n " hours" }
                n = int((m + 720) / 1440)
                if (n <= 1)   return "Daily"
                if (n >= 6 && n <= 8) return "Weekly"
                if (n <= 15)  return "Every " n " days"
                return "Rarely"
            }
            $5 ~ /User with login name "/ && $5 ~ /successfully authenticated/ {
                if (!match($5, /login name "[^"]*"/)) next
                u = substr($5, RSTART + 12, RLENGTH - 13)
                # the blacklist tests the RAW token (its rules are exact and
                # case-sensitive: *nobody would survive a toupper)
                if (u == "" || bl_blank("login", u)) next
                u = toupper(u)
                cnt[u]++
                ts = $1 " " $2
                if (fst[u] == "" || ts < fst[u]) fst[u] = ts
                if (lst[u] == "" || ts > lst[u]) lst[u] = ts
                if ($1 ~ /^[0-9][0-9][0-9][0-9]-/ && $2 ~ /^[0-9][0-9]:/) {
                    m = minof($1, $2)
                    lgm[u SUBSEP m] = 1
                    if (!(u in m0) || m < m0[u]) m0[u] = m
                    if (!(u in m1) || m > m1[u]) m1[u] = m
                }
                if (ORD[u] == "") { ORD[u] = ++no; NM[no] = u }   # first-seen order (cache order is stable)
                # the same logon, keyed by the client ADDRESS (the host file)
                ha = addrof($5)
                if (ha != "" && !bl_blank("host", ha)) {
                    hcnt[ha]++
                    if (hfst[ha] == "" || ts < hfst[ha]) hfst[ha] = ts
                    if (hlst[ha] == "" || ts > hlst[ha]) hlst[ha] = ts
                    if ($1 ~ /^[0-9][0-9][0-9][0-9]-/ && $2 ~ /^[0-9][0-9]:/) {
                        m = minof($1, $2)
                        hlgm[ha SUBSEP m] = 1
                        if (!(ha in hm0) || m < hm0[ha]) hm0[ha] = m
                        if (!(ha in hm1) || m > hm1[ha]) hm1[ha] = m
                    }
                    if (hORD[ha] == "") { hORD[ha] = ++hno; HNM[hno] = ha }
                }
            }
            # OUR outbound connections: one line per SSH/FTP connection ST
            # opens toward a partner — the Remote address is the TARGET
            $5 ~ /had initiated a connection over / {
                ha = addrof($5)
                if (ha != "" && !bl_blank("host", ha)) {
                    hocnt[ha]++
                    ts = $1 " " $2
                    if (hofst[ha] == "" || ts < hofst[ha]) hofst[ha] = ts
                    if (holst[ha] == "" || ts > holst[ha]) holst[ha] = ts
                    if ($1 ~ /^[0-9][0-9][0-9][0-9]-/ && $2 ~ /^[0-9][0-9]:/) {
                        m = minof($1, $2)
                        holgm[ha SUBSEP m] = 1
                        if (!(ha in hom0) || m < hom0[ha]) hom0[ha] = m
                        if (!(ha in hom1) || m > hom1[ha]) hom1[ha] = m
                    }
                    if (hORD[ha] == "") { hORD[ha] = ++hno; HNM[hno] = ha }
                }
                next
            }
            # OUR outbound connection failures, keyed by the target host
            # (hostname or address, lowercased — one key space) and
            # CLASSIFIED (see the header; w = Network is the catch-all)
            $5 ~ /^Connection failure while / {
                if (match($5, / tried to connect to remote host [^ :]+/)) {
                    h9 = tolower(substr($5, RSTART + 33, RLENGTH - 33))
                    if (h9 != "" && !bl_blank("host", h9)) {
                        if (tolower($5) ~ /timed? ?out/ || $5 ~ /response on time/) cc9 = "t"
                        else if ($5 ~ /SshException/)                               cc9 = "s"
                        else if ($5 ~ /bad_certificate|handshake_failure|certificate_unknown/) cc9 = "h"
                        else if ($5 ~ /Too many connections/)                       cc9 = "m"
                        else if ($5 ~ /negotiate algorithms|host key was not accepted/) cc9 = "n"
                        else if ($5 ~ /SOCKS|socks5/)                               cc9 = "x"
                        else                                                        cc9 = "w"
                        hcc[cc9 SUBSEP h9]++
                        ts = $1 " " $2
                        if (hccl[cc9 SUBSEP h9] == "" || ts > hccl[cc9 SUBSEP h9]) hccl[cc9 SUBSEP h9] = ts
                        if (hORD[h9] == "") { hORD[h9] = ++hno; HNM[hno] = h9 }
                    }
                }
                next
            }
            # OUR outbound authentication failures, keyed by the target
            # HOSTNAME (logon.sh'\''s Outgoing family)
            $5 ~ /^Authentication failure connecting to remote host / {
                r9 = $5; sub(/^Authentication failure connecting to remote host /, "", r9)
                if (match(r9, /^[^:]+/)) {
                    h9 = tolower(substr(r9, RSTART, RLENGTH))
                    if (h9 != "" && !bl_blank("host", h9)) {
                        hxc[h9]++
                        ts = $1 " " $2
                        if (hxl[h9] == "" || ts > hxl[h9]) hxl[h9] = ts
                        # the class split — logon.sh'\''s Outgoing classifier
                        # verbatim, so the host rows and the report columns
                        # always agree
                        cls9 = "o"
                        if (match(r9, / as user [^:]+:/)) {
                            rr9 = substr(r9, RSTART + RLENGTH); sub(/^ +/, "", rr9)
                            cls9 = (rr9 ~ /^Password /) ? "p" : (rr9 ~ /^Publickey /) ? "k" : \
                                   (rr9 ~ /^530 Need certificate/ || rr9 ~ /^534 /) ? "c" : "o"
                        }
                        hxcc[cls9 SUBSEP h9]++
                        if (hxcl[cls9 SUBSEP h9] == "" || ts > hxcl[cls9 SUBSEP h9]) hxcl[cls9 SUBSEP h9] = ts
                        if (hORD[h9] == "") { hORD[h9] = ++hno; HNM[hno] = h9 }
                    }
                }
                next
            }
            # the ANONYMOUS authentication failure — no username, no address:
            # only its TIMING can say whose it was (see the header). Collect
            # the stamps; the window join runs in END.
            index($5, "[Ssh Default] Authentication failed using local.") > 0 {
                if ($1 ~ /^[0-9][0-9][0-9][0-9]-/ && $2 ~ /^[0-9][0-9]:/) { nf9++; FS9[nf9] = secof($1, $2); FT9[nf9] = $1 " " $2 }
                next
            }
            # the [Ssh Default] logon-screening funnel — logon.sh'\''s seven
            # families replicated with the same guards and token extraction
            # (the door-knocker and Outgoing families it consumes with
            # `next` first match none of these regexes, so a flat replica
            # counts identically). Counts only; the report keeps the drills.
            index($5, "[Ssh Default]") > 0 {
                m9 = $5; side = ""; u2 = ""
                if (match(m9, /\[Ssh Default\] Allowed user /))         { side = "A"; u2 = qtok(substr(m9, RSTART + RLENGTH)) }
                else if (m9 ~ /successfully authenticated over SSH/ && match(m9, /login name /)) {
                    side = "T"; u2 = qtok(substr(m9, RSTART + RLENGTH)) }
                else if (match(m9, /\[Ssh Default\] Disallowed user /)) { side = "D"; u2 = qtok(substr(m9, RSTART + RLENGTH)) }
                else if (match(m9, /Unable to find account with username: [^ ]+/)) {
                    side = "N"; u2 = substr(m9, RSTART + 38, RLENGTH - 38); sub(/[.,;]$/, "", u2) }
                else if (match(m9, /no certificate is found for user /)) {
                    side = "B"; u2 = qtok(substr(m9, RSTART + RLENGTH)); sub(/^.*@/, "", u2) }
                else if (match(m9, /\[Ssh Default\] User [A-Za-z0-9_.-]+ failed to login successfully/)) {
                    side = "K"; u2 = substr(m9, RSTART + 19); sub(/ failed to login.*$/, "", u2) }
                else if (match(m9, /\[Ssh Default\] User /) && m9 ~ /is locked/) {
                    side = "L"; u2 = qtok(substr(m9, RSTART + RLENGTH))
                    if (u2 == "" && match(m9, /Username: /)) u2 = qtok(substr(m9, RSTART + RLENGTH)) }
                if (side == "" || u2 == "") next
                # the screening lines carry the client address too (the host
                # file) — captured BEFORE the login blacklist: the address
                # activity is real whichever credential it carried
                if ((side == "A" || side == "D") && match(m9, /from address /)) {
                    ha = qtok(substr(m9, RSTART + RLENGTH))
                    if (ha != "" && !bl_blank("host", ha)) {
                        hfc[side SUBSEP ha]++
                        ts = $1 " " $2
                        if (hfl[side SUBSEP ha] == "" || ts > hfl[side SUBSEP ha]) hfl[side SUBSEP ha] = ts
                        if (hORD[ha] == "") { hORD[ha] = ++hno; HNM[hno] = ha }
                    }
                }
                if (bl_blank("login", u2)) next   # raw token, pre-toupper
                u2 = toupper(u2)
                fcnt[side SUBSEP u2]++
                ts9 = $1 " " $2; k9f = side SUBSEP u2
                if (fls[k9f] == "" || ts9 > fls[k9f]) fls[k9f] = ts9   # last stamp per family
                # the Allowed and SSH-success events feed the anon-failure
                # window join (a success CONSUMES its Allowed — see END)
                if ($1 ~ /^[0-9][0-9][0-9][0-9]-/ && $2 ~ /^[0-9][0-9]:/) {
                    if (side == "A")      { na9++; AS9[na9] = secof($1, $2); AU9[na9] = u2 }
                    else if (side == "T") { nt9++; TS9[nt9] = secof($1, $2); TU9[nt9] = u2 }
                }
                if (ORD[u2] == "") { ORD[u2] = ++no; NM[no] = u2 }
            }
            END {
                # attribute each anonymous failure to the NEWEST Allowed line
                # at most one second before it. An Allowed followed by ITS
                # OWN SSH success before the failure is CONSUMED — that
                # connection got in, it cannot be the failer (FE000508
                # authenticates 14 ms after its Allowed; without this rule
                # its screening shadowed FE000260 failing 500 ms later).
                # Unconsumed candidates from two DIFFERENT logins attribute
                # to neither: a line that identifies nothing accuses nothing.
                for (f9 = 1; f9 <= nf9; f9++) {
                    fs9 = FS9[f9]
                    nc9 = 0
                    for (a9 = 1; a9 <= na9; a9++) {
                        if (AS9[a9] > fs9 || fs9 - AS9[a9] > 1) continue
                        nc9++; CS9[nc9] = AS9[a9]; CU9[nc9] = AU9[a9]; CC9[nc9] = 0
                    }
                    if (nc9 == 0) continue
                    for (t9 = 1; t9 <= nt9; t9++) {
                        if (TS9[t9] > fs9) continue
                        for (c9x = 1; c9x <= nc9; c9x++)
                            if (!CC9[c9x] && TU9[t9] == CU9[c9x] && TS9[t9] >= CS9[c9x]) CC9[c9x] = 1
                    }
                    b9 = 0; amb9 = 0
                    for (c9x = 1; c9x <= nc9; c9x++) {
                        if (CC9[c9x]) continue
                        if (b9 == 0) b9 = c9x
                        else if (CU9[c9x] != CU9[b9]) amb9 = 1
                        else if (CS9[c9x] > CS9[b9]) b9 = c9x
                    }
                    if (b9 > 0 && !amb9) {
                        afc[CU9[b9]]++
                        if (afl[CU9[b9]] == "" || FT9[f9] > afl[CU9[b9]]) afl[CU9[b9]] = FT9[f9]
                    }
                }
                for (i9 = 1; i9 <= no; i9++) {
                    u = NM[i9]
                    c9 = (u in cnt) ? cnt[u] : 0
                    # a funnel-only login (screened, never authenticated)
                    pat = (c9 > 0) ? ((u in m0) ? cadence(lgm, u, m0[u], m1[u]) : "Rarely") : "Never"
                    printf "%s\t%s\t%s\t%d\t%s\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", u, \
                        (c9 > 0 ? fst[u] : "-"), (c9 > 0 ? lst[u] : "-"), c9, pat, \
                        fk("A", u), fk("D", u), fk("T", u), fk("N", u), fk("B", u), fk("K", u), fk("L", u), \
                        ((u in afc) ? afc[u] : 0), \
                        fl9("A", u), fl9("D", u), fl9("T", u), fl9("N", u), fl9("B", u), fl9("K", u), fl9("L", u), \
                        (afl[u] != "" ? afl[u] : "-")
                }
                # ---- the per-ADDRESS host file (see the header) ---------------
                for (i9 = 1; i9 <= hno; i9++) {
                    ha = HNM[i9]
                    c9 = (ha in hcnt) ? hcnt[ha] : 0
                    pat = (c9 > 0) ? ((ha in hm0) ? cadence(hlgm, ha, hm0[ha], hm1[ha]) : "Rarely") : "Never"
                    oc9 = (ha in hocnt) ? hocnt[ha] : 0
                    opat = (oc9 > 0) ? ((ha in hom0) ? cadence(holgm, ha, hom0[ha], hom1[ha]) : "Rarely") : "Never"
                    printf "%s\t%s\t%s\t%d\t%s\t%d\t%d\t%s\t%s\t%d\t%s\t%s\t%s\t%d\t%s\t%d\t%s\t%d\t%s\t%d\t%s\t%d\t%s", ha, \
                        (c9 > 0 ? hfst[ha] : "-"), (c9 > 0 ? hlst[ha] : "-"), c9, pat, \
                        ((("A" SUBSEP ha) in hfc) ? hfc["A" SUBSEP ha] : 0), \
                        ((("D" SUBSEP ha) in hfc) ? hfc["D" SUBSEP ha] : 0), \
                        (hfl["A" SUBSEP ha] != "" ? hfl["A" SUBSEP ha] : "-"), \
                        (hfl["D" SUBSEP ha] != "" ? hfl["D" SUBSEP ha] : "-"), \
                        oc9, (oc9 > 0 ? hofst[ha] : "-"), (oc9 > 0 ? holst[ha] : "-"), opat, \
                        ((ha in hxc) ? hxc[ha] : 0), (hxl[ha] != "" ? hxl[ha] : "-"), \
                        hf9("p", ha), hl9x("p", ha), hf9("k", ha), hl9x("k", ha), \
                        hf9("c", ha), hl9x("c", ha), hf9("o", ha), hl9x("o", ha) > HOUT
                    for (cc9i = 1; cc9i <= 7; cc9i++) {
                        cc9 = substr("tswhmnx", cc9i, 1)
                        printf "\t%d\t%s", (((cc9 SUBSEP ha) in hcc) ? hcc[cc9 SUBSEP ha] : 0), \
                            (hccl[cc9 SUBSEP ha] != "" ? hccl[cc9 SUBSEP ha] : "-") > HOUT
                    }
                    printf "\n" > HOUT
                }
                close(HOUT)
            }
            function fk(s, u) { return ((s SUBSEP u) in fcnt) ? fcnt[s SUBSEP u] : 0 }
            function fl9(s, u) { return (fls[s SUBSEP u] != "") ? fls[s SUBSEP u] : "-" }
            function hf9(c, a) { return ((c SUBSEP a) in hxcc) ? hxcc[c SUBSEP a] : 0 }
            function hl9x(c, a) { return (hxcl[c SUBSEP a] != "") ? hxcl[c SUBSEP a] : "-" }
            # the cadence label over a keyed minute set LGM[key SUBSEP minute]
            # walked lo..hi: the median gap between the minutes, bursts
            # collapsed into visits (a gap > 30 min starts one) when the
            # median visit span is short. Fewer than 3 minutes = "Rarely".
            # All work arrays are locals (the extra parameters).
            function cadence(LGM, key, lo, hi,   LG2, gh2, SS2, SE2, dh2, nl, li, m, g, maxg, ng, half, c2, med, ns, maxd, meddur) {
                nl = 0
                for (m = lo; m <= hi; m++) if ((key SUBSEP m) in LGM) LG2[++nl] = m
                if (nl < 3) return "Rarely"
                maxg = 0; ng = 0
                for (li = 2; li <= nl; li++) { g = LG2[li] - LG2[li - 1]; gh2[g]++; ng++; if (g > maxg) maxg = g }
                half = int(ng / 2) + 1; c2 = 0; med = 0
                for (g = 1; g <= maxg; g++) if (g in gh2) { c2 += gh2[g]; if (c2 >= half) { med = g; break } }
                ns = 0
                for (li = 1; li <= nl; li++) {
                    if (li == 1 || LG2[li] - LG2[li - 1] > 30) { SS2[++ns] = LG2[li]; SE2[ns] = LG2[li] }
                    else SE2[ns] = LG2[li]
                }
                # the median visit SPAN, whatever the visit count (uc2-status.sh
                # verbatim, 2026-09-03): short spans = a bursty client, whose
                # cadence is a statement about VISITS — fewer than 3 visits is
                # no cadence at all, so the label is the plain visit count; a
                # sustained single visit keeps its real cadence
                maxd = 0
                for (li = 1; li <= ns; li++) { g = SE2[li] - SS2[li]; dh2[g]++; if (g > maxd) maxd = g }
                half = int((ns + 1) / 2); c2 = 0; meddur = 0
                for (g = 0; g <= maxd; g++) if (g in dh2) { c2 += dh2[g]; if (c2 >= half) { meddur = g; break } }
                if (meddur <= 15 && ns < 3) return (ns == 1 ? "Once" : patron(SS2[2] - SS2[1]))   # one visit: Once; two: the spacing between them (2026-09-03, user request)
                if (meddur <= 15) {
                    delete gh2; maxg = 0; ng = 0
                    for (li = 2; li <= ns; li++) { g = SS2[li] - SS2[li - 1]; gh2[g]++; ng++; if (g > maxg) maxg = g }
                    half = int(ng / 2) + 1; c2 = 0
                    for (g = 1; g <= maxg; g++) if (g in gh2) { c2 += gh2[g]; if (c2 >= half) { med = g; break } }
                }
                return patron(med)
            }
        ' "$_lg_parse" > "$_lg_tmp"
    fi
    if [ -f "$_lg_out" ] && cmp -s "$_lg_tmp" "$_lg_out"; then rm -f "$_lg_tmp"
    else mv "$_lg_tmp" "$_lg_out"; fi
    if [ -f "$_lg_hout" ] && cmp -s "$_lg_htmp" "$_lg_hout"; then rm -f "$_lg_htmp"
    else mv "$_lg_htmp" "$_lg_hout"; fi
    return 0
}
