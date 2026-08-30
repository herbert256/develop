#!/usr/bin/env bash
#
# bin/analyses/publish-insights.sh — render the seven INSIGHT analyses pages
# (docs/<env>/analyses/*.html) for the CURRENT env. Called by
# bin/analyses/publish.sh before write_analyses_index (the index lists only
# pages that exist). All pages are config-vs-reality joins over data already
# on disk — the flow-manager caches, the transfer/server report .rpt files,
# the parse caches and (certificates + cron, like write_cronjobs_page) the
# raw FlowManager JSON exports via jq:
#   whitelist-audit.html   whitelisted IPs vs the addresses actually connecting
#   config-hygiene.html    config twins and orphaned objects
#   double.html            names configured as BOTH an application and a
#                          partner, and subscriptions tied to two partners
#   expired.html           staged UC2 files deleted before pickup (Expired):
#                          retention timing, per-account pickup behavior
# Every page degrades gracefully: a missing source skips that column/section
# rather than failing the publish. No arguments; runs from any directory.
#
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../publish_lib.sh"   # cd's to the repo root; html_head/esc/…

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

# Server-side inbound connections per source address (inbound-connections.rpt)
SRVADDR="$TMPD/srvaddr.tsv"
if [ -f "$SRPT/inbound-connections.rpt" ]; then
    awk -F'\t' '$1=="TABLE"{t=$2} $1=="ROW" && t=="By source address" && $2 !~ /^@\{/ { print $2 "\t" $3 }' \
        "$SRPT/inbound-connections.rpt" > "$SRVADDR"
else
    : > "$SRVADDR"
fi

# Open incidents (episodes.rpt table 1): site, tail, since, days, lastok, files
OPENINC="$TMPD/openinc.tsv"
if [ -f "$TRPT/episodes.rpt" ]; then
    awk -F'\t' '$1=="TABLE"{t++} $1=="ROW" && t==1 && $2 !~ /^@\{colspan/ {
        lo = $6; sub(/^@\{[^}]*\}/, "", lo)
        printf "%s\t%s\t%s\t%s\t%s\t%s\n", $2, $3, $4, $5, lo, $7 }' "$TRPT/episodes.rpt" > "$OPENINC"
else
    : > "$OPENINC"
fi

