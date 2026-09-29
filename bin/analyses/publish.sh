#!/usr/bin/env bash
#
# bin/analyses/publish.sh — render the ANALYSES .rpt files into docs/:
#
#   docs/analyses/first-seen.html          the First seen table
#   docs/analyses/use-cases.html, subscriptions.html, logical-detection.html,
#   accounts.html                           the Configuration pages
#   docs/analyses/*.html                    the analyses .rpt pages (via
#                                           publish-insights.sh and the
#                                           subscription group renders)
#   docs/first-seen/<member>-<key>.html     one page per First seen cell
#   docs/coverage/<member>-<key>.html       the 5 PDA Configured cell pages
# (the Analyses start page, docs/analyses/index.html, went 2026-09-29 — the
# one Reports pulldown, docs/reports/index.html, is the catalog)
#
# The Entities coverage page and the whole docs/coverage/ cell tree were
# REMOVED 2026-07: the home + analyses Status figures had all moved to the
# Transfer > Entities views, leaving the page as the only door into 341 cell
# pages nothing else reached. What the home status tables still need — the
# per-member SEEN count — is produced by bin/analyses/reports/home.sh, which
# replaced the entities/PDA report scripts.
#
# The cell pages of the tables that remain render FIRST: a table links only
# the cell pages that exist, so a zero cell stays plain. Run AFTER the
# per-area publishes and BEFORE bin/build/publish.sh (which applies the report
# groups to these pages). Runs from any working directory.
#
# Usage:  bin/analyses/publish.sh            every analyses page
#         bin/analyses/publish.sh catchup    ONLY the pages the report catch-ups
#                                            feed + the box-reason sidecar (see
#                                            THE CATCH-UP MODE at the bottom)
#         bin/analyses/publish.sh catchup-pages   the same WITHOUT the sidecar —
#                                            bin/build.sh runs the sidecar as its
#                                            own step first, then this beside the
#                                            transfer catch-up (2026-09-29)
#
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../publish_lib.sh"   # cd's to the repo root; html_head/esc/dotify/first_page/…
source "$SCRIPT_DIR/../uc-cases.sh"      # uc_meta(): the shared UC<n> description (From/To/role/human)

# the MODE (2026-09-29): an explicit argument — never a freshness check
AP_MODE=${1:-full}
AP_SIDECAR=1
case $AP_MODE in
    full|catchup) ;;
    catchup-pages) AP_MODE=catchup; AP_SIDECAR=0 ;;   # the sidecar ran as its own step
    *) printf 'usage: bin/analyses/publish.sh [catchup|catchup-pages]\n' >&2; exit 2 ;;
esac

ARPT="$DATA/analyses/reports"
FSRPT="$DATA/first-seen"
FSDIR="$DOCS/first-seen"
ADIR="$DOCS/analyses"
COVRPT="$DATA/coverage"   # the coverage cell .rpts (the 5 PDA Configured cells: logicals, partners, domains, applications, BL)
COVDIR="$DOCS/coverage"   # and their pages (restored 2026-07, linked from the home)

ensure_assets   # topbar-data.js (the menus' data file)

