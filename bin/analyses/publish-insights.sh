#!/usr/bin/env bash
#
# bin/analyses/publish-insights.sh — render the three INSIGHT analyses pages
# (docs/analyses/*.html). Called by
# bin/analyses/publish.sh (the Reports start page, bin/build/publish.sh, lists only
# pages that exist). All pages are config-vs-reality joins over data already
# on disk — the flow-manager caches, the transfer/server report .rpt files,
# the parse caches and (certificates + cron, like uc3-polling.sh) the
# raw FlowManager JSON exports via jq:
#   whitelist-audit.html   whitelisted IPs vs the addresses actually connecting
#   config-hygiene.html    config twins, orphaned objects, the server-log config
#                          defects and the "one name, two roles" tables
#   subscriptions-in-boxes.html  every subscription boxed by what is true of it
# Every page degrades gracefully: a missing source skips that column/section
# rather than failing the publish. Runs from any directory.
#
# Usage:  bin/analyses/publish-insights.sh           the three pages (+ the sidecar)
#         bin/analyses/publish-insights.sh sidecar   ONLY the box-reason sidecar
#             _subs-boxes.tsv, no page (2026-09-29) — bin/analyses/publish.sh
#             catchup: the failed.sh catch-up rewrote _errpage-evidence.tsv, the
#             sidecar's one input that moved; the pages read none of it
#
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../publish_lib.sh"   # cd's to the repo root; html_head/esc/…

# the MODE: an explicit argument — never a freshness check
PI_MODE=${1:-all}
case $PI_MODE in
    all|sidecar) ;;
    *) printf 'usage: bin/analyses/publish-insights.sh [sidecar]\n' >&2; exit 2 ;;
esac

ADIR="$DOCS/analyses"
mkdir -p "$ADIR"
FMJ="$FM_CONFIG_DIR"                       # SKIP-filtered copy when present (see publish_lib.sh)
XREF="$DATA/flow-manager/xref"
FBASE="$DATA/flow-manager/base"
FILESC="$DATA/transfer/cache/_files.tsv"
TRPT="$DATA/transfer/reports"
SRPT="$DATA/server/reports"

TMPD=$(mktemp -d)
trap 'rm -rf "$TMPD"' EXIT