# ---- 4. Whitelist audit -----------------------------------------------------
write_whitelist_audit_page() {
    local out="$ADIR/whitelist-audit.html"
    if [ ! -f "$FBASE/_white.tsv" ]; then rm -f "$out"; return 0; fi
    {
        html_head "Whitelist audit" "../assets/style.css" "" "ANALYSES" "whitelist-audit"
        printf '<h1>Whitelist audit</h1>\n'
        analyses_group_tabs whitelist-audit.html
        printf '<p class="subtitle">Every whitelisted partner IP against what actually connects: <strong>Used</strong> carried real Files, <strong>Connects only</strong> shows server-log connections but no transfer, <strong>Never seen</strong> is prunable attack surface. The second table is the reverse: source addresses that carried traffic without a whitelist entry.</p>\n'
        awk -F'\t' -v WHITE="$FBASE/_white.tsv" -v AW="$XREF/_accounts-white.tsv" \
            -v OBS="$TMPD/obsaddr.tsv" -v SRV="$TMPD/srvaddr.tsv" '
            function e(s) { gsub(/&/, "\\&amp;", s); gsub(/</, "\\&lt;", s); gsub(/>/, "\\&gt;", s); gsub(/"/, "\\&quot;", s); return s }
            function padkey(v,   o) { if (v ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) { split(v, o, "."); return sprintf("%03d%03d%03d%03d", o[1], o[2], o[3], o[4]) } return toupper(v) }
            BEGIN {
                while ((getline l < WHITE) > 0) { split(l, a, "\t"); if (a[1] != "") { W[a[1]] = 1; WR[a[1]] = a[3] } } close(WHITE)
                while ((getline l < AW) > 0) { split(l, a, "\t"); if (a[2] != "") { WA[a[2]]++; AWPAIR[a[1], a[2]] = 1
                    if (WN[a[2]] == "") WN[a[2]] = a[1]; else if (WA[a[2]] <= 3) WN[a[2]] = WN[a[2]] ", " a[1] } } close(AW)
                while ((getline l < OBS) > 0) { split(l, a, "\t"); if (a[1] != "") { OF[a[1]] = a[2]; OL[a[1]] = a[3] } } close(OBS)
                while ((getline l < SRV) > 0) { split(l, a, "\t"); if (a[1] != "") SC[a[1]] = a[2] } close(SRV)

                nw = 0; used = 0; conly = 0; never = 0
                for (ip in W) { nw++
                    f = OF[ip] + 0; c = SC[ip] + 0
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
                printf "<tr><th>IP</th><th>Allowing accounts</th><th class=\"num\">Files</th><th class=\"num\">Server connections</th><th>Last File</th><th>Verdict</th></tr>\n"
                n = 0; for (ip in W) if (OF[ip] + 0 > 0 || SC[ip] + 0 > 0) KEY[++n] = padkey(ip) "\t" ip
                for (i = 1; i <= n; i++) { for (j = i + 1; j <= n; j++) if (KEY[j] < KEY[i]) { t2 = KEY[i]; KEY[i] = KEY[j]; KEY[j] = t2 } }
                if (n == 0) printf "<tr><td colspan=\"6\">No whitelisted address shows any activity.</td></tr>\n"
                for (i = 1; i <= n; i++) { split(KEY[i], kk, "\t"); ip = kk[2]
                    f = OF[ip] + 0; c = SC[ip] + 0
                    if (f > 0)      { v = "Used"; res = "green" }
                    else            { v = "Connects only — no Files"; res = "orange" }
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
                    if (OF[ip] + 0 > 0 || SC[ip] + 0 > 0) AU[acct]++
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
                printf "<tr><th>Address</th><th class=\"num\">Files</th><th class=\"num\">Server connections</th><th>Last File</th></tr>\n"
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
        printf '<p class="range">Whitelist from the partner AllowIP configuration (<span class="mono">base/_white.tsv</span>); observed Files from the transfer logs (inbound-connection source addresses), server connections from the server <strong>Inbound Connections</strong> report. Internal cluster addresses can appear among the unlisted sources — they connect over PeSIT without needing a whitelist entry. A named (non-IP) source is an already-resolved hostname.</p>\n'
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
        analyses_group_tabs config-hygiene.html
        printf '<p class="subtitle">The cleanup backlog: likely-duplicate <strong>twins</strong> (names identical once case and the <span class="mono">-</span>/<span class="mono">_</span> separators are folded &mdash; configured as separate entities, usually one is legacy) and <strong>orphans</strong> (objects nothing references: accounts without a subscription, hosts and logins no subscription uses, whitelist entries no account allows). Not in Flow Manager covers the reverse direction &mdash; logged values missing from the configuration.</p>\n'
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
                if (res != "green" && res != "orange" && res != "red" && res != "blue") res = ""
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
                    for (k2 in G) if (G[k2] > 1) {
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
        printf '<p class="range">Twins fold case and the <span class="mono">-</span>/<span class="mono">_</span> separators (the known real phenomenon: <span class="mono">FRE-SAPCD-&hellip;</span> vs <span class="mono">FRE_SAPCD_&hellip;</span> configured as separate flows). Orphan checks use the cross-reference pair caches; rows are tinted by each entity&rsquo;s standard result color, so a green &ldquo;twin&rdquo; pair is two entities that BOTH work &mdash; deliberate, not legacy.</p>\n'
        # ---- the SERVER-LOG defect families (2026-08 study E3) --------------
        # Rendered from the config-defects.tsv sidecar bin/server/reports/
        # config-defects.sh computes (compute there, render here). Transfer
        # profiles are PARSE-INTERNAL: plain text, no link, no entity KIND.
        local _cdf="$DATA/server/reports/config-defects.tsv"
        if [ -s "$_cdf" ]; then
            printf '<h2>Server-log config defects</h2>\n'
            printf '<p class="range">Three recurring single-cause families from the server log, each fixable with one configuration change: transfer profiles missing their <strong>Receive File As</strong> field (every incoming transfer of that profile errors), configured hosts <strong>DNS cannot resolve</strong>, and the recurring server-tuning warning.</p>\n'
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
                    printf "<p class=\"range\">The profile is missing its <strong>Receive File As</strong> field, so every incoming transfer that uses it errors. Profiles are internal flow plumbing and have no page of their own.</p>\n"
                    printf "<h3>DNS-dead configured hosts</h3>\n<div class=\"tablewrap\"><table class=\"fit\">\n<tr><th>Host</th><th class=\"num\">Failed lookups</th><th>First</th><th>Last</th></tr>\n"
                    for (i = 1; i <= nd; i++) print dr[i]
                    if (nd == 0) print "<tr><td colspan=\"4\">None in this window.</td></tr>"
                    printf "<tr class=\"total\"><td>Total (%d host(s))</td><td class=\"num\">%d</td><td></td><td></td></tr>\n</table></div>\n", nd+0, td+0
                    printf "<p class=\"range\">A configured endpoint name DNS cannot resolve. A Last date near the window end means it is STILL failing; a single-day range was a transient.</p>\n"
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
# Names configured as BOTH an application and a partner (the PDA derivation
# legitimately creates both: a relay's middle token is simultaneously the
# internal system and the external party, or the same organisation appears as
# the middle segment of one account name and the trailing segment of another),
# plus the subscriptions whose config connects them to TWO partner groups.
# 2026-07: folded into the Config hygiene page (both are configuration smells);
# emits the two Double sections to stdout, called by write_config_hygiene_page.
emit_double_sections() {
    if [ ! -f "$FBASE/_apps.tsv" ] || [ ! -f "$FBASE/_partners.tsv" ]; then return 0; fi
    # names configured as both (case-folded intersection of the two base lists)
    local dbl="$TMPD/double-names.txt"
    comm -12 <(cut -f1 "$FBASE/_apps.tsv" | tr '[:lower:]' '[:upper:]' | LC_ALL=C sort -u) \
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
    printf '<p class="range">The first table lists every name configured as BOTH an <strong>application</strong> and a <strong>partner</strong> &mdash; two separate entities with their own detail pages, counts and result colors. The second lists the subscriptions whose configuration connects them to <strong>two partner groups</strong>. Each row names the accounts that put the name in each role.</p>\n'
    {
        awk -F'\t' -v B="$FBASE" -v X="$XREF" -v DET="$TRPT/details" '
            function e(s) { gsub(/&/, "\\&amp;", s); gsub(/</, "\\&lt;", s); gsub(/>/, "\\&gt;", s); gsub(/"/, "\\&quot;", s); return s }
            function loadbase(t, f,   l, a) { while ((getline l < f) > 0) { split(l, a, "\t")
                if (a[1] == "") continue
                NM[t, toupper(a[1])] = a[1]; DIRV[t, toupper(a[1])] = a[2]; RES[t, toupper(a[1])] = a[3] } close(f) }
            function loadslugs(t, f,   l, a) { while ((getline l < f) > 0) { split(l, a, "\t"); if (a[1] != "") SL[t, toupper(a[1])] = a[2] } close(f) }
            function loadpairs(arr, f, tag,   l, a, k) { while ((getline l < f) > 0) { split(l, a, "\t")
                if (a[1] == "" || a[2] == "") continue
                k = toupper(a[1])
                if (!((tag, k, a[2]) in PSEEN)) { PSEEN[tag, k, a[2]] = 1; arr[k] = arr[k] (arr[k] == "" ? "" : "\037") a[2] } } close(f) }
            function resc(r) { return (r == "green" || r == "orange" || r == "red" || r == "blue") ? " res-" r : "" }
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
        printf '<p class="range">Both roles are CORRECT products of the account naming convention, not collisions: a <strong>relay</strong> makes the middle token the internal system and the external party at once (the UC5 rule, and the 3-part <span class="mono">&hellip;_P2P</span> special; a UC8 relay reclassifies the partner token as an application), an account like <span class="mono">DOM_TOKEN_TOKEN</span> simply repeats the token, and the remaining cases are one organisation appearing as the middle segment of one account name and the trailing segment of another. A subscription with two partners comes from the same rules: a two-partner account name or a UC5 relay whose application token is also a partner.</p>\n'
    }
}


# ---- 9. Subscriptions in boxes ----------------------------------------------
# One row per CONFIGURED subscription — the whole estate, not a problem list —
# with one column per box saying what is true of it. TWENTY boxes (the account
# view adds a 21st, No subscriptions) from three kinds of source: a report's
# own .rpt, columns derived here from _files.tsv (One-legged, Waiting,
# Expired), and the config/coverage caches, which have no report at all
# (Not seen, Server log only, OK). _subs_box_rows below is the ONE authority
# for the box list — count there, not here.
# A cell names its box and links into it with ?axway_search=<name>, so a page
# with a search box arrives filtered. Its OWN analyses group (menu line, index
# section, sitemap card), which it LEADS as the group's overview. A missing
# source .rpt (production skips some server reports) contributes no rows,
# leaving that column empty — and report.js then hides it.
# Missing cron is the odd one out among the report-backed columns: the analyses
# pages are hand-rendered rather than .rpt-driven, so bin/analyses/publish.sh's
# Missing cronjobs page exports it as a TSV sidecar, written just before that
# script runs this one.
# _subs_box_rows -> "<colno>\t<subscription>" for the twenty boxes, one line
# per (box, subscription). SHARED by BOTH box pages: Subscriptions in boxes
# renders it directly, Accounts in boxes maps each subscription onto its
# configured accounts. Extracted so the two can never disagree about what a box
# MEANS — the account page is defined as "a connected subscription is in this
# box", so it has to start from exactly these rows and nothing recomputed.
_subs_box_rows() {
    local spec f c nf
        # column 1 — One-legged, REFINED (2026-07): a one-legged CoreId is only
        # a problem when NO OK File followed it — an OK delivery after the last
        # one-legged occurrence means the flow recovered. Computed from
        # _files.tsv directly (pirates' own condition is col 10 == 1, so the
        # membership can only shrink, never disagree with pirates-details);
        # the cache carries full sortkeys, so "after" is exact, not per-day.
        # OK = not Failed/Expired (the site-wide rule: Waiting counts as OK).
        # columns 5 + 6 — Waiting / Expired: the subscription's LAST _files
        # entry (max sortkey) has that outcome — the newest staged file is
        # still awaiting pickup (5) or was deleted before any pickup (6).
        if [ -f "$FILESC" ]; then
            awk -F'\t' '
                $12 == "" { next }
                {
                    if (!(($12) in ls)) orda[++na] = $12
                    if ($6 > ls[$12]) { ls[$12] = $6; lout[$12] = $2 }
                    if ($10 == 1) { if (!(($12) in lp)) ord[++n] = $12; if ($6 > lp[$12]) lp[$12] = $6 }
                    if ($2 != "Failed" && $2 != "Expired") { if ($6 > lo[$12]) lo[$12] = $6 }
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
            "2:$TRPT/from-green-to-red.rpt:../transfer/from-green-to-red.html:From green to red:2" \
            "3:$SRPT/went-kaput.rpt:../server/went-kaput.html:Trouble after success:2" \
            "4:$TRPT/only-red.rpt:../transfer/only-red.html:Only red:2" \
            "7:$SRPT/no-remote-dir.rpt:../server/no-remote-dir.html:No Dir:3" \
            "8:$SRPT/no-remote-files.rpt:../server/no-remote-files.html:No Files:3" \
            "9:$TRPT/missing-cronjobs.rpt:../transfer/missing-cronjobs.html:Missing cron:2" \
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
        # columns 11 + 12 have NO report of their own — they are states, read
        # straight from the sources the two Entities views are built from, so the
        # figures here and there cannot drift:
        #   11 not seen — showseen's coverage TSV, col 3 = the seen flag. This is
        #      the +Server reading, in which a server-log-only subscription counts
        #      as SEEN, so 11 and 12 are disjoint (verified: 0 overlap).
        #   12 server   — result "blue" in the base cache: known to the server log,
        #      never a transfer.
        [ -f "$TRPT/coverage/subscriptions.tsv" ] && \
            awk -F'\t' '$1 != "" && $3 == 0 { print "11\t" $1 }' "$TRPT/coverage/subscriptions.tsv"
        [ -f "$FBASE/_subscriptions.tsv" ] && \
            awk -F'\t' '$1 != "" && $3 == "blue" { print "12\t" $1 }' "$FBASE/_subscriptions.tsv"
        #   13 OK — result "green": the newest File was delivered. Also no report;
        #      the Subscriptions / OK entity view is the list. Including it is what
        #      turns this from a problem list into a complete box-up of the estate,
        #      so the first box can honestly say TOTAL.
        [ -f "$FBASE/_subscriptions.tsv" ] && \
            awk -F'\t' '$1 != "" && $3 == "green" { print "13\t" $1 }' "$FBASE/_subscriptions.tsv"
        #   17 seen — the TRANSFER-scope reading (2026-08): coverage col 3 != 0
        #      MINUS the blue set, which has its own box (12). The
        #      Subscriptions / Seen (Transfer scope) entity view is the list,
        #      and the invariant is Seen + Server log only + Not seen = Total.
        #   18 error — result "red": the newest File Failed or Expired, the
        #      exact opposite of 13. The Subscriptions / Error entity view is
        #      the list.
        [ -f "$TRPT/coverage/subscriptions.tsv" ] && \
            awk -F'\t' -v BF="$FBASE/_subscriptions.tsv" '
                BEGIN { while ((getline l < BF) > 0) { n = split(l, b, "\t"); if (n >= 3 && b[3] == "blue") BL[toupper(b[1])] = 1 } close(BF) }
                $1 != "" && $3 != 0 && !(toupper($1) in BL) { print "17\t" $1 }' "$TRPT/coverage/subscriptions.tsv"
        [ -f "$FBASE/_subscriptions.tsv" ] && \
            awk -F'\t' '$1 != "" && $3 == "red" { print "18\t" $1 }' "$FBASE/_subscriptions.tsv"
        # column 14 — Connection failures, UNRESOLVED (the One-legged rule): the
        # server logged a connection failure for this subscription and NO OK File
        # followed it. A flow whose connections failed and then delivered has
        # recovered; site-failures keeps the full history either way. The filter
        # is what makes the column mean "still broken" — it drops 36 of 48 here.
        # The failure instant comes from the @data:loglines payload (newest
        # first, so entry 1 is the latest) rather than the row's Last seen DATE,
        # which is too coarse to order against an OK File on the same day; a row
        # without the payload falls back to that date at END of day, so only an
        # OK on a LATER day clears it — the conservative reading, since wrongly
        # clearing hides a live problem while wrongly flagging only costs a look.
        if [ -f "$SRPT/site-failures.rpt" ] && [ -f "$FILESC" ]; then
            awk -F'\t' '
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
                { if ($12 != "" && $2 != "Failed" && $2 != "Expired" && $6 > lok[$12]) lok[$12] = $6 }
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
            awk -F'\t' -v LS="$XREF/_logins-subscriptions.tsv" '
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
                { if ($12 != "" && $2 != "Failed" && $2 != "Expired" && $6 > lok[$12]) lok[$12] = $6 }
                END { for (s in ce) if (lok[s] == "" || lok[s] < ce[s]) print "20\t" s }
            ' "$SRPT/logon.rpt" "$FILESC"
            awk -F'\t' -v HS="$XREF/_hosts-subscriptions.tsv" '
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
                    if (key == "" && $10 ~ /^[0-9]/) { d = $10; gsub(/-/, "", d); key = d "23:59:59.999" }
                    if (key == "") next
                    hu = tolower(h)
                    if (hu in SUBS) { m2 = split(substr(SUBS[hu], 2), S2, "\037")
                        for (i2 = 1; i2 <= m2; i2++) if (S2[i2] != "" && (!(S2[i2] in ce) || key > ce[S2[i2]])) ce[S2[i2]] = key }
                    next
                }
                { if ($12 != "" && $2 != "Failed" && $2 != "Expired" && $6 > lok[$12]) lok[$12] = $6 }
                END { for (s in ce) if (lok[s] == "" || lok[s] < ce[s]) print "21\t" s }
            ' "$SRPT/logon.rpt" "$FILESC"
        fi
        # column 19 — Failing polls: the UC3 scheduled poll itself errors
        # server-side — the state the UC status / UC3 page calls
        # "server - error". Read from that report's own rpt (status field 2,
        # subscription field 3), so the two can never disagree.
        if [ -f "$SRPT/uc3-status.rpt" ]; then
            awk -F'\t' '
                $1 == "TABLE" { t++; next }
                $1 != "ROW" || t != 1 { next }
                { st = $2; sub(/^@\{[^}]*\}/, "", st)
                  if (st != "server - error") next
                  nm = $3; sub(/^@\{[^}]*\}/, "", nm)
                  if (nm == "" || nm ~ / / || substr(nm, 1, 1) == "(") next
                  print "19\t" nm }
            ' "$SRPT/uc3-status.rpt"
        fi
        # column 15 — Deploy: the server told SecureTransport to ABANDON the
        # route (deploy-errors.rpt, ARSP0001 "stop further route execution").
        # That report already drops anything that recovered, so this box
        # inherits the UNRESOLVED reading like column 14. Its rows name an
        # ACCOUNT or a SUBSCRIPTION, so a subscription is flagged when it is
        # named directly OR when one of its configured accounts is.
        if [ -f "$SRPT/deploy-errors.rpt" ]; then
            awk -F'\t' -v AS="$XREF/_accounts-subscriptions.tsv" -v SUBF="$FBASE/_subscriptions.tsv" '
                BEGIN { while ((getline l < AS) > 0) { n = split(l, a, "\t")
                            if (n >= 2 && a[1] != "") ASUB[toupper(a[1])] = ASUB[toupper(a[1])] "\037" a[2] }
                        close(AS)
                        while ((getline l < SUBF) > 0) { split(l, a, "\t")
                            if (a[1] != "") EST[toupper(a[1])] = 1 }
                        close(SUBF) }
                $1 == "TABLE" { t++; next }
                $1 != "ROW" || t != 1 { next }
                { nm = $2; sub(/^@\{[^}]*\}/, "", nm); if (nm == "") next
                  k = toupper(nm)
                  # a "Subscription" name NOT in the configured estate would add
                  # a phantom row (the table rows are the union of the box
                  # lists) — send it through the account map instead.
                  if ($3 == "Subscription" && (k in EST)) { print "15\t" nm; next }
                  if (k in ASUB) { m = split(substr(ASUB[k], 2), S, "\037")
                                   for (i = 1; i <= m; i++) if (S[i] != "") print "15\t" S[i] } }
            ' "$SRPT/deploy-errors.rpt"
        fi
        :   # the tests above are the last commands; keep the exit status 0
}

# The "main reason" sidecar (2026-08): data/<env>/analyses/reports/
# _subs-boxes.tsv, "subscription <TAB> box label" — ONE line per subscription,
# naming the most specific box it sits in. The home page's Still-failing table
# shows it as the Reason column, so a red flow says WHY in the same vocabulary
# this page uses. Membership comes from _subs_box_rows (the one authority); the
# order below is the only thing decided here — most specific cause first.
# Boxes that are states rather than a cause are left out entirely: OK, Seen,
# Not seen, Server log only, and — deliberately — ERROR, box 18. "Error" only
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
        "3${TAB}19${TAB}Failing polls" \
        "4${TAB}14${TAB}Connection failures" \
        "5${TAB}21${TAB}Login errors (out)" \
        "6${TAB}20${TAB}Login errors (in)" \
        "7${TAB}1${TAB}One-legged" \
        "8${TAB}6${TAB}Expired" \
        "9${TAB}4${TAB}Only red" \
        "10${TAB}2${TAB}From green to red" \
        "11${TAB}9${TAB}Missing cron" \
        "12${TAB}8${TAB}No Files" \
        "13${TAB}5${TAB}Waiting"
}
# The evidence classifier for a red-by-server-log flow (see above). Input: the
# newest Error/Warn line that flipped it. Output: a short cause in the boxes'
# vocabulary, or "" when the line says nothing recognisable — better a blank
# cell than a guess. The function TEXT lives in bin/flip-reason.awk (2026-08):
# failed.sh classifies its Reason column with the same function, and the
# two must never drift apart — the home page's Reason and the Failed Subscriptions
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
                  # For a flow with a failed File, the page the home row opens
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
    if cmp -s "$side.tmp" "$side" 2>/dev/null; then rm -f "$side.tmp"; else mv "$side.tmp" "$side"; fi
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
    n12=$(printf '%s\n' "$probs" | awk -F'\t' '$1==12' | wc -l | tr -d ' ')
    n13=$(printf '%s\n' "$probs" | awk -F'\t' '$1==13' | wc -l | tr -d ' ')
    n14=$(printf '%s\n' "$probs" | awk -F'\t' '$1==14' | wc -l | tr -d ' ')
    n15=$(printf '%s\n' "$probs" | awk -F'\t' '$1==15' | wc -l | tr -d ' ')
    n17=$(printf '%s\n' "$probs" | awk -F'\t' '$1==17' | wc -l | tr -d ' ')
    n18=$(printf '%s\n' "$probs" | awk -F'\t' '$1==18' | wc -l | tr -d ' ')
    n19=$(printf '%s\n' "$probs" | awk -F'\t' '$1==19' | wc -l | tr -d ' ')
    n20=$(printf '%s\n' "$probs" | awk -F'\t' '$1==20' | wc -l | tr -d ' ')
    n21=$(printf '%s\n' "$probs" | awk -F'\t' '$1==21' | wc -l | tr -d ' ')
    {
        html_head "Subscriptions in boxes" "../assets/style.css" "" "ANALYSES" "subscriptions-in-boxes"
        printf '<h1>Subscriptions in boxes</h1>\n'
        analyses_group_tabs subscriptions-in-boxes.html   # the Subscriptions group row
        # The intro is GENERAL — what the page is and how to read it. What each
        # individual signal means belongs to the per-box explanation below the
        # boxes, which follows the active one (setupStatFilter swaps .pfshow).
        printf '<p class="subtitle">Every subscription configured in FlowManager, boxed by what is true of it. The page opens on the <strong>OK</strong> box; <strong>click a box</strong> to narrow the table to that box &mdash; the note under the boxes always explains the one you picked, and columns with nothing to show are hidden. A subscription can be in several boxes at once, and the one in several is the one to open first. Rows are sorted by name and tinted with the subscription&rsquo;s site-wide result color.</p>\n'
        # BOX COLOURS follow the site-wide result vocabulary (style.css .stat-*,
        # the same four tints as res-green/orange/red/blue), so a box reads the
        # same way as a row tint anywhere else:
        #   green  the flow is delivering            (OK)
        #   red    it is failing or has failed       (one leg, green->red, only
        #          red, expired, no Dir)
        #   orange attention, or not working YET     (troubles, waiting, no Files,
        #          no cron, quiet, not seen)
        #   blue   known to the server log only      (server)
        # The TOTAL box stays neutral: it is the whole estate, not a verdict.
        # The problem rows list the ORANGE boxes before the RED ones (same
        # relative order within each colour); the table columns mirror this.
        # data-pf-default: the box setupStatFilter opens the page on.
        printf '<div class="pfboxes" data-pf-default="13"><div class="stat pfon" data-pf=""><span class="stat-v">%s</span><span class="stat-l">Total subscriptions</span></div>' "$n_all"
        printf '<div class="stat stat-green" data-pf="13"><span class="stat-v">%s</span><span class="stat-l">OK</span></div>' "$n13"
        printf '<div class="stat" data-pf="17"><span class="stat-v">%s</span><span class="stat-l">Seen</span></div>' "$n17"
        printf '<div class="stat stat-orange" data-pf="11"><span class="stat-v">%s</span><span class="stat-l">Not seen</span></div>' "$n11"
        printf '<div class="stat stat-red" data-pf="18"><span class="stat-v">%s</span><span class="stat-l">Error</span></div>' "$n18"
        printf '<div class="stat stat-blue" data-pf="12"><span class="stat-v">%s</span><span class="stat-l">Server log only</span></div>' "$n12"
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
        printf '<div class="stat stat-red" data-pf="19"><span class="stat-v">%s</span><span class="stat-l">Failing polls</span></div>' "$n19"
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
        printf '<p class="range pfdesc" data-pf="2"><a href="../transfer/from-green-to-red.html?axway_search="><strong>From green to red</strong></a> &mdash; the REGRESSION list: the subscription is red right now (its latest File Failed or Expired) but an earlier day ended on an OK File. It <em>used to work</em> and broke since; <a href="../transfer/from-green-to-red.html?axway_search=">From green to red</a> names the day it flipped, which is where to start looking for what changed.</p>\n'
        printf '<p class="range pfdesc" data-pf="3"><a href="../server/went-kaput.html?axway_search="><strong>Trouble after success</strong></a> &mdash; the SERVER-log signal: the subscription&rsquo;s last transfer was OK, but it (or a connected login, account or remote host) logged an <strong>Error</strong> <em>after</em> that transfer, and the flow is <strong>still green</strong>. Warnings do not count &mdash; the warnings-only shape has its own <em>Transfer site missing</em> report. A fresh problem on a flow whose transfer history still looks healthy &mdash; the earliest warning you get, before a file fails. Where the same evidence has already reddened a flow it is no longer a warning but a failure, and the box for it is one of the red ones. <a href="../server/went-kaput.html?axway_search=">Trouble after Success</a> has the full list.</p>\n'
        printf '<p class="range pfdesc" data-pf="4"><a href="../transfer/only-red.html?axway_search="><strong>Only red</strong></a> &mdash; the NEVER-WORKED list: not one OK delivery in the whole window, every File Failed or Expired. This is not a regression (those are on <a href="../transfer/from-green-to-red.html?axway_search=">From green to red</a>) &mdash; nothing here ever worked, which points at the configuration or the partner side never having been finished, rather than at something that broke. <a href="../transfer/only-red.html?axway_search=">Only red</a> has the full list.</p>\n'
        printf '<p class="range pfdesc" data-pf="5"><a href="../transfer/waiting.html?axway_search="><strong>Waiting</strong></a> &mdash; the subscription&rsquo;s <strong>newest</strong> File is still STAGED for pickup: it arrived and sits in the folder, but the partner has not dialled in to collect it (UC2). Not an error &mdash; briefly waiting is the normal state of a pickup flow &mdash; but a newest file that has been waiting for days means the partner stopped collecting, and the retention sweep will delete it. <a href="../transfer/waiting.html?axway_search=">Waiting Files</a> has the full list.</p>\n'
        printf '<p class="range pfdesc" data-pf="6"><a href="../transfer/expired.html?axway_search="><strong>Expired</strong></a> &mdash; the subscription&rsquo;s <strong>newest</strong> staged File was DELETED by the nightly File Maintenance retention sweep (~11 days) before any pickup. It was never delivered and can no longer be collected &mdash; a silent failure: nothing errored, the file just aged out. Expired counts as an Error site-wide; <a href="../transfer/expired.html?axway_search=">the Expired report</a> has the retention timing and the per-account pickup behavior.</p>\n'
        printf '<p class="range pfdesc" data-pf="14"><a href="../server/site-failures.html?axway_search="><strong>Connection failures</strong></a> &mdash; the server log records a failed CONNECTION to the partner for this subscription (timeout, refused, dropped, an SSH negotiation that never completed), and <strong>no OK File has followed it</strong>. That filter is the whole point: connections fail transiently all the time and a flow that failed and then delivered has recovered, so only the still-unresolved ones are boxed here &mdash; 36 of 48 are cleared this way. It usually adds the <em>reason</em> to a subscription already boxed as Only red or One-legged: not merely &ldquo;nothing arrives&rdquo; but &ldquo;we cannot get a connection to the partner at all&rdquo;, which points at the partner host, the port or the credentials rather than at the flow. <a href="../server/site-failures.html?axway_search=">Connection Failures per Subscription</a> has the full list with the failure messages.</p>\n'
        printf '<p class="range pfdesc" data-pf="15"><a href="../server/deploy-errors.html?axway_search="><strong>Deploy</strong></a> &mdash; the server log records a <strong>configuration defect</strong> for this subscription: the Advanced Routing step error <span class="mono">ARSP0001</span>, where a routing step failed and <strong>its configuration told SecureTransport to abandon the rest of the route</strong> so nothing downstream ran for that file; or a PeSIT transfer profile <strong>missing its &ldquo;Receive File As&rdquo; field</strong>, which errors every incoming transfer of the flow. Like Connection failures, only the <strong>unresolved</strong> ones are boxed &mdash; an OK File after the last such message means something has got through since. The distinction from a plain failure is that the flow does not merely error, it <em>stops</em>: no onward delivery, no follow-up step, and the subscription can sit that way looking quiet rather than broken. The line names an account or a subscription, so an account is counted against every subscription configured for it. <a href="../server/deploy-errors.html?axway_search=">Deploy errors</a> has the full list with the message counts and the last occurrence.</p>\n'
        printf '<p class="range pfdesc" data-pf="20"><a href="../server/logons-incoming.html?axway_search="><strong>Login errors (in)</strong></a> &mdash; a login connected to this subscription FAILED the incoming SSH screening &mdash; disallowed address, unknown key, repeated key failures or a lockout &mdash; and <strong>no OK File has followed</strong> (the error day counts to its end, so only a later day&rsquo;s delivery clears it). The partner is knocking and not getting in; <a href="../server/logons-incoming.html?axway_search=">Logons / Incoming</a> has the per-login funnel with the drill-down log lines.</p>\n'
        printf '<p class="range pfdesc" data-pf="21"><a href="../server/logons-outgoing.html?axway_search="><strong>Login errors (out)</strong></a> &mdash; WE failed to authenticate at the remote host behind this subscription (wrong password, refused key or certificate policy) and <strong>no OK File has followed</strong>. The flow cannot fetch or deliver until the credential is fixed; <a href="../server/logons-outgoing.html?axway_search=">Logons / Outgoing</a> has the per-host failures split into Password / Key / Other.</p>\n'
        printf '<p class="range pfdesc" data-pf="7"><a href="../server/no-remote-dir.html?axway_search="><strong>No Dir</strong></a> &mdash; we reached the partner, asked for a directory listing, and the partner answered <em>No such file</em>: the configured REMOTE directory is not there. The connection and the credentials are fine &mdash; it is the path that is wrong, or was removed on the partner side. <a href="../server/no-remote-dir.html?axway_search=">No remote dir</a> has the full list.</p>\n'
        printf '<p class="range pfdesc" data-pf="8"><a href="../server/no-remote-files.html?axway_search="><strong>No Files</strong></a> &mdash; the UC3 poll works end to end (connection, credentials and listing all succeed) but the remote directory is <strong>always empty</strong>. Every slot spent here is a connection and a listing for no data: either the partner never delivers, or we are polling the wrong place. <a href="../server/no-remote-files.html?axway_search=">No remote files</a> has the full list.</p>\n'
        printf '<p class="range pfdesc" data-pf="19"><a href="uc-status-uc3.html?axway_search="><strong>Failing polls</strong></a> &mdash; the scheduled UC3 poll itself ERRORS: the server log shows the poll attempt failing on the server side, so nothing is ever listed or collected &mdash; this is the state the <a href="uc-status-uc3.html?axway_search=">UC status / UC3</a> page calls <strong>&ldquo;server - error&rdquo;</strong>. Different from <strong>No Dir</strong> (we reach the partner, the path is wrong) and <strong>No Files</strong> (the poll works, the directory is empty): here the poll does not complete at all. <a href="uc-status-uc3.html?axway_search=">UC status / UC3</a> has the full status view with the last log line per subscription.</p>\n'
        printf '<p class="range pfdesc" data-pf="9"><a href="../transfer/missing-cronjobs.html?axway_search="><strong>Missing cron</strong></a> &mdash; the only <em>configuration</em> signal here, and the only one that stops the flow before it ever starts. A subscription of a cron-triggered use case carries <strong>no cron expression at all</strong>, and nothing else would make it poll, so it simply never runs: no connection, no file, no error, and nothing in either log to notice. Nothing is broken and nothing errored &mdash; the flow was simply never finished, and its silence looks exactly like a partner that has gone quiet unless you check the configuration. <a href="../transfer/missing-cronjobs.html?axway_search=">Missing cronjobs</a> has the full list.</p>\n'
        printf '<p class="range pfdesc" data-pf="10"><a href="../transfer/went-quiet-subscriptions.html?axway_search="><strong>Went quiet</strong></a> &mdash; the flow carried Files and then simply stopped: nothing at all in the last <strong>7 days</strong> of the window, whatever the outcome used to be. It fires on an <em>absence where there used to be traffic</em>, which is why no error report catches it &mdash; nothing failed, there is just nothing there. Usually the partner stopped sending, the source system stopped producing, or the flow was decommissioned and never cleaned up. A subscription can be green and still be listed: green only means its LAST File was delivered, however long ago. <a href="../transfer/went-quiet-subscriptions.html?axway_search=">Went quiet</a> has the full list with the days.</p>\n'
        printf '<p class="range pfdesc" data-pf="11"><a href="../transfer/entities/subscription-not-seen.html?axway_search="><strong>Not seen</strong></a> &mdash; configured in FlowManager and never seen in <em>either</em> log: no transfer, no server-log mention. Not a broken flow but an unbuilt or abandoned one, and the emptiest box on the page: <strong>Server log only</strong> has at least a connection to show, and every box that judges delivery needs the flow to have run at least once. It has no report of its own &mdash; the <a href="../transfer/entities/subscription-not-seen.html?axway_search=">Subscriptions / Not seen</a> entity view is the full list.</p>\n'
        printf '<p class="range pfdesc" data-pf="12"><a href="../transfer/entities/subscription-server.html?axway_search="><strong>Server log only</strong></a> &mdash; the server log mentions it (a connection, a poll, an authentication) but it has never produced a transfer: the site-wide <strong>blue</strong> result. Something is reaching us and being recognised, yet no file ever completes &mdash; typically a flow configured and connecting but not yet delivering. Disjoint from <strong>Not seen</strong> by construction, since a server-log sighting counts as seen. No report of its own &mdash; the <a href="../transfer/entities/subscription-server.html?axway_search=">Subscriptions / Server</a> entity view is the full list.</p>\n'
        printf '<p class="range pfdesc" data-pf="13"><a href="../transfer/entities/subscription-ok.html?axway_search="><strong>OK</strong></a> &mdash; the subscription&rsquo;s <strong>newest</strong> File was delivered: the site-wide <strong>green</strong> result. Green describes that LAST File and nothing else, so an OK subscription can still sit in other boxes &mdash; a flow whose last File was delivered a month ago and which has carried nothing since is OK <em>and</em> Went quiet. No report of its own &mdash; the <a href="../transfer/entities/subscription-ok.html?axway_search=">Subscriptions / OK</a> entity view is the full list.</p>\n'
        printf '<p class="range pfdesc" data-pf="17"><a href="../transfer/entities/subscription-seen-transfer.html?axway_search="><strong>Seen</strong></a> &mdash; the subscription has real TRANSFER data: at least one File in the transfer log. A subscription known only from the server log is NOT counted here &mdash; that is its own box, <strong>Server log only</strong> &mdash; so Seen, Server log only and Not seen together are always the whole estate. No report of its own &mdash; the <a href="../transfer/entities/subscription-seen-transfer.html?axway_search=">Subscriptions / Seen (Transfer scope)</a> entity view is the full list.</p>\n'
        printf '<p class="range pfdesc" data-pf="18"><a href="../transfer/entities/subscription-error.html?axway_search="><strong>Error</strong></a> &mdash; the subscription&rsquo;s <strong>newest</strong> File Failed or Expired: the site-wide <strong>red</strong> result, the exact opposite of <strong>OK</strong>. <em>Which way</em> it is failing is what the other red boxes say &mdash; a red subscription is usually also in From green to red (it used to work) or Only red (it never did). No report of its own &mdash; the <a href="../transfer/entities/subscription-error.html?axway_search=">Subscriptions / Error</a> entity view is the full list.</p>\n'
        # nosearch: the stat-box filters are this page's narrowing mechanism —
        # report.js must not add its search box on top of them
        # SHORT column names, and .pftable for the 90% font — ELEVEN columns beside
        # 40+ character subscription names made this the widest page on the site.
        # The full name of each signal survives twice over: the stat box above the
        # table and the pfdesc paragraph still spell it out, and every flagged
        # cell keeps its long title= as the hover tooltip.
        printf '<div class="tablewrap"><table class="fit pftable" data-nosearch="1">\n'
        printf '<tr><th>Subscription</th><th data-pf="13">ok</th><th data-pf="17">seen</th><th data-pf="11">not seen</th><th data-pf="18">error</th><th data-pf="3">troubles</th><th data-pf="5">waiting</th><th data-pf="8">no Files</th><th data-pf="9">no cron</th><th data-pf="10">quiet</th><th data-pf="1">one leg</th><th data-pf="2">green-&gt;red</th><th data-pf="4">red</th><th data-pf="6">expired</th><th data-pf="14">connection</th><th data-pf="15">deploy</th><th data-pf="20">login in</th><th data-pf="21">login out</th><th data-pf="7">no Dir</th><th data-pf="19">failing polls</th><th data-pf="12">server</th></tr>\n'
        if [ -z "$probs" ]; then
            printf '<tr><td colspan="21">No subscription is in any box.</td></tr>\n'
        else
            printf '%s\n' "$probs" | awk -F'\t' '
                { k = $2; if (!(k in seen)) { seen[k] = 1; ord[++n] = k } f[k, $1] = 1 }
                END { for (i = 1; i <= n; i++) { k = ord[i]
                        c = ((k,1) in f) + ((k,2) in f) + ((k,3) in f) + ((k,4) in f) + ((k,5) in f) + ((k,6) in f) + ((k,7) in f) + ((k,8) in f) + ((k,9) in f) + ((k,10) in f) + ((k,11) in f) + ((k,12) in f) + ((k,13) in f) + ((k,14) in f) + ((k,15) in f) + ((k,17) in f) + ((k,18) in f) + ((k,19) in f) + ((k,20) in f) + ((k,21) in f)
                        printf "%d\t%s\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\n", c, k, ((k,1) in f), ((k,2) in f), ((k,3) in f), ((k,4) in f), ((k,5) in f), ((k,6) in f), ((k,7) in f), ((k,8) in f), ((k,9) in f), ((k,10) in f), ((k,11) in f), ((k,12) in f), ((k,13) in f), ((k,14) in f), ((k,15) in f), ((k,17) in f), ((k,18) in f), ((k,19) in f), ((k,20) in f), ((k,21) in f) } }' \
            | LC_ALL=C sort -t"$TAB" -k2,2 \
            | awk -F'\t' -v SM="$TRPT/details/subscriptions/_slugmap.tsv" -v SUBF="$FBASE/_subscriptions.tsv" '
                function e(s) { gsub(/&/, "\\&amp;", s); gsub(/</, "\\&lt;", s); gsub(/>/, "\\&gt;", s); gsub(/"/, "\\&quot;", s); return s }
                # a flagged cell carries the COLUMN NAME itself (not a symbol),
                # linking into that report with the subscription as the search.
                # The href is relative to docs/<env>/analyses/, so it needs the
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
                    if (index(href, "?") == 0) href = href "?axway_search=" nm
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
                    if (res != "green" && res != "orange" && res != "red" && res != "blue") res = ""
                    if (u in SL) nm = "<a href=\"../details/subscriptions/" SL[u] ".html\">" nm "</a>"
                    pf = ""
                    if ($3) pf = pf " 1"; if ($4) pf = pf " 2"; if ($5) pf = pf " 3"
                    if ($6) pf = pf " 4"; if ($7) pf = pf " 5"; if ($8) pf = pf " 6"; if ($9) pf = pf " 7"; if ($10) pf = pf " 8"
                    if ($11) pf = pf " 9"; if ($12) pf = pf " 10"; if ($13) pf = pf " 11"; if ($14) pf = pf " 12"; if ($15) pf = pf " 13"; if ($16) pf = pf " 14"; if ($17) pf = pf " 15"
                    if ($18) pf = pf " 17"; if ($19) pf = pf " 18"; if ($20) pf = pf " 19"
                    if ($21) pf = pf " 20"; if ($22) pf = pf " 21"
                    # 23 %s = 3 (data-pf, res attr, name) + ONE PER FLAG CELL,
                    # now 20. awk silently DROPS a surplus argument, so a
                    # miscount costs the LAST column its cells site-wide.
                    printf "<tr data-pf=\"%s\"%s><td class=\"cl\">%s</td>%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s</tr>\n", \
                        substr(pf, 2), (res != "" ? " data-res=\"" res "\"" : ""), nm, \
                        flag($15, "../transfer/entities/subscription-ok.html", e($2), "Newest File delivered \342\200\224 the subscription is green", "ok", "pfok"), \
                        flag($18, "../transfer/entities/subscription-seen-transfer.html", e($2), "Seen in the transfer log \342\200\224 at least one File", "seen", "pfneu"), \
                        flag($13, "../transfer/entities/subscription-not-seen.html", e($2), "Configured, never seen in either log", "not seen"), \
                        flag($19, "../transfer/entities/subscription-error.html", e($2), "Newest File Failed or Expired \342\200\224 the subscription is red", "error"), \
                        flag($5, "../server/went-kaput.html", e($2), "On Trouble after Success", "troubles"), \
                        flag($7, "../transfer/waiting.html", e($2), "Newest File is Waiting", "waiting"), \
                        flag($10, "../server/no-remote-files.html", e($2), "On No remote files", "no Files"), \
                        flag($11, "../transfer/missing-cronjobs.html", e($2), "Cron-triggered, but no cron expression configured", "no cron"), \
                        flag($12, "../transfer/went-quiet-subscriptions.html", e($2), "Carried Files, then stopped \342\200\224 no traffic in the last 7 days", "quiet"), \
                        flag($3, "../transfer/pirates-details.html", e($2), "On One-legged transfers", "one leg"), \
                        flag($4, "../transfer/from-green-to-red.html", e($2), "On From green to red", "green-&gt;red"), \
                        flag($6, "../transfer/only-red.html", e($2), "On Only red", "red"), \
                        flag($8, "../transfer/expired.html", e($2), "Newest File is Expired", "expired"), \
                        flag($16, "../server/site-failures.html", e($2), "The server logged a connection failure and no OK File followed it", "connection"), \
                        flag($17, "../server/deploy-errors.html", e($2), "A configuration defect stopped the flow (route abandoned, or the profile cannot receive) and no OK File followed it", "deploy"), \
                        flag($21, "../server/logons-incoming.html?axway_sort=2:-1", e($2), "A connected login failed the incoming SSH screening and no OK File followed", "login in"), \
                        flag($22, "../server/logons-outgoing.html?axway_sort=2:-1", e($2), "We failed to authenticate at the remote host and no OK File followed", "login out"), \
                        flag($9, "../server/no-remote-dir.html", e($2), "On No remote dir", "no Dir"), \
                        flag($20, "uc-status-uc3.html", e($2), "The UC3 poll fails server-side \342\200\224 \"server - error\" on UC status", "failing polls"), \
                        flag($14, "../transfer/entities/subscription-server.html", e($2), "Seen in the server log only \342\200\224 never a transfer", "server")
                }'
            # 17 numeric cells in COLUMN order (the previous version was one
            # cell short — the deploy column was missing, latent because
            # setupStatFilter rewrites this row; it is also the no-JS fallback)
            printf '<tr class="total"><td>Total (%s subscriptions)</td><td class="num">%s</td><td class="num">%s</td><td class="num">%s</td><td class="num">%s</td><td class="num">%s</td><td class="num">%s</td><td class="num">%s</td><td class="num">%s</td><td class="num">%s</td><td class="num">%s</td><td class="num">%s</td><td class="num">%s</td><td class="num">%s</td><td class="num">%s</td><td class="num">%s</td><td class="num">%s</td><td class="num">%s</td><td class="num">%s</td><td class="num">%s</td><td class="num">%s</td></tr>\n' \
                "$n_all" "$n13" "$n17" "$n11" "$n18" "$n3" "$n5" "$n8" "$n9" "$n10" "$n1" "$n2" "$n4" "$n6" "$n14" "$n15" "$n20" "$n21" "$n7" "$n19" "$n12"
        fi
        printf '</table></div>\n'
        printf '<p class="range">Sources: seven of the columns are read from the reports&rsquo; own data files, so this page always agrees with them. Three more are derived here from the transfer cache (<span class="mono">_files.tsv</span>): <strong>One-legged</strong> is the refined, still-unresolved subset of <a href="../transfer/pirates-details.html">pirates-details</a>, and <strong>Waiting</strong> / <strong>Expired</strong> test the state of the subscription&rsquo;s newest File &mdash; see the note under the box you pick. The last five have no report at all: <strong>OK</strong>, <strong>Error</strong> and <strong>Server log only</strong> are the site-wide green, red and blue results straight from the configuration cache, and <strong>Seen</strong> / <strong>Not seen</strong> are showseen&rsquo;s coverage flag both ways &mdash; the same sources the <a href="../transfer/entities/subscription-all.html">Entities views</a> are built from, so the figures cannot drift. A source that does not exist in this environment contributes no rows rather than failing the page, and its column is then hidden along with every other column that has nothing to show.</p>\n'
        printf '</body>\n</html>\n'
    } > "$out"
}

# ---- Accounts in boxes (docs/<env>/analyses/accounts-in-boxes.html)
#
# The ACCOUNT view of the same twenty boxes: an account is in a box when one of
# its CONNECTED SUBSCRIPTIONS is. Connection is taken ONLY from the xref cache
# data/<env>/flow-manager/xref/_subscriptions-accounts.tsv — never from the
# names. The two are related by convention (a subscription is commonly
# UC<n>_<account>_<account>), which makes name matching look like it works:
# measured here, every one of the 363 connected account names IS a substring of
# one of its subscriptions. It is still the wrong key — the convention is not a
# guarantee, the separator twins (FRE-SAPCD-X / FRE_SAPCD_X) are DIFFERENT
# entities that a loose match merges, and a substring hit says nothing about
# which subscription. The xref is the configuration itself.
#
# So the per-cell link carries the SUBSCRIPTIONS that put the account in that
# box, joined with the site search operator " or " — the cell lands on exactly
# those rows of the existing subscription report, and no Account version of
# those reports is needed. Longest such link in acceptance is ~860 characters
# (one account with 16 subscriptions in one box); the query string is read by
# report.js and never sent anywhere, so length is a non-issue.
#
# ONE box is account-only: "no subs" (16), the account no subscription
# references at all. Without it those 11 accounts would sit in NO box and the
# Total would stop meaning "every account is in at least one box" -- the
# property that makes this a box-up of the estate rather than a problem list.
# It is the same condition as the WARN banner on the account detail page and
# as Config hygiene's "Account without subscriptions", which is where it links.
write_accounts_in_boxes_page() {
    local out="$ADIR/accounts-in-boxes.html"
    local TAB; TAB=$(printf '\t')
    local SA="$XREF/_subscriptions-accounts.tsv" ACCF="$FBASE/_accounts.tsv"
    [ -f "$ACCF" ] || return 0
    [ -f "$SA" ] || return 0
    # rows: box \t account \t subscription   (box 16 carries an empty subscription)
    local rows
    rows=$(
        _subs_box_rows | awk -F'\t' -v SA="$SA" -v ACCF="$ACCF" '
            BEGIN { while ((getline l < SA) > 0) { n = split(l, a, "\t")
                        if (n >= 2 && a[1] != "" && a[2] != "")
                            A[toupper(a[1])] = A[toupper(a[1])] "\037" a[2] }
                    close(SA)
                    while ((getline l < ACCF) > 0) { split(l, a, "\t")
                        if (a[1] != "" && a[3] == "green") GRN[toupper(a[1])] = 1 }
                    close(ACCF) }
            # Box 13 (OK) is the one box that judges the ACCOUNT, not a single
            # subscription: only accounts whose own site-wide result is GREEN
            # (= every connected subscription green) are kept — one green flow
            # among red ones must not put the account in the OK box.
            { k = toupper($2); if (!(k in A)) next
              m = split(substr(A[k], 2), S, "\037")
              for (i = 1; i <= m; i++)
                  if ($1 != 13 || (toupper(S[i]) in GRN)) print $1 "\t" S[i] "\t" $2 }'
        awk -F'\t' -v SA="$SA" '
            BEGIN { while ((getline l < SA) > 0) { n = split(l, a, "\t")
                        if (n >= 2 && a[2] != "") HAS[toupper(a[2])] = 1 }
                    close(SA) }
            $1 != "" && !(toupper($1) in HAS) { print "16\t" $1 "\t" }' "$ACCF"
        :
    )
    # distinct ACCOUNTS per box (a box row exists per connected subscription)
    local a_all a1 a2 a3 a4 a5 a6 a7 a8 a9 a10 a11 a12 a13 a14 a15 a16 a17 a18 i
    a_all=$(printf '%s\n' "$rows" | awk -F'\t' '$2!=""{ if(!s[$2]++) n++ } END{print n+0}')
    for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21; do
        eval "a$i=\$(printf '%s\n' \"\$rows\" | awk -F'\t' -v b=$i '\$1==b && \$2!=\"\" { if(!s[\$2]++) n++ } END{print n+0}')"
    done
    # box | th label | href (analyses-relative) | cell title | extra class
    # Display order mirrors Subscriptions in boxes — the problem boxes ORANGE
    # before RED — with the account-only "no subs" beside "no cron": both say
    # the configuration was never finished.
    local BOXSPEC
    BOXSPEC=$(printf '%s\037' \
        '13|ok|../transfer/entities/subscription-ok.html|The account is green: every connected subscription delivers|pfok' \
        '17|seen|../transfer/entities/subscription-seen-transfer.html|A connected subscription has real transfer data (server-log-only does not count)|pfneu' \
        '11|not seen|../transfer/entities/subscription-not-seen.html|A connected subscription was never seen in either log|' \
        '18|error|../transfer/entities/subscription-error.html|A connected subscription is red: its newest File Failed or Expired|' \
        '3|troubles|../server/went-kaput.html|A connected subscription logged an Error or Warning after its last OK transfer|' \
        '5|waiting|../transfer/waiting.html|The newest File of a connected subscription is still staged for pickup|' \
        '8|no Files|../server/no-remote-files.html|A connected subscription polls fine but the remote directory is always empty|' \
        '9|no cron|../transfer/missing-cronjobs.html|A connected subscription is cron-triggered with no cron expression|' \
        '16|no subs|config-hygiene.html|No subscription references this account at all|' \
        '10|quiet|../transfer/went-quiet-subscriptions.html|A connected subscription carried Files and then stopped|' \
        '1|one leg|../transfer/pirates-details.html|A connected subscription has an unresolved one-legged transfer|' \
        '2|green-&gt;red|../transfer/from-green-to-red.html|A connected subscription used to work and is red now|' \
        '4|red|../transfer/only-red.html|A connected subscription has never had an OK delivery|' \
        '6|expired|../transfer/expired.html|The newest File of a connected subscription was deleted before pickup|' \
        '14|connection|../server/site-failures.html|A connected subscription has an unresolved connection failure|' \
        '15|deploy|../server/deploy-errors.html|A connected subscription has an unresolved configuration defect (abandoned route, or a profile that cannot receive)|' \
        '20|login in|../server/logons-incoming.html?axway_sort=2:-1|A connected login failed the incoming SSH screening and no OK File followed|' \
        '21|login out|../server/logons-outgoing.html?axway_sort=2:-1|We failed to authenticate at a remote host of a connected subscription and no OK File followed|' \
        '7|no Dir|../server/no-remote-dir.html|The remote directory of a connected subscription does not exist|' \
        '19|failing polls|uc-status-uc3.html|The UC3 poll of a connected subscription fails server-side ("server - error" on UC status)|' \
        '12|server|../transfer/entities/subscription-server.html|A connected subscription is seen in the server log only|')
    {
        html_head "Accounts in boxes" "../assets/style.css" "" "ANALYSES" "accounts-in-boxes"
        printf '<h1>Accounts in boxes</h1>\n'
        analyses_group_tabs accounts-in-boxes.html
        printf '<p class="subtitle">Every account configured in FlowManager, boxed by what is true of <em>the subscriptions connected to it</em>: an account is in a box when at least one of its subscriptions is &mdash; except <strong>OK</strong>, which holds only the accounts that are green as a whole (every connected subscription green). The page opens on the <strong>OK</strong> box; <strong>click a box</strong> to narrow the table &mdash; the note under the boxes always explains the one you picked, and columns with nothing to show are hidden. Each flagged cell opens the subscription report already searched for <em>the subscriptions that put this account in that box</em>, so there is no account version of those reports to keep in step. Accounts are connected to subscriptions through the FlowManager configuration, never by name. Rows are sorted by name and tinted with the account&rsquo;s site-wide result color.</p>\n'
        printf '<div class="pfboxes" data-pf-default="13"><div class="stat pfon" data-pf=""><span class="stat-v">%s</span><span class="stat-l">Total accounts</span></div>' "$a_all"
        printf '<div class="stat stat-green" data-pf="13"><span class="stat-v">%s</span><span class="stat-l">OK</span></div>' "$a13"
        printf '<div class="stat" data-pf="17"><span class="stat-v">%s</span><span class="stat-l">Seen</span></div>' "$a17"
        printf '<div class="stat stat-orange" data-pf="11"><span class="stat-v">%s</span><span class="stat-l">Not seen</span></div>' "$a11"
        printf '<div class="stat stat-red" data-pf="18"><span class="stat-v">%s</span><span class="stat-l">Error</span></div>' "$a18"
        printf '<div class="stat stat-blue" data-pf="12"><span class="stat-v">%s</span><span class="stat-l">Server log only</span></div>' "$a12"
        printf '<div class="pfbreak"></div>'
        printf '<div class="stat stat-orange" data-pf="3"><span class="stat-v">%s</span><span class="stat-l">Trouble after success</span></div>' "$a3"
        printf '<div class="stat stat-orange" data-pf="5"><span class="stat-v">%s</span><span class="stat-l">Waiting</span></div>' "$a5"
        printf '<div class="stat stat-orange" data-pf="8"><span class="stat-v">%s</span><span class="stat-l">No Files</span></div>' "$a8"
        printf '<div class="stat stat-orange" data-pf="9"><span class="stat-v">%s</span><span class="stat-l">Missing cron</span></div>' "$a9"
        printf '<div class="stat stat-orange" data-pf="16"><span class="stat-v">%s</span><span class="stat-l">No subscriptions</span></div>' "$a16"
        printf '<div class="stat stat-orange" data-pf="10"><span class="stat-v">%s</span><span class="stat-l">Went quiet</span></div>' "$a10"
        printf '<div class="stat stat-red" data-pf="1"><span class="stat-v">%s</span><span class="stat-l">One-legged</span></div>' "$a1"
        printf '<div class="stat stat-red" data-pf="2"><span class="stat-v">%s</span><span class="stat-l">From green to red</span></div>' "$a2"
        printf '<div class="stat stat-red" data-pf="4"><span class="stat-v">%s</span><span class="stat-l">Only red</span></div>' "$a4"
        printf '<div class="stat stat-red" data-pf="6"><span class="stat-v">%s</span><span class="stat-l">Expired</span></div>' "$a6"
        printf '<div class="stat stat-red" data-pf="14"><span class="stat-v">%s</span><span class="stat-l">Connection failures</span></div>' "$a14"
        printf '<div class="stat stat-red" data-pf="15"><span class="stat-v">%s</span><span class="stat-l">Deploy</span></div>' "$a15"
        printf '<div class="stat stat-red" data-pf="20"><span class="stat-v">%s</span><span class="stat-l">Login errors (in)</span></div>' "$a20"
        printf '<div class="stat stat-red" data-pf="21"><span class="stat-v">%s</span><span class="stat-l">Login errors (out)</span></div>' "$a21"
        printf '<div class="stat stat-red" data-pf="7"><span class="stat-v">%s</span><span class="stat-l">No Dir</span></div>' "$a7"
        printf '<div class="stat stat-red" data-pf="19"><span class="stat-v">%s</span><span class="stat-l">Failing polls</span></div>' "$a19"
        printf '</div>\n'
        printf '<p class="range pfdesc pfshow" data-pf=""><a href="../transfer/entities/account-all.html?axway_search="><strong>Total accounts</strong></a> &mdash; every account configured in FlowManager, whatever its state, and each one is in at least one of the boxes above. Twenty of the boxes describe the account&rsquo;s <em>subscriptions</em>; the one that is not, <strong>No subscriptions</strong>, is the account that has none for them to describe. The same estate with each account&rsquo;s own traffic figures is the <a href="../transfer/entities/account-all.html?axway_search=">Accounts / All</a> entity view.</p>\n'
        printf '<p class="range pfdesc" data-pf="13"><a href="../transfer/entities/account-ok.html?axway_search="><strong>OK</strong></a> &mdash; the account itself is <strong>green</strong>: the site-wide rollup, which an account only gets when <strong>every</strong> connected subscription is green. This is the one box that judges the whole account rather than a single flow &mdash; an account with one delivering flow beside a red one is NOT here (it is in Error, and in the red box that says why). Green still describes each subscription&rsquo;s LAST File and nothing else, so an OK account can sit in Went quiet at the same time. The <a href="../transfer/entities/account-ok.html?axway_search=">Accounts / OK</a> entity view is the full list.</p>\n'
        printf '<p class="range pfdesc" data-pf="17"><a href="../transfer/entities/subscription-seen-transfer.html?axway_search="><strong>Seen</strong></a> &mdash; at least one connected subscription has real TRANSFER data: a File in the transfer log. A flow known only from the server log does NOT count here &mdash; that is the <strong>Server log only</strong> box. The <a href="../transfer/entities/subscription-seen-transfer.html?axway_search=">Subscriptions / Seen (Transfer scope)</a> entity view is the full list.</p>\n'
        printf '<p class="range pfdesc" data-pf="18"><a href="../transfer/entities/subscription-error.html?axway_search="><strong>Error</strong></a> &mdash; at least one connected subscription is <strong>red</strong>: its newest File Failed or Expired, the exact opposite of <strong>OK</strong> &mdash; and an account with several flows is routinely in both boxes at once. <em>Which way</em> it is failing is what the other red boxes say. The <a href="../transfer/entities/subscription-error.html?axway_search=">Subscriptions / Error</a> entity view is the full list.</p>\n'
        printf '<p class="range pfdesc" data-pf="1"><a href="../transfer/pirates-details.html?axway_search="><strong>One-legged</strong></a> &mdash; a connected subscription logged a transfer with only ONE leg, and no OK File has followed it. A complete transfer is store-and-forward: an Inbound leg (partner &rarr; ST) and an Outbound leg (ST &rarr; partner), so a single-leg CoreId means the file never made the full crossing. <a href="../transfer/pirates-details.html?axway_search=">One-Legged Transfers</a> has the full history.</p>\n'
        printf '<p class="range pfdesc" data-pf="2"><a href="../transfer/from-green-to-red.html?axway_search="><strong>From green to red</strong></a> &mdash; a connected subscription is red right now but ended an earlier day on an OK File: it <em>used to work</em> and broke since. <a href="../transfer/from-green-to-red.html?axway_search=">From green to red</a> names the day it flipped, which is where to start looking for what changed.</p>\n'
        printf '<p class="range pfdesc" data-pf="3"><a href="../server/went-kaput.html?axway_search="><strong>Trouble after success</strong></a> &mdash; a connected subscription had an OK last transfer but logged an Error or Warning <em>after</em> it. The earliest warning available: a fresh problem on a flow whose transfer history still looks healthy, before any file fails. <a href="../server/went-kaput.html?axway_search=">Trouble after Success</a> has the full list.</p>\n'
        printf '<p class="range pfdesc" data-pf="4"><a href="../transfer/only-red.html?axway_search="><strong>Only red</strong></a> &mdash; a connected subscription has never had one OK delivery in the whole window. Not a regression but a flow that never worked, which points at the configuration or the partner side never having been finished. <a href="../transfer/only-red.html?axway_search=">Only red</a> has the full list.</p>\n'
        printf '<p class="range pfdesc" data-pf="5"><a href="../transfer/waiting.html?axway_search="><strong>Waiting</strong></a> &mdash; the newest File of a connected subscription is still STAGED for pickup: it arrived and sits in the folder, but the partner has not dialled in to collect it (UC2). Briefly waiting is the normal state of a pickup flow; days of waiting means the partner stopped collecting, and the retention sweep will delete it. <a href="../transfer/waiting.html?axway_search=">Waiting Files</a> has the full list.</p>\n'
        printf '<p class="range pfdesc" data-pf="6"><a href="../transfer/expired.html?axway_search="><strong>Expired</strong></a> &mdash; the newest staged File of a connected subscription was DELETED by the nightly retention sweep (~11 days) before any pickup. Never delivered, no longer collectable, and nothing errored &mdash; the file just aged out. <a href="../transfer/expired.html?axway_search=">The Expired report</a> has the retention timing and the per-account pickup behavior.</p>\n'
        printf '<p class="range pfdesc" data-pf="14"><a href="../server/site-failures.html?axway_search="><strong>Connection failures</strong></a> &mdash; the server log records a failed CONNECTION to the partner for a connected subscription (timeout, refused, dropped, an SSH negotiation that never completed) and <strong>no OK File has followed it</strong>. Connections fail transiently all the time, so only the still-unresolved ones are boxed. It usually adds the <em>reason</em> to an account already boxed as Only red or One-legged: not merely &ldquo;nothing arrives&rdquo; but &ldquo;we cannot get a connection at all&rdquo;, which points at the partner host, the port or the credentials. <a href="../server/site-failures.html?axway_search=">Connection Failures per Subscription</a> has the failure messages.</p>\n'
        printf '<p class="range pfdesc" data-pf="15"><a href="../server/deploy-errors.html?axway_search="><strong>Deploy</strong></a> &mdash; the server log records a <strong>configuration defect</strong> for a connected subscription: the Advanced Routing step error <span class="mono">ARSP0001</span>, where a routing step failed and <strong>its configuration told SecureTransport to abandon the rest of the route</strong>; or a PeSIT transfer profile <strong>missing its &ldquo;Receive File As&rdquo; field</strong>, which errors every incoming transfer of the flow. Only the <strong>unresolved</strong> ones are boxed. The flow does not merely error, it <em>stops</em>, so it can sit looking quiet rather than broken. <a href="../server/deploy-errors.html?axway_search=">Deploy errors</a> has the message counts and the last occurrence.</p>\n'
        printf '<p class="range pfdesc" data-pf="20"><a href="../server/logons-incoming.html?axway_search="><strong>Login errors (in)</strong></a> &mdash; a login of a connected subscription FAILED the incoming SSH screening (disallowed address, unknown key, repeated key failures or a lockout) and no OK File has followed. <a href="../server/logons-incoming.html?axway_search=">Logons / Incoming</a> has the per-login funnel.</p>\n'
        printf '<p class="range pfdesc" data-pf="21"><a href="../server/logons-outgoing.html?axway_search="><strong>Login errors (out)</strong></a> &mdash; we failed to authenticate at a remote host behind a connected subscription (wrong password, refused key or certificate policy) and no OK File has followed. <a href="../server/logons-outgoing.html?axway_search=">Logons / Outgoing</a> has the per-host split into Password / Key / Other.</p>\n'
        printf '<p class="range pfdesc" data-pf="7"><a href="../server/no-remote-dir.html?axway_search="><strong>No Dir</strong></a> &mdash; we reached the partner for a connected subscription, asked for a directory listing, and the partner answered <em>No such file</em>: the configured REMOTE directory is not there. Connection and credentials are fine &mdash; it is the path that is wrong, or was removed on the partner side. <a href="../server/no-remote-dir.html?axway_search=">No remote dir</a> has the full list.</p>\n'
        printf '<p class="range pfdesc" data-pf="8"><a href="../server/no-remote-files.html?axway_search="><strong>No Files</strong></a> &mdash; a connected UC3 poll works end to end (connection, credentials and listing all succeed) but the remote directory is <strong>always empty</strong>. Every slot spent there is a connection and a listing for no data: either the partner never delivers, or we poll the wrong place. <a href="../server/no-remote-files.html?axway_search=">No remote files</a> has the full list.</p>\n'
        printf '<p class="range pfdesc" data-pf="19"><a href="uc-status-uc3.html?axway_search="><strong>Failing polls</strong></a> &mdash; the scheduled UC3 poll of a connected subscription ERRORS on the server side, so nothing is ever listed or collected &mdash; the state the <a href="uc-status-uc3.html?axway_search=">UC status / UC3</a> page calls <strong>&ldquo;server - error&rdquo;</strong>. Different from <strong>No Dir</strong> (wrong path) and <strong>No Files</strong> (empty directory): the poll does not complete at all. <a href="uc-status-uc3.html?axway_search=">UC status / UC3</a> has the full status view.</p>\n'
        printf '<p class="range pfdesc" data-pf="9"><a href="../transfer/missing-cronjobs.html?axway_search="><strong>Missing cron</strong></a> &mdash; a connected subscription of a cron-triggered use case carries <strong>no cron expression at all</strong>, so nothing makes it poll and it simply never runs: no connection, no file, no error, nothing in either log to notice. Its silence looks exactly like a partner that has gone quiet unless you check the configuration. <a href="../transfer/missing-cronjobs.html?axway_search=">Missing cronjobs</a> has the full list.</p>\n'
        printf '<p class="range pfdesc" data-pf="16"><a href="config-hygiene.html?axway_search="><strong>No subscriptions</strong></a> &mdash; the account-only box, and the one that is not about a flow at all: <strong>no subscription references this account</strong>, so nothing can ever route a file through it. It is configured and inert &mdash; the other twenty boxes have nothing to say about it because there is no subscription for them to judge. The same condition puts the amber banner on the <a href="../transfer/entities/account-all.html?axway_search=">account detail page</a> and lists it under &ldquo;Account without subscriptions&rdquo; on <a href="config-hygiene.html?axway_search=">Config hygiene</a>.</p>\n'
        printf '<p class="range pfdesc" data-pf="10"><a href="../transfer/went-quiet-subscriptions.html?axway_search="><strong>Went quiet</strong></a> &mdash; a connected subscription carried Files and then simply stopped: nothing at all in the last <strong>7 days</strong>. It fires on an <em>absence where there used to be traffic</em>, which is why no error report catches it &mdash; nothing failed, there is just nothing there. An account can be OK and still be listed: OK only means one subscription delivered its LAST File, however long ago. <a href="../transfer/went-quiet-subscriptions.html?axway_search=">Went quiet</a> has the full list with the days.</p>\n'
        printf '<p class="range pfdesc" data-pf="11"><a href="../transfer/entities/subscription-not-seen.html?axway_search="><strong>Not seen</strong></a> &mdash; a connected subscription is configured and has never been seen in <em>either</em> log: no transfer, no server-log mention. Not a broken flow but an unbuilt or abandoned one. The <a href="../transfer/entities/subscription-not-seen.html?axway_search=">Subscriptions / Not seen</a> entity view is the full list.</p>\n'
        printf '<p class="range pfdesc" data-pf="12"><a href="../transfer/entities/subscription-server.html?axway_search="><strong>Server log only</strong></a> &mdash; the server log mentions a connected subscription (a connection, a poll, an authentication) but it has never produced a transfer: the site-wide <strong>blue</strong> result. Something is reaching us and being recognised, yet no file completes. Disjoint from <strong>Not seen</strong>, since a server-log sighting counts as seen. The <a href="../transfer/entities/subscription-server.html?axway_search=">Subscriptions / Server</a> entity view is the full list.</p>\n'
        # data-pf-noun: setupStatFilter writes the total row itself and needs the
        # unit; without it the footer would read "subscriptions" on this page.
        printf '<div class="tablewrap"><table class="fit pftable" data-nosearch="1" data-pf-noun="account">\n'
        printf '%s\n' "$BOXSPEC" | awk -v RS='\037' -F'|' '
            BEGIN { printf "<tr><th>Account</th>" }
            NF >= 2 { printf "<th data-pf=\"%s\">%s</th>", $1, $2 }
            END { print "</tr>" }'
        if [ -z "$rows" ]; then
            printf '<tr><td colspan="22">No account is in any box.</td></tr>\n'
        else
            printf '%s\n' "$rows" | LC_ALL=C sort -t"$TAB" -k2,2 -k1,1n -k3,3 \
            | awk -F'\t' -v SPEC="$BOXSPEC" -v SM="$TRPT/details/accounts/_slugmap.tsv" -v ACCF="$ACCF" '
                function e(s) { gsub(/&/, "\\&amp;", s); gsub(/</, "\\&lt;", s); gsub(/>/, "\\&gt;", s); gsub(/"/, "\\&quot;", s); return s }
                # the cell carries the COLUMN NAME and opens that report already
                # searched for the SUBSCRIPTIONS behind this flag, joined with the
                # site search operator " or " (%20or%20 once URL-encoded). Box 16
                # has no subscription, so it searches the ACCOUNT on Config hygiene.
                function cell(b, acct,   q) {
                    if (!((acct, b) in SUB)) return "<td></td>"
                    q = substr(SUB[acct, b], 2); gsub(/\037/, "%20or%20", q)
                    if (b == 16) q = acct
                    # an href already carrying a query is used as-is (the two
                    # login-error boxes: the Logons rows are logins/hosts)
                    if (index(HREF[b], "?") > 0)
                        return "<td class=\"ctr\"><a class=\"pfx" (CLS[b] != "" ? " " CLS[b] : "") "\" href=\"" HREF[b] "\" title=\"" e(TTL[b]) "\">" LBL[b] "</a></td>"
                    return "<td class=\"ctr\"><a class=\"pfx" (CLS[b] != "" ? " " CLS[b] : "") "\" href=\"" HREF[b] "?axway_search=" q "\" title=\"" e(TTL[b]) "\">" LBL[b] "</a></td>"
                }
                function flush(   i, pf, out) {
                    if (cur == "") return
                    pf = ""; out = ""
                    for (i = 1; i <= nb; i++) {
                        if ((cur, ORD[i]) in SUB) pf = pf " " ORD[i]
                        out = out cell(ORD[i], cur)
                    }
                    nm = e(cur)
                    if (toupper(cur) in SL) nm = "<a href=\"../details/accounts/" SL[toupper(cur)] ".html\">" nm "</a>"
                    printf "<tr data-pf=\"%s\"%s><td class=\"cl\">%s</td>%s</tr>\n", \
                        substr(pf, 2), (RES[toupper(cur)] != "" ? " data-res=\"" RES[toupper(cur)] "\"" : ""), nm, out
                }
                BEGIN {
                    nb = split(SPEC, B, "\037")
                    for (i = 1; i <= nb; i++) {
                        if (B[i] == "") { nb = i - 1; break }
                        split(B[i], F, "|")
                        ORD[i] = F[1] + 0; LBL[F[1]+0] = F[2]; HREF[F[1]+0] = F[3]; TTL[F[1]+0] = F[4]; CLS[F[1]+0] = F[5]
                    }
                    while ((getline l < SM) > 0) { split(l, a, "\t"); if (a[1] != "") SL[toupper(a[1])] = a[2] } close(SM)
                    while ((getline l < ACCF) > 0) { split(l, a, "\t")
                        if (a[1] != "" && (a[3] == "green" || a[3] == "orange" || a[3] == "red" || a[3] == "blue"))
                            RES[toupper(a[1])] = a[3] } close(ACCF)
                    cur = ""
                }
                $2 == "" { next }
                { if ($2 != cur) { flush(); cur = $2 }
                  if ($3 != "" || $1 == 16) SUB[cur, $1 + 0] = SUB[cur, $1 + 0] "\037" $3 }
                END { flush() }'
            # the footer is rewritten by setupStatFilter on every box click; this
            # is the unfiltered state it starts from (and the no-JS fallback)
            printf '<tr class="total"><td>Total (%s accounts)</td>' "$a_all"
            printf '%s\n' "$BOXSPEC" | awk -v RS='\037' -F'|' -v C="$a13,$a17,$a11,$a18,$a3,$a5,$a8,$a9,$a16,$a10,$a1,$a2,$a4,$a6,$a14,$a15,$a20,$a21,$a7,$a19,$a12" '
                BEGIN { split(C, V, ",") }
                NF >= 2 { printf "<td class=\"num\">%s</td>", V[++i] }
                END { print "</tr>" }'
        fi
        printf '</table></div>\n'
        printf '<p class="range">Sources: this page adds nothing of its own &mdash; it takes the twenty box memberships of <a href="subscriptions-in-boxes.html">Subscriptions in boxes</a> exactly as computed there and joins them onto accounts through the FlowManager configuration cache <span class="mono">xref/_subscriptions-accounts.tsv</span>, so the two pages can never disagree about what a box means. The account-only box, <strong>No subscriptions</strong>, is the account that has no row in that cache. Every account and subscription figure therefore traces back to the same report data files, the transfer cache and the configuration &mdash; never to a name.</p>\n'
        printf '</body>\n</html>\n'
    } > "$out"
}

write_whitelist_audit_page
write_config_hygiene_page
write_subscriptions_in_boxes_page
write_accounts_in_boxes_page

echo "Wrote the insight analyses pages to $ADIR." >&2