mkdir -p "$ADIR"
if [ "$AP_MODE" = full ]; then rm -f "$ADIR"/*.html; fi   # the catch-up overwrites its own pages only
# ---- First seen cell pages (docs/first-seen/) --------------------------------
# One page per data/first-seen/*.rpt (bin/analyses/reports/first-seen.sh:
# TITLE / MEMBER / KEY + ROW name|dir|seen|link|first_ts[|log]): the items
# counted in one cell of the First seen table. Row tint = the entity
# result from the member's base cache (data-res), like the coverage pages.
# Rebuilt from scratch on every publish.
# ONE cell page. Split out of the loop below so the pool can run several at
# once — the body reads a single .rpt and writes a single page, sharing nothing.
_fs_cell() {   # $1 = the cell .rpt
    local rpt=$1 title member key rows resfile nlabel ltcol
    [ -f "$rpt" ] || return 0
    title=$(field1 TITLE "$rpt"); member=$(field1 MEMBER "$rpt"); key=$(field1 KEY "$rpt")
    rows=$(awk -F'\t' '$1 == "ROW" { sub(/^ROW\t/, ""); print }' "$rpt")
    [ -n "$rows" ] || return 0
    resfile=""
    case $member in
        subscriptions) resfile="$DATA/flow-manager/base/_subscriptions.tsv"; nlabel="Subscription" ;;
        accounts)      resfile="$DATA/flow-manager/base/_accounts.tsv";      nlabel="Account" ;;
        logins)        resfile="$DATA/flow-manager/base/_logins.tsv";        nlabel="Login" ;;
        hosts)         resfile="$DATA/flow-manager/base/_hosts.tsv";         nlabel="Host" ;;
        partners)      resfile="$DATA/flow-manager/base/_partners.tsv";      nlabel="Partner" ;;
        *)             nlabel="Name" ;;
    esac
    [ -f "$resfile" ] || resfile=""
    local ltcol=1
    # the Total / Seen / Not seen cells open the Entities views instead
    # (write_first_seen_page) — no cell page of their own (2026-09-29), and
    # first-seen.sh writes no .rpt for them any more; a guard only
    case $key in total|seen|notseen) return 0 ;; esac
    {
        html_head "$title" "../assets/style.css" "" "HOME" "first-seen"
        esc "$title"; printf '<h1>%s</h1>\n' "$ESC"
        printf '<p class="range"><a href="../analyses/first-seen.html">&larr; Back to First seen</a> &mdash; the items counted in this cell of the First seen table.</p>\n'
        printf '<p class="range">Row colors: <strong>light green</strong> = last transfer OK &middot; <strong>light orange</strong> = configured but never seen &middot; <strong>light red</strong> = last transfer Error (or server-log errors after it).</p>\n'
        printf '<div class="tablewrap"><table class="index fit">\n'
        if [ "$ltcol" = 1 ]; then
            printf '<tr><th>%s</th><th>First transfer</th></tr>\n' "$nlabel"
        else
            printf '<tr><th>%s</th></tr>\n' "$nlabel"
        fi
        printf '%s\n' "$rows" | awk -F'\t' -v lc="$ltcol" -v resf="$resfile" '
            function e(s) { gsub(/&/, "\\&amp;", s); gsub(/</, "\\&lt;", s); gsub(/>/, "\\&gt;", s); gsub(/"/, "\\&quot;", s); return s }
            BEGIN { if (resf != "") { while ((getline line < resf) > 0) { split(line, a, "\t"); res[toupper(a[1])] = a[3] } close(resf) } }
            NF {
                name = e($1)
                if ($4 != "") name = "<a href=\"../details/" $4 ".html\">" name "</a>"
                trattr = ""   # (no data-seen: nothing reads it on these pages — 2026-09-29 audit)
                rr = res[toupper($1)]
                if (rr == "green" || rr == "orange" || rr == "red") trattr = trattr " data-res=\"" rr "\""
                nrows++; if ($3 == 1) nseen++
                tail = (lc == 1) ? "<td>" e($5) "</td>" : ""
                printf "<tr%s><td>%s</td>%s</tr>\n", trattr, name, tail
            }
            END {
                tail = (lc == 1) ? "<td>" (nseen+0) " seen</td>" : ""
                printf "<tr class=\"total\"><td>Total (%d)</td>%s</tr>\n", nrows+0, tail
            }'
        printf '</table></div>\n'
        printf '</body>\n</html>\n'
    } > "$FSDIR/$member-$key.html"
}

render_first_seen_pages() {
    rm -rf "$FSDIR"; mkdir -p "$FSDIR"
    local rpt npages
    for rpt in "$FSRPT"/*.rpt; do
        [ -f "$rpt" ] || continue
        pub_run _fs_cell "$rpt"
    done
    pub_wait
    # counted from the output, not a loop variable: the increment used to live in
    # the loop body, which now runs in a child where it could not propagate.
    npages=$(find "$FSDIR" -name '*.html' 2>/dev/null | wc -l | tr -d ' ')
    echo "Wrote $npages First-seen cell page(s) to docs/first-seen/." >&2
}


# ---- the First seen page (docs/analyses/first-seen.html) ---------------------
# Rendered from data/analyses/reports/first-seen.rpt: the Seen and Not seen
# header rows, one row per calendar day in the logs, the Total footer — per
# column, Seen + Not seen = Total and the day rows sum to Seen. Every nonzero
# cell links its item list (docs/first-seen/, rendered above so the
# existence checks hold).
render_coverage_pages() {
    rm -rf "$COVDIR"; mkdir -p "$COVDIR"
    local rpt member key title ltcol dircol rows awfile npages=0
    for rpt in "$COVRPT"/*.rpt; do
        [ -f "$rpt" ] || continue
        title=$(field1 TITLE "$rpt"); member=$(field1 MEMBER "$rpt"); key=$(field1 KEY "$rpt")
        ltcol=$(field1 LTCOL "$rpt"); dircol=$(field1 DIRCOL "$rpt")
        # the In only / Out only category pages hold ONE direction by
        # construction — the Direction column would repeat it on every row
        case $key in *inonly*|*outonly*) dircol=0 ;; esac
        rows=$(awk -F'\t' '$1 == "ROW" { sub(/^ROW\t/, ""); print }' "$rpt")
        [ -n "$rows" ] || continue
        # EVERY coverage row is tinted by the entity RESULT — the member base
        # cache's third field (bin/result.sh): green / orange / red carried
        # as data-res on the <tr> (style.css light green / orange / red).
        # whitelist pages join the allowing account(s) per IP
        awfile=""; [ "$member" = whitelist ] && [ -f $DATA/flow-manager/xref/_accounts-white.tsv ] && awfile="$DATA/flow-manager/xref/_accounts-white.tsv"
        # row tint source: the member's base cache (name/direction/result)
        resfile=""
        case $member in
            subscriptions) resfile="$DATA/flow-manager/base/_subscriptions.tsv" ;;
            logicals)      resfile="$DATA/flow-manager/base/_logicals.tsv" ;;
            accounts)      resfile="$DATA/flow-manager/base/_accounts.tsv" ;;
            logins)        resfile="$DATA/flow-manager/base/_logins.tsv" ;;
            hosts)         resfile="$DATA/flow-manager/base/_hosts.tsv" ;;
            whitelist)     resfile="$DATA/flow-manager/base/_white.tsv" ;;
            partners)      resfile="$DATA/flow-manager/base/_partners.tsv" ;;
            applications)  resfile="$DATA/flow-manager/base/_apps.tsv" ;;
            domains)       resfile="$DATA/flow-manager/base/_domains.tsv" ;;
            bl)            resfile="$DATA/flow-manager/base/_bl.tsv" ;;
        esac
        [ -f "$resfile" ] || resfile=""
        # the <member>-subscriptions xref: the movement half of the Direction
        # pair is the union of these subscriptions' flowdir (only the three PDA
        # members render a Direction column, so only they need one)
        local msubf=""
        case $member in
            logicals)      msubf="$DATA/flow-manager/xref/_logicals-subscriptions.tsv" ;;
            partners)      msubf="$DATA/flow-manager/xref/_partners-subscriptions.tsv" ;;
            applications)  msubf="$DATA/flow-manager/xref/_apps-subscriptions.tsv" ;;
            domains)       msubf="$DATA/flow-manager/xref/_domains-subscriptions.tsv" ;;
            bl)            msubf="$DATA/flow-manager/xref/_bl-subscriptions.tsv" ;;
        esac
        [ -f "$msubf" ] || msubf=""
        # PARTNER GROUPS (2026-07): a partner that is a merged group carries the
        # same 🔗 icon as the Entities partner views, linking the page that
        # explains why those tokens are one organisation. The map is the group
        # list keyed to the partners DETAIL slugmap — exactly how
        # render_entity_report builds GRPICON_MAP, so icon and page agree.
        local grpmapc=""
        if [ "$member" = partners ]; then
            local _gf="$DATA/flow-manager/xref/_partner-groups.tsv"
            local _ps="$DATA/transfer/reports/details/partners/_slugmap.tsv"
            if [ -f "$_gf" ] && [ -f "$_ps" ]; then
                grpmapc=$(mktemp "${TMPDIR:-/tmp}/covgrp.XXXXXX")
                LC_ALL=C awk -F'\t' -v OFS='\t' -v sm="$_ps" '
                    BEGIN { while ((getline l < sm) > 0) { split(l, a, "\t"); s[toupper(a[1])] = a[2] } close(sm) }
                    { k = toupper($1); if (k in s) print k, s[k] }' "$_gf" > "$grpmapc" 2>/dev/null || { rm -f "$grpmapc"; grpmapc=""; }
            fi
        fi
        {
            html_head "$title" "../assets/style.css" "" "HOME" "coverage"
            esc "$title"; printf '<h1>%s</h1>\n' "$ESC"
            if [ "$member" = logicals ]; then
                printf '<p class="range"><a href="../index.html">&larr; Back to the home status table</a> &mdash; the logical flows counted in this cell of the Logical row (Logical, Partners, Domains, Applications &amp; BL table). A logical flow is a FlowID family condensed to one three-part name (a hyphen marks parts the derivation combined); its members are the configured subscriptions that carry those FlowIDs.</p>\n'
            elif [ "$member" = partners ]; then
                printf '<p class="range"><a href="../index.html">&larr; Back to the home status table</a> &mdash; the partners counted in this cell of the Partners row (Logical, Partners, Domains, Applications &amp; BL table). A partner is the last part of the logical flow names (domain_application_partner), merged into one organisation by shared endpoints, shared whitelist IPs, whitelisted host addresses and curated aliases; its configured endpoint(s) and member accounts are listed.</p>\n'
            elif [ "$member" = applications ]; then
                printf '<p class="range"><a href="../index.html">&larr; Back to the home status table</a> &mdash; the applications counted in this cell of the Applications row (Logical, Partners, Domains, Applications &amp; BL table). An application is the middle part of the three-part logical flow name (domain_application_partner), so this list is derived from the logical flows; an application active in both directions counts once per side.</p>\n'
            elif [ "$member" = domains ]; then
                printf '<p class="range"><a href="../index.html">&larr; Back to the home status table</a> &mdash; the business domains counted in this cell of the Domains row (Logical, Partners, Domains, Applications &amp; BL table). The domain is the first part of the three-part logical flow name (domain_application_partner), so this list is derived from the logical flows; a domain active in both directions counts once per side.</p>\n'
            elif [ "$member" = bl ]; then
                printf '<p class="range"><a href="../index.html">&larr; Back to the home status table</a> &mdash; the BL tags counted in this cell of the BL row (Logical, Partners, Domains, Applications &amp; BL table). A BL is a subscriptions.json tags entry starting with BL, kept verbatim; its members are the configured subscriptions that carry the tag, and a tag active in both directions counts once per side.</p>\n'
            else
                printf '<p class="range"><a href="../index.html">&larr; Back to the home status table</a> &mdash; the items counted in this cell of the Entities table.</p>\n'
            fi
            printf '<p class="range">Row colors: <strong>light green</strong> = last transfer OK &middot; <strong>light orange</strong> = configured but never seen &middot; <strong>light red</strong> = last transfer Error (or server-log errors after it).</p>\n'
            # the three selector groups (report.js setupSelFilter) —
            # Connection / Movement (the two halves of the Direction pair)
            # and Use case; single-select per group, the groups combine with
            # AND. Real <button>s: keyboard-operable. On every one of the
            # five unified pages (2026-08-31; was partners-only).
            if [ "$key" = configured ]; then
                printf '<p class="tabs selrow">'
                printf '<span class="selgrp" data-sel="conn"><span class="sel-l">Connection</span><button type="button" class="tab active" data-v="">All</button><button type="button" class="tab" data-v="in">In</button><button type="button" class="tab" data-v="out">Out</button><button type="button" class="tab" data-v="both">Both</button></span>'
                printf '<span class="tabsep"></span>'
                printf '<span class="selgrp" data-sel="move"><span class="sel-l">Movement</span><button type="button" class="tab active" data-v="">All</button><button type="button" class="tab" data-v="in">In</button><button type="button" class="tab" data-v="out">Out</button><button type="button" class="tab" data-v="both">Both</button></span>'
                printf '<span class="tabsep"></span>'
                printf '<span class="selgrp" data-sel="uc"><span class="sel-l">Use case</span><button type="button" class="tab active" data-v="">All</button><button type="button" class="tab" data-v="1">UC1</button><button type="button" class="tab" data-v="2">UC2</button><button type="button" class="tab" data-v="3">UC3</button><button type="button" class="tab" data-v="4">UC4</button></span>'
                printf '</p>\n'
            fi
            printf '<div class="tablewrap"><table class="index fit">\n'
            local hdir="" htail='<th>Seen</th>'
            [ "$dircol" = 1 ] && hdir='<th>Direction</th>'
            [ "$ltcol" = 1 ] && htail='<th>Last transfer</th>'
            [ "$ltcol" = 2 ] && htail=''   # no trailing column (partners Configured)
            # ONE column set for all five derived members (2026-08-31, user
            # request — the pages are exactly the same but for the first
            # column's entity name): Direction, then Subscriptions / Accounts
            # / Endpoints / Whitelisted IPs, then UC1..UC4.
            local flabel=""
            case $member in
                logicals) flabel="Logical flow" ;; bl) flabel="BL" ;; partners) flabel="Partner" ;;
                applications) flabel="Application" ;; domains) flabel="Domain" ;;
            esac
            if [ "$member" = whitelist ]; then
                [ "$ltcol" = 1 ] && htail='<th>Last inbound transfer</th>'
                printf '<tr><th>IP</th><th>Allowed for account(s)</th>%s</tr>\n' "$htail"
            elif [ -n "$flabel" ]; then
                printf '<tr><th>%s</th>%s<th>Subscriptions</th><th>Accounts</th><th>Endpoints</th><th>Whitelisted IPs</th>%s<th class="num">UC1</th><th class="num">UC2</th><th class="num">UC3</th><th class="num">UC4</th></tr>\n' "$flabel" "$hdir" "$htail"
            else
                printf '<tr><th>Name</th>%s%s</tr>\n' "$hdir" "$htail"
            fi
            # every column of the five unified pages comes from the member's
            # OWN xref pair caches (2026-08-31): _<item>-subscriptions (the
            # Subscriptions cells + the Direction/UC machinery — msubf above),
            # _<item>-accounts, _<item>-logins + _<item>-hosts (the Endpoints
            # cells, each value linked through the login/host slugmaps) and
            # _<item>-white (the Whitelisted IPs — partners keep their
            # coverage-TSV col 8, whose Out-alias handling the xref lacks).
            local lmap="" hmap="" ptf=0 amf="" elf="" ehf="" whf="" smap="" amap="" item=""
            case $member in
                logicals) item=logicals ;; partners) item=partners ;; applications) item=apps ;;
                domains) item=domains ;; bl) item=bl ;;
            esac
            if [ -n "$item" ]; then
                ptf=1
                [ -f "$DATA/flow-manager/xref/_$item-accounts.tsv" ] && amf="$DATA/flow-manager/xref/_$item-accounts.tsv"
                [ -f "$DATA/flow-manager/xref/_$item-logins.tsv" ] && elf="$DATA/flow-manager/xref/_$item-logins.tsv"
                [ -f "$DATA/flow-manager/xref/_$item-hosts.tsv" ] && ehf="$DATA/flow-manager/xref/_$item-hosts.tsv"
                [ "$member" != partners ] && [ -f "$DATA/flow-manager/xref/_$item-white.tsv" ] && whf="$DATA/flow-manager/xref/_$item-white.tsv"
                [ -f $DATA/transfer/reports/details/logins/_slugmap.tsv ] && lmap="$DATA/transfer/reports/details/logins/_slugmap.tsv"
                [ -f $DATA/transfer/reports/details/hosts/_slugmap.tsv ] && hmap="$DATA/transfer/reports/details/hosts/_slugmap.tsv"
                [ -f $DATA/transfer/reports/details/subscriptions/_slugmap.tsv ] && smap="$DATA/transfer/reports/details/subscriptions/_slugmap.tsv"
                [ -f $DATA/transfer/reports/details/accounts/_slugmap.tsv ] && amap="$DATA/transfer/reports/details/accounts/_slugmap.tsv"
            fi
            printf '%s\n' "$rows" | awk -F'\t' -v wl="$([ "$member" = whitelist ] && echo 1 || echo 0)" \
                -v pt="$ptf" -v dc="$dircol" -v lc="$ltcol" \
                -v ipc="$([ "$member" = partners ] && echo 1 || echo 0)" -v aw="$awfile" \
                -v amf="$amf" -v elf="$elf" -v ehf="$ehf" -v whf="$whf" -v smap="$smap" -v amap="$amap" \
                -v lmap="$lmap" -v hmap="$hmap" -v resf="$resfile" -v grpf="$grpmapc" \
                -v fdf="$DATA/flow-manager/xref/_subscriptions-flowdir.tsv" -v msub="$msubf" \
                -v ucdf="$DATA/flow-manager/xref/_subscriptions-ucderived.tsv" '
                function e(s) { gsub(/&/, "\\&amp;", s); gsub(/</, "\\&lt;", s); gsub(/>/, "\\&gt;", s); gsub(/"/, "\\&quot;", s); return s }
                # one endpoint value -> a link to its login/host detail page
                # (type t: "l" login, "h" host); no slugmap entry, no link
                # connection side + the entity name -> "conn/movement", lowercase
                # (these pages are hand-written, so no dirfold runs over them)
                function dirpair(c, nm,   ku, m) {
                    if (c == "") return ""
                    ku = toupper(nm)
                    m = (mvi[ku] && mvo[ku]) ? "both" : (mvi[ku] ? "in" : (mvo[ku] ? "out" : "?"))
                    return c "/" m
                }
                function eplink(p, t,   s) {
                    s = (t == "l") ? lslug[p] : hslug[tolower(p)]
                    if (s == "") return e(p)
                    return "<a href=\"../details/" ((t == "l") ? "logins/" : "hosts/") s ".html\">" e(p) "</a>"
                }
                function slink(v,   s) { s = sslug[v]
                    if (s == "") return e(v)
                    return "<a href=\"../details/subscriptions/" s ".html\">" e(v) "</a>" }
                function alink2(v,   s) { s = aslug[v]
                    if (s == "") return e(v)
                    return "<a href=\"../details/accounts/" s ".html\">" e(v) "</a>" }
                # a \x1f-joined raw list -> the collapsed linked cell (typ: s
                # subscription, a account, e typed endpoint); CELLN carries
                # the count out for the data-sortval and the footer sums
                function listcell(raw, noun, typ,   n2, A2, i2, o2, v2) {
                    CELLN = (raw == "") ? 0 : split(substr(raw, 2), A2, US)
                    if (CELLN == 0) return ""
                    o2 = ""
                    for (i2 = 1; i2 <= CELLN; i2++) {
                        if (typ == "s") v2 = slink(A2[i2])
                        else if (typ == "a") v2 = alink2(A2[i2])
                        else v2 = eplink(substr(A2[i2], 2), substr(A2[i2], 1, 1))
                        o2 = o2 (o2 == "" ? "" : "<br>") v2
                    }
                    return "<details><summary>" CELLN " " noun (CELLN > 1 ? "s" : "") "</summary>" o2 "</details>"
                }
                BEGIN { US = sprintf("%c", 31)
                        # Direction = the CONNECTION/MOVEMENT pair (out/in). The
                        # connection side is the I|B|O flag on the row; the
                        # movement side is the union of the flowdir of every
                        # subscription the entity is connected to (relay counts
                        # as BOTH sides) — the same rule the detail-page title
                        # and the Entities views use.
                        if (fdf != "" && msub != "") {
                            while ((getline l < fdf) > 0) { k=split(l,a,"\t"); if (k>=2) fd[a[1]]=a[2] }
                            close(fdf)
                            while ((getline l < msub) > 0) { k=split(l,a,"\t"); if (k<2) continue
                                sv=fd[a[2]]; ku=toupper(a[1])
                                if (sv=="relay") { mvi[ku]=1; mvo[ku]=1 }
                                else if (sv=="in") mvi[ku]=1
                                else if (sv=="out") mvo[ku]=1
                                # UC1..UC4 subscription counts per entity (all
                                # five unified pages render them; a pair appears
                                # once per direction in the xref, so dedupe) —
                                # and the SAME deduped walk collects each
                                # entity member subscriptions (raw names;
                                # linked at row time once the slugmaps are in)
                                su=toupper(a[2])
                                if (!ssdup[ku SUBSEP su]++) { ssn[ku]++; ss[ku] = ss[ku] US a[2] }
                                # a name without a UC prefix counts under its DERIVED use case
                                # (2026-09-29: the columns counted UC-named subscriptions only)
                                if (!ucdl) { ucdl = 1; while ((getline ul < ucdf) > 0) { uk = split(ul, ua, "\t"); if (uk >= 2 && ua[1] != "") UCD[toupper(ua[1])] = ua[2] } close(ucdf) }
                                if (su ~ /^UC[1-4][_-]/) ucn[ku SUBSEP substr(su,3,1)]++
                                else if ((su in UCD) && UCD[su] ~ /^UC[1-4]$/) ucn[ku SUBSEP substr(UCD[su],3,1)]++ }
                            close(msub)
                        }
                    if (aw != "") { while ((getline line < aw) > 0) { split(line, a, "\t"); acc[a[2]] = (acc[a[2]] == "" ? a[1] : acc[a[2]] ", " a[1]) } close(aw) }
                    # the unified column sets, from the member own pair caches
                    # (raw values, deduped per entity; endpoints carry a type
                    # prefix — l login, h host — read back at render time)
                    if (amf != "") { while ((getline line < amf) > 0) { k=split(line,a,"\t"); if (k>=2 && a[1]!="" && a[2]!="") { ku=toupper(a[1])
                        if (!acdup[ku SUBSEP toupper(a[2])]++) { acn[ku]++; ac2[ku] = ac2[ku] US a[2] } } } close(amf) }
                    if (elf != "") { while ((getline line < elf) > 0) { k=split(line,a,"\t"); if (k>=2 && a[1]!="" && a[2]!="") { ku=toupper(a[1])
                        if (!epdup[ku SUBSEP toupper(a[2])]++) { epn[ku]++; epv[ku] = epv[ku] US "l" a[2] } } } close(elf) }
                    if (ehf != "") { while ((getline line < ehf) > 0) { k=split(line,a,"\t"); if (k>=2 && a[1]!="" && a[2]!="") { ku=toupper(a[1])
                        if (!epdup[ku SUBSEP toupper(a[2])]++) { epn[ku]++; epv[ku] = epv[ku] US "h" a[2] } } } close(ehf) }
                    if (whf != "") { while ((getline line < whf) > 0) { k=split(line,a,"\t"); if (k>=2 && a[1]!="" && a[2]!="") { ku=toupper(a[1])
                        if (!wdup[ku SUBSEP a[2]]++) { wn2[ku]++; wip[ku] = wip[ku] US a[2] } } } close(whf) }
                    if (lmap != "") { while ((getline line < lmap) > 0) { split(line, a, "\t"); lslug[a[1]] = a[2] } close(lmap) }
                    if (hmap != "") { while ((getline line < hmap) > 0) { split(line, a, "\t"); hslug[tolower(a[1])] = a[2] } close(hmap) }
                    if (smap != "") { while ((getline line < smap) > 0) { split(line, a, "\t"); sslug[a[1]] = a[2] } close(smap) }
                    if (amap != "") { while ((getline line < amap) > 0) { split(line, a, "\t"); aslug[a[1]] = a[2] } close(amap) }
                    if (resf != "") { while ((getline line < resf) > 0) { split(line, a, "\t"); res[toupper(a[1])] = a[3] } close(resf) }
                    if (grpf != "") { while ((getline line < grpf) > 0) { split(line, a, "\t"); grp[a[1]] = a[2] } close(grpf) } }
                NF {
                    name = e($1)
                    seen = ($3 == 1) ? "yes" : "no"
                    nrows++                                       # footer figures
                    if ($3 == 1) nseen++
                    if ($6 == "F") nfail++; else if ($6 == "P") nproc++
                    # trailing cells: Last transfer + Result, or (Not Seen
                    # pages, where both are always blank) Seen instead; lc 2 =
                    # no trailing cell at all (the partners Configured page —
                    # the row tint already carries seen-ness)
                    tail = (lc == 2) ? "" : ((lc == 1) ? "<td>" ((ipc == 1) ? substr($5, 1, 10) : e($5)) "</td>" : "<td>" seen "</td>")   # (the Result column is gone — the row tint carries the outcome)
                    # every row is tinted by the entity result — green /
                    # orange / red from the base cache (data-res, style.css)
                    trattr = ""   # (no data-seen: nothing reads it here — 2026-09-29 audit)
                    rr = res[toupper($1)]
                    # base result carries the tint directly
                    if (rr == "green" || rr == "orange" || rr == "red") trattr = trattr " data-res=\"" rr "\""
                    if (wl == 1)
                        printf "<tr%s><td><code>%s</code></td><td>%s</td>%s</tr>\n", trattr, name, e(acc[$1]), tail
                    else if (pt == 1) {
                        # ONE row shape for all five pages (2026-08-31, user
                        # request): Subscriptions / Accounts / Endpoints from
                        # the member own pair caches, each cell COLLAPSED to
                        # its count (a click discloses the linked list);
                        # Whitelisted IPs from col 8 on partners (its
                        # Out-alias handling lives in the coverage TSV), from
                        # the _<item>-white cache on the other four; then the
                        # UC1..UC4 subscription counts.
                        nc = ($4 != "") ? "<a href=\"../details/" $4 ".html\">" name "</a>" : name
                        if (toupper($1) in grp)   # a merged partner group: the "why" page
                            nc = nc " <a class=\"grpicon\" href=\"../details/partner-groups/" grp[toupper($1)] ".html\" title=\"Why these partners form one group\">&#128279;</a>"
                        dir = dirpair(($2 == "I") ? "in" : (($2 == "B") ? "both" : "out"), $1)
                        dcell = (dc == 1) ? "<td>" dir "</td>" : ""
                        ku2 = toupper($1)
                        scell2 = listcell(ss[ku2], "subscription", "s"); nsub2 = CELLN; nsubs2 += CELLN
                        scell2 = "<td class=\"wrap\" data-sortval=\"" nsub2 "\">" scell2 "</td>"
                        acell2 = listcell(ac2[ku2], "account", "a"); nacc2 = CELLN; naccs2 += CELLN
                        acell2 = "<td class=\"wrap\" data-sortval=\"" nacc2 "\">" acell2 "</td>"
                        ecell2 = listcell(epv[ku2], "endpoint", "e"); nep2 = CELLN; nend += CELLN
                        ecell2 = "<td class=\"wrap\" data-sortval=\"" nep2 "\">" ecell2 "</td>"
                        if (ipc == 1) { nip = ($8 == "") ? 0 : split($8, W8, US); ws = $8 }
                        else          { nip = wn2[ku2] + 0; ws = substr(wip[ku2], 2) }
                        nips += nip
                        gsub(US, ", ", ws)
                        if (nip > 0) ws = "<details><summary>" nip " IP" (nip > 1 ? "s" : "") "</summary><code>" e(ws) "</code></details>"
                        else ws = ""
                        wcell = "<td class=\"wrap\" data-sortval=\"" nip "\">" ws "</td>"
                        # UC1..UC4 cells; a use case the entity has no
                        # subscription of stays EMPTY
                        uccells = ""; ucl = ""
                        for (ud = 1; ud <= 4; ud++) { uv = ucn[ku2 SUBSEP ud] + 0; uct[ud] += uv
                            if (uv > 0) ucl = ucl (ucl == "" ? "" : " ") ud
                            uccells = uccells "<td class=\"num\">" (uv > 0 ? uv : "") "</td>" }
                        # the selector groups (report.js setupSelFilter)
                        # filter on these: the two halves of the Direction
                        # pair — mirroring what dirpair() renders — and the
                        # UC token list mirroring the UC cells
                        cvv = ($2 == "I") ? "in" : (($2 == "B") ? "both" : "out")
                        mvv = (mvi[ku2] && mvo[ku2]) ? "both" : (mvi[ku2] ? "in" : (mvo[ku2] ? "out" : ""))
                        trattr = trattr " data-conn=\"" cvv "\" data-move=\"" mvv "\" data-uc=\"" ucl "\""
                        printf "<tr%s><td>%s</td>%s%s%s%s%s%s%s</tr>\n", trattr, nc, dcell, scell2, acell2, ecell2, wcell, tail, uccells
                    }
                    else {
                        nc = ($4 != "") ? "<a href=\"../details/" $4 ".html\">" name "</a>" : name
                        dir = dirpair(($2 == "I") ? "in" : (($2 == "O") ? "out" : (($2 == "B") ? "both" : "")), $1)
                        dcell = (dc == 1) ? "<td>" dir "</td>" : ""
                        printf "<tr%s><td>%s</td>%s%s</tr>\n", trattr, nc, dcell, tail
                    }
                }
                END {   # footer: row count + a summary per countable column
                    # the seen count sits under Last transfer (or under Seen
                    # on the Not Seen pages, which have no Last transfer);
                    # lc 2 has neither column, so no footer cell either
                    sc = (nseen+0) " seen"
                    rc = ""
                    if (nproc + nfail > 0) rc = (nproc+0) " OK, " (nfail+0) " Error"
                    tail = (lc == 2) ? "" : "<td>" sc ((lc == 1 && rc != "") ? ", " rc : "") "</td>"
                    dcell = (dc == 1) ? "<td></td>" : ""
                    if (wl == 1)
                        printf "<tr class=\"total\"><td>Total (%d)</td><td></td>%s</tr>\n", nrows+0, tail
                    else if (pt == 1) {
                        uctot = ""
                        for (ud = 1; ud <= 4; ud++) uctot = uctot "<td class=\"num\">" (uct[ud] > 0 ? uct[ud] : "") "</td>"
                        printf "<tr class=\"total\"><td>Total (%d)</td>%s<td>%d subscription(s)</td><td>%d account(s)</td><td>%d endpoint(s)</td><td>%d IPs</td>%s%s</tr>\n", nrows+0, dcell, nsubs2+0, naccs2+0, nend+0, nips+0, tail, uctot
                    }
                    else
                        printf "<tr class=\"total\"><td>Total (%d)</td>%s%s</tr>\n", nrows+0, dcell, tail
                }'
            printf '</table></div>\n'
            printf '</body>\n</html>\n'
        } > "$COVDIR/$member-$key.html"
        [ -n "$grpmapc" ] && rm -f "$grpmapc"
        npages=$((npages + 1))
    done
    echo "Wrote $npages coverage cell page(s) to docs/coverage/." >&2
}

write_first_seen_page() {
    local base="first-seen" kp=""
    # (the page's note and DESC subtitle went 2026-09-29 — no prose on a report page; help/first-seen.html)
    local rpt="$ARPT/$base.rpt"
    [ -f "$rpt" ] || { rm -f "$ADIR/$base.html"; return 0; }
    local out="$ADIR/$base.html"
    # one numeric cell: blank when 0, linked when its cell page exists. The
    # Total / Seen / Not seen cells open the Entities All / Seen / Not seen
    # views (2026-09-29: their cell pages listed exactly those names)
    fscell() {   # $1 value  $2 member  $3 key
        if [ -z "$1" ] || [ "$1" = 0 ]; then printf '<td class="num"></td>'; return; fi
        esc "$(dotify "$1")"
        local ek="" ev=""
        case $2 in logicals) ek=logical ;; partners) ek=partner ;; subscriptions) ek=subscription ;; accounts) ek=account ;; logins) ek=login ;; hosts) ek=remote-host ;; esac
        case $3 in total) ev=all ;; seen) ev=seen ;; notseen) ev=not-seen ;; esac
        if [ -n "$ek" ] && [ -n "$ev" ] && [ -f "$DOCS/transfer/entities/$ek-$ev.html" ]; then
            printf '<td class="num"><a href="../transfer/entities/%s-%s.html">%s</a></td>' "$ek" "$ev" "$ESC"
        elif [ -f "$FSDIR/$2-$3.html" ]; then
            printf '<td class="num"><a href="../first-seen/%s-%s.html">%s</a></td>' "$2" "$3" "$ESC"
        else
            printf '<td class="num">%s</td>' "$ESC"
        fi
    }
    local members=(logicals partners subscriptions accounts logins hosts)
    {
        html_head "First seen" "../assets/style.css" "" "ANALYSES" "first-seen"
        printf '<h1>First seen</h1>\n'
        # NOT class="index": index tables get report.js whole-row links, which
        # would make the Date cell navigate to the row's first cell page.
        printf '<div class="tablewrap"><table class="fit" data-nosort="1">\n'
        local thead='<tr><th></th><th class="num">Logical</th><th class="num">Partners</th><th class="num">Subscriptions</th><th class="num">Accounts</th><th class="num">Logins</th><th class="num">Hosts</th></tr>'
        printf '%s\n' "$thead"
        # the Total row renders TWICE — above the Not seen row and as the
        # footer — so the column totals are in view from the top
        total_row() {
            local i=0 m
            printf '<tr class="total"><td>Total</td>'
            for m in "${members[@]}"; do i=$((i+1)); eval "fscell \"\$t$i\" $m ${kp}total"; done
            printf '</tr>\n'
        }
        local t1 t2 t3 t4 t5 t6
        IFS=$'\t' read -r _ t1 t2 t3 t4 t5 t6 <<<"$(grep -m1 $'^TOTAL\t' "$rpt")"
        total_row
        local tag d v1 v2 v3 v4 v5 v6 i
        while IFS=$'\t' read -r tag d v1 v2 v3 v4 v5 v6; do
            case $tag in
                SEEN)
                    # SEEN/NOTSEEN carry no date column: shift the read fields
                    v6=$v5; v5=$v4; v4=$v3; v3=$v2; v2=$v1; v1=$d
                    printf '<tr data-res="green"><td>Seen</td>'
                    i=0; for m in "${members[@]}"; do i=$((i+1)); eval "fscell \"\$v$i\" $m ${kp}seen"; done
                    printf '</tr>\n' ;;
                NOTSEEN)
                    v6=$v5; v5=$v4; v4=$v3; v3=$v2; v2=$v1; v1=$d
                    printf '<tr data-res="orange"><td>Not seen</td>'
                    i=0; for m in "${members[@]}"; do i=$((i+1)); eval "fscell \"\$v$i\" $m ${kp}notseen"; done
                    printf '</tr>\n' ;;
                NODATE)
                    # seen names with no dated transfer of their own
                    # (sibling-credited names): they count into Seen, so the day rows + this
                    # row sum to the Seen row
                    v6=$v5; v5=$v4; v4=$v3; v3=$v2; v2=$v1; v1=$d
                    printf '<tr data-res="green"><td>Seen, no date</td>'
                    i=0; for m in "${members[@]}"; do i=$((i+1)); eval "fscell \"\$v$i\" $m ${kp}nodate"; done
                    printf '</tr>\n' ;;
                ROW)
                    printf '<tr><td>%s</td>' "$d"
                    i=0; for m in "${members[@]}"; do i=$((i+1)); eval "fscell \"\$v$i\" $m \"$kp$d\""; done
                    printf '</tr>\n' ;;
                TOTAL)
                    total_row ;;
            esac
        done < "$rpt"
        printf '%s\n' "$thead"   # the title row repeats at the bottom
        printf '</table></div>\n'
        printf '</body>\n</html>\n'
    } > "$out"
}

# ---- the Use cases page (docs/analyses/use-cases.html) ----------------------
# ONE page per use case (2026-09-29: the Use Case definitions page and the 26
# docs/use-cases/<uc>-<metric>.html cell pages folded in): per use case its
# Direction, the definition columns (Trigger, We are, We — bin/uc-cases.sh's
# uc_meta, shared with the Subscription detail pages) and the status counts
# (Total / Seen / Error / Warning / Ok), then the FlowManager templates. The
# use case of a subscription is the ONE site-wide derivation: its UC<n> name
# prefix, else the derived use case (xref/_subscriptions-ucderived.tsv, the
# configured pattern) — the UC status pages, the Subscriptions page and the
# detail pages read the same (2026-09-29: this page counted the non-UC names
# under "(none)", so its UC2 disagreed with UC status). Every nonzero count
# links the Subscriptions page filtered to that use case and colour (its
# Use case + Color columns, ?axway_search) — the list the cell pages held.
# (The Use Case / Use Case Status view row, _ucgroup_tabs, went 2026-09-29:
# both pages are members of the "Use cases & delivery" report group, whose
# first row links them.)
_uccell() {   # $1 value  $2 class  [$3 href] — 0 renders blank
    if [ "${1:-0}" = 0 ]; then printf '<td class="%s"></td>' "$2"; return 0; fi
    if [ -n "${3:-}" ]; then printf '<td class="%s"><a href="%s">%s</a></td>' "$2" "$3" "$(dotify "$1")"
    else printf '<td class="%s">%s</td>' "$2" "$(dotify "$1")"; fi
}
# _ucsearch UC METRIC -> the Subscriptions page href filtered to that cell
# (quoted terms match a whole cell: the Use case and Color columns); "" for
# the (none) bucket, whose Use case cell is blank
_ucsearch() {
    local uc=$1 q
    case $uc in UC[0-9]*) ;; *) return 0 ;; esac
    case $2 in
        total)   q="\"$uc\" and not \"white\"" ;;   # the skip-listed rows (result white) are not in the Total (2026-09-29: 49 opened 51 rows)
        error)   q="\"$uc\" and \"red\"" ;;
        warning) q="\"$uc\" and \"orange\"" ;;
        ok)      q="\"$uc\" and \"green\"" ;;
    esac
    q=${q//\"/%22}; q=${q// /%20}
    printf 'subscriptions.html?axway_search=%s' "$q"
}

# The DOUBLE Direction of a use case, the site-wide XXX/YYY convention the
# detail-page titles use: CONNECTION side / FILE-MOVEMENT side. Both come from
# uc_meta, so this page can never disagree with the definition columns:
#   connection = "We are" — Client (WE connect out) -> out, Server (the partner
#                connects in) -> in, a MIXED relay ("Client + Server", UC6/UC8)
#                -> both. NOT uc_meta's `exp`, which is "" for exactly those two
#                and would render them unknown when the answer is both.
#   movement   = "We"     — Send (the file leaves us) -> out, Receive (it enters
#                us) -> in, relay -> both.
# So UC3 reads out/in: we dial the partner, the file travels towards us.
# LOWERCASE like every other Direction column on the site — the .rpt-rendered
# pages get that from render_rpt.awk's dirfold, but this page is hand-rendered,
# so it spells the lowercase out itself.
_uc_direction() {   # $1 "We are"  $2 "We"  -> "out/in" etc; "" when undefined
    local c m
    case $1 in
        *+*)     c=both ;;
        Client)  c=out ;;
        Server)  c=in ;;
        *)       c="" ;;
    esac
    case $2 in
        Send)    m=out ;;
        Receive) m=in ;;
        relay)   m=both ;;
        *)       m="" ;;
    esac
    # the "(none)" bucket (subscriptions with no UC prefix) has no definition and
    # so no direction — a blank cell, not a guessed one
    [ -n "$c" ] && [ -n "$m" ] || return 0
    printf '%s/%s' "$c" "$m"
}

write_use_cases_page() {
    local out="$ADIR/use-cases.html" subs="$DATA/flow-manager/base/_subscriptions.tsv"
    local ucdf="$DATA/flow-manager/xref/_subscriptions-ucderived.tsv"; [ -f "$ucdf" ] || ucdf=/dev/null
    # SEEN = the coverage seen flag (showseen.sh coverage/subscriptions.tsv
    # col 3 — "in the transfer log"), the figure every other Seen cell on the
    # site reads (2026-09-29 audit: Error + Ok counted a red flow that never
    # transferred — the UC3 cannot-connect red — as seen)
    local covf="$DATA/transfer/reports/coverage/subscriptions.tsv"; [ -f "$covf" ] || covf=/dev/null
    [ -f "$subs" ] || { rm -f "$out"; return 0; }
    # per use case: total / not seen / error / ok / seen, and the configured
    # directions (out / in / other) for the direction-vs-UC consistency check
    local rows
    rows=$(awk -F'\t' '
        FILENAME == ARGV[1] { if ($1 != "" && $2 != "") UCD[toupper($1)] = $2; next }
        FILENAME == ARGV[2] { if ($1 != "" && $3 == "1") SEENF[toupper($1)] = 1; next }
        $1 != "" {
            name = $1; res = $3
            uc = "(none)"
            if (match(name, /^UC[0-9]+/)) uc = substr(name, RSTART, RLENGTH)
            else if (toupper(name) in UCD) uc = UCD[toupper(name)]
            tot[uc]++; seen[uc] = 1
            if (res == "green")          ok[uc]++
            else if (res == "orange")    ns[uc]++
            else if (res == "red")       err[uc]++
            if (toupper(name) in SEENF)  sn[uc]++
            if ($2 == "out") dout[uc]++; else if ($2 == "in") din[uc]++; else doth[uc]++
        }
        END { for (u in seen) print u "\t" tot[u] "\t" (ns[u]+0) "\t" (err[u]+0) "\t" (ok[u]+0) "\t" (dout[u]+0) "\t" (din[u]+0) "\t" (doth[u]+0) "\t" (sn[u]+0) }
    ' "$ucdf" "$covf" "$subs" | LC_ALL=C sort -V)
    # UNION with the template catalog: a UC whose template is published but has
    # no subscriptions yet (today UC6/UC7) still gets a row — all-zero counts.
    local tmpl="$DATA/flow-manager/xref/_templates.tsv"
    if [ -s "$tmpl" ]; then
        rows=$({ printf '%s\n' "$rows"
                 awk -F'\t' -v have="$(printf '%s\n' "$rows" | cut -f1 | tr '\n' ' ')" '
                     BEGIN { n = split(have, H, " "); for (i = 1; i <= n; i++) seen[H[i]] = 1 }
                     $2 != "" && !($2 in seen) && !dup[$2]++ { print $2 "\t0\t0\t0\t0\t0\t0\t0\t0" }
                 ' "$tmpl"; } | LC_ALL=C sort -V)
    fi
    {
        html_head "Use cases" "../assets/style.css" "" "" "use-cases" "" "" "sort-fresh"
        printf '<h1>Use cases</h1>\n'
        printf '<div class="tablewrap"><table class="index fit" data-nosearch="1">\n'
        printf '<tr><th>Use Case</th><th>Direction</th><th>Trigger</th><th>We are</th><th>We</th><th class="num">Total</th><th class="num">Seen</th><th class="num">Error</th><th class="num">Warning</th><th class="num">Ok</th><th>Description</th></tr>\n'
        local uc t ns er okc dout din doth sn mm Tt=0 Tns=0 Ter=0 Tok=0 Tsn=0 Tmm=0
        while IFS=$'\t' read -r uc t ns er okc dout din doth sn; do
            [ -n "$uc" ] || continue
            local ucfrom ucto weare we human exp trigger
            # read on \036 (RS, not IFS whitespace) so an EMPTY middle field keeps
            # its place — UC8's `exp` is empty, and a plain IFS=$'\t' read would
            # collapse it, shifting the trigger (OpsWise) into `exp` and blanking it.
            IFS=$'\036' read -r ucfrom ucto weare we human exp trigger <<< "$(uc_meta "$uc" | tr '\t' '\036')"
            sn=${sn:-0}   # Seen = in the transfer log (the coverage flag), NOT Error + Ok
            mm=0; case $exp in out) mm=$((din + doth)) ;; in) mm=$((dout + doth)) ;; esac
            Tmm=$((Tmm + mm))
            printf '<tr>'
            esc "$uc"; printf '<td>%s</td>' "$ESC"
            printf '<td>%s</td>' "$(_uc_direction "$weare" "$we")"
            esc "$trigger"; printf '<td>%s</td>' "$ESC"
            esc "$weare"; printf '<td>%s</td>' "$ESC"
            esc "$we"; printf '<td>%s</td>' "$ESC"
            _uccell "$t"   "num"          "$(_ucsearch "$uc" total)"
            _uccell "$sn"  "num"          ""   # no link (2026-09-29 audit): Seen = the coverage flag, which no search on the Subscriptions page can reproduce (a red never-transferred flow is not seen)
            _uccell "$er"  "num st-err"   "$(_ucsearch "$uc" error)"
            _uccell "$ns"  "num st-warn"  "$(_ucsearch "$uc" warning)"
            _uccell "$okc" "num st-ok"    "$(_ucsearch "$uc" ok)"
            esc "$human"; printf '<td>%s</td>' "$ESC"
            printf '</tr>\n'
            Tt=$((Tt+t)); Tns=$((Tns+ns)); Ter=$((Ter+er)); Tok=$((Tok+okc)); Tsn=$((Tsn+sn))
        done <<< "$rows"
        # the Error / Warning / Ok totals keep their column tint (2026-09-29)
        printf '<tr class="total"><td>Total</td><td></td><td></td><td></td><td></td><td class="num">%s</td><td class="num">%s</td><td class="num st-err">%s</td><td class="num st-warn">%s</td><td class="num st-ok">%s</td><td></td></tr>\n' \
            "$(dotify "$Tt")" "$(dotify "$Tsn")" "$(dotify "$Ter")" "$(dotify "$Tns")" "$(dotify "$Tok")"
        printf '</table></div>\n'
        # the direction-vs-use-case consistency check: only when it finds something
        [ "$Tmm" -gt 0 ] && printf '<p class="range"><strong>&#9888; %d subscription(s)</strong> are configured with a direction that disagrees with their use case &mdash; a naming or configuration error.</p>\n' "$Tmm"
        # the FlowManager flow templates behind the use cases (xref/_templates.tsv):
        # Route = the template's flowPatternName; Subscriptions = the configured
        # subscriptions created from it, joined on patternName
        # (_subscriptions-patterns.tsv col 2)
        if [ -s "$tmpl" ]; then
            local pmap="$DATA/flow-manager/xref/_subscriptions-patterns.tsv"; [ -f "$pmap" ] || pmap=/dev/null
            printf '<h2>Templates</h2>\n'
            printf '<div class="tablewrap"><table class="index fit" data-nosearch="1">\n'
            printf '<tr><th>Template</th><th>Use Case</th><th>Route</th><th class="num">Subscriptions</th><th>Status</th><th>Last modified</th></tr>\n'
            LC_ALL=C sort -t"$(printf '\t')" -k2,2 -k1,1 "$tmpl" | awk -F'\t' '
                function e(s) { gsub(/&/,"\\&amp;",s); gsub(/</,"\\&lt;",s); gsub(/>/,"\\&gt;",s); gsub(/"/,"\\&quot;",s); return s }
                NR == FNR { if ($2 != "") cnt[$2]++; next }
                $2 != "" {
                    n = cnt[$4] + 0; tot += n; nt++
                    ucc = e($2)
                    if ($2 ~ /^UC[0-9]+$/) ucc = "<a href=\"subscriptions.html?axway_search=%22" $2 "%22\">" ucc "</a>"
                    nm = "<code>" e($1) "</code>"
                    if ($5 != "") nm = nm " <a class=\"fmlink\" href=\"" e($5) "\" title=\"Open in FlowManager\" target=\"_blank\" rel=\"noopener\">&#128279;</a>"
                    printf "<tr><td>%s</td><td>%s</td><td><code>%s</code></td><td class=\"num\">%s</td><td>%s</td><td>%s</td></tr>\n", \
                           nm, ucc, e($4), (n > 0 ? n : ""), e($3), e($6)
                }
                END { printf "<tr class=\"total\"><td>Total (%d templates)</td><td></td><td></td><td class=\"num\">%d</td><td></td><td></td></tr>\n", nt, tot }
            ' "$pmap" -
            printf '</table></div>\n'
        fi
        printf '</body>\n</html>\n'
    } > "$out"
}

# (the Use Case patterns page went 2026-09-29: its multi-subscription accounts
# are the Account sharing page, the single-use-case buckets said nothing more)

# ---- the Logical detection page (docs/analyses/logical-detection.html) ------
# One row per configured FlowID (2026-08-31, user request): the FlowID, the
# Logical it detected to, and the rule trail that produced it — the third
# column of xref/_logical-rules.tsv, written by the derivation itself in
# bin/flow-manager.sh, so page and pipeline can never disagree. Rows tint by
# the Logical result; the Logical cell links its detail page.
write_logical_detection_page() {
    local out="$ADIR/logical-detection.html"
    local rules="$DATA/flow-manager/xref/_logical-rules.tsv"
    local lmap="$DATA/transfer/reports/details/logicals/_slugmap.tsv"
    local lbase="$DATA/flow-manager/base/_logicals.tsv"
    [ -s "$rules" ] || { rm -f "$out"; return 0; }
    [ -f "$lmap" ] || lmap=/dev/null
    [ -f "$lbase" ] || lbase=/dev/null
    local rows n
    rows=$(LC_ALL=C awk -F'\t' -v LM="$lmap" -v LB="$lbase" '
        function e(s) { gsub(/&/, "\\&amp;", s); gsub(/</, "\\&lt;", s); gsub(/>/, "\\&gt;", s); gsub(/"/, "\\&quot;", s); return s }
        BEGIN { while ((getline l < LM) > 0) { split(l, a, "\t"); if (a[1] != "") slug[toupper(a[1])] = a[2] } close(LM)
                while ((getline l < LB) > 0) { n2 = split(l, a, "\t"); if (n2 >= 3 && a[1] != "") res[toupper(a[1])] = a[3] } close(LB) }
        NF >= 3 {
            k = toupper($2); tr = "<tr"
            r = res[k]
            if (r == "green" || r == "orange" || r == "red") tr = tr " data-res=\"" r "\""
            lc = e($2)
            if (k in slug) lc = "<a href=\"../details/logicals/" slug[k] ".html\">" lc "</a>"
            print tr "><td><code>" e($1) "</code></td><td>" lc "</td><td class=\"wrap\">" e($3) "</td></tr>"
        }' "$rules")
    n=$(printf '%s' "$rows" | grep -c '<tr' || true)
    {
        html_head "Logical detection" "../assets/style.css" "" "" "logical-detection" "" "" "sort-fresh"
        printf '<h1>Logical detection</h1>\n'
        printf '<div class="tablewrap"><table class="index fit">\n'
        printf '<tr><th>FlowID</th><th>Logical</th><th>Rules</th></tr>\n'
        [ -n "$rows" ] && printf '%s\n' "$rows"
        printf '<tr class="total"><td>Total (%s)</td><td></td><td></td></tr>\n' "$n"
        printf '</table></div>\n'
        printf '</body>\n</html>\n'
    } > "$out"
}

# (the Added BL page went 2026-09-29: the Subscriptions page BL column marks
# every value input/BL.txt added with a "+")

# ---- the Subscriptions page (docs/analyses/subscriptions.html) --------------
# ONE ROW PER CONFIGURED SUBSCRIPTION (2026-09-13, user request — until then
# the rows folded onto the FlowID with a UCx column): the complete
# subscription name (linking its detail page), the derived Logical / Account /
# Partner / Domain / Application / BL groups (the config caches joined onto the
# row), the endpoint (the login the partner connects in with, or the remote
# host we dial out to), the From / To folders exactly as the subscription
# detail page's Features rows show them (lifted from the detail .rpt files
# — the pickup-side file mask as the green
# suffix), the Cron expression and Schedule exactly as the Polling page shows
# them (subscriptions.json via jq + bin/cron2human.awk, the same pipeline as
# polling.sh; blank without a cron), and the ALL-TIME File counts — Total files · In · Out · Errors ·
# Auto Retries · Resubmit OK / Error · Waiting · Expired — from
# month-stats.sh's _alltime.tsv sidecar (the Entities
# definitions; a subscription never seen in the log shows blanks; 0 shows
# blank). Rows tint by the subscription's result (green / orange / red);
# baked order use case (the name prefix, else the derived one) then
# name. The roster is the pristine configured snapshot (base/.configured.tsv —
# the base cache gains discovered names after the build's append steps),
# falling back to the base cache on a pre-snapshot tree ("Unknown", the
# no-subscription value, never enters it). No prose on the page (help page subscriptions).
# ACTIVE (2026-09-14, user request), the second column: "Yes", or the
# ", "-joined codes of why the subscription is not active, read from
# subscriptions.json with jq — 1 status.code UNDEPLOYED, 2 status.code
# SAVED_NOT_DEPLOYED, 3 a *_receive_scheduler_enable parameter set to No, 4
# source_folder_monitoring_state Inactive — with the words as the hover title;
# blank for a subscription the JSON does not name.
# SKIPPED (2026-09-15, user request): the subscriptions skip.txt removed from
# the config (filtered/_skipped.tsv) get a row too: Active and cron from the
# RAW export (input/flow-manager/subscriptions.json still names them), "n/a"
# in the nine count columns (the parse dropped their records), no groups, no
# tint. COLOR (2026-09-15): the result as a word, green / red / orange,
# white for a skipped or unresulted subscription. ERROR REASON (2026-09-15):
# the reason of the NEWEST File in error of the subscription (failed-files.rpt,
# the Failed files page: Failed or Expired), linking its error page; the
# analyses publish catch-up runs after failed-files.sh, so one build converges.
# A name containing SWIFT shows Active "CFT" (2026-09-15, user rule).
# DIRECTION (2026-09-15, user request): connection / file movement, e.g.
# out/in, exactly the detail page title prefix lowercased (base direction;
# xref flowdir with relay = both; ? = unknown side); blank when skipped.
_subs_tcell() {   # $1 value  $2 classes — a total-row count cell, 0 blanked like the rows
    if [ "${1:-0}" = 0 ]; then printf '<td class="%s z"></td>' "$2"; else printf '<td class="%s">%s</td>' "$2" "$1"; fi
}
write_subscriptions_page() {
    local out="$ADIR/subscriptions.html"
    local B="$DATA/flow-manager/base" X="$DATA/flow-manager/xref" DET="$DATA/transfer/reports/details"
    local ALLT="$DATA/transfer/reports/_alltime.tsv"
    [ -f "$B/_subscriptions.tsv" ] || { rm -f "$out"; return 0; }
    local conf="$B/.configured.tsv"; [ -f "$conf" ] || conf=""
    local args=() f d
    for f in _subscriptions-ucderived _subscriptions-flowdir _subscriptions-accounts _subscriptions-logins _subscriptions-hosts \
             _subscriptions-logicals _subscriptions-partners _subscriptions-domains _subscriptions-apps \
             _subscriptions-bl _subscriptions-bl-added; do
        [ -f "$X/$f.tsv" ] && args+=("$X/$f.tsv")
    done
    for d in subscriptions accounts logins hosts logicals partners domains applications bl; do
        [ -f "$DET/$d/_slugmap.tsv" ] && args+=("$DET/$d/_slugmap.tsv")
    done
    [ -f "$ALLT" ] && args+=("$ALLT")
    # the skipped subscriptions and the newest error reason per subscription (2026-09-15)
    local SKS="$DATA/flow-manager/filtered/_skipped.tsv" FFR="$DATA/transfer/reports/failed-files.rpt" RAWS="input/flow-manager/subscriptions.json"
    [ -f "$SKS" ] && args+=("$SKS")
    [ -f "$FFR" ] && args+=("$FFR")
    # the cron expressions (2026-09-13, user request): name / proto / display
    # cron / plain-English schedule per configured receive scheduler — the
    # Polling page's own pipeline, so the two pages never disagree
    local cronf; cronf=$(mktemp "${TMPDIR:-/tmp}/subcron.XXXXXX")
    if command -v jq >/dev/null 2>&1 && [ -f "$FM_CONFIG_DIR/subscriptions.json" ]; then
        jq -r '
            .[] | . as $s
            | (["sftp","ftp"][] as $p
               | ($s.parameters["hybrid_partner_\($p)_relay0_receive_scheduler_cron_expression"]) as $c
               | select($c != null and $c != "")
               | [ $s.name, ($p|ascii_upcase), $c ] | @tsv)
          ' "$FM_CONFIG_DIR/subscriptions.json" 2>/dev/null | awk -F'\t' -v CF=3 -f "$SCRIPT_DIR/../cron2human.awk" > "$cronf" || true
    fi
    args+=("$cronf")
    # the SKIPPED rows' cron (2026-09-15): the same program over the RAW export
    local cronrf; cronrf=$(mktemp "${TMPDIR:-/tmp}/subcronr.XXXXXX")
    if command -v jq >/dev/null 2>&1 && [ -f "$SKS" ] && [ -f "$RAWS" ]; then
        jq -r '
            .[] | . as $s
            | (["sftp","ftp"][] as $p
               | ($s.parameters["hybrid_partner_\($p)_relay0_receive_scheduler_cron_expression"]) as $c
               | select($c != null and $c != "")
               | [ $s.name, ($p|ascii_upcase), $c ] | @tsv)
          ' "$RAWS" 2>/dev/null | awk -F'\t' -v CF=3 -f "$SCRIPT_DIR/../cron2human.awk" > "$cronrf" || true
    fi
    args+=("$cronrf")
    # the ACTIVE codes (2026-09-14, user request): name / the comma-joined
    # codes, empty = active — bin/subscription-active.jq, the one definition
    # the subscription detail pages' Features Status rows share
    local actf; actf=$(mktemp "${TMPDIR:-/tmp}/subact.XXXXXX")
    if command -v jq >/dev/null 2>&1 && [ -f "$FM_CONFIG_DIR/subscriptions.json" ]; then
        jq -r -f "$SCRIPT_DIR/../subscription-active.jq" "$FM_CONFIG_DIR/subscriptions.json" > "$actf" 2>/dev/null || : > "$actf"
    fi
    args+=("$actf")
    # the SKIPPED rows' Active codes (2026-09-15): the same jq over the RAW export
    local actrf; actrf=$(mktemp "${TMPDIR:-/tmp}/subactr.XXXXXX")
    if command -v jq >/dev/null 2>&1 && [ -f "$SKS" ] && [ -f "$RAWS" ]; then
        jq -r -f "$SCRIPT_DIR/../subscription-active.jq" "$RAWS" > "$actrf" 2>/dev/null || : > "$actrf"
    fi
    args+=("$actrf")
    # the subscription detail .rpt files: their Features From / To rows (the
    # first of each per file)
    shopt -s nullglob
    local drpts=("$DET/subscriptions"/*.rpt)
    shopt -u nullglob
    local all rows tots
    all=$(LC_ALL=C awk -F'\t' -v CONF="$conf" '
        function e(s) { gsub(/&/, "\\&amp;", s); gsub(/</, "\\&lt;", s); gsub(/>/, "\\&gt;", s); gsub(/"/, "\\&quot;", s); return s }
        # per-subscription value sets, deduped per (map, sub, value)
        function addv(M, tag, s, v,   k2) {
            if (s == "" || v == "") return
            k2 = toupper(s)
            if (!((tag SUBSEP k2 SUBSEP toupper(v)) in dupv)) { dupv[tag SUBSEP k2 SUBSEP toupper(v)] = 1; M[k2] = M[k2] US v }
        }
        # one name -> its detail link (no slugmap entry, or sub2 "" = plain)
        function lnk(sub2, nm,   k2) {
            k2 = toupper(nm)
            if (sub2 != "" && ((sub2 SUBSEP k2) in SLUG))
                return "<a href=\"../details/" sub2 "/" SLUG[sub2 SUBSEP k2] ".html\">" e(nm) "</a>"
            return e(nm)
        }
        # "UC12" -> 12, so the baked order puts UC2 before UC10
        function ucnum(u,   t) { t = u; sub(/^UC/, "", t); return t + 0 }
        # a \x1f set -> sorted, each value linked, ", "-joined
        function cell(sub2, set,   A2, n2, i2, j2, t3, o2) {
            if (set == "") return ""
            n2 = split(substr(set, 2), A2, US)
            for (i2 = 2; i2 <= n2; i2++) { t3 = A2[i2]
                for (j2 = i2 - 1; j2 >= 1 && A2[j2] > t3; j2--) A2[j2+1] = A2[j2]
                A2[j2+1] = t3 }
            o2 = ""
            for (i2 = 1; i2 <= n2; i2++) o2 = o2 (o2 == "" ? "" : ", ") lnk(sub2, A2[i2])
            return o2
        }
        # the BL cell: cell() with a "+" on every value input/BL.txt added
        # on top of subscriptions.json (2026-09-29: the Added BL page went)
        function blcell(k, set,   A2, n2, i2, j2, t3, o2) {
            if (set == "") return ""
            n2 = split(substr(set, 2), A2, US)
            for (i2 = 2; i2 <= n2; i2++) { t3 = A2[i2]
                for (j2 = i2 - 1; j2 >= 1 && A2[j2] > t3; j2--) A2[j2+1] = A2[j2]
                A2[j2+1] = t3 }
            o2 = ""
            for (i2 = 1; i2 <= n2; i2++) o2 = o2 (o2 == "" ? "" : ", ") lnk("bl", A2[i2]) \
                (((k SUBSEP toupper(A2[i2])) in ADDBL) ? "<sup title=\"added by input/BL.txt\">+</sup>" : "")
            return o2
        }
        # a detail-page location cell: "-" = nothing configured; "@{mask=M}path"
        # = the path with its file mask (render_rpt.awk shows the mask as the
        # green .mask suffix — the same markup here)
        function loccell(raw,   p, m) {
            if (index(raw, "@{mask=") == 1) { p = index(raw, "}"); m = substr(raw, 8, p - 8)
                return e(substr(raw, p + 1)) "<span class=\"mask\">" e(m) "</span>" }
            return e(raw)
        }
        # a cron cell: several expressions (one per line, \x1f-joined by
        # cron2human.awk) stack with <br>
        function crcell(raw,   o) { o = e(raw); gsub(/\037/, "<br>", o); return "<code>" o "</code>" }
        # the Active cell (2026-09-14): Yes, or the codes ", "-joined with their
        # words as the hover title; blank when the JSON does not name it
        function actcell(k, AA,   c, n3, A3, W3, i3, o, t) {
            # a SWIFT subscription runs through CFT (2026-09-15, user rule): CFT, whatever the JSON says
            if (index(k, "SWIFT") > 0) return "<td class=\"act\" title=\"SWIFT: runs through CFT\">CFT</td>"
            if (!(k in AA)) return "<td class=\"act\"></td>"
            c = AA[k]; if (c == "") return "<td class=\"act\">Yes</td>"
            split("status Undeployed|status SAVED_NOT_DEPLOYED|schedule No|folder monitoring Inactive", W3, "|")
            n3 = split(c, A3, ","); o = ""; t = ""
            for (i3 = 1; i3 <= n3; i3++) { o = o (o == "" ? "" : ", ") A3[i3]; t = t (t == "" ? "" : "; ") A3[i3] " " W3[A3[i3] + 0] }
            return "<td class=\"act\" title=\"" e(t) "\">" o "</td>"
        }
        # the Color cell (2026-09-15): the result as a word, white = none
        function colcell(r) { if (r != "green" && r != "orange" && r != "red") r = "white"; return "<td class=\"rescol\">" r "</td>" }
        # the Error reason cell (2026-09-15): the newest File in error, linking its error page
        function ercell(k) {
            if (!(k in ERR) || ERR[k] == "") return "<td class=\"wrap ereason\"></td>"
            if (ERH[k] != "") return "<td class=\"wrap ereason\"><a href=\"" e(ERH[k]) "\">" e(ERR[k]) "</a></td>"
            return "<td class=\"wrap ereason\">" e(ERR[k]) "</td>"
        }
        # the Direction cell (2026-09-15, user request): connection / file movement,
        # the detail page title prefix lowercased; blank when both sides are unknown
        function dircell(k,   c, m) {
            c = ((k in CDIR) && CDIR[k] != "") ? CDIR[k] : "?"; m = ((k in MVD) && MVD[k] != "") ? MVD[k] : "?"
            return "<td class=\"dir\">" ((c == "?" && m == "?") ? "" : c "/" m) "</td>"
        }
        # a count cell: 0 shows blank (class z = no tint), like the report tables
        function ncell(v, cls) { v = v + 0; if (v == 0) return "<td class=\"" cls " z\"></td>"; return "<td class=\"" cls "\">" v "</td>" }
        BEGIN { US = sprintf("%c", 31)
            if (CONF != "") { while ((getline l < CONF) > 0) { n = split(l, a, "\t")
                    if (n >= 2 && a[1] == "_subscriptions" && a[2] != "" && !(toupper(a[2]) in seenr)) { seenr[toupper(a[2])] = 1; RN[++nr] = a[2] } }
                close(CONF) }
        }
        FILENAME ~ /details\/subscriptions\/[^\/]*\.rpt$/ {
            if (FNR == 1) { lslug = FILENAME; sub(/.*\//, "", lslug); sub(/\.rpt$/, "", lslug) }
            if ($1 == "ROW" && ($2 == "From" || $2 == "To") && !((lslug SUBSEP $2) in LOC)) LOC[lslug SUBSEP $2] = $3
            next }
        FILENAME ~ /base\/_subscriptions\.tsv$/ { RES[toupper($1)] = $3; CDIR[toupper($1)] = $2
            if (CONF == "" && $1 != "" && !(toupper($1) in seenr)) { seenr[toupper($1)] = 1; RN[++nr] = $1 }
            next }
        FILENAME ~ /subact\.[A-Za-z0-9]+$/ { if ($1 != "") ACT[toupper($1)] = $2; next }
        FILENAME ~ /subactr\.[A-Za-z0-9]+$/ { if ($1 != "") ACTR[toupper($1)] = $2; next }
        FILENAME ~ /subcronr\.[A-Za-z0-9]+$/ { if ($1 != "" && $3 != "") { u = toupper($1)
                CRXR[u] = CRXR[u] ((u in CRXR) && CRXR[u] != "" ? "\037" : "") $3
                CRHR[u] = CRHR[u] ((u in CRHR) && CRHR[u] != "" ? "; " : "") $4 }
            next }
        FILENAME ~ /filtered\/_skipped\.tsv$/ { if ($1 == "Subscription" && $2 != "") SKN[++nsk] = $2; next }
        FILENAME ~ /failed-files\.rpt$/ { if ($1 == "ROW" && $2 != "") { u = toupper($2)
                if (!(u in ERT) || $3 > ERT[u]) { ERT[u] = $3; rr = $4; hh = ""
                    if (index(rr, "@{") == 1) { pp = index(rr, "}"); at = substr(rr, 3, pp - 3); rr = substr(rr, pp + 1)
                        if (match(at, /href=[^,]*/)) hh = substr(at, RSTART + 5, RLENGTH - 5) }
                    ERR[u] = rr; ERH[u] = hh } }
            next }
        FILENAME ~ /subcron\.[A-Za-z0-9]+$/ { if ($1 != "" && $3 != "") { u = toupper($1)
                CRX[u] = CRX[u] ((u in CRX) && CRX[u] != "" ? "\037" : "") $3
                CRH[u] = CRH[u] ((u in CRH) && CRH[u] != "" ? "; " : "") $4 }
            next }
        FILENAME ~ /_alltime\.tsv$/ { if ($1 == "subscription") CNT[toupper($2)] = $3 "\t" $4 "\t" $5 "\t" $6 "\t" $7 "\t" $8 "\t" $9 "\t" $10 "\t" $11; next }
        FILENAME ~ /details\/subscriptions\/_slugmap\.tsv$/ { SLUG["subscriptions" SUBSEP toupper($1)] = $2; next }
        FILENAME ~ /details\/accounts\/_slugmap\.tsv$/      { SLUG["accounts"      SUBSEP toupper($1)] = $2; next }
        FILENAME ~ /details\/logins\/_slugmap\.tsv$/        { SLUG["logins"        SUBSEP toupper($1)] = $2; next }
        FILENAME ~ /details\/hosts\/_slugmap\.tsv$/         { SLUG["hosts"         SUBSEP toupper($1)] = $2; next }
        FILENAME ~ /details\/logicals\/_slugmap\.tsv$/      { SLUG["logicals"      SUBSEP toupper($1)] = $2; next }
        FILENAME ~ /details\/partners\/_slugmap\.tsv$/      { SLUG["partners"      SUBSEP toupper($1)] = $2; next }
        FILENAME ~ /details\/domains\/_slugmap\.tsv$/       { SLUG["domains"       SUBSEP toupper($1)] = $2; next }
        FILENAME ~ /details\/applications\/_slugmap\.tsv$/  { SLUG["applications"  SUBSEP toupper($1)] = $2; next }
        FILENAME ~ /details\/bl\/_slugmap\.tsv$/            { SLUG["bl"            SUBSEP toupper($1)] = $2; next }
        FILENAME ~ /_subscriptions-ucderived\.tsv$/ { if ($1 != "" && $2 != "") UCD[toupper($1)] = $2; next }
        FILENAME ~ /_subscriptions-flowdir\.tsv$/   { if ($1 != "") { v = $2; if (v == "relay") v = "both"; MVD[toupper($1)] = v }; next }
        FILENAME ~ /_subscriptions-accounts\.tsv$/  { addv(ACC, "a", $1, $2); next }
        FILENAME ~ /_subscriptions-logins\.tsv$/    { addv(LGN, "l", $1, $2); next }
        FILENAME ~ /_subscriptions-hosts\.tsv$/     { addv(HST, "h", $1, $2); next }
        FILENAME ~ /_subscriptions-logicals\.tsv$/  { addv(LGC, "g", $1, $2); next }
        FILENAME ~ /_subscriptions-partners\.tsv$/  { addv(PTN, "p", $1, $2); next }
        FILENAME ~ /_subscriptions-domains\.tsv$/   { addv(DOM, "d", $1, $2); next }
        FILENAME ~ /_subscriptions-apps\.tsv$/      { addv(APP, "z", $1, $2); next }
        FILENAME ~ /_subscriptions-bl\.tsv$/        { addv(BLE, "b", $1, $2); next }
        FILENAME ~ /_subscriptions-bl-added\.tsv$/  { if ($1 != "" && $2 != "") ADDBL[toupper($1) SUBSEP toupper($2)] = 1; next }
        END {
            for (i = 1; i <= nr; i++) { nm = RN[i]; k = toupper(nm)
                # baked order: use case (the name prefix, else the derived one) then name
                uc = ""
                if (match(nm, /^UC[0-9]+/)) uc = substr(nm, RSTART, RLENGTH)
                else if (k in UCD) uc = UCD[k]
                ucsort = sprintf("%03d", ucnum(toupper(uc)))
                slug = (("subscriptions" SUBSEP k) in SLUG) ? SLUG["subscriptions" SUBSEP k] : ""
                fr = (slug != "" && ((slug SUBSEP "From") in LOC)) ? loccell(LOC[slug SUBSEP "From"]) : ""
                to = (slug != "" && ((slug SUBSEP "To") in LOC)) ? loccell(LOC[slug SUBSEP "To"]) : ""
                ep = cell("logins", (k in LGN) ? LGN[k] : ""); hp = cell("hosts", (k in HST) ? HST[k] : "")
                epc = ep ((ep != "" && hp != "") ? ", " : "") hp
                res = (k in RES) ? RES[k] : ""
                tr = "<tr"
                if (res == "green" || res == "orange" || res == "red") tr = tr " data-res=\"" res "\""
                if (k in CNT) split(CNT[k], C, "\t"); else for (ci = 1; ci <= 9; ci++) C[ci] = 0
                for (ci = 1; ci <= 9; ci++) TOT[ci] += C[ci]
                # column order (2026-09-13, user request): name, Active (2026-09-14), the routing
                # (Endpoint, From, To), the counts, the groups, the cron
                # columns last; the Schedule cell never wraps
                print ucsort "\t" k "\t" tr ">" \
                    "<td>" lnk("subscriptions", nm) "</td>" \
                    "<td>" e(uc) "</td>" \
                    actcell(k, ACT) colcell(res) dircell(k) \
                    "<td class=\"wrap\">" epc "</td>" \
                    "<td class=\"wrap\">" fr "</td>" \
                    "<td class=\"wrap\">" to "</td>" \
                    ncell(C[1], "num") ncell(C[2], "num") ncell(C[3], "num") ncell(C[4], "num failed") \
                    ncell(C[5], "num warn") ncell(C[6], "num warn") ncell(C[7], "num failed") \
                    ncell(C[8], "num warn") ncell(C[9], "num failed") \
                    ercell(k) \
                    "<td>" cell("logicals", (k in LGC) ? LGC[k] : "") "</td>" \
                    "<td class=\"wrap\">" cell("accounts", (k in ACC) ? ACC[k] : "") "</td>" \
                    "<td class=\"wrap\">" cell("partners", (k in PTN) ? PTN[k] : "") "</td>" \
                    "<td>" cell("domains", (k in DOM) ? DOM[k] : "") "</td>" \
                    "<td>" cell("applications", (k in APP) ? APP[k] : "") "</td>" \
                    "<td>" blcell(k, (k in BLE) ? BLE[k] : "") "</td>" \
                    "<td class=\"mono\">" ((k in CRX) ? crcell(CRX[k]) : "") "</td>" \
                    "<td>" ((k in CRH) ? e(CRH[k]) : "") "</td></tr>"
            }
            # the SKIPPED subscriptions (2026-09-15, user request): n/a counts, white, no groups
            for (i = 1; i <= nsk; i++) { nm = SKN[i]; k = toupper(nm)
                if (k in seenr) continue
                seenr[k] = 1
                uc = ""
                if (match(nm, /^UC[0-9]+/)) uc = substr(nm, RSTART, RLENGTH)
                else if (k in UCD) uc = UCD[k]
                ucsort = sprintf("%03d", ucnum(toupper(uc)))
                na = ""; for (ci = 1; ci <= 9; ci++) na = na "<td class=\"num na\">n/a</td>"
                print ucsort "\t" k "\t<tr data-skipped=\"1\">" \
                    "<td>" lnk("subscriptions", nm) "</td>" \
                    "<td>" e(uc) "</td>" \
                    actcell(k, ACTR) colcell("") "<td class=\"dir\"></td>" \
                    "<td class=\"wrap\"></td><td class=\"wrap\"></td><td class=\"wrap\"></td>" \
                    na ercell(k) \
                    "<td></td><td class=\"wrap\"></td><td class=\"wrap\"></td><td></td><td></td><td></td>" \
                    "<td class=\"mono\">" ((k in CRXR) ? crcell(CRXR[k]) : "") "</td>" \
                    "<td>" ((k in CRHR) ? e(CRHR[k]) : "") "</td></tr>"
            }
            # the column sums: sorted LAST ("~" > every UC key), split off below
            printf "~\t~"; for (ci = 1; ci <= 9; ci++) printf "\t%d", TOT[ci] + 0; printf "\n"
        }' ${args[@]+"${args[@]}"} ${drpts[@]+"${drpts[@]}"} "$B/_subscriptions.tsv" \
        | LC_ALL=C sort -t"$(printf '\t')" -k1,1 -k2,2)
    rm -f "$cronf" "$actf" "$cronrf" "$actrf"
    rows=$(printf '%s\n' "$all" | awk -F'\t' '$1 != "~"' | cut -f3-)
    tots=$(printf '%s\n' "$all" | awk -F'\t' '$1 == "~"' | cut -f3-)
    local n; n=$(printf '%s' "$rows" | grep -c '<tr' || true)
    local t1 t2 t3 t4 t5 t6 t7 t8 t9 tcells
    IFS=$'\t' read -r t1 t2 t3 t4 t5 t6 t7 t8 t9 <<< "$tots"
    # the FM EXPORT stamp in the title (2026-09-28, user request): the RAW
    # subscriptions.json modification time — the inbox intake copies the
    # export with cp -p, so this is the export's own time, not the build's
    local fmts=""
    [ -f "$RAWS" ] && fmts=$(stat -f '%Sm' -t '%Y-%m-%d %H:%M' "$RAWS" 2>/dev/null || true)
    tcells="$(_subs_tcell "$t1" num)$(_subs_tcell "$t2" num)$(_subs_tcell "$t3" num)$(_subs_tcell "$t4" "num failed")$(_subs_tcell "$t5" "num warn")$(_subs_tcell "$t6" "num warn")$(_subs_tcell "$t7" "num failed")$(_subs_tcell "$t8" "num warn")$(_subs_tcell "$t9" "num failed")"
    {
        html_head "Configured subscriptions" "../assets/style.css" "" "" "subscriptions" "" "" "sort-fresh"
        printf '<h1>Configured subscriptions%s</h1>\n' "${fmts:+ - FM export $fmts}"
        printf '<div class="tablewrap"><table class="index fit">\n'
        printf '<tr><th>Subscription</th><th>Use case</th><th>Active</th><th>Color</th><th>Direction</th><th>Endpoint</th><th>From</th><th>To</th><th class="num">Total files</th><th class="num">In Files</th><th class="num">Out Files</th><th class="num">Errors</th><th class="num">Auto Retries</th><th class="num">Resubmit OK</th><th class="num">Resubmit Error</th><th class="num">Waiting</th><th class="num">Expired</th><th>Error reason</th><th>Logical</th><th>Account</th><th>Partner</th><th>Domain</th><th>Application</th><th>BL</th><th>Cron expression</th><th>Schedule</th></tr>\n'
        [ -n "$rows" ] && printf '%s\n' "$rows"
        printf '<tr class="total"><td>Total (%s)</td><td></td><td></td><td></td><td></td><td></td><td></td><td></td>%s<td></td><td></td><td></td><td></td><td></td><td></td><td></td><td></td><td></td></tr>\n' "$n" "$tcells"
        printf '</table></div>\n'
        printf '</body>\n</html>\n'
    } > "$out"
}