# ---- shared extracts --------------------------------------------------------
# (the page writers' inputs only — the sidecar mode skips them)
if [ "$PI_MODE" = all ]; then
    # Credentials: account, credential name, type, private, expiry date, days left
    # (empty when the credential carries no expiration). jq's strftime/now do the
    # date math, so the awk side stays POSIX.
    CERTS="$TMPD/certs.tsv"
    if [ -f "$FMJ/partners.json" ]; then
        jq -r '.[] | .name as $n | (.credentials // [])[]
            | [$n, (.name // "-"), (.type // "-"), (if (.isPrivateCertificate // false) then "private" else "public" end),
               (if .expiration then ((.expiration/1000) | strftime("%Y-%m-%d")) else "" end),
               (if .expiration then (((.expiration/1000 - now)/86400) | floor | tostring) else "" end)]
            | @tsv' "$FMJ/partners.json" > "$CERTS" 2>/dev/null || : > "$CERTS"
    else
        : > "$CERTS"
    fi

    # Observed INBOUND source addresses from the transfer logs: addr, Files, last date
    OBSADDR="$TMPD/obsaddr.tsv"
    if [ -f "$FILESC" ]; then
        awk -F'\t' '$16 == "in" && $15 != "" { c[$15]++; if ($4 > l[$15]) l[$15] = $4 }
            END { for (a in c) printf "%s\t%d\t%s\n", a, c[a], l[a] }' "$FILESC" | LC_ALL=C sort > "$OBSADDR"
    else
        : > "$OBSADDR"
    fi

    # Server-side INBOUND contact per client address: the inbound connection
    # lines (_inbound-addr.tsv, uncapped) plus the SSH logon lines of that
    # address (_logons-hosts.tsv: field 4 authentications + field 7 disallowed,
    # else field 6 allowed) — bin/server-inbound-addr.awk, shared with the
    # Cleanup backlog. (Until 2026-09-29 this read the Connections report's
    # top-50 "By source address" table, whose lines were mostly OUR outbound
    # connections — the targets read as partner sources.)
    SRVADDR="$TMPD/srvaddr.tsv"
    _ia="$SRPT/_inbound-addr.tsv"; [ -f "$_ia" ] || _ia=/dev/null
    _lh="$DATA/server/cache/_logons-hosts.tsv"; [ -f "$_lh" ] || _lh=/dev/null
    awk -F'\t' -f "$SCRIPT_DIR/../server-inbound-addr.awk" "$_ia" "$_lh" | LC_ALL=C sort > "$SRVADDR"
fi

# ---- 4. Whitelist audit -----------------------------------------------------
write_whitelist_audit_page() {
    local out="$ADIR/whitelist-audit.html"
    if [ ! -f "$FBASE/_white.tsv" ]; then rm -f "$out"; return 0; fi
    {
        html_head "Whitelist audit" "../assets/style.css" "" "ANALYSES" "whitelist-audit"
        printf '<h1>Whitelist audit</h1>\n'
        # SERVER-SEEN = an inbound connection (SRV) OR a server-log mention
        # (MEN = unknown/white.tsv) — the Cleanup backlog's rule too
        # (2026-09-29: this page ignored the mentions, the backlog the
        # connections, so the two disagreed on "Never seen")
        awk -F'\t' -v WHITE="$FBASE/_white.tsv" -v AW="$XREF/_accounts-white.tsv" \
            -v OBS="$TMPD/obsaddr.tsv" -v SRV="$TMPD/srvaddr.tsv" -v MEN="$DATA/unknown/white.tsv" '
            function e(s) { gsub(/&/, "\\&amp;", s); gsub(/</, "\\&lt;", s); gsub(/>/, "\\&gt;", s); gsub(/"/, "\\&quot;", s); return s }
            function padkey(v,   o) { if (v ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) { split(v, o, "."); return sprintf("%03d%03d%03d%03d", o[1], o[2], o[3], o[4]) } return toupper(v) }
            BEGIN {
                while ((getline l < WHITE) > 0) { split(l, a, "\t"); if (a[1] != "") { W[a[1]] = 1; WR[a[1]] = a[3] } } close(WHITE)
                while ((getline l < AW) > 0) { split(l, a, "\t"); if (a[2] != "") { WA[a[2]]++; AWPAIR[a[1], a[2]] = 1
                    if (WN[a[2]] == "") WN[a[2]] = a[1]; else if (WA[a[2]] <= 3) WN[a[2]] = WN[a[2]] ", " a[1] } } close(AW)
                while ((getline l < OBS) > 0) { split(l, a, "\t"); if (a[1] != "") { OF[a[1]] = a[2]; OL[a[1]] = a[3] } } close(OBS)
                while ((getline l < SRV) > 0) { split(l, a, "\t"); if (a[1] != "") SC[a[1]] = a[2] } close(SRV)
                while ((getline l < MEN) > 0) { split(l, a, "\t"); if (a[1] != "") MN[a[1]] = 1 } close(MEN)

                nw = 0; used = 0; conly = 0; never = 0
                for (ip in W) { nw++
                    f = OF[ip] + 0; c = SC[ip] + 0 + ((ip in MN) ? 1 : 0)
                    if (f > 0) used++
                    else if (c > 0) conly++
                    else never++
                }
                printf "<div><div class=\"stat\"><span class=\"stat-v\">%d</span><span class=\"stat-l\">Whitelisted IPs</span></div>", nw
                printf "<div class=\"stat stat-green\"><span class=\"stat-v\">%d</span><span class=\"stat-l\">Used (Files)</span></div>", used
                printf "<div class=\"stat\"><span class=\"stat-v\">%d</span><span class=\"stat-l\">Connect only</span></div>", conly
                printf "<div class=\"stat stat-red\"><span class=\"stat-v\">%d</span><span class=\"stat-l\">Never seen</span></div></div>\n", never

                # ACTIVE whitelisted addresses individually; the never-seen
                # bulk (the whitelist is the EXPANDED AllowIP list — CIDR
                # ranges exploded into thousands of members) aggregates per
                # allowing account below instead of drowning the page.
                printf "<h2>Active whitelisted addresses</h2>\n<div class=\"tablewrap\"><table class=\"fit\">\n"
                printf "<tr><th>IP</th><th>Allowing accounts</th><th class=\"num\">Files</th><th class=\"num\">Server contacts (in)</th><th>Last File</th><th>Verdict</th></tr>\n"
                n = 0; for (ip in W) if (OF[ip] + 0 > 0 || SC[ip] + 0 > 0 || (ip in MN)) KEY[++n] = padkey(ip) "\t" ip
                for (i = 1; i <= n; i++) { for (j = i + 1; j <= n; j++) if (KEY[j] < KEY[i]) { t2 = KEY[i]; KEY[i] = KEY[j]; KEY[j] = t2 } }
                if (n == 0) printf "<tr><td colspan=\"6\">No whitelisted address shows any activity.</td></tr>\n"
                for (i = 1; i <= n; i++) { split(KEY[i], kk, "\t"); ip = kk[2]
                    f = OF[ip] + 0; c = SC[ip] + 0
                    if (f > 0)      { v = "Used"; res = "green" }
                    else if (c > 0) { v = "Connects only — no Files"; res = "orange" }
                    else            { v = "Server-log mention only — no Files"; res = "orange" }
                    an = WA[ip] + 0
                    lbl = (an > 3) ? WN[ip] ", … (" an ")" : WN[ip]
                    printf "<tr data-res=\"%s\"><td class=\"mono\">%s</td><td>%s</td><td class=\"num\">%s</td><td class=\"num\">%s</td><td>%s</td><td>%s</td></tr>\n", \
                        res, e(ip), e(lbl), (f ? f : ""), (c ? c : ""), (OL[ip] != "" ? OL[ip] : "-"), v
                }
                printf "</table></div>\n"

                # whitelist bloat per allowing account: how much of each
                # account'\''s allowed set never connects at all
                printf "<h2>Unused whitelist entries per account</h2>\n<div class=\"tablewrap\"><table class=\"fit\">\n"
                printf "<tr><th>Account</th><th class=\"num\">Whitelisted IPs</th><th class=\"num\">Active</th><th class=\"num\">Never seen</th></tr>\n"
                m = 0
                for (k2 in AWPAIR) { split(k2, kk, SUBSEP); acct = kk[1]; ip = kk[2]
                    AT[acct]++
                    if (OF[ip] + 0 > 0 || SC[ip] + 0 > 0 || (ip in MN)) AU[acct]++
                }
                for (acct in AT) if (AT[acct] > AU[acct] + 0) BK2[++m] = sprintf("%08d", 99999999 - (AT[acct] - AU[acct])) "\t" acct
                for (i = 1; i <= m; i++) { for (j = i + 1; j <= m; j++) if (BK2[j] < BK2[i]) { t2 = BK2[i]; BK2[i] = BK2[j]; BK2[j] = t2 } }
                if (m == 0) printf "<tr><td colspan=\"4\">Every whitelisted address is active.</td></tr>\n"
                for (i = 1; i <= m; i++) { split(BK2[i], kk, "\t"); acct = kk[2]
                    u = AU[acct] + 0; res = (u == 0) ? "red" : "orange"
                    printf "<tr data-res=\"%s\"><td>%s</td><td class=\"num\">%d</td><td class=\"num\">%d</td><td class=\"num\">%d</td></tr>\n", \
                        res, e(acct), AT[acct], u, AT[acct] - u }
                printf "</table></div>\n"

                printf "<h2>Sources without a whitelist entry</h2>\n<div class=\"tablewrap\"><table class=\"fit\">\n"
                printf "<tr><th>Address</th><th class=\"num\">Files</th><th class=\"num\">Server contacts (in)</th><th>Last File</th></tr>\n"
                m = 0
                for (a2 in OF) if (!(a2 in W)) U[a2] = 1
                for (a2 in SC) if (!(a2 in W)) U[a2] = 1
                for (a2 in U) UK[++m] = padkey(a2) "\t" a2
                for (i = 1; i <= m; i++) { for (j = i + 1; j <= m; j++) if (UK[j] < UK[i]) { t2 = UK[i]; UK[i] = UK[j]; UK[j] = t2 } }
                if (m == 0) printf "<tr><td colspan=\"4\">Every observed inbound source address is whitelisted.</td></tr>\n"
                for (i = 1; i <= m; i++) { split(UK[i], kk, "\t"); a2 = kk[2]
                    printf "<tr><td class=\"mono\">%s</td><td class=\"num\">%s</td><td class=\"num\">%s</td><td>%s</td></tr>\n", \
                        e(a2), (OF[a2] ? OF[a2] : ""), (SC[a2] ? SC[a2] : ""), (OL[a2] != "" ? OL[a2] : "-") }
                printf "</table></div>\n"
            }
        ' /dev/null
        printf '</body>\n</html>\n'
    } > "$out"
}

# ---- 7. Config hygiene ------------------------------------------------------
write_config_hygiene_page() {
    local out="$ADIR/config-hygiene.html"
    if [ ! -f "$FBASE/_accounts.tsv" ]; then rm -f "$out"; return 0; fi
    {
        html_head "Config hygiene" "../assets/style.css" "" "ANALYSES" "config-hygiene"
        printf '<h1>Config hygiene</h1>\n'
        awk -F'\t' -v B="$FBASE" -v X="$XREF" -v DET="$TRPT/details" '
            function e(s) { gsub(/&/, "\\&amp;", s); gsub(/</, "\\&lt;", s); gsub(/>/, "\\&gt;", s); gsub(/"/, "\\&quot;", s); return s }
            function fold(s) { s = toupper(s); gsub(/_/, "-", s); return s }
            function loadbase(t, f,   l, a) { while ((getline l < f) > 0) { split(l, a, "\t")
                if (a[1] == "") continue
                N[t, ++CNT[t]] = a[1]; RES[t, a[1]] = a[3] } close(f) }
            function loadset(arr, f, col,   l, a) { while ((getline l < f) > 0) { split(l, a, "\t"); if (a[col] != "") arr[toupper(a[col])] = 1 } close(f) }
            function loadslugs(t, f,   l, a) { while ((getline l < f) > 0) { split(l, a, "\t"); if (a[1] != "") SL[t, toupper(a[1])] = a[2] } close(f) }
            function lnk(t, sd, name,   nm) { nm = e(name)
                if ((t, toupper(name)) in SL) return "<a href=\"../details/" sd "/" SL[t, toupper(name)] ".html\">" nm "</a>"
                return nm }
            function row(cat, t, sd, name, detail,   res) {
                res = RES[t, name]
                if (res != "green" && res != "orange" && res != "red") res = ""
                OUT[++NOUT] = "<tr" (res != "" ? " data-res=\"" res "\"" : "") "><td>" cat "</td><td class=\"cl\">" lnk(t, sd, name) "</td><td>" detail "</td></tr>"
                CATN[cat]++ }
            BEGIN {
                loadbase("acct", B "/_accounts.tsv");      loadslugs("acct", DET "/accounts/_slugmap.tsv")
                loadbase("sub",  B "/_subscriptions.tsv"); loadslugs("sub",  DET "/subscriptions/_slugmap.tsv")
                loadbase("login", B "/_logins.tsv");       loadslugs("login", DET "/logins/_slugmap.tsv")
                loadbase("host", B "/_hosts.tsv");         loadslugs("host", DET "/hosts/_slugmap.tsv")
                loadbase("white", B "/_white.tsv")
                loadset(HASSUB, X "/_accounts-subscriptions.tsv", 1)
                loadset(SUBHOST, X "/_hosts-subscriptions.tsv", 1)
                loadset(LOGACC, X "/_logins-accounts.tsv", 1)
                loadset(WHITEACC, X "/_white-accounts.tsv", 1)

                # orphans first — the twins list is long, so it goes last
                for (i = 1; i <= CNT["acct"]; i++) { nm = N["acct", i]
                    if (!(toupper(nm) in HASSUB)) row("Account without subscriptions", "acct", "accounts", nm, "no subscription references this account") }
                for (i = 1; i <= CNT["host"]; i++) { nm = N["host", i]
                    if (!(toupper(nm) in SUBHOST)) row("Host referenced by no subscription", "host", "hosts", nm, "configured endpoint, no subscription uses it") }
                for (i = 1; i <= CNT["login"]; i++) { nm = N["login", i]
                    if (!(toupper(nm) in LOGACC)) row("Login tied to no account", "login", "logins", nm, "no account pairs with this login") }
                for (i = 1; i <= CNT["white"]; i++) { nm = N["white", i]
                    if (!(toupper(nm) in WHITEACC)) row("Whitelist entry no account allows", "white", "", nm, "in the expanded whitelist but paired with no account") }
                # twins per type: same folded key, >1 spelling — subscriptions
                # before accounts, at the BOTTOM of the table
                split("sub:subscriptions:Subscription acct:accounts:Account login:logins:Login host:hosts:Host", TT, " ")
                for (z = 1; z <= 4; z++) { split(TT[z], tt, ":"); t = tt[1]; sd = tt[2]; lab = tt[3]
                    delete G; delete GN
                    for (i = 1; i <= CNT[t]; i++) { nm = N[t, i]; k2 = fold(nm)
                        G[k2]++; GN[k2] = GN[k2] (GN[k2] == "" ? "" : "\t") nm }
                    # the twin groups in KEY order (an insertion sort — a
                    # hash walk put them on the page in a different order per
                    # awk build)
                    delete KS; nks = 0
                    for (k2 in G) if (G[k2] > 1) KS[++nks] = k2
                    for (i = 2; i <= nks; i++) { v9 = KS[i]; for (j = i - 1; j >= 1 && KS[j] > v9; j--) KS[j + 1] = KS[j]; KS[j + 1] = v9 }
                    for (q9 = 1; q9 <= nks; q9++) { k2 = KS[q9]
                        ng = split(GN[k2], gg, "\t")
                        for (i = 1; i <= ng; i++) { twins = ""
                            for (j = 1; j <= ng; j++) if (j != i) twins = twins (twins == "" ? "" : ", ") e(gg[j])
                            row(lab " twins", t, sd, gg[i], "twin of " twins) } }
                }

                printf "<div>"
                printf "<div class=\"stat\"><span class=\"stat-v\">%d</span><span class=\"stat-l\">Findings</span></div>", NOUT+0
                printf "</div>\n"
                printf "<div class=\"tablewrap\"><table class=\"fit\">\n<tr><th>Category</th><th>Item</th><th>Detail</th></tr>\n"
                if (NOUT == 0) printf "<tr><td colspan=\"3\">No twins or orphans — the configuration is clean.</td></tr>\n"
                for (i = 1; i <= NOUT; i++) print OUT[i]
                printf "</table></div>\n"
            }
        ' /dev/null
        # ---- the SERVER-LOG defect families (2026-08 study E3) --------------
        # Rendered from the config-defects.tsv sidecar bin/server/reports/
        # config-defects.sh computes (compute there, render here). Transfer
        # profiles are PARSE-INTERNAL: plain text, no link, no entity KIND.
        local _cdf="$DATA/server/reports/config-defects.tsv"
        if [ -s "$_cdf" ]; then
            printf '<h2>Server-log config defects</h2>\n'
            awk -F'\t' -v DET="$TRPT/details" '
                function e(s) { gsub(/&/, "\\&amp;", s); gsub(/</, "\\&lt;", s); gsub(/>/, "\\&gt;", s); return s }
                function loadslugs(f,   l, a) { while ((getline l < f) > 0) { split(l, a, "\t"); if (a[1] != "") HSL[toupper(a[1])] = a[2] } close(f) }
                BEGIN { loadslugs(DET "/hosts/_slugmap.tsv") }
                $1 == "PROFILE" { np++; pr[np] = "<tr><td class=\"cl\"><span class=\"mono\">" e($2) "</span></td><td class=\"num\">" $3 "</td><td>" $4 "</td><td>" $5 "</td></tr>"; tp += $3 }
                $1 == "DNSDEAD" { nd++
                    h = e($2); if (toupper($2) in HSL) h = "<a href=\"../details/hosts/" HSL[toupper($2)] ".html\">" h "</a>"
                    dr[nd] = "<tr data-res=\"red\"><td class=\"cl\">" h "</td><td class=\"num\">" $3 "</td><td>" $4 "</td><td>" $5 "</td></tr>"; td += $3 }
                $1 == "TUNING"  { nt++; tr2[nt] = "<tr><td class=\"cl\"><span class=\"mono\">" e($2) "</span></td><td class=\"num\">" $3 "</td><td>" $4 "</td><td>" $5 "</td></tr>"; tt += $3 }
                END {
                    printf "<h3>Profiles that cannot receive</h3>\n<div class=\"tablewrap\"><table class=\"fit\">\n<tr><th>Transfer profile</th><th class=\"num\">Errors</th><th>First</th><th>Last</th></tr>\n"
                    for (i = 1; i <= np; i++) print pr[i]
                    if (np == 0) print "<tr><td colspan=\"4\">None in this window.</td></tr>"
                    printf "<tr class=\"total\"><td>Total (%d profile(s))</td><td class=\"num\">%d</td><td></td><td></td></tr>\n</table></div>\n", np+0, tp+0
                    printf "<h3>DNS-dead configured hosts</h3>\n<div class=\"tablewrap\"><table class=\"fit\">\n<tr><th>Host</th><th class=\"num\">Failed lookups</th><th>First</th><th>Last</th></tr>\n"
                    for (i = 1; i <= nd; i++) print dr[i]
                    if (nd == 0) print "<tr><td colspan=\"4\">None in this window.</td></tr>"
                    printf "<tr class=\"total\"><td>Total (%d host(s))</td><td class=\"num\">%d</td><td></td><td></td></tr>\n</table></div>\n", nd+0, td+0
                    printf "<h3>Server tuning warnings</h3>\n<div class=\"tablewrap\"><table class=\"fit\">\n<tr><th>Setting</th><th class=\"num\">Warnings</th><th>First</th><th>Last</th></tr>\n"
                    for (i = 1; i <= nt; i++) print tr2[i]
                    if (nt == 0) print "<tr><td colspan=\"4\">None in this window.</td></tr>"
                    printf "<tr class=\"total\"><td>Total (%d setting(s))</td><td class=\"num\">%d</td><td></td><td></td></tr>\n</table></div>\n", nt+0, tt+0
                }
            ' "$_cdf"
        fi
        emit_double_sections   # 2026-07: the former Double page, folded in (one name, two roles)
        printf '</body>\n</html>\n'
    } > "$out"
}

# ---- 7b. Double — one name, two roles ---------------------------------------
# Names configured as BOTH an application and a partner (the logical-based
# PDA derivation legitimately creates both: a relay's counterparty token is
# the middle part of one logical flow name and the last part of another —
# the internal system of one flow IS the external party of the other),
# plus the subscriptions whose config connects them to TWO partner groups
# (rarer under the logical derivation — a subscription usually carries one
# FlowID — so an empty second table is normal).
# 2026-07: folded into the Config hygiene page (both are configuration smells);
# emits the two Double sections to stdout, called by write_config_hygiene_page.
emit_double_sections() {
    if [ ! -f "$FBASE/_apps.tsv" ] || [ ! -f "$FBASE/_partners.tsv" ]; then return 0; fi
    # names configured as both (case-folded intersection of the two base lists)
    local dbl="$TMPD/double-names.txt"
    LC_ALL=C comm -12 <(cut -f1 "$FBASE/_apps.tsv" | tr '[:lower:]' '[:upper:]' | LC_ALL=C sort -u) \
             <(cut -f1 "$FBASE/_partners.tsv" | tr '[:lower:]' '[:upper:]' | LC_ALL=C sort -u) > "$dbl"
    # subscriptions mapped to MORE than one partner group (xref, pairs deduped)
    local msub="$TMPD/double-subs.tsv"
    if [ -f "$XREF/_subscriptions-partners.tsv" ]; then
        LC_ALL=C awk -F'\t' '!seen[$1 SUBSEP $2]++ { c[$1]++; p[$1] = p[$1] "\037" $2 }
            END { for (s in c) if (c[s] > 1) printf "%s\t%s\n", s, substr(p[s], 2) }' \
            "$XREF/_subscriptions-partners.tsv" | LC_ALL=C sort > "$msub"
    else
        : > "$msub"
    fi
    printf '<h2>Double &mdash; one name, two roles</h2>\n'
    {
        awk -F'\t' -v B="$FBASE" -v X="$XREF" -v DET="$TRPT/details" '
            function e(s) { gsub(/&/, "\\&amp;", s); gsub(/</, "\\&lt;", s); gsub(/>/, "\\&gt;", s); gsub(/"/, "\\&quot;", s); return s }
            function loadbase(t, f,   l, a) { while ((getline l < f) > 0) { split(l, a, "\t")
                if (a[1] == "") continue
                NM[t, toupper(a[1])] = a[1]; RES[t, toupper(a[1])] = a[3] } close(f) }
            function loadslugs(t, f,   l, a) { while ((getline l < f) > 0) { split(l, a, "\t"); if (a[1] != "") SL[t, toupper(a[1])] = a[2] } close(f) }
            function loadpairs(arr, f, tag,   l, a, k) { while ((getline l < f) > 0) { split(l, a, "\t")
                if (a[1] == "" || a[2] == "") continue
                k = toupper(a[1])
                if (!((tag, k, a[2]) in PSEEN)) { PSEEN[tag, k, a[2]] = 1; arr[k] = arr[k] (arr[k] == "" ? "" : "\037") a[2] } } close(f) }
            function resc(r) { return (r == "green" || r == "orange" || r == "red") ? " res-" r : "" }
            function alnk(name,   nm) { nm = e(name)
                if (("acct", toupper(name)) in SL) return "<a href=\"../details/accounts/" SL["acct", toupper(name)] ".html\">" nm "</a>"
                return nm }
            function accell(list,   n, i, a, o) { n = split(list, a, "\037"); o = ""
                for (i = 1; i <= n; i++) o = o (o == "" ? "" : ", ") alnk(a[i])
                return o == "" ? "&mdash;" : o }
            BEGIN {
                # ptn: the display spelling (NM) + the table-2 partner links;
                # sub: the table-2 subscription cell. The _apps base list and
                # the applications slugmap went with the role columns (2026-07)
                loadbase("ptn", B "/_partners.tsv");  loadslugs("ptn", DET "/partners/_slugmap.tsv")
                loadbase("sub", B "/_subscriptions.tsv"); loadslugs("sub", DET "/subscriptions/_slugmap.tsv")
                loadslugs("acct", DET "/accounts/_slugmap.tsv")
                loadpairs(PACC, X "/_partners-accounts.tsv", "p")
                loadpairs(AACC, X "/_apps-accounts.tsv", "a")
            }
            FILENAME ~ /double-names/ && NF {
                u = $1
                R1[++n1] = "<tr><td>" e(NM["ptn", u] != "" ? NM["ptn", u] : u) "</td>" \
                    "<td>" accell(PACC[u]) "</td>" \
                    "<td>" accell(AACC[u]) "</td></tr>"
                next
            }
            FILENAME ~ /double-subs/ && NF {
                u = toupper($1)
                pl = ""; np = split($2, pp, "\037")
                for (i = 1; i <= np; i++) { pn = toupper(pp[i])
                    l2 = e(pp[i])
                    if (("ptn", pn) in SL) l2 = "<a href=\"../details/partners/" SL["ptn", pn] ".html\">" l2 "</a>"
                    pl = pl (pl == "" ? "" : ", ") l2 }
                sc = ""
                if (("sub", u) in SL) sc = "<td class=\"cl" resc(RES["sub", u]) "\"><a href=\"../details/subscriptions/" SL["sub", u] ".html\">" e($1) "</a></td>"
                else sc = "<td class=\"" substr(resc(RES["sub", u]), 2) "\">" e($1) "</td>"
                R2[++n2] = "<tr>" sc "<td>" pl "</td></tr>"
                next
            }
            END {
                printf "<div>"
                printf "<div class=\"stat\"><span class=\"stat-v\">%d</span><span class=\"stat-l\">Names with both roles</span></div>", n1+0
                printf "<div class=\"stat\"><span class=\"stat-v\">%d</span><span class=\"stat-l\">Subscriptions with two partners</span></div>", n2+0
                printf "</div>\n"
                printf "<h2>Application and partner sharing one name</h2>\n"
                printf "<div class=\"tablewrap\"><table class=\"fit\">\n"
                printf "<tr><th>Name</th><th>Partner accounts</th><th>Application accounts</th></tr>\n"
                if (n1 == 0) printf "<tr><td colspan=\"3\">No name is configured as both an application and a partner.</td></tr>\n"
                for (i = 1; i <= n1; i++) print R1[i]
                printf "</table></div>\n"
                printf "<h2>Subscriptions connected to two partners</h2>\n"
                printf "<div class=\"tablewrap\"><table class=\"fit\">\n"
                printf "<tr><th>Subscription</th><th>Partners</th></tr>\n"
                if (n2 == 0) printf "<tr><td colspan=\"2\">No subscription connects to more than one partner group.</td></tr>\n"
                for (i = 1; i <= n2; i++) print R2[i]
                printf "</table></div>\n"
            }
        ' "$dbl" "$msub"
    }
}


# ---- 9. Subscriptions in boxes ----------------------------------------------
# One row per CONFIGURED subscription — the whole estate, not a problem list —
# with one column per box saying what is true of it. The boxes come from three
# kinds of source: a report's
# own .rpt, columns derived here from _files.tsv (One-legged, Waiting,
# Expired), and the config/coverage caches, which have no report at all
# (Not seen, Seen, OK, Error). _subs_box_rows below is the ONE authority
# for the box list — count there, not here.
# A cell names its box and links into it with ?axway_search=<name>, so a page
# with a search box arrives filtered. Its OWN analyses group (menu line, index
# section, sitemap card), which it LEADS as the group's overview. A missing
# source .rpt (production skips some server reports) contributes no rows,
# leaving that column empty — and report.js then hides it.
# Missing cron reads the pageless missing-cronjobs.rpt like any report-backed
# column (the Polling page shows those rows as Schedule "no cron").
# _subs_box_rows -> "<colno>\t<subscription>" for every box, one line per
# (box, subscription). (The Accounts in boxes page that shared it went
# 2026-09-29.)
# endk() — a _files.tsv row's END (col 24, "YYYY-MM-DD HH:MM:SS.mmm") in the
# col 6 sortkey shape "YYYYMMDDHH:MM:SS.mmm", the start sortkey when the parse
# wrote no end: "an OK File after it" means one that ENDED after it, the
# 2026-09-12 rule result.sh applies (a retry burst that started before the
# error and delivered after it is a recovery). Shared by every box below.
ENDK_AWK='
    function endk(   e) { e = $24; return (e ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] /) ? substr(e, 1, 4) substr(e, 6, 2) substr(e, 9, 2) substr(e, 12) : $6 }
'
_subs_box_rows() {
    local spec f c nf
        # column 1 — One-legged, REFINED (2026-07): a one-legged CoreId is only
        # a problem when NO OK File followed it — an OK delivery after the last
        # one-legged occurrence means the flow recovered. Computed from
        # _files.tsv directly (pirates' own condition is col 10 == 1, so the
        # membership can only shrink, never disagree with pirates-details);
        # the cache carries full sortkeys, so "after" is exact, not per-day.
        # OK = not Failed/Expired (the site-wide rule: Waiting counts as OK),
        # and "after" means the OK File ENDED after it (col 24, the 2026-09-12
        # rule result.sh applies — endk() puts that end in the sortkey shape;
        # the start when the parse wrote no end).
        # columns 5 + 6 — Waiting / Expired: the subscription's LAST _files
        # entry (max sortkey; the later row wins a tie, as in result.sh) has
        # that outcome — the newest staged file is still awaiting pickup (5)
        # or was deleted before any pickup (6).
        if [ -f "$FILESC" ]; then
            awk -F'\t' "$ENDK_AWK"'
                $12 == "" || $12 == "Unknown" { next }   # "Unknown" = no subscription (2026-09-29): in no box
                {
                    if (!(($12) in ls)) orda[++na] = $12
                    if ($6 >= ls[$12]) { ls[$12] = $6; lout[$12] = $2 }
                    if ($10 == 1) { if (!(($12) in lp)) ord[++n] = $12; if ($6 > lp[$12]) lp[$12] = $6 }
                    if ($2 != "Failed" && $2 != "Expired") { ek = endk(); if (ek > lo[$12]) lo[$12] = ek }
                }
                END {
                    for (i = 1; i <= n; i++) { s = ord[i]
                        if (lo[s] == "" || lo[s] <= lp[s]) print "1\t" s }
                    for (i = 1; i <= na; i++) { s = orda[i]
                        if (lout[s] == "Waiting") print "5\t" s
                        else if (lout[s] == "Expired") print "6\t" s }
                }' "$FILESC"
        fi
        # colno : rpt : page href (analyses-relative) : column label : ROW field
        # holding the subscription name (no-remote-dir leads with its Last date)
        for spec in \
            "2:$TRPT/from-green-to-red.rpt:failed.html:From green to red:2" \
            "3:$SRPT/went-kaput.rpt:-:Trouble after success:2" \
            "4:$TRPT/only-red.rpt:failed.html:Only red:2" \
            "7:$SRPT/no-remote-dir.rpt:uc-status-uc3.html:No Dir:3" \
            "8:$SRPT/no-remote-files.rpt:uc-status-uc3.html:No Files:3" \
            "9:$TRPT/missing-cronjobs.rpt:polling.html:Missing cron:2" \
            "10:$TRPT/went-quiet.rpt:../transfer/went-quiet-subscriptions.html:Went quiet:2"; do
            c=${spec%%:*}; f=${spec#*:}; f=${f%%:*}; nf=${spec##*:}
            [ -f "$f" ] || continue
            # table 1 only; skip empty-state colspan rows and pseudo-values —
            # a real subscription name never contains a space (which also drops
            # no-remote-dir's "Clone - UC3_…" config artifacts)
            awk -F'\t' -v c="$c" -v nf="$nf" '
                $1 == "TABLE" { t++ }
                $1 == "ROW" && t == 1 {
                    if ($2 ~ /^@\{colspan/) next
                    nm = $nf; sub(/^@\{[^}]*\}/, "", nm)
                    if (nm == "" || nm ~ / / || substr(nm, 1, 1) == "(") next
                    print c "\t" nm
                }' "$f"
        done
        # column 11 has NO report of its own — it is a state, read straight from
        # the source the Entities views are built from, so the figures here and
        # there cannot drift:
        #   11 not seen — showseen's coverage TSV, col 3 = the seen flag.
        [ -f "$TRPT/coverage/subscriptions.tsv" ] && \
            awk -F'\t' '$1 != "" && $3 == 0 { print "11\t" $1 }' "$TRPT/coverage/subscriptions.tsv"
        #   13 OK — result "green": the newest File was delivered. Also no report;
        #      the Subscriptions / OK entity view is the list. Including it is what
        #      turns this from a problem list into a complete box-up of the estate,
        #      so the first box can honestly say TOTAL.
        [ -f "$FBASE/_subscriptions.tsv" ] && \
            awk -F'\t' '$1 != "" && $3 == "green" { print "13\t" $1 }' "$FBASE/_subscriptions.tsv"
        #   17 seen — coverage col 3 != 0, the exact complement of 11. The
        #      Subscriptions / Seen entity view is the list, and the invariant
        #      is Seen + Not seen = Total.
        #   18 error — result "red": its newest File Failed, or a server-log
        #      Error after its last transfer, or (a UC3 that never transferred)
        #      three failed connection attempts in a row — never merely an
        #      Expired newest File, which is orange. The Subscriptions / Error
        #      entity view is the list.
        [ -f "$TRPT/coverage/subscriptions.tsv" ] && \
            awk -F'\t' '$1 != "" && $3 != 0 { print "17\t" $1 }' "$TRPT/coverage/subscriptions.tsv"
        [ -f "$FBASE/_subscriptions.tsv" ] && \
            awk -F'\t' '$1 != "" && $3 == "red" { print "18\t" $1 }' "$FBASE/_subscriptions.tsv"
        # column 14 — Connection failures, UNRESOLVED (the One-legged rule): the
        # server logged a connection failure for this subscription and NO OK File
        # followed it. A flow whose connections failed and then delivered has
        # recovered; site-failures keeps the full history either way. The filter
        # is what makes the column mean "still broken". "Followed" = the OK
        # File ENDED after the failure (col 24 — result.sh's rule; endk()).
        # The failure instant comes from the @data:loglines payload (newest
        # first, so entry 1 is the latest) rather than the row's Last seen DATE,
        # which is too coarse to order against an OK File on the same day; a row
        # without the payload falls back to that date at END of day, so only an
        # OK on a LATER day clears it — the conservative reading, since wrongly
        # clearing hides a live problem while wrongly flagging only costs a look.
        if [ -f "$SRPT/site-failures.rpt" ] && [ -f "$FILESC" ]; then
            awk -F'\t' "$ENDK_AWK"'
                FILENAME ~ /site-failures/ {
                    if ($1 == "TABLE") { t++; next }
                    if ($1 != "ROW" || t != 1) next
                    nm = $2; sub(/^@\{[^}]*\}/, "", nm); if (nm == "") next
                    key = ""
                    for (i = 3; i <= NF; i++)
                        if (index($i, "@data:loglines=") == 1) {
                            split(substr($i, 16), L, "\037"); s = L[1]
                            if (s ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] /) {
                                d = substr(s, 1, 10); gsub(/-/, "", d); key = d substr(s, 12, 12)
                            }
                            break
                        }
                    if (key == "" && $6 ~ /^[0-9]/) { d = $6; gsub(/-/, "", d); key = d "23:59:59.999" }
                    if (key != "") cf[nm] = key
                    next
                }
                { if ($12 != "" && $2 != "Failed" && $2 != "Expired") { ek = endk(); if (ek > lok[$12]) lok[$12] = ek } }
                END { for (s in cf) if (lok[s] == "" || lok[s] < cf[s]) print "14\t" s }
            ' "$SRPT/site-failures.rpt" "$FILESC"
        fi
        # columns 20 / 21 — Login errors (in / out), UNRESOLVED (2026-08): the
        # Logons report's failure rows joined onto subscriptions — in: the
        # login's Disallowed/Bad key/Key failures/Locked funnel counts, via
        # _logins-subscriptions; out: the remote host's outbound auth
        # failures, via _hosts-subscriptions. The one-legged rule applies: an
        # OK File AFTER the last error clears the flag. The out side takes its
        # instant from the newest loglines entry (falling back to the Last
        # date at end of day); the in side has only per-DATE funnel buckets
        # (metrics m2/m4/m5/m6 = Disallowed/Bad key/Key failures/Locked), so
        # the error date counts as end-of-day — only a LATER day's OK clears.
        if [ -f "$SRPT/logon.rpt" ] && [ -f "$FILESC" ]; then
            awk -F'\t' -v LS="$XREF/_logins-subscriptions.tsv" "$ENDK_AWK"'
                BEGIN { while ((getline l < LS) > 0) { n = split(l, a, "\t")
                            if (n >= 2 && a[1] != "") SUBS[toupper(a[1])] = SUBS[toupper(a[1])] "\037" a[2] }
                        close(LS) }
                FILENAME ~ /logon\.rpt/ {
                    if ($1 == "TABLE") { t++; next }
                    if ($1 != "ROW" || t != 1) next
                    nm = $2; sub(/^@\{[^}]*\}/, "", nm); if (nm == "") next
                    if (($4+0) + ($7+0) + ($8+0) + ($9+0) == 0) next
                    led = ""
                    for (i = 3; i <= NF; i++) if (index($i, "@data:buckets=") == 1) {
                        nb = split(substr($i, 15), B, ",")
                        for (j = 1; j <= nb; j++) { split(B[j], M, ":")
                            if ((M[4]+0) + (M[6]+0) + (M[7]+0) + (M[8]+0) > 0 && M[1] > led) led = M[1] }
                        break }
                    if (led == "") next
                    key = led; gsub(/-/, "", key); key = key "23:59:59.999"
                    ku = toupper(nm)
                    if (ku in SUBS) { m2 = split(substr(SUBS[ku], 2), S2, "\037")
                        for (i2 = 1; i2 <= m2; i2++) if (S2[i2] != "" && (!(S2[i2] in ce) || key > ce[S2[i2]])) ce[S2[i2]] = key }
                    next
                }
                { if ($12 != "" && $2 != "Failed" && $2 != "Expired") { ek = endk(); if (ek > lok[$12]) lok[$12] = ek } }
                END { for (s in ce) if (lok[s] == "" || lok[s] < ce[s]) print "20\t" s }
            ' "$SRPT/logon.rpt" "$FILESC"
            awk -F'\t' -v HS="$XREF/_hosts-subscriptions.tsv" "$ENDK_AWK"'
                BEGIN { while ((getline l < HS) > 0) { n = split(l, a, "\t")
                            if (n >= 2 && a[1] != "") SUBS[tolower(a[1])] = SUBS[tolower(a[1])] "\037" a[2] }
                        close(HS) }
                FILENAME ~ /logon\.rpt/ {
                    if ($1 == "TABLE") { t++; next }
                    if ($1 != "ROW" || t != 2) next
                    h = $2; sub(/^@\{[^}]*\}/, "", h); if (h == "") next
                    key = ""
                    for (i = 3; i <= NF; i++) if (index($i, "@data:loglines=") == 1) {
                        split(substr($i, 16), L, "\037"); s = L[1]
                        if (s ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] /) {
                            d = substr(s, 1, 10); gsub(/-/, "", d); key = d substr(s, 12, 12) }
                        break }
                    if (key == "" && $11 ~ /^[0-9]/) { d = $11; gsub(/-/, "", d); key = d "23:59:59.999" }   # Last ($11; $10 is First — 2026-09-29 fix)
                    if (key == "") next
                    hu = tolower(h)
                    if (hu in SUBS) { m2 = split(substr(SUBS[hu], 2), S2, "\037")
                        for (i2 = 1; i2 <= m2; i2++) if (S2[i2] != "" && (!(S2[i2] in ce) || key > ce[S2[i2]])) ce[S2[i2]] = key }
                    next
                }
                { if ($12 != "" && $2 != "Failed" && $2 != "Expired") { ek = endk(); if (ek > lok[$12]) lok[$12] = ek } }
                END { for (s in ce) if (lok[s] == "" || lok[s] < ce[s]) print "21\t" s }
            ' "$SRPT/logon.rpt" "$FILESC"
        fi
        # (column 12 "Server log only" and column 19 "Failing polls" were the
        # blue result and the UC3 "server - error" status, both removed
        # 2026-09-27; their numbers stay unused so no box id changes meaning.)
        # column 15 — Deploy: the server told SecureTransport to ABANDON the
        # route (deploy-errors.rpt, ARSP0001 "stop further route execution").
        # That report already drops anything that recovered, so this box
        # inherits the UNRESOLVED reading like column 14. Its rows name an
        # ACCOUNT or a SUBSCRIPTION, so a subscription is flagged when it is
        # named directly OR when one of its configured accounts is — and, for
        # the account case, only when the flow itself has NOT moved a file OK
        # (ENDED, col 24) after the row's last message (2026-08-31 audit: box
        # 15 is the top-ranked Reason, and an account row fanned onto every
        # flow of a hybrid account put its healthy siblings in the red Deploy
        # box).
        if [ -f "$SRPT/deploy-errors.rpt" ]; then
            _fc15="$FILESC"; [ -f "$_fc15" ] || _fc15=/dev/null
            awk -F'\t' -v AS="$XREF/_accounts-subscriptions.tsv" -v SUBF="$FBASE/_subscriptions.tsv" -v FC="$_fc15" "$ENDK_AWK"'
                BEGIN { while ((getline l < AS) > 0) { n = split(l, a, "\t")
                            if (n >= 2 && a[1] != "") ASUB[toupper(a[1])] = ASUB[toupper(a[1])] "\037" a[2] }
                        close(AS)
                        while ((getline l < SUBF) > 0) { split(l, a, "\t")
                            if (a[1] != "") EST[toupper(a[1])] = 1 }
                        close(SUBF) }
                FILENAME == FC { if ($12 != "" && $2 != "Failed" && $2 != "Expired") { ek = endk(); if (ek > lok[toupper($12)]) lok[toupper($12)] = ek }; next }
                $1 == "TABLE" { t++; next }
                $1 != "ROW" || t != 1 { next }
                { nm = $2; sub(/^@\{[^}]*\}/, "", nm); if (nm == "") next
                  k = toupper(nm)
                  # a "Subscription" name NOT in the configured estate would add
                  # a phantom row (the table rows are the union of the box
                  # lists) — send it through the account map instead.
                  if ($3 == "Subscription" && (k in EST)) { print "15\t" nm; next }
                  # the row Last message (col 6, "YYYY-MM-DD HH:MM:SS.mmm") in the
                  # _files.tsv sortkey shape; a flow with an OK File after it has recovered
                  key = $6; if (key ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] /) key = substr(key, 1, 4) substr(key, 6, 2) substr(key, 9, 2) substr(key, 12); else key = ""
                  if (k in ASUB) { m = split(substr(ASUB[k], 2), S, "\037")
                                   for (i = 1; i <= m; i++) if (S[i] != "" && (key == "" || lok[toupper(S[i])] == "" || lok[toupper(S[i])] < key)) print "15\t" S[i] } }
            ' "$_fc15" "$SRPT/deploy-errors.rpt"
        fi
        :   # the tests above are the last commands; keep the exit status 0
}

# The "main reason" sidecar (2026-08): data/analyses/reports/
# _subs-boxes.tsv, "subscription <TAB> box label" — ONE line per subscription,
# naming the most specific box it sits in. The Entities Subscriptions Error
# view (publish_lib.sh) and failed.sh's server rows fall back to it for their
# Reason, so a red flow says WHY in the same vocabulary this page uses. Membership comes from _subs_box_rows (the one authority); the
# order below is the only thing decided here — most specific cause first.
# Boxes that are states rather than a cause are left out entirely: OK, Seen,
# Not seen, and — deliberately — ERROR, box 18. "Error" only
# restates the red the row is already painted in, so it is not a reason.
# The two ORANGE boxes that describe a MOOD rather than a fault are out for the
# same reason: "Trouble after success" says only that something was logged, and
# "Went quiet" that nothing was — neither tells you what broke, and both would
# outrank nothing on a row that is already red. RED boxes therefore come first
# in the order, the remaining orange ones (a missing cron, an empty remote dir,
# a file waiting for pickup) only after them.
# A red flow in NO box at all is red by SERVER-LOG evidence — the after-last-
# transfer flip — so its reason comes from that evidence instead: _flip_reason()
# reads the Trouble-after-Success report, which carries the very line that
# reddened it, and names the fault. Where the line matches a red box the box
# name is used; the remaining causes are phrased like the deploy-errors Cause
# column, which is the same kind of short verdict.
# The DEPLOY box is refined one level further, because that box holds two
# unrelated defects and the report already tells them apart: its label becomes
# the deploy-errors Cause — "Route stopped" or "Receive File As not set".
_box_reason_order() {
    printf '%s\n' \
        "1${TAB}15${TAB}Deploy" \
        "2${TAB}7${TAB}No Dir" \
        "3${TAB}14${TAB}Connection failures" \
        "4${TAB}21${TAB}Login errors (out)" \
        "5${TAB}20${TAB}Login errors (in)" \
        "6${TAB}1${TAB}One-legged" \
        "7${TAB}6${TAB}Expired" \
        "8${TAB}4${TAB}Only red" \
        "9${TAB}2${TAB}From green to red" \
        "10${TAB}9${TAB}Missing cron" \
        "11${TAB}8${TAB}No Files" \
        "12${TAB}5${TAB}Waiting"
}
# The evidence classifier for a red-by-server-log flow (see above). Input: the
# newest Error/Warn line that flipped it. Output: a short cause in the boxes'
# vocabulary, or "" when the line says nothing recognisable — better a blank
# cell than a guess. The function TEXT lives in bin/flip-reason.awk (2026-08):
# failed.sh classifies its Reason column with the same function, and the
# two must never drift apart — the Entities Reason and the Failed Subscriptions
# page's Reason are the same verdict about the same evidence.
_flip_reason_awk() {
    cat "$SCRIPT_DIR/../flip-reason.awk"
}
_write_box_reason_sidecar() {   # $1 = the _subs_box_rows output
    local TAB; TAB=$(printf '\t')
    local side="$DATA/analyses/reports/_subs-boxes.tsv" tmpp
    mkdir -p "$(dirname "$side")"
    tmpp=$(mktemp "${TMPDIR:-/tmp}/axboxprio.XXXXXX")
    _box_reason_order > "$tmpp"
    local dep="$SRPT/deploy-errors.rpt"; [ -f "$dep" ] || dep=/dev/null
    local asx="$XREF/_accounts-subscriptions.tsv"; [ -f "$asx" ] || asx=/dev/null
    # the Trouble-after-Success EVIDENCE sidecar (name, latest issue, source,
    # message) — every subscription with post-transfer errors, red ones
    # included; its report page lists the still-green half only
    local srvsub="$DATA/server/cache/subscriptions"
    local kap="$SRPT/_kaput-evidence.tsv"; [ -f "$kap" ] || kap=/dev/null
    # a SECOND evidence source, same layout: the newest Error/Warning line the
    # flow's own drill pages show (bin/transfer/reports/failed.sh). The
    # kaput sidecar only covers flows whose last transfer was OK, so a flow that
    # is red BY ITS OWN last file and sits in no specific box has no reason
    # without this — though its error page names the fault.
    local epv="$TRPT/_errpage-evidence.tsv"; [ -f "$epv" ] || epv=/dev/null
    printf '%s\n' "$1" | awk -F'\t' -v P="$tmpp" -v DEP="$dep" -v ASX="$asx" -v KAP="$kap" -v EPV="$epv" -v SRVSUB="$srvsub" "$(_flip_reason_awk)"'
        BEGIN { while ((getline l < P) > 0) { n = split(l, a, "\t")
                    if (n >= 3) { rank[a[2]] = a[1]; lab[a[2]] = a[3] } }
                close(P)
                # the two DEPLOY causes, keyed per subscription: the report row
                # names a subscription (its own cause, which always wins) or an
                # account (the cause carries to every subscription configured
                # for it — box 15 flags them the same way). Rows arrive most
                # frequent first, so the first account cause reaching a
                # subscription is the loudest one.
                while ((getline l < ASX) > 0) { n = split(l, a, "\t")
                    if (n >= 2 && a[1] != "") AS[toupper(a[1])] = AS[toupper(a[1])] "\037" a[2] }
                close(ASX)
                t = 0
                while ((getline l < DEP) > 0) { n = split(l, a, "\t")
                    if (a[1] == "TABLE") { t++; continue }
                    if (a[1] != "ROW" || t != 1 || n < 4) continue
                    nm = a[2]; sub(/^@\{[^}]*\}/, "", nm); if (nm == "" || a[4] == "") continue
                    if (a[3] == "Subscription") { DC[toupper(nm)] = a[4]; own[toupper(nm)] = 1; continue }
                    k = toupper(nm)
                    if (k in AS) { m = split(substr(AS[k], 2), S, "\037")
                        for (i = 1; i <= m; i++) if (S[i] != "" && !(toupper(S[i]) in own) && DC[toupper(S[i])] == "")
                            DC[toupper(S[i])] = a[4] } }
                close(DEP)
                # the server-log evidence per subscription: the newest
                # Error/Warn line after the last OK transfer, which is exactly
                # the line the red flip acted on (col 4 of the sidecar)
                while ((getline l < KAP) > 0) { n = split(l, a, "\t")
                    if (n >= 4 && a[1] != "") { EV[toupper(a[1])] = a[4]
                        if (n >= 5) EVE[toupper(a[1])] = a[5] } }   # newest E-level line
                close(KAP)
                # The error pages, NEWEST LAST as the file is sorted by stamp:
                # keep them as an ordered candidate list per flow so the reason
                # can walk them newest-first and take the first that classifies.
                # The newest line of a burst is often the least informative
                # ("… - Failed to create connection" beside the "Connection
                # failure while <flow> tried to connect …" that explains it).
                while ((getline l < EPV) > 0) { n = split(l, a, "\t")
                    if (n >= 4 && a[1] != "") { k2 = toupper(a[1])
                        EPN[k2]++; EPM[k2, EPN[k2]] = a[4]; EPL[k2, EPN[k2]] = a[3] } }
                close(EPV) }
        # The FIRST classification the error page yields, reading from the
        # START: the opening error of a failure is the cause and everything
        # after it is consequence — a rejected host key, then "failed to create
        # connection", then the connection failure, then a trailing ARRC0029
        # "No files were processed during step execution". ERROR lines before
        # warnings, each in page order (the sidecar stores them oldest first).
        function pagereason(nm3,   k3, i, r3) {
            k3 = toupper(nm3)
            for (i = 1; i <= EPN[k3]; i++) if (EPL[k3, i] == "Error") { r3 = flip_reason(EPM[k3, i]); if (r3 != "") return r3 }
            for (i = 1; i <= EPN[k3]; i++) if (EPL[k3, i] != "Error") { r3 = flip_reason(EPM[k3, i]); if (r3 != "") return r3 }
            return "" }
        # the newest Error/Warn line the flow logged for itself ("" when it has
        # no ring); the rings are newest-first, so line 1 is it
        function ringtop(nm2,   f, l2, a2) {
            f = SRVSUB "/" nm2 "_err_warn.tsv"
            if ((getline l2 < f) > 0) { close(f); split(l2, a2, "\t"); return a2[5] }
            close(f); return "" }
        # the Deploy label is replaced by the CAUSE behind it; a deploy row we
        # cannot attribute keeps the box name
        function label(box, nm2,   c) {   # nm2: "sub" is an awk BUILT-IN name
            if (box != 15) return lab[box]
            c = DC[toupper(nm2)]
            return (c != "") ? c : lab[box] }
        # every subscription the boxes named at all, box or not: the ones with
        # no ranked box are the candidates for the evidence reason. LB[] keeps
        # every label a flow qualifies for, so the END block can let RECENCY
        # choose between them.
        $2 != "" { all[$2] = 1 }
        $2 != "" && ($1 in rank) {
            lb = label($1, $2)
            LB[$2] = LB[$2] "\037" lb "\037"
            if (!($2 in best) || rank[$1] + 0 < best[$2] + 0) { best[$2] = rank[$1]; bl[$2] = lb } }
        END { for (s in all) {
                  # THE SERVER LOG ON ITS OWN ERROR PAGE COMES FIRST (2026-08).
                  # For a flow with a failed File, the page its Failed Subscriptions row opens
                  # is the evidence a reader will check, so the Reason has to be
                  # what that page says — not a box the flow also happens to
                  # sit in.
                  pr = pagereason(s)
                  if (pr != "") { print s "\t" pr; continue }
                  # THEN THE NEWEST LINE ACROSS THE FLOW\047S CONNECTED RINGS
                  # (the kaput evidence: subscription, account, login, and the
                  # single configured host). A box is a rank, not a clock — a
                  # flow with an old route-stop in the Deploy box and a
                  # connection failure from this week read "Route stopped"
                  # while the log had moved on (UC1_ZG_IKAZ_IMPRESS, 2026-08).
                  # The reason is descriptive, not a verdict: the COLOUR still
                  # never rests on a line attributed to no flow.
                  # newest ERROR first; the newest line of any level only when
                  # no error followed at all — a benign warning that happens to
                  # be newer must not outrank the error that explains the red
                  kr = flip_reason(EVE[toupper(s)])
                  if (kr == "") kr = flip_reason(EV[toupper(s)])
                  if (kr != "") { print s "\t" kr; continue }
                  # boxes are the source for everything else
                  if (s in best) {
                      # A flow can sit in several CAUSE boxes at once, and the
                      # fixed order then picks the most specific — which is not
                      # always the CURRENT one: a flow with an old route-stop
                      # and a connection failure from this morning read "Route
                      # stopped" while its log said otherwise. Where the flow
                      # own newest Error/Warn line classifies to a box it is
                      # ALSO in, that wins: same vocabulary, same membership
                      # rules, but the reason now names what the log last said.
                      nl = flip_reason(ringtop(s))
                      if (nl != "" && index(LB[s], "\037" nl "\037") > 0) print s "\t" nl
                      else print s "\t" bl[s]
                      continue }
                  r = flip_reason(EV[toupper(s)])
                  if (r != "") print s "\t" r } }' | LC_ALL=C sort > "$side.tmp"
    rm -f "$tmpp"
    mv "$side.tmp" "$side"
}
write_subscriptions_in_boxes_page() {
    local out="$ADIR/subscriptions-in-boxes.html"
    local TAB; TAB=$(printf '\t')
    local probs; probs=$(_subs_box_rows)
    _write_box_reason_sidecar "$probs"
    local n_all n1 n2 n3 n4
    n_all=$(printf '%s\n' "$probs" | awk -F'\t' '$2!=""{ if(!s[$2]++) n++ } END{print n+0}')
    n1=$(printf '%s\n' "$probs" | awk -F'\t' '$1==1' | wc -l | tr -d ' ')
    n2=$(printf '%s\n' "$probs" | awk -F'\t' '$1==2' | wc -l | tr -d ' ')
    n3=$(printf '%s\n' "$probs" | awk -F'\t' '$1==3' | wc -l | tr -d ' ')
    n4=$(printf '%s\n' "$probs" | awk -F'\t' '$1==4' | wc -l | tr -d ' ')
    n5=$(printf '%s\n' "$probs" | awk -F'\t' '$1==5' | wc -l | tr -d ' ')
    n6=$(printf '%s\n' "$probs" | awk -F'\t' '$1==6' | wc -l | tr -d ' ')
    n7=$(printf '%s\n' "$probs" | awk -F'\t' '$1==7' | wc -l | tr -d ' ')
    n8=$(printf '%s\n' "$probs" | awk -F'\t' '$1==8' | wc -l | tr -d ' ')
    n9=$(printf '%s\n' "$probs" | awk -F'\t' '$1==9' | wc -l | tr -d ' ')
    n10=$(printf '%s\n' "$probs" | awk -F'\t' '$1==10' | wc -l | tr -d ' ')
    n11=$(printf '%s\n' "$probs" | awk -F'\t' '$1==11' | wc -l | tr -d ' ')
    n13=$(printf '%s\n' "$probs" | awk -F'\t' '$1==13' | wc -l | tr -d ' ')
    n14=$(printf '%s\n' "$probs" | awk -F'\t' '$1==14' | wc -l | tr -d ' ')
    n15=$(printf '%s\n' "$probs" | awk -F'\t' '$1==15' | wc -l | tr -d ' ')
    n17=$(printf '%s\n' "$probs" | awk -F'\t' '$1==17' | wc -l | tr -d ' ')
    n18=$(printf '%s\n' "$probs" | awk -F'\t' '$1==18' | wc -l | tr -d ' ')
    n20=$(printf '%s\n' "$probs" | awk -F'\t' '$1==20' | wc -l | tr -d ' ')
    n21=$(printf '%s\n' "$probs" | awk -F'\t' '$1==21' | wc -l | tr -d ' ')
    {
        html_head "Subscriptions in boxes" "../assets/style.css" "" "ANALYSES" "subscriptions-in-boxes"
        printf '<h1>Subscriptions in boxes</h1>\n'
        # The intro is GENERAL — what the page is and how to read it. What each
        # individual signal means belongs to the per-box explanation below the
        # boxes, which follows the active one (setupStatFilter swaps .pfshow).
        # BOX COLOURS follow the site-wide result vocabulary (style.css .stat-*,
        # the same three tints as res-green/orange/red), so a box reads the
        # same way as a row tint anywhere else:
        #   green  the flow is delivering            (OK)
        #   red    it is failing or has failed       (one leg, green->red, only
        #          red, expired, no Dir)
        #   orange attention, or not working YET     (troubles, waiting, no Files,
        #          no cron, quiet, not seen)
        # The TOTAL box stays neutral: it is the whole estate, not a verdict.
        # The problem rows list the ORANGE boxes before the RED ones (same
        # relative order within each colour); the table columns mirror this.
        # data-pf-default: the box setupStatFilter opens the page on.
        printf '<div class="pfboxes" data-pf-default="13"><div class="stat pfon" data-pf=""><span class="stat-v">%s</span><span class="stat-l">Total subscriptions</span></div>' "$n_all"
        printf '<div class="stat stat-green" data-pf="13"><span class="stat-v">%s</span><span class="stat-l">OK</span></div>' "$n13"
        printf '<div class="stat" data-pf="17"><span class="stat-v">%s</span><span class="stat-l">Seen</span></div>' "$n17"
        printf '<div class="stat stat-orange" data-pf="11"><span class="stat-v">%s</span><span class="stat-l">Not seen</span></div>' "$n11"
        printf '<div class="stat stat-red" data-pf="18"><span class="stat-v">%s</span><span class="stat-l">Error</span></div>' "$n18"
        printf '<div class="pfbreak"></div>'
        printf '<div class="stat stat-orange" data-pf="3"><span class="stat-v">%s</span><span class="stat-l">Trouble after success</span></div>' "$n3"
        printf '<div class="stat stat-orange" data-pf="5"><span class="stat-v">%s</span><span class="stat-l">Waiting</span></div>' "$n5"
        printf '<div class="stat stat-orange" data-pf="8"><span class="stat-v">%s</span><span class="stat-l">No Files</span></div>' "$n8"
        printf '<div class="stat stat-orange" data-pf="9"><span class="stat-v">%s</span><span class="stat-l">Missing cron</span></div>' "$n9"
        printf '<div class="stat stat-orange" data-pf="10"><span class="stat-v">%s</span><span class="stat-l">Went quiet</span></div>' "$n10"
        printf '<div class="stat stat-red" data-pf="1"><span class="stat-v">%s</span><span class="stat-l">One-legged</span></div>' "$n1"
        printf '<div class="stat stat-red" data-pf="2"><span class="stat-v">%s</span><span class="stat-l">From green to red</span></div>' "$n2"
        printf '<div class="stat stat-red" data-pf="4"><span class="stat-v">%s</span><span class="stat-l">Only red</span></div>' "$n4"
        printf '<div class="stat stat-red" data-pf="6"><span class="stat-v">%s</span><span class="stat-l">Expired</span></div>' "$n6"
        printf '<div class="stat stat-red" data-pf="14"><span class="stat-v">%s</span><span class="stat-l">Connection failures</span></div>' "$n14"
        printf '<div class="stat stat-red" data-pf="15"><span class="stat-v">%s</span><span class="stat-l">Deploy</span></div>' "$n15"
        printf '<div class="stat stat-red" data-pf="20"><span class="stat-v">%s</span><span class="stat-l">Login errors (in)</span></div>' "$n20"
        printf '<div class="stat stat-red" data-pf="21"><span class="stat-v">%s</span><span class="stat-l">Login errors (out)</span></div>' "$n21"
        printf '<div class="stat stat-red" data-pf="7"><span class="stat-v">%s</span><span class="stat-l">No Dir</span></div>' "$n7"
        printf '</div>\n'
        # Every link out of a box explanation carries `?axway_search=` — the
        # empty form of the search override (2026-08). Search persists per
        # REPORT (sessionStorage, report-key), so a query typed on the target
        # earlier would still be filtering it when you arrive from a box, and
        # the list you clicked for would come up short with no hint why. The
        # empty value is applied and PERSISTED like a typed one, then
        # syncSearchUrl drops the parameter from the address bar again.
        # One explanation per box, ALL baked, only the active one shown (.pfshow;
        # style.css hides the rest). report.js setupStatFilter moves .pfshow with
        # .pfon, so the text always describes the box you clicked; with no JS the
        # baked pair — the "all" box and its paragraph — is what stands.
        printf '<p class="range pfdesc pfshow" data-pf=""><a href="../transfer/entities/subscription-all.html?axway_search="><strong>Total subscriptions</strong></a> &mdash; every subscription configured in FlowManager, whatever its state. Not a selection but the whole estate: each one is in at least one of the boxes above. The other boxes narrow this list; this box brings it all back. The same estate with each subscription&rsquo;s traffic figures is the <a href="../transfer/entities/subscription-all.html?axway_search=">Subscriptions / All</a> entity view.</p>\n'
        printf '<p class="range pfdesc" data-pf="1"><a href="../transfer/pirates-details.html?axway_search="><strong>One-legged</strong></a> &mdash; a logical transfer that logged only ONE leg. A complete transfer is store-and-forward: an Inbound leg (partner &rarr; ST) and an Outbound leg (ST &rarr; partner). A single-leg CoreId is one-sided &mdash; the counterpart leg never happened &mdash; so the file never made the full crossing. Flagged here only while it is <strong>unresolved</strong>: an OK File delivered after the last one-legged transfer clears it, though <a href="../transfer/pirates-details.html?axway_search=">One-Legged Transfers</a> still lists the full history.</p>\n'
        printf '<p class="range pfdesc" data-pf="2"><a href="failed.html?axway_search="><strong>From green to red</strong></a> &mdash; the REGRESSION list: the subscription is red right now (its latest File Failed or Expired) but an earlier day ended on an OK File. It <em>used to work</em> and broke since; <a href="failed.html?axway_search=">Failed Subscriptions</a> names the day it flipped (Last green day), which is where to start looking for what changed.</p>\n'
        printf '<p class="range pfdesc" data-pf="3"><strong>Trouble after success</strong> &mdash; the SERVER-log signal: the subscription&rsquo;s last transfer was OK, but it (or a connected login, account or remote host) logged an <strong>Error</strong> <em>after</em> that transfer, and the flow is <strong>still green</strong>. Warnings do not count. A fresh problem on a flow whose transfer history still looks healthy &mdash; the earliest warning you get, before a file fails. Where the same evidence has already reddened a flow it is no longer a warning but a failure, and the box for it is one of the red ones. Each flag opens the subscription&rsquo;s page, whose banner names the error.</p>\n'
        printf '<p class="range pfdesc" data-pf="4"><a href="failed.html?axway_search="><strong>Only red</strong></a> &mdash; the NEVER-WORKED list: not one OK delivery in the whole window, every File Failed or Expired. This is not a regression (those carry a Last green day on <a href="failed.html?axway_search=">Failed Subscriptions</a>) &mdash; nothing here ever worked, which points at the configuration or the partner side never having been finished, rather than at something that broke. <a href="failed.html?axway_search=">Failed Subscriptions</a> lists them with Last green day <em>never</em>.</p>\n'
        printf '<p class="range pfdesc" data-pf="5"><a href="../transfer/waiting.html?axway_search="><strong>Waiting</strong></a> &mdash; the subscription&rsquo;s <strong>newest</strong> File is still STAGED for pickup: it arrived and sits in the folder, but the partner has not dialled in to collect it (UC2). Not an error &mdash; briefly waiting is the normal state of a pickup flow &mdash; but a newest file that has been waiting for days means the partner stopped collecting, and the retention sweep will delete it. <a href="../transfer/waiting.html?axway_search=">Waiting Files</a> has the full list.</p>\n'
        printf '<p class="range pfdesc" data-pf="6"><a href="../transfer/expired.html?axway_search="><strong>Expired</strong></a> &mdash; the subscription&rsquo;s <strong>newest</strong> staged File was DELETED by the nightly File Maintenance retention sweep (~11 days) before any pickup. It was never delivered and can no longer be collected &mdash; a silent failure: nothing errored, the file just aged out. Expired counts as an Error site-wide; <a href="../transfer/expired.html?axway_search=">the Expired report</a> has the retention timing and the per-account pickup behavior.</p>\n'
        printf '<p class="range pfdesc" data-pf="14"><a href="../server/failure-flows.html?axway_search="><strong>Connection failures</strong></a> &mdash; the server log records a failed CONNECTION to the partner for this subscription (timeout, refused, dropped, an SSH negotiation that never completed), and <strong>no OK File has followed it</strong>. That filter is the whole point: connections fail transiently all the time and a flow that failed and then delivered has recovered, so only the still-unresolved ones are boxed here &mdash; most of them are cleared this way. It usually adds the <em>reason</em> to a subscription already boxed as Only red or One-legged: not merely &ldquo;nothing arrives&rdquo; but &ldquo;we cannot get a connection to the partner at all&rdquo;, which points at the partner host, the port or the credentials rather than at the flow. <a href="../server/failure-flows.html?axway_search=">Errors / Per flow</a> has the full list with the failure messages (the Connection failure reason rows).</p>\n'
        printf '<p class="range pfdesc" data-pf="15"><a href="../server/routing-errors.html?axway_search="><strong>Deploy</strong></a> &mdash; the server log records a <strong>configuration defect</strong> for this subscription: the Advanced Routing step error <span class="mono">ARSP0001</span>, where a routing step failed and <strong>its configuration told SecureTransport to abandon the rest of the route</strong> so nothing downstream ran for that file; or a PeSIT transfer profile <strong>missing its &ldquo;Receive File As&rdquo; field</strong>, which errors every incoming transfer of the flow. Like Connection failures, only the <strong>unresolved</strong> ones are boxed &mdash; an OK File after the last such message means something has got through since. The distinction from a plain failure is that the flow does not merely error, it <em>stops</em>: no onward delivery, no follow-up step, and the subscription can sit that way looking quiet rather than broken. The line names an account or a subscription, so an account is counted against every subscription configured for it. <a href="../server/routing-errors.html?axway_search=">Routing errors</a> lists the lines (Route stopped).</p>\n'
        printf '<p class="range pfdesc" data-pf="20"><a href="../server/logons-incoming.html?axway_search="><strong>Login errors (in)</strong></a> &mdash; a login connected to this subscription FAILED the incoming SSH screening &mdash; disallowed address, unknown key, repeated key failures or a lockout &mdash; and <strong>no OK File has followed</strong> (the error day counts to its end, so only a later day&rsquo;s delivery clears it). The partner is knocking and not getting in; <a href="../server/logons-incoming.html?axway_search=">Logons / Incoming</a> has the per-login funnel with the drill-down log lines.</p>\n'
        printf '<p class="range pfdesc" data-pf="21"><a href="../server/logons-outgoing.html?axway_search="><strong>Login errors (out)</strong></a> &mdash; WE failed to authenticate at the remote host behind this subscription (wrong password, refused key or certificate policy) and <strong>no OK File has followed</strong>. The flow cannot fetch or deliver until the credential is fixed; <a href="../server/logons-outgoing.html?axway_search=">Logons / Outgoing</a> has the per-host failures split into Password / Key / Other.</p>\n'
        printf '<p class="range pfdesc" data-pf="7"><a href="uc-status-uc3.html?axway_search="><strong>No Dir</strong></a> &mdash; we reached the partner, asked for a directory listing, and the partner answered <em>No such file</em>: the configured REMOTE directory is not there. The connection and the credentials are fine &mdash; it is the path that is wrong, or was removed on the partner side. The <a href="uc-status-uc3.html?axway_search=">UC status / UC3</a> tab lists them (Missing remote directories).</p>\n'
        printf '<p class="range pfdesc" data-pf="8"><a href="uc-status-uc3.html?axway_search="><strong>No Files</strong></a> &mdash; the UC3 poll works end to end (connection, credentials and listing all succeed) but the remote directory is <strong>always empty</strong>. Every slot spent here is a connection and a listing for no data: either the partner never delivers, or we are polling the wrong place. The <a href="uc-status-uc3.html?axway_search=">UC status / UC3</a> tab lists them (never find a file).</p>\n'
        printf '<p class="range pfdesc" data-pf="9"><a href="polling.html?axway_search=%%22no%%20cron%%22"><strong>Missing cron</strong></a> &mdash; the only <em>configuration</em> signal here, and the only one that stops the flow before it ever starts. A subscription of a cron-triggered use case carries <strong>no cron expression at all</strong>, and nothing else would make it poll, so it simply never runs: no connection, no file, no error, and nothing in either log to notice. Nothing is broken and nothing errored &mdash; the flow was simply never finished, and its silence looks exactly like a partner that has gone quiet unless you check the configuration. <a href="polling.html?axway_search=%%22no%%20cron%%22">Polling</a> lists them (Schedule <em>no cron</em>).</p>\n'
        printf '<p class="range pfdesc" data-pf="10"><a href="../transfer/went-quiet-subscriptions.html?axway_search="><strong>Went quiet</strong></a> &mdash; the flow carried Files and then simply stopped: nothing at all in the last <strong>7 days</strong> of the window, whatever the outcome used to be. It fires on an <em>absence where there used to be traffic</em>, which is why no error report catches it &mdash; nothing failed, there is just nothing there. Usually the partner stopped sending, the source system stopped producing, or the flow was decommissioned and never cleaned up. A subscription can be green and still be listed: green only means its LAST File was delivered, however long ago. <a href="../transfer/went-quiet-subscriptions.html?axway_search=">Went quiet</a> has the full list with the days.</p>\n'
        printf '<p class="range pfdesc" data-pf="11"><a href="../transfer/entities/subscription-not-seen.html?axway_search="><strong>Not seen</strong></a> &mdash; configured in FlowManager and never seen in the transfer log: not one File. Usually not a broken flow but an unbuilt or abandoned one &mdash; except a UC3 whose polls cannot connect (three failures in a row), which is red and in <strong>Error</strong> too &mdash; and the emptiest box on the page: every box that judges delivery needs the flow to have run at least once. A UC3 flow that polls cleanly with nothing to fetch is here too: without a File it stays orange. It has no report of its own &mdash; the <a href="../transfer/entities/subscription-not-seen.html?axway_search=">Subscriptions / Not seen</a> entity view is the full list.</p>\n'
        printf '<p class="range pfdesc" data-pf="13"><a href="../transfer/entities/subscription-ok.html?axway_search="><strong>OK</strong></a> &mdash; the subscription&rsquo;s <strong>newest</strong> File was delivered: the site-wide <strong>green</strong> result. Green describes that LAST File and nothing else, so an OK subscription can still sit in other boxes &mdash; a flow whose last File was delivered a month ago and which has carried nothing since is OK <em>and</em> Went quiet. No report of its own &mdash; the <a href="../transfer/entities/subscription-ok.html?axway_search=">Subscriptions / OK</a> entity view is the full list.</p>\n'
        printf '<p class="range pfdesc" data-pf="17"><a href="../transfer/entities/subscription-seen.html?axway_search="><strong>Seen</strong></a> &mdash; the subscription has real TRANSFER data: at least one File in the transfer log. Seen and Not seen together are always the whole estate. No report of its own &mdash; the <a href="../transfer/entities/subscription-seen.html?axway_search=">Subscriptions / Seen</a> entity view is the full list.</p>\n'
        printf '<p class="range pfdesc" data-pf="18"><a href="../transfer/entities/subscription-error.html?axway_search="><strong>Error</strong></a> &mdash; the site-wide <strong>red</strong> result: the subscription&rsquo;s <strong>newest</strong> File Failed, or the server log recorded an Error after its last transfer, or &mdash; a UC3 that never transferred &mdash; its polls cannot connect. A newest File that <strong>Expired</strong> is orange, not red (a pickup problem, see Expired). <em>Which way</em> it is failing is what the other red boxes say &mdash; a red subscription is usually also in From green to red (it used to work) or Only red (it never did). No report of its own &mdash; the <a href="../transfer/entities/subscription-error.html?axway_search=">Subscriptions / Error</a> entity view is the full list.</p>\n'
        # nosearch: the stat-box filters are this page's narrowing mechanism —
        # report.js must not add its search box on top of them
        # SHORT column names, and .pftable for the 90% font — ELEVEN columns beside
        # 40+ character subscription names made this the widest page on the site.
        # The full name of each signal survives twice over: the stat box above the
        # table and the pfdesc paragraph still spell it out, and every flagged
        # cell keeps its long title= as the hover tooltip.
        printf '<div class="tablewrap"><table class="fit pftable" data-nosearch="1">\n'
        printf '<tr><th>Subscription</th><th data-pf="13">ok</th><th data-pf="17">seen</th><th data-pf="11">not seen</th><th data-pf="18">error</th><th data-pf="3">troubles</th><th data-pf="5">waiting</th><th data-pf="8">no Files</th><th data-pf="9">no cron</th><th data-pf="10">quiet</th><th data-pf="1">one leg</th><th data-pf="2">green-&gt;red</th><th data-pf="4">red</th><th data-pf="6">expired</th><th data-pf="14">connection</th><th data-pf="15">deploy</th><th data-pf="20">login in</th><th data-pf="21">login out</th><th data-pf="7">no Dir</th></tr>\n'
        if [ -z "$probs" ]; then
            printf '<tr><td colspan="19">No subscription is in any box.</td></tr>\n'
        else
            printf '%s\n' "$probs" | awk -F'\t' '
                { k = $2; if (!(k in seen)) { seen[k] = 1; ord[++n] = k } f[k, $1] = 1 }
                END { for (i = 1; i <= n; i++) { k = ord[i]
                        c = ((k,1) in f) + ((k,2) in f) + ((k,3) in f) + ((k,4) in f) + ((k,5) in f) + ((k,6) in f) + ((k,7) in f) + ((k,8) in f) + ((k,9) in f) + ((k,10) in f) + ((k,11) in f) + ((k,13) in f) + ((k,14) in f) + ((k,15) in f) + ((k,17) in f) + ((k,18) in f) + ((k,20) in f) + ((k,21) in f)
                        printf "%d\t%s\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\n", c, k, ((k,1) in f), ((k,2) in f), ((k,3) in f), ((k,4) in f), ((k,5) in f), ((k,6) in f), ((k,7) in f), ((k,8) in f), ((k,9) in f), ((k,10) in f), ((k,11) in f), ((k,13) in f), ((k,14) in f), ((k,15) in f), ((k,17) in f), ((k,18) in f), ((k,20) in f), ((k,21) in f) } }' \
            | LC_ALL=C sort -t"$TAB" -k2,2 \
            | awk -F'\t' -v SM="$TRPT/details/subscriptions/_slugmap.tsv" -v SUBF="$FBASE/_subscriptions.tsv" '
                function e(s) { gsub(/&/, "\\&amp;", s); gsub(/</, "\\&lt;", s); gsub(/>/, "\\&gt;", s); gsub(/"/, "\\&quot;", s); return s }
                # a name as a URL query value, byte by byte (2026-09-28 fix: the
                # raw name went into ?axway_search=, so a percent sign, an
                # ampersand, a hash or a space broke the link)
                function urlq(s,   i, c, o) {
                    if (!_URLQI) { for (i = 1; i < 256; i++) URLQB[sprintf("%c", i)] = i; _URLQI = 1 }
                    o = ""
                    for (i = 1; i <= length(s); i++) { c = substr(s, i, 1); o = o ((c ~ /[A-Za-z0-9_.~-]/) ? c : sprintf("%%%02X", URLQB[c])) }
                    return o
                }
                # a flagged cell carries the COLUMN NAME itself (not a symbol),
                # linking into that report with the subscription as the search.
                # The href is relative to docs/analyses/, so it needs the
                # AREA prefix — nine of these were bare and had been resolving to
                # analyses/<name>.html, which does not exist. The header links
                # above always carried the right prefix; only the cells were wrong.
                # cls: an extra class on the link. OK is the one box that is not a
                # problem, so it renders GREEN (pfok) instead of the flag red.
                function flag(on, href, nm, ttl, lbl, cls) {
                    if (!on) return "<td></td>"
                    # an href already carrying a query is used as-is (the two
                    # login-error boxes: the Logons rows are logins/hosts, so a
                    # subscription-name search would match nothing)
                    # an EMPTY href = a plain flag (troubles of a subscription
                    # with no detail page: its report page went 2026-09-29)
                    if (href == "") return "<td class=\"ctr\"><span class=\"pfx" (cls ? " " cls : "") "\" title=\"" ttl "\">" lbl "</span></td>"
                    if (index(href, "?") == 0 && index(href, "/details/") == 0) href = href "?axway_search=" urlq(nm)   # a detail page needs no search
                    return "<td class=\"ctr\"><a class=\"pfx" (cls ? " " cls : "") "\" href=\"" href "\" title=\"" ttl "\">" lbl "</a></td>"
                }
                BEGIN {
                    while ((getline l < SM) > 0) { split(l, a, "\t"); if (a[1] != "") SL[toupper(a[1])] = a[2] } close(SM)
                    # base result: exact, else the configured name that PREFIXES
                    # the logged site value (the showseen rule)
                    while ((getline l < SUBF) > 0) { split(l, a, "\t"); if (a[1] != "") { RES[toupper(a[1])] = a[3]; BN[++nb] = toupper(a[1]) } } close(SUBF)
                }
                {
                    nm = e($2); u = toupper($2)
                    res = RES[u]
                    if (res == "") for (j = 1; j <= nb; j++) if (index(u, BN[j]) == 1) { res = RES[BN[j]]; break }
                    if (res != "green" && res != "orange" && res != "red") res = ""
                    if (u in SL) nm = "<a href=\"../details/subscriptions/" SL[u] ".html\">" nm "</a>"
                    pf = ""
                    if ($3) pf = pf " 1"; if ($4) pf = pf " 2"; if ($5) pf = pf " 3"
                    if ($6) pf = pf " 4"; if ($7) pf = pf " 5"; if ($8) pf = pf " 6"; if ($9) pf = pf " 7"; if ($10) pf = pf " 8"
                    if ($11) pf = pf " 9"; if ($12) pf = pf " 10"; if ($13) pf = pf " 11"; if ($14) pf = pf " 13"; if ($15) pf = pf " 14"; if ($16) pf = pf " 15"
                    if ($17) pf = pf " 17"; if ($18) pf = pf " 18"
                    if ($19) pf = pf " 20"; if ($20) pf = pf " 21"
                    # 21 %s = 3 (data-pf, res attr, name) + ONE PER FLAG CELL,
                    # now 18. awk silently DROPS a surplus argument, so a
                    # miscount costs the LAST column its cells site-wide.
                    printf "<tr data-pf=\"%s\"%s><td class=\"cl\">%s</td>%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s</tr>\n", \
                        substr(pf, 2), (res != "" ? " data-res=\"" res "\"" : ""), nm, \
                        flag($14, "../transfer/entities/subscription-ok.html", $2, "Newest File delivered \342\200\224 the subscription is green", "ok", "pfok"), \
                        flag($17, "../transfer/entities/subscription-seen.html", $2, "Seen in the transfer log \342\200\224 at least one File", "seen", "pfneu"), \
                        flag($13, "../transfer/entities/subscription-not-seen.html", $2, "Configured, never seen in the transfer log", "not seen"), \
                        flag($18, "../transfer/entities/subscription-error.html", $2, "The subscription is red \342\200\224 its newest File Failed, or server-log errors after its last transfer", "error"), \
                        flag($5, (u in SL) ? "../details/subscriptions/" SL[u] ".html" : "", $2, "Trouble after success \342\200\224 an Error was logged after the last OK transfer; the subscription page banner names it", "troubles"), \
                        flag($7, "../transfer/waiting.html", $2, "Newest File is Waiting", "waiting"), \
                        flag($10, "uc-status-uc3.html", $2, "On No remote files", "no Files"), \
                        flag($11, "polling.html", $2, "Cron-triggered, but no cron expression configured", "no cron"), \
                        flag($12, "../transfer/went-quiet-subscriptions.html", $2, "Carried Files, then stopped \342\200\224 no traffic in the last 7 days", "quiet"), \
                        flag($3, "../transfer/pirates-details.html", $2, "On One-legged transfers", "one leg"), \
                        flag($4, "failed.html", $2, "On From green to red", "green-&gt;red"), \
                        flag($6, "failed.html", $2, "On Only red", "red"), \
                        flag($8, "../transfer/expired.html", $2, "Newest File is Expired", "expired"), \
                        flag($15, "../server/failure-flows.html", $2, "The server logged a connection failure and no OK File followed it", "connection"), \
                        flag($16, "../server/routing-errors.html", $2, "A configuration defect stopped the flow (route abandoned, or the profile cannot receive) and no OK File followed it", "deploy"), \
                        flag($19, "../server/logons-incoming.html?axway_sort=2:-1", $2, "A connected login failed the incoming SSH screening and no OK File followed", "login in"), \
                        flag($20, "../server/logons-outgoing.html?axway_sort=2:-1", $2, "We failed to authenticate at the remote host and no OK File followed", "login out"), \
                        flag($9, "uc-status-uc3.html", $2, "On No remote dir", "no Dir")
                }'
            # 18 numeric cells in COLUMN order (the previous version was one
            # cell short — the deploy column was missing, latent because
            # setupStatFilter rewrites this row; it is also the no-JS fallback)
            printf '<tr class="total"><td>Total (%s subscriptions)</td><td class="num">%s</td><td class="num">%s</td><td class="num">%s</td><td class="num">%s</td><td class="num">%s</td><td class="num">%s</td><td class="num">%s</td><td class="num">%s</td><td class="num">%s</td><td class="num">%s</td><td class="num">%s</td><td class="num">%s</td><td class="num">%s</td><td class="num">%s</td><td class="num">%s</td><td class="num">%s</td><td class="num">%s</td><td class="num">%s</td></tr>\n' \
                "$n_all" "$n13" "$n17" "$n11" "$n18" "$n3" "$n5" "$n8" "$n9" "$n10" "$n1" "$n2" "$n4" "$n6" "$n14" "$n15" "$n20" "$n21" "$n7"
        fi
        printf '</table></div>\n'
        printf '</body>\n</html>\n'
    } > "$out"
}

# (Accounts in boxes, docs/analyses/accounts-in-boxes.html, went 2026-09-29:
# the same box memberships joined onto accounts — 9 of 137 accounts carried
# more than one subscription, and its one account-only box, "no subs", is the
# Cleanup backlog / Config hygiene config-orphan row.)

# the SIDECAR MODE (see Usage): the sidecar exactly as the boxes page writes
# it — the same box rows, the same writer — and no page
if [ "$PI_MODE" = sidecar ]; then
    _pi_probs=$(_subs_box_rows)
    _write_box_reason_sidecar "$_pi_probs"
    echo "Wrote the box-reason sidecar $DATA/analyses/reports/_subs-boxes.tsv (no page)." >&2
    exit 0
fi

write_whitelist_audit_page
write_config_hygiene_page
write_subscriptions_in_boxes_page

echo "Wrote the insight analyses pages to $ADIR." >&2