# ---- the Accounts page (docs/analyses/accounts.html) — account + comm-profile checks
# A comm profile (partners.json communicationProfiles[]) defines how ST talks to
# ONE partner endpoint. Its name is coded <TYPE>_<partner>_<AUTH>: the PREFIX is
# the connection type — SCP/SSCP = server (ST connects out), CCP = client (the
# partner connects in) — and the SUFFIX is the auth — PWD = password, KEY = public
# key. This page tallies both and checks them against each profile's real .type
# and .clientAuthentication. Reads partners.json with jq (skipped if it is
# absent, e.g. a fresh clone without the config exports).
write_accounts_page() {
    local out="$ADIR/accounts.html" P="$FM_CONFIG_DIR/partners.json"   # SKIP-filtered when present
    [ -f "$P" ] || { rm -f "$out"; return 0; }
    local total server client sftp ftp
    read -r total server client sftp ftp <<<"$(jq -rn --slurpfile P "$P" '$P[0]|[.[].communicationProfiles[]?]|"\(length) \([.[]|select(.type=="SERVER")]|length) \([.[]|select(.type=="CLIENT")]|length) \([.[]|select(.protocol=="SFTP")]|length) \([.[]|select(.protocol=="FTP")]|length)"')"
    local prefix_rows suffix_rows mm_rows nmm
    prefix_rows=$(jq -r '[.[].communicationProfiles[]?|{p:(.name|split("_")[0]),t:.type}]|group_by(.p)|map("\(.[0].p)\t\(length)\t\(.[0].t)")[]' "$P" | LC_ALL=C sort -t"$(printf '\t')" -k2,2nr)
    suffix_rows=$(jq -rn --slurpfile P "$P" '($P[0]|[.[].communicationProfiles[]?|{s:(.name|split("_")[-1]),a:(.clientAuthentication//"null")}]) as $c|
      ($c|map(select(.s=="PWD"))) as $p|($c|map(select(.s=="KEY"))) as $k|($c|map(select(.s!="PWD" and .s!="KEY"))) as $o|
      "PWD\tpassword\t\($p|length)\t\($p|map(select(.a=="PASSWORD"))|length)",
      "KEY\tpublic key\t\($k|length)\t\($k|map(select(.a|IN("PUBLIC_KEY","PASSWORD_OR_PUBLIC_KEY")))|length)",
      "(other)\tno PWD/KEY suffix (the FTP endpoints, below)\t\($o|length)\t-"')
    mm_rows=$(jq -r '.[]|.communicationProfiles[]?|select(.name!=null)|(.name|split("_")[-1]) as $s|
      select(($s=="PWD" and .clientAuthentication!="PASSWORD") or ($s=="KEY" and (.clientAuthentication|IN("PUBLIC_KEY","PASSWORD_OR_PUBLIC_KEY")|not)))|
      "\(.name)\t\($s)\t\(.clientAuthentication//"null")"' "$P" | LC_ALL=C sort)
    nmm=$(printf '%s' "$mm_rows" | grep -c $'\t' || true)

    # (the naming-rule check — the Breaking naming rules table: an incoming
    # account separating its parts with "_" or an outgoing one with "-" — went
    # 2026-09-29, user request)

    # ---- PDA completeness: an account is meant to be connected to a LOGICAL
    # flow, whose three-part name D_A_P is where the domain / application /
    # partner come from (the 2026-08-30 logical-based derivation). Rather than
    # re-deriving that here, ask the DERIVATION what it managed to assign — the
    # three xref caches bin/flow-manager.sh composes through the FlowID. The
    # why is binary: no FlowID at all (no subscription of the account carries
    # one), or a FlowID whose logical is a pinned short name (input/logical.txt
    # — no domain/application/partner slots).
    local pda_rows pda_bad
    pda_rows=$(awk -F'\t' '
        # ALL of an account'\''s values, ", "-joined and deduped (2026-08-31
        # audit: a plain m[$1]=$2 over these many-valued caches showed a
        # hybrid production account, connected to three domains, with one)
        function acc(M, k, v) { if (index("\037" M[k] "\037", "\037" v "\037") == 0) M[k] = (M[k] == "" ? v : M[k] "\037" v) }
        function j(v) { gsub(/\037/, ", ", v); return v }
        FILENAME ~ /-domains/  { acc(D, toupper($1), $2); next }
        FILENAME ~ /-apps/     { acc(A, toupper($1), $2); next }
        FILENAME ~ /-partners/ { acc(P, toupper($1), $2); next }
        FILENAME ~ /_accounts-profiles/ { F[toupper($1)] = 1; next }
        $1 != "#" && $1 != "" {
            k = toupper($1)
            if ((k in D) && (k in A) && (k in P)) { ok++; next }
            miss = ""
            if (!(k in D)) miss = miss "domain, "
            if (!(k in A)) miss = miss "application, "
            if (!(k in P)) miss = miss "partner, "
            sub(/, $/, "", miss)
            why = (k in F) ? "its logical flow has a pinned short name — no domain/application/partner parts" \
                : "not connected to any logical flow (no subscription of this account carries a FlowID)"
            printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n", $1, \
                   (k in D ? j(D[k]) : ""), (k in A ? j(A[k]) : ""), (k in P ? j(P[k]) : ""), miss, why, $3
            bad++
        }
        END { printf "#\t%d\t%d\n", ok+0, bad+0 }' \
        "$DATA/flow-manager/xref/_accounts-domains.tsv" "$DATA/flow-manager/xref/_accounts-apps.tsv" \
        "$DATA/flow-manager/xref/_accounts-partners.tsv" "$DATA/flow-manager/xref/_accounts-profiles.tsv" \
        "$DATA/flow-manager/base/_accounts.tsv")
    local pda_ok
    IFS=$'\t' read -r _ pda_ok pda_bad <<< "$(printf '%s\n' "$pda_rows" | grep '^#')"
    pda_rows=$(printf '%s\n' "$pda_rows" | grep -v '^#' || true)
    # The FTP profiles == the "(other)" auth-suffix exceptions (same set): FTP has
    # no public key, so their auth is unset and their name ends in a partner tag.
    local ftp_rows nftp
    ftp_rows=$(jq -r '.[]|.communicationProfiles[]?|select(.protocol=="FTP")|"\(.name)\t\((.name|split("_")[-1]))\t\(.clientAuthentication//"none")"' "$P" | LC_ALL=C sort)
    nftp=$(printf '%s' "$ftp_rows" | grep -c $'\t' || true)
    # Incoming (CLIENT) partners with NO AllowIP whitelist — unrestricted inbound.
    local iw_rows niw
    iw_rows=$(jq -r '.[] | select(any(.communicationProfiles[]?; .type=="CLIENT")) |
      select([.customAttributes // {} | to_entries[] | select(.key|test("^AllowIP[0-9]+$")) | .value | select(.!=null and .!="")] | length == 0) |
      .name as $p | ([.communicationProfiles[] | select(.type=="CLIENT")][0]) as $cp |
      "\($p)\t\($cp.protocol)\t\($cp.clientAuthentication // "none")"' "$P" | LC_ALL=C sort -u)
    niw=$(printf '%s' "$iw_rows" | grep -c $'\t' || true)
    # Remote-host conflicts, GENERALISED: for EVERY host-intrinsic connection
    # attribute, the hosts reached from >1 SERVER profile that carry >1 distinct
    # value. One tagged stream "field<TAB>label<TAB>host<TAB>value<TAB>profiles"
    # (profiles capped at 6 + "(+N more)"), so any attribute that ever diverges
    # gets its own table below. clientAuthentication is per-account (not host-
    # intrinsic) and excluded; protocol/fips/enabled are checked too so a future
    # divergence is covered even though they agree today.
    local hc_stream="" spec field label r
    for spec in "port|Port" "serverVerification|Host-key verification" "storedPublicKey|Stored host key" \
                "protocol|Protocol" "fipsEnabled|FIPS mode" "enabled|Profile enabled"; do
        field=${spec%%|*}; label=${spec#*|}
        r=$(jq -r --arg a "$field" '.[].communicationProfiles[]? | select((.hosts//[])|length>0) |
              (.[$a]|tostring) as $v | .name as $prof | (.hosts[]|select(.!=null and .!="")|ascii_downcase) as $h |
              "\($h)\t\($v)\t\($prof)"' "$P" \
            | LC_ALL=C sort -u | awk -F'\t' '
                { k=$1 SUBSEP $2; if(!(k in seen)){seen[k]=1; idx[++n]=k; hh[n]=$1; vv[n]=$2; nset[$1]++; pc[k]=0} pc[k]++; if(pc[k]<=6) pj[k]=pj[k](pj[k]?", ":"")$3 }
                END{ for(i=1;i<=n;i++) if(nset[hh[i]]>1){p=pj[idx[i]]; if(pc[idx[i]]>6) p=p" (+"(pc[idx[i]]-6)" more)"; print hh[i]"\t"vv[i]"\t"p} }')
        [ -n "$r" ] && hc_stream+="$(printf '%s\n' "$r" | awk -v f="$field" -v l="$label" 'BEGIN{FS=OFS="\t"}{print f,l,$0}')"$'\n'
    done
    # Whitelist conflicts, GENERALISED (the inbound mirror of the host check):
    # for EVERY incoming CLIENT attribute, the whitelisted IPs shared by >1
    # incoming partner that carry >1 distinct value. Tagged stream
    # "field<TAB>label<TAB>ip<TAB>value<TAB>partners" (partners capped), one table
    # per diverging attribute. Per-account login/loginName are excluded (they
    # differ by account by design); protocol/fips/enabled are checked for the
    # future though they agree today.
    local wc_stream="" wspec wfield wlabel wr
    for wspec in "clientAuthentication|Authentication" "protocol|Protocol" "fipsEnabled|FIPS mode" "enabled|Profile enabled"; do
        wfield=${wspec%%|*}; wlabel=${wspec#*|}
        wr=$(jq -r --arg a "$wfield" '.[] | select(any(.communicationProfiles[]?; .type=="CLIENT")) |
              .name as $pt | ([.communicationProfiles[] | select(.type=="CLIENT")][0]) as $cp |
              (.customAttributes // {} | to_entries[] | select(.key|test("^AllowIP[0-9]+$")) | .value | select(.!=null and .!="")) as $raw |
              ($raw | split(";")[] | gsub("[[:space:]]";"") | select(.!="")) as $ip |
              "\($ip)\t\($cp[$a]|tostring)\t\($pt)"' "$P" \
            | LC_ALL=C sort -u | awk -F'\t' '
                { k=$1 SUBSEP $2; if(!(k in seen)){seen[k]=1; idx[++n]=k; ii[n]=$1; vv[n]=$2; nset[$1]++; pc[k]=0} pc[k]++; if(pc[k]<=6) pj[k]=pj[k](pj[k]?", ":"")$3 }
                END{ for(i=1;i<=n;i++) if(nset[ii[i]]>1){p=pj[idx[i]]; if(pc[idx[i]]>6) p=p" (+"(pc[idx[i]]-6)" more)"; print ii[i]"\t"vv[i]"\t"p} }')
        [ -n "$wr" ] && wc_stream+="$(printf '%s\n' "$wr" | awk -v f="$wfield" -v l="$wlabel" 'BEGIN{FS=OFS="\t"}{print f,l,$0}')"$'\n'
    done
    # ---- ACCOUNT / LOGIN integrity checks (rendered at the end) --------------
    # A CLIENT profile login (the username a partner connects IN with) is
    # normally a provisioned FE<digits> account; SERVER profiles carry no login.
    # 1. non-standard login (a CLIENT login that is not FE<digits>)
    local nsl_rows nnsl
    nsl_rows=$(jq -r '.[] as $a | $a.communicationProfiles[]? | select(.type=="CLIENT") | (.login//"") as $l
        | select($l!="" and (($l|test("^FE[0-9]"))|not)) | "\($a.name)\t\(.name)\t\($l)"' "$P" | LC_ALL=C sort)
    nnsl=$(printf '%s' "$nsl_rows" | grep -c $'\t' || true)
    # 2. one login used by more than one account
    local shl_rows nshl
    shl_rows=$(jq -r '.[] as $a | $a.communicationProfiles[]? | (.login//"") | select(.!="") | "\(.)\t\($a.name)"' "$P" \
        | LC_ALL=C sort -u | awk -F'\t' '{c[$1]++; ac[$1]=ac[$1](ac[$1]?", ":"")$2} END{for(l in c) if(c[l]>1) print l"\t"c[l]"\t"ac[l]}' | LC_ALL=C sort)
    nshl=$(printf '%s' "$shl_rows" | grep -c $'\t' || true)
    # 3. communication profiles with more than one host (a SERVER endpoint should
    #    resolve to exactly one host)
    local mh_rows nmh
    mh_rows=$(jq -r '.[] as $a | $a.communicationProfiles[]? | select((.hosts//[])|length>1)
        | "\($a.name)\t\(.name)\t\((.hosts//[])|length)\t\((.hosts//[])|join(", "))"' "$P" | LC_ALL=C sort)
    nmh=$(printf '%s' "$mh_rows" | grep -c $'\t' || true)
    # 4. incoming (CLIENT) password profiles whose login credential holds NO
    #    password (clientAuthentication=PASSWORD but the credential hasPassword=false)
    local npw_rows nnpw
    npw_rows=$(jq -r '.[] as $a | ($a.credentials//[]) as $c
        | $a.communicationProfiles[]? | select(.type=="CLIENT" and .clientAuthentication=="PASSWORD") | .login as $l
        | select([$c[] | select(.login==$l and .hasPassword==true)] | length == 0)
        | "\($a.name)\t\(.name)\t\($l // "-")"' "$P" | LC_ALL=C sort)
    nnpw=$(printf '%s' "$npw_rows" | grep -c $'\t' || true)
    # 5. accounts with more than one communication profile (normally one endpoint)
    local mcp_rows nmcp
    mcp_rows=$(jq -r '.[] | select((.communicationProfiles//[])|length>1)
        | "\(.name)\t\((.communicationProfiles|length))\t\([.communicationProfiles[].name]|join(" | "))"' "$P" | LC_ALL=C sort)
    nmcp=$(printf '%s' "$mcp_rows" | grep -c $'\t' || true)
    # 6. login vs loginName mismatch (the two should agree on CLIENT profiles)
    local lnm_rows nlnm
    lnm_rows=$(jq -r '.[] as $a | $a.communicationProfiles[]? | select(.type=="CLIENT" and .login!=null and .loginName!=null and (.login!=.loginName))
        | "\($a.name)\t\(.name)\t\(.login)\t\(.loginName)"' "$P" | LC_ALL=C sort)
    nlnm=$(printf '%s' "$lnm_rows" | grep -c $'\t' || true)
    {
        html_head "Configured accounts" "../assets/style.css" "" "" "accounts" "" "" "sort-fresh"
        printf '<h1>Configured accounts</h1>\n'   # = its Reports menu label (2026-09-29)
        printf '<div class="sxs">\n'
        printf '<div class="sxscol"><h2>Connection type</h2><div class="tablewrap"><table class="index fit">\n'
        printf '<tr><th>Type</th><th class="num">Profiles</th></tr>\n'
        printf '<tr><td>Server &mdash; we connect out to the partner</td><td class="num">%s</td></tr>\n' "$(dotify "$server")"
        printf '<tr><td>Client &mdash; the partner connects in to us</td><td class="num">%s</td></tr>\n' "$(dotify "$client")"
        printf '<tr class="total"><td>Total</td><td class="num">%s</td></tr>\n' "$(dotify "$total")"
        printf '</table></div></div>\n'
        printf '<div class="sxscol"><h2>Protocol</h2><div class="tablewrap"><table class="index fit">\n'
        printf '<tr><th>Protocol</th><th class="num">Profiles</th></tr>\n'
        printf '<tr><td>SFTP &mdash; secure</td><td class="num">%s</td></tr>\n' "$(dotify "$sftp")"
        printf '<tr data-res="red"><td>FTP &mdash; <strong>insecure</strong></td><td class="num">%s</td></tr>\n' "$(dotify "$ftp")"
        printf '<tr class="total"><td>Total</td><td class="num">%s</td></tr>\n' "$(dotify "$total")"
        printf '</table></div></div>\n'
        printf '</div>\n'
        printf '<h2>Type &mdash; the name prefix</h2>\n<div class="tablewrap"><table class="index fit">\n'
        printf '<tr><th>Prefix</th><th>Meaning</th><th class="num">Profiles</th><th>Configured type</th></tr>\n'
        printf '%s\n' "$prefix_rows" | tr '\t' '\036' | while IFS=$'\036' read -r tok n typ; do
            [ -n "$tok" ] || continue
            case $tok in SCP) mean="Server comm profile" ;; SSCP) mean="Secure server comm profile" ;; CCP) mean="Client comm profile" ;; *) mean="&mdash;" ;; esac
            esc "$tok"; te=$ESC; esc "$typ"; tye=$ESC
            printf '<tr><td>%s</td><td>%s</td><td class="num">%s</td><td>%s</td></tr>\n' "$te" "$mean" "$(dotify "$n")" "$tye"
        done
        printf '</table></div>\n'
        printf '<h2>Authentication &mdash; the name suffix</h2>\n<div class="tablewrap"><table class="index fit">\n'
        printf '<tr><th>Suffix</th><th>Meaning</th><th class="num">Profiles</th><th class="num">Match auth</th><th class="num">Mismatch</th></tr>\n'
        printf '%s\n' "$suffix_rows" | while IFS=$'\t' read -r tok mean n match; do
            [ -n "$tok" ] || continue
            esc "$tok"; se=$ESC
            if [ "$match" = "-" ]; then
                printf '<tr><td>%s</td><td>%s</td><td class="num">%s</td><td class="num"></td><td class="num"></td></tr>\n' "$se" "$mean" "$(dotify "$n")"
            else
                mmc=$((n - match))
                printf '<tr><td>%s</td><td>%s</td><td class="num">%s</td><td class="num st-ok">%s</td>%s</tr>\n' "$se" "$mean" "$(dotify "$n")" "$(dotify "$match")" \
                    "$( [ "$mmc" -gt 0 ] && printf '<td class="num st-err">%s</td>' "$(dotify "$mmc")" || printf '<td class="num"></td>' )"
            fi
        done
        printf '</table></div>\n'
        printf '<h2>Naming inconsistencies (%s)</h2>\n' "$nmm"
        if [ "$nmm" -gt 0 ]; then
            printf '<div class="tablewrap"><table class="index fit">\n<tr><th>Communication profile</th><th>Suffix says</th><th>Actual authentication</th></tr>\n'
            printf '%s\n' "$mm_rows" | while IFS=$'\t' read -r nm suf auth; do
                [ -n "$nm" ] || continue
                esc "$nm"; nme=$ESC; esc "$suf"; sfe=$ESC; esc "$auth"; ae=$ESC
                printf '<tr data-res="red"><td><code>%s</code></td><td>%s</td><td>%s</td></tr>\n' "$nme" "$sfe" "$ae"
            done
            printf '</table></div>\n'
        else
            printf '<p class="range">No inconsistencies &mdash; every profile&rsquo;s auth suffix matches its configured authentication.</p>\n'
        fi
        printf '<h2>Not clear domain-application-partner (%s)</h2>\n' "$(dotify "${pda_bad:-0}")"
        if [ "${pda_bad:-0}" -gt 0 ]; then
            printf '<div class="tablewrap"><table class="index fit">\n<tr><th>Account</th><th>Domain</th><th>Application</th><th>Partner</th><th>Missing</th><th>Why</th></tr>\n'
            # \037, not TAB: a TAB is IFS whitespace, so consecutive empty
            # fields (a missing domain/application/partner is exactly that)
            # collapse on read and shift every later column.
            printf '%s\n' "$pda_rows" | tr '\t' '\036' | while IFS=$'\036' read -r nm dm ap pt miss why res; do
                [ -n "$nm" ] || continue
                esc "$nm"; nme=$ESC; esc "$dm"; dme=$ESC; esc "$ap"; ape=$ESC; esc "$pt"; pte=$ESC
                esc "$miss"; mse=$ESC; esc "$why"; whe=$ESC
                printf '<tr data-res="%s"><td><code>%s</code></td><td>%s</td><td>%s</td><td>%s</td><td>%s</td><td>%s</td></tr>\n' \
                    "${res:-orange}" "$nme" "${dme:-&mdash;}" "${ape:-&mdash;}" "${pte:-&mdash;}" "$mse" "$whe"
            done
            printf '</table></div>\n'
        else
            printf '<p class="range">All %s accounts resolve to a domain, an application and a partner.</p>\n' "$(dotify "${pda_ok:-0}")"
        fi
        printf '<h2>FTP endpoints (%s) &mdash; insecure</h2>\n' "$(dotify "$nftp")"
        printf '<div class="tablewrap"><table class="index fit">\n<tr><th>Communication profile</th><th>Name suffix</th><th>Authentication</th></tr>\n'
        printf '%s\n' "$ftp_rows" | tr '\t' '\036' | while IFS=$'\036' read -r nm suf auth; do
            [ -n "$nm" ] || continue
            esc "$nm"; nme=$ESC; esc "$suf"; sfe=$ESC; esc "$auth"; ae=$ESC
            printf '<tr data-res="red"><td><code>%s</code></td><td>%s</td><td>%s</td></tr>\n' "$nme" "$sfe" "$ae"
        done
        printf '</table></div>\n'
        printf '<h2>Incoming partners without IP whitelisting (%s)</h2>\n' "$(dotify "$niw")"
        if [ "$niw" -gt 0 ]; then
            printf '<div class="tablewrap"><table class="index fit">\n<tr><th>Partner</th><th>Protocol</th><th>Authentication</th><th>Status</th></tr>\n'
            printf '%s\n' "$iw_rows" | tr '\t' '\036' | while IFS=$'\036' read -r p proto auth; do
                [ -n "$p" ] || continue
                res=$(awk -F'\t' -v n="$p" 'toupper($1)==toupper(n){print $3; exit}' $DATA/flow-manager/base/_accounts.tsv)
                case $res in green) st="seen (last OK)" ;; red) st="seen (last Error)" ;; orange) st="never seen" ;; *) st="-" ;; esac
                esc "$p"; pe=$ESC; esc "$proto"; pre=$ESC; esc "$auth"; ae=$ESC; esc "$st"; ste=$ESC
                printf '<tr data-res="red"><td>%s</td><td>%s</td><td>%s</td><td>%s</td></tr>\n' "$pe" "$pre" "$ae" "$ste"
            done
            printf '</table></div>\n'
        else
            printf '<p class="range">Every incoming (CLIENT) partner has an <code>AllowIP</code> whitelist &mdash; no unrestricted inbound access.</p>\n'
        fi
        printf '<h2>Hosts with conflicting setup</h2>\n'
        if [ -n "$hc_stream" ]; then
            local aspec arows anh prevh
            for aspec in "port|Port" "serverVerification|Host-key verification" "storedPublicKey|Stored host key" \
                         "protocol|Protocol" "fipsEnabled|FIPS mode" "enabled|Profile enabled"; do
                field=${aspec%%|*}; label=${aspec#*|}
                arows=$(printf '%s\n' "$hc_stream" | awk -F'\t' -v f="$field" '$1==f{print $3"\t"$4"\t"$5}')
                [ -n "$arows" ] || continue
                anh=$(printf '%s\n' "$arows" | awk -F'\t' 'NF && !($1 in h){h[$1]=1;n++} END{print n+0}')
                esc "$label"
                printf '<h3>%s (%s host(s))</h3>\n<div class="tablewrap"><table class="index fit">\n<tr><th>Remote host</th><th>Value</th><th>Profiles</th></tr>\n' "$ESC" "$(dotify "$anh")"
                prevh=""
                printf '%s\n' "$arows" | tr '\t' '\036' | while IFS=$'\036' read -r h v pf; do
                    [ -n "$h" ] || continue
                    if [ "$h" = "$prevh" ]; then hcell=""; else esc "$h"; hcell="<code>$ESC</code>"; prevh="$h"; fi
                    esc "$v"; ve=$ESC; esc "$pf"; pfe=$ESC
                    printf '<tr data-res="red"><td>%s</td><td>%s</td><td>%s</td></tr>\n' "$hcell" "$ve" "$pfe"
                done
                printf '</table></div>\n'
            done
        else
            printf '<p class="range">Every remote host used by more than one profile is configured identically &mdash; no conflicts.</p>\n'
        fi
        printf '<h2>Whitelisted IPs with conflicting incoming setup</h2>\n'
        if [ -n "$wc_stream" ]; then
            local waspec warows wanh previp
            for waspec in "clientAuthentication|Authentication" "protocol|Protocol" "fipsEnabled|FIPS mode" "enabled|Profile enabled"; do
                wfield=${waspec%%|*}; wlabel=${waspec#*|}
                warows=$(printf '%s\n' "$wc_stream" | awk -F'\t' -v f="$wfield" '$1==f{print $3"\t"$4"\t"$5}')
                [ -n "$warows" ] || continue
                wanh=$(printf '%s\n' "$warows" | awk -F'\t' 'NF && !($1 in h){h[$1]=1;n++} END{print n+0}')
                esc "$wlabel"
                printf '<h3>%s (%s IP(s))</h3>\n<div class="tablewrap"><table class="index fit">\n<tr><th>Whitelisted IP</th><th>Value</th><th>Partners</th></tr>\n' "$ESC" "$(dotify "$wanh")"
                previp=""
                printf '%s\n' "$warows" | tr '\t' '\036' | while IFS=$'\036' read -r ip v pf; do
                    [ -n "$ip" ] || continue
                    if [ "$ip" = "$previp" ]; then ic=""; else esc "$ip"; ic="<code>$ESC</code>"; previp="$ip"; fi
                    esc "$v"; ve=$ESC; esc "$pf"; pfe=$ESC
                    printf '<tr data-res="orange"><td>%s</td><td>%s</td><td>%s</td></tr>\n' "$ic" "$ve" "$pfe"
                done
                printf '</table></div>\n'
            done
        else
            printf '<p class="range">Every whitelisted IP shared by multiple incoming partners is configured identically &mdash; no conflicts.</p>\n'
        fi
        # ---- Account & login checks ------------------------------------------
        printf '<h2>Account &amp; login checks</h2>\n'
        # 1. non-standard login names
        printf '<h3>Non-standard login names (%s)</h3>\n' "$(dotify "$nnsl")"
        if [ "$nnsl" -gt 0 ]; then
            printf '<div class="tablewrap"><table class="index fit">\n<tr><th>Account</th><th>Communication profile</th><th>Login</th></tr>\n'
            printf '%s\n' "$nsl_rows" | tr '\t' '\036' | while IFS=$'\036' read -r a p l; do
                [ -n "$a" ] || continue; esc "$a"; ae=$ESC; esc "$p"; pe=$ESC; esc "$l"; le=$ESC
                printf '<tr data-res="orange"><td>%s</td><td><code>%s</code></td><td><code>%s</code></td></tr>\n' "$ae" "$pe" "$le"
            done
            printf '</table></div>\n'
        else printf '<p class="range">Every incoming login is a standard <code>FE&lt;digits&gt;</code> name.</p>\n'; fi
        # 2. one login on more than one account
        printf '<h3>Login used by more than one account (%s)</h3>\n' "$(dotify "$nshl")"
        if [ "$nshl" -gt 0 ]; then
            printf '<div class="tablewrap"><table class="index fit">\n<tr><th>Login</th><th class="num">Accounts</th><th>On</th></tr>\n'
            printf '%s\n' "$shl_rows" | while IFS=$'\t' read -r l n ac; do
                [ -n "$l" ] || continue; esc "$l"; le=$ESC; esc "$ac"; ace=$ESC
                printf '<tr data-res="orange"><td><code>%s</code></td><td class="num">%s</td><td>%s</td></tr>\n' "$le" "$n" "$ace"
            done
            printf '</table></div>\n'
        else printf '<p class="range">Every login belongs to a single account.</p>\n'; fi
        # 3. communication profiles with more than one host
        printf '<h3>Communication profiles with more than one host (%s)</h3>\n' "$(dotify "$nmh")"
        if [ "$nmh" -gt 0 ]; then
            printf '<div class="tablewrap"><table class="index fit">\n<tr><th>Account</th><th>Communication profile</th><th class="num">Hosts</th><th>Host list</th></tr>\n'
            printf '%s\n' "$mh_rows" | tr '\t' '\036' | while IFS=$'\036' read -r a p n hl; do
                [ -n "$a" ] || continue; esc "$a"; ae=$ESC; esc "$p"; pe=$ESC; esc "$hl"; hle=$ESC
                printf '<tr data-res="orange"><td>%s</td><td><code>%s</code></td><td class="num">%s</td><td>%s</td></tr>\n' "$ae" "$pe" "$n" "$hle"
            done
            printf '</table></div>\n'
        else printf '<p class="range">Every communication profile resolves to a single host.</p>\n'; fi
        # 4. incoming password profiles with no stored password
        printf '<h3>Incoming password profiles with no stored password (%s)</h3>\n' "$(dotify "$nnpw")"
        if [ "$nnpw" -gt 0 ]; then
            printf '<div class="tablewrap"><table class="index fit">\n<tr><th>Account</th><th>Communication profile</th><th>Login</th></tr>\n'
            printf '%s\n' "$npw_rows" | tr '\t' '\036' | while IFS=$'\036' read -r a p l; do
                [ -n "$a" ] || continue; esc "$a"; ae=$ESC; esc "$p"; pe=$ESC; esc "$l"; le=$ESC
                printf '<tr data-res="orange"><td>%s</td><td><code>%s</code></td><td><code>%s</code></td></tr>\n' "$ae" "$pe" "$le"
            done
            printf '</table></div>\n'
        else printf '<p class="range">Every incoming password profile has a stored password.</p>\n'; fi
        # 5. accounts with more than one communication profile
        printf '<h3>Accounts with more than one communication profile (%s)</h3>\n' "$(dotify "$nmcp")"
        if [ "$nmcp" -gt 0 ]; then
            printf '<div class="tablewrap"><table class="index fit">\n<tr><th>Account</th><th class="num">Profiles</th><th>Communication profiles</th></tr>\n'
            printf '%s\n' "$mcp_rows" | tr '\t' '\036' | while IFS=$'\036' read -r a n ps; do
                [ -n "$a" ] || continue; esc "$a"; ae=$ESC; esc "$ps"; pse=$ESC
                printf '<tr data-res="orange"><td>%s</td><td class="num">%s</td><td><code>%s</code></td></tr>\n' "$ae" "$n" "$pse"
            done
            printf '</table></div>\n'
        else printf '<p class="range">Every account has exactly one communication profile.</p>\n'; fi
        # 6. login vs loginName mismatch
        printf '<h3>Login / login-name mismatch (%s)</h3>\n' "$(dotify "$nlnm")"
        if [ "$nlnm" -gt 0 ]; then
            printf '<div class="tablewrap"><table class="index fit">\n<tr><th>Account</th><th>Communication profile</th><th>login</th><th>loginName</th></tr>\n'
            printf '%s\n' "$lnm_rows" | tr '\t' '\036' | while IFS=$'\036' read -r a p l ln; do
                [ -n "$a" ] || continue; esc "$a"; ae=$ESC; esc "$p"; pe=$ESC; esc "$l"; le=$ESC; esc "$ln"; lne=$ESC
                printf '<tr data-res="orange"><td>%s</td><td><code>%s</code></td><td><code>%s</code></td><td><code>%s</code></td></tr>\n' "$ae" "$pe" "$le" "$lne"
            done
            printf '</table></div>\n'
        else printf '<p class="range">Every <code>login</code> matches its <code>loginName</code>.</p>\n'; fi
        printf '</body>\n</html>\n'
    } > "$out"
}

# (the Cronjobs page — docs/analyses/cronjobs.html, hand-written here until
# 2026-09-05 — is gone: its two tables are .rpt tables on the UC status / UC3
# tab now, bin/analyses/reports/uc3-polling.sh)


# laps (2026-09-27, speed round 10): TIME lines on the build console
_ap0=$(date +%s)
_aplap() { local _t1; _t1=$(date +%s); printf "TIME %5ds  analyses publish: %s\n" "$((_t1 - _ap0))" "$1" >&2; _ap0=$_t1; }
# ---- THE CATCH-UP MODE ------------------------------------------------------
# `bin/analyses/publish.sh catchup` (2026-09-29) is bin/build.sh's "publish
# catch-up: analyses" step. It runs after the report catch-ups (failed.sh,
# failed-files.sh, failing-reasons.sh) and re-renders ONLY the
# analyses outputs that read what those rewrote after the first (full) run of
# this script. Until 2026-09-29 the step re-ran the whole script.
# THE DEPENDENCY TRACE (keep it in step with the readers). What changed since
# the first run: failed.sh's outputs (failed.rpt, failed-sub-all.rpt,
# _failed-reasons.tsv, _errpage-evidence.tsv, _srvsubs.tsv, _srvsubs-map.tsv,
# the errors/ + files/ .rpt sets), failed-files.rpt and failing-reasons.rpt.
# Their readers here:
#   subscriptions.html            failed-files.rpt (the Error reason column —
#                                 write_subscriptions_page)
#   _subs-boxes.tsv (data)        _errpage-evidence.tsv — publish-insights.sh
#                                 sidecar; the transfer catch-up after this step
#                                 reads it (the Entities Error view's Reason)
#   failed.html                   failed.rpt       } render_subs_group_pages,
#   failing-reasons.html          failing-reasons.rpt } those two members only
#   failed-sub-all.html           failed-sub-all.rpt (+ the selector row on it
#                                 and on failed.html, below)
# Everything else here reads report-stage .rpt files, caches and config that no
# step since the first run rewrites — the boxes page itself included (its box
# rows read the report-stage lists; only its sidecar reads the evidence) — and
# no docs/ page but the Entities views, which exist since the transfer publish.
# A NEW analyses-page reader of one of the files above joins this list.
if [ "$AP_MODE" = catchup ]; then
    write_subscriptions_page
    _aplap "catch-up: Configured subscriptions"
    if [ "$AP_SIDECAR" = 1 ]; then
        "$SCRIPT_DIR/publish-insights.sh"   # the box-reason sidecar _subs-boxes.tsv (no page)
        _aplap "catch-up: the box-reason sidecar"
    fi
    # the two members through the ONE group renderer: its member list
    # narrowed for the call (render_report reads it only for its own name)
    _ap_sgr=$SUBS_GROUP_REPORTS
    SUBS_GROUP_REPORTS=" "
    for _ap_spec in $_ap_sgr; do
        case ${_ap_spec#*:} in failed|failing-reasons) SUBS_GROUP_REPORTS="$SUBS_GROUP_REPORTS$_ap_spec " ;; esac
    done
    render_subs_group_pages
    SUBS_GROUP_REPORTS=$_ap_sgr
    _aplap "catch-up: Failed Subscriptions + Error reasons"
    # the view pages below render only when their .rpt exists: clear the
    # first run's copies, as the full mode's rm -f does (never a page with a
    # stale view or a second selector row)
    rm -f "$ADIR"/failed-sub-*.html
else
    render_coverage_pages   # the 5 PDA Configured cell pages (linked from the home)
    _aplap "coverage pages"
    # (the Use cases per-cell pages went 2026-09-29 — the counts link the
    # Subscriptions page; nothing writes docs/use-cases/, use-case-patterns.html,
    # added-bl.html or analyses/index.html any more, and every build starts from
    # an empty docs/, so there is nothing to clean up)
    render_first_seen_pages # docs/first-seen/*.html, before the First seen table links them
    write_use_cases_page
    write_subscriptions_page
    write_logical_detection_page
    write_accounts_page
    write_first_seen_page
    _aplap "use cases, first seen, configuration pages"
    "$SCRIPT_DIR/publish-insights.sh"    # the box-reason sidecar _subs-boxes.tsv (its three insight pages went 2026-09-29)
    _aplap "the box-reason sidecar"
    # The SUBS_GROUP_REPORTS pages (four Configuration-group reports whose DATA is
    # transfer/server but whose PAGES belong here). Rendered from THIS script (not
    # the area publishes, which run earlier — the rm -f above would wipe their
    # output) and AFTER publish-insights.sh, which renders into the same tree.
    render_subs_group_pages
    _aplap "subscription group pages"
fi

# The Failed Subscriptions VIEW page (failed-sub-all.rpt, written by
# bin/transfer/reports/failed.sh beside the default failed.rpt, which
# render_subs_group_pages just rendered): the All view — reached only through
# the selector row below, rendered as the SAME report (the "failed" help slug
# and search/sort persistence key, so a typed search survives a view switch;
# its group row comes from bin/build/publish.sh apply_report_groups).
_fsaved_dates=${CUR_DATES:-}; CUR_DATES=$TRANSFER_DATES
for _frpt in "$DATA"/transfer/reports/failed-*.rpt; do
    [ -f "$_frpt" ] || continue
    _fname=${_frpt##*/}; _fname=${_fname%.rpt}
    # the view variants ONLY (failed-sub-*): the glob also matches
    # failed-files.rpt — the Failed files report, a transfer page of its own
    case $_fname in failed-sub-*) ;; *) continue ;; esac
    RPT_NOPROSE=1 render_rpt "$_frpt" "$ADIR/$_fname.html" "../assets/style.css" "index.html" \
        "TRANSFER - Failed Subscriptions" 1 "failed" "failed"   # a report page: no INTRO / NOTE prose (the help page carries it)
done
CUR_DATES=$_fsaved_dates
_aplap "failed pages"

# (The Error reasons DRILL pages, failing-reasons-<slug>.html, went
# 2026-09-29: a reason row opens the Failed files page searched on it.)

# THE VIEW SELECTOR ROW — Still failing (failed.html, the default, FIRST since
# 2026-09-29) · All (failed-sub-all.html) — injected into both pages BELOW the
# From/To date controls (report.js hoists its controls anchor back over a
# p.tabs.undertabs row, so the row comes out controls -> row -> table).
# (The Selection group — All files / Subscription — went 2026-09-29 with the
# every-File views: the Failed files page is that list.)
_fpage() {   # $1 filter -> page basename
    if [ "$1" = failing ]; then echo "failed.html"; else echo "failed-sub-$1.html"; fi
}
for _ffil in failing all; do
    _ff="$ADIR/$(_fpage "$_ffil")"
    [ -f "$_ff" ] || continue
    _frow='<p class="tabs undertabs">'
    for _fs in "failing:Still failing" "all:All"; do
        _fk=${_fs%%:*}; _flbl=${_fs#*:}
        if [ "$_fk" = "$_ffil" ]; then _frow+="<span class=\"tab active\">$_flbl</span>"
        else _frow+="<a class=\"tab\" href=\"$(_fpage "$_fk")\">$_flbl</a>"; fi
    done
    _frow+='</p>'
    _inject_before_table "$_ff" "$_frow"
done

_aplap "the rest"

if [ "$AP_MODE" = catchup ]; then
    echo "Wrote the analyses catch-up (subscriptions, failed, failed-sub-*, failing-reasons + the box-reason sidecar)." >&2
else
    echo "Wrote docs/analyses (the analysis pages), docs/first-seen and docs/coverage." >&2
fi
