#!/usr/bin/env bash
#
# bin/analyses/publish.sh — render the ANALYSES .rpt files into docs/:
#
#   docs/analyses/first-seen{,-both}.html   the First seen tables
#   docs/analyses/use-cases.html + use-case-{definitions,patterns}.html
#   docs/analyses/accounts.html, cronjobs.html
#   docs/analyses/index.html                the analyses catalog page
#   docs/first-seen/<member>-<key>.html     one page per First seen cell
#   docs/use-cases/<uc>-<member>.html       one page per Use case cell
#
# The Entities coverage page and the whole docs/<env>/coverage/ cell tree were
# REMOVED 2026-07: the home + analyses Status figures had all moved to the
# Transfer > Entities views, leaving the page as the only door into 341 cell
# pages nothing else reached. What the home status tables still need — the
# per-member SEEN count — is produced by bin/analyses/reports/home.sh, which
# replaced the entities/PDA report scripts.
#
# The cell pages of the tables that remain render FIRST: a table links only
# the cell pages that exist, so a zero cell stays plain. Run AFTER the
# per-area publishes and BEFORE bin/build/publish.sh (whose root index card links
# docs/analyses/index.html). Runs from any working directory.
#
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../publish_lib.sh"   # cd's to the repo root; html_head/esc/dotify/first_page/…
source "$SCRIPT_DIR/../uc-cases.sh"      # uc_meta(): the shared UC<n> description (From/To/role/human)

ARPT="$DATA/analyses/reports"
FSRPT="$DATA/first-seen"
FSDIR="$DOCS/first-seen"
ADIR="$DOCS/analyses"
COVRPT="$DATA/coverage"   # the coverage cell .rpts (the 3 PDA Configured cells)
COVDIR="$DOCS/coverage"   # and their pages (restored 2026-07, linked from the home)

ensure_assets   # ALWAYS — see the note in bin/transfer/publish.sh

# The widest dep set of any publish: its own .rpt trees, the transfer reports
# (coverage TSVs, detail slugmaps, the .rpt the insight pages read), the parse
# cache publish-insights.sh reads directly, the config caches, and the RAW
# FlowManager exports its jq passes (certificates, cron) go to.
STAMP="$PUBLISH_STAMP_DIR/analyses.stamp"
if publish_is_fresh "$STAMP" "$ADIR" "${BASH_SOURCE[0]}" \
       "$SCRIPT_DIR/publish-insights.sh" "$SCRIPT_DIR/lib.sh" \
       "$SCRIPT_DIR/../cron2human.awk" "$SCRIPT_DIR/../flip-reason.awk" \
       docs/assets/file-search.js \
       "$ARPT" "$FSRPT" "$COVRPT" "$DATA/transfer/reports" "$DATA/transfer/cache" \
       "$DATA/server/reports" "$DATA/flow-manager" "$FM_CONFIG_DIR"; then
    echo "docs/$SITE_ENV/analyses/ is up to date; skipping." >&2
    exit 0
fi

mkdir -p "$ADIR"
rm -f "$ADIR"/*.html
# ---- First seen cell pages (docs/first-seen/) --------------------------------
# One page per data/first-seen/*.rpt (bin/analyses/reports/first-seen.sh:
# TITLE / MEMBER / KEY + ROW name|dir|seen|link|first_ts[|log]): the items
# counted in one cell of the First seen table. A both- KEY prefix marks the
# "Both Transfer & Server logs" view — its rows carry the log that saw the
# item first as a 6th field, rendered as a Log column. Row tint = the entity
# result from the member's base cache (data-res), like the coverage pages.
# Rebuilt from scratch on every publish.
# ONE cell page. Split out of the loop below so the pool can run several at
# once — the body reads a single .rpt and writes a single page, sharing nothing.
_fs_cell() {   # $1 = the cell .rpt
    local rpt=$1 title member key rows resfile nlabel bothv back ltcol
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
    bothv=0; back="first-seen.html"
    case $key in both-*) bothv=1; back="first-seen-both.html" ;; esac
    # the Not seen pages drop the First/Log columns (always blank there)
    local ltcol=1
    case $key in notseen|both-notseen) ltcol=0 ;; esac
    {
        html_head "$title" "../assets/style.css" "" "HOME" "first-seen"
        esc "$title"; printf '<h1>%s</h1>\n' "$ESC"
        printf '<p class="range"><a href="../analyses/%s">&larr; Back to First seen</a> &mdash; the items counted in this cell of the First seen table.</p>\n' "$back"
        printf '<p class="range">Row colors: <strong>light green</strong> = last transfer OK &middot; <strong>light orange</strong> = configured but never seen &middot; <strong>light red</strong> = last transfer Error (or server-log errors after it) &middot; <strong>light blue</strong> = seen in the server log only (never in the transfer log).</p>\n'
        printf '<div class="tablewrap"><table class="index fit">\n'
        if [ "$ltcol" = 1 ] && [ "$bothv" = 1 ]; then
            printf '<tr><th>%s</th><th>First seen</th><th>Log</th></tr>\n' "$nlabel"
        elif [ "$ltcol" = 1 ]; then
            printf '<tr><th>%s</th><th>First transfer</th></tr>\n' "$nlabel"
        else
            printf '<tr><th>%s</th></tr>\n' "$nlabel"
        fi
        printf '%s\n' "$rows" | awk -F'\t' -v lc="$ltcol" -v both="$bothv" -v resf="$resfile" '
            function e(s) { gsub(/&/, "\\&amp;", s); gsub(/</, "\\&lt;", s); gsub(/>/, "\\&gt;", s); gsub(/"/, "\\&quot;", s); return s }
            BEGIN { if (resf != "") { while ((getline line < resf) > 0) { split(line, a, "\t"); res[toupper(a[1])] = a[3] } close(resf) } }
            NF {
                name = e($1)
                if ($4 != "") name = "<a href=\"../details/" $4 ".html\">" name "</a>"
                trattr = " data-seen=\"" $3 "\""
                rr = res[toupper($1)]
                if (rr == "green" || rr == "orange" || rr == "red" || rr == "blue") trattr = trattr " data-res=\"" rr "\""
                nrows++; if ($3 == 1) nseen++
                tail = (lc == 1) ? "<td>" e($5) "</td>" : ""
                if (lc == 1 && both == 1) tail = tail "<td>" e($6) "</td>"
                printf "<tr%s><td>%s</td>%s</tr>\n", trattr, name, tail
            }
            END {
                tail = (lc == 1) ? "<td>" (nseen+0) " seen</td>" : ""
                if (lc == 1 && both == 1) tail = tail "<td></td>"
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


# ---- the First seen pages (docs/analyses/first-seen{,-both}.html) ------------
# Rendered from data/analyses/reports/first-seen.rpt (Transfer log only) and
# first-seen-both.rpt (Both Transfer & Server logs — first sighting in either
# log): the Seen and Not seen header rows, one row per calendar day in the
# logs, the Total footer — per column, Seen + Not seen = Total and the day
# rows sum to Seen. A two-button tab
# row switches the views. Every nonzero cell links its item list
# (docs/first-seen/, rendered above so the existence checks hold; the both
# view's cell pages carry a both- key prefix).
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
                printf '<p class="range"><a href="../../index.html">&larr; Back to the home status table</a> &mdash; the logical flows counted in this cell of the Logical row (Logical, Partners, Domains, Applications &amp; BL table). A logical flow is a FlowID family condensed to one three-part name (a hyphen marks parts the derivation combined); its members are the configured subscriptions that carry those FlowIDs.</p>\n'
            elif [ "$member" = partners ]; then
                printf '<p class="range"><a href="../../index.html">&larr; Back to the home status table</a> &mdash; the partners counted in this cell of the Partners row (Logical, Partners, Domains, Applications &amp; BL table). A partner is the last part of the logical flow names (domain_application_partner), merged into one organisation by shared endpoints, shared whitelist IPs, whitelisted host addresses and curated aliases; its configured endpoint(s) and member accounts are listed.</p>\n'
            elif [ "$member" = applications ]; then
                printf '<p class="range"><a href="../../index.html">&larr; Back to the home status table</a> &mdash; the applications counted in this cell of the Applications row (Logical, Partners, Domains, Applications &amp; BL table). An application is the middle part of the three-part logical flow name (domain_application_partner), so this list is derived from the logical flows; an application active in both directions counts once per side.</p>\n'
            elif [ "$member" = domains ]; then
                printf '<p class="range"><a href="../../index.html">&larr; Back to the home status table</a> &mdash; the business domains counted in this cell of the Domains row (Logical, Partners, Domains, Applications &amp; BL table). The domain is the first part of the three-part logical flow name (domain_application_partner), so this list is derived from the logical flows; a domain active in both directions counts once per side.</p>\n'
            elif [ "$member" = bl ]; then
                printf '<p class="range"><a href="../../index.html">&larr; Back to the home status table</a> &mdash; the BL tags counted in this cell of the BL row (Logical, Partners, Domains, Applications &amp; BL table). A BL is a subscriptions.json tags entry starting with BL, kept verbatim; its members are the configured subscriptions that carry the tag, and a tag active in both directions counts once per side.</p>\n'
            else
                printf '<p class="range"><a href="../../index.html">&larr; Back to the home status table</a> &mdash; the items counted in this cell of the Entities table.</p>\n'
            fi
            printf '<p class="range">Row colors: <strong>light green</strong> = last transfer OK &middot; <strong>light orange</strong> = configured but never seen &middot; <strong>light red</strong> = last transfer Error (or server-log errors after it) &middot; <strong>light blue</strong> = surfaced only by the Server &rarr; Transfer step (bin/seen-in-server-log.sh) with no real transfer.</p>\n'
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
                -v fdf="$DATA/flow-manager/xref/_subscriptions-flowdir.tsv" -v msub="$msubf" '
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
                                if (su ~ /^UC[1-4][_-]/) ucn[ku SUBSEP substr(su,3,1)]++ }
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
                    trattr = " data-seen=\"" $3 "\""
                    rr = res[toupper($1)]
                    # base result carries the tint directly, blue included
                    if (rr == "green" || rr == "orange" || rr == "red" || rr == "blue") trattr = trattr " data-res=\"" rr "\""
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

write_first_seen_page() {   # $1 view: 1 = transfer-only (default), 2 = both logs
    local view=${1:-1} base kp note
    if [ "$view" = 2 ]; then
        base="first-seen-both"; kp="both-"
        note='Seen means seen in the <strong>transfer</strong> logs or flagged <strong>blue</strong> (server-log only): a blue name never transferred, so it shows the <strong>oldest first transfer of its cross-referenced entities</strong> (its account, subscription, login, host, logical flow or partner from the FlowManager config) — the day its surrounding flow first became active. The cell pages tag those rows <strong>Server</strong>. Each count links the list of items behind it.'
    else
        base="first-seen"; kp=""
        note='Seen means seen in the <strong>transfer</strong> logs: an entity that only ever appears in the server log counts as Not seen here (its rows are tinted light blue on the cell pages). Each count links the list of items behind it.'
    fi
    local rpt="$ARPT/$base.rpt"
    [ -f "$rpt" ] || { rm -f "$ADIR/$base.html"; return 0; }
    local out="$ADIR/$base.html"
    # one numeric cell: blank when 0, linked when its cell page exists
    fscell() {   # $1 value  $2 member  $3 key
        if [ -z "$1" ] || [ "$1" = 0 ]; then printf '<td class="num"></td>'; return; fi
        esc "$(dotify "$1")"
        if [ -f "$FSDIR/$2-$3.html" ]; then
            printf '<td class="num"><a href="../first-seen/%s-%s.html">%s</a></td>' "$2" "$3" "$ESC"
        else
            printf '<td class="num">%s</td>' "$ESC"
        fi
    }
    local members=(logicals partners subscriptions accounts logins hosts)
    {
        html_head "First seen" "../assets/style.css" "" "ANALYSES" "first-seen"
        printf '<h1>First seen</h1>\n'
        analyses_group_tabs first-seen.html
        printf '<p class="subtitle">%s</p>\n' "$(field1 DESC "$rpt" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')"
        # the view switch: two buttons, the current one active
        if [ "$view" = 2 ]; then
            printf '<p class="tabs"><a class="tab" href="first-seen.html">Transfer log only</a><span class="tab active">Both Transfer &amp; Server logs</span></p>\n'
        else
            printf '<p class="tabs"><span class="tab active">Transfer log only</span><a class="tab" href="first-seen-both.html">Both Transfer &amp; Server logs</a></p>\n'
        fi
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
                    # seen names with no dated transfer of their own (UC3
                    # clean-poll greens, sibling-credited names, undated
                    # blues): they count into Seen, so the day rows + this
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
        printf '<p class="range">%s</p>\n' "$note"
        printf '</body>\n</html>\n'
    } > "$out"
}


# ---- the Use cases page (docs/analyses/use-cases.html) ----------------------
# The configured subscriptions grouped by their UC<n> prefix (UC1_/UC3_/UC4-/…).
# The UC number IS the flow direction: UC1 we push to the partner, UC3 we pull
# from it (both OUTBOUND — ST connects to the partner's server); UC4 the partner
# pushes to us, UC2 it pulls from us (both INBOUND — the partner connects to ST).
# Confirmed against the comm-profile type / participant role / context.direction,
# which agree 100%. Columns: Flow (the meaning), Total configured, Server
# (surfaced only by the fake Server->Transfer step), Not seen (orange), Error
# (red), OK (green) — a fake counts under Server only, so Total = Server + Not
# seen + Error + OK. The Flow cell also carries the consistency check: any
# subscription whose CONFIGURED direction (base cache col 2) disagrees with its
# UC prefix (UC1/UC3/UC5/UC8 = out, UC2/UC4 = in) is flagged. No date, no search.
_uccell() {   # $1 value  $2 class  [$3 detail href, page-relative] — 0 renders blank; links when the page exists
    if [ "${1:-0}" = 0 ]; then printf '<td class="%s"></td>' "$2"; return 0; fi
    if [ -n "${3:-}" ] && [ -f "$DOCS/${3#../}" ]; then
        printf '<td class="%s"><a href="%s">%s</a></td>' "$2" "$3" "$(dotify "$1")"
    else
        printf '<td class="%s">%s</td>' "$2" "$(dotify "$1")"
    fi
}
_uclink() {   # $1 text  $2 href — a text cell linked to its detail page (plain
    # text when the page does not exist — a UC with no subscriptions has no
    # cell pages — and an empty <td> when the text is empty)
    esc "$1"
    if [ -n "$1" ] && [ -n "${2:-}" ] && [ -f "$DOCS/${2#../}" ]; then
        printf '<td><a href="%s">%s</a></td>' "$2" "$ESC"
    else
        printf '<td>%s</td>' "$ESC"
    fi
}
# (The UC<n> descriptions moved to bin/uc-cases.sh's uc_meta — shared with the
# Subscription detail-page Summary — so the two never disagree.)
# One detail page per nonzero Use cases cell (docs/use-cases/<uc>-<metric>.html):
# the subscriptions counted in that cell, each linked to its subscription
# detail page — the same idea as the coverage cell pages, but scoped to the
# UC prefix x status buckets (metric = total/server/notseen/error/ok). Rebuilt
# from scratch on every publish; a 0 cell gets no page (and no link).
render_use_case_pages() {
    local subs="$DATA/flow-manager/base/_subscriptions.tsv"
    [ -f "$subs" ] || return 0
    local smap="$DATA/transfer/reports/details/subscriptions/_slugmap.tsv"; [ -f "$smap" ] || smap=/dev/null
    local ucdir="$DOCS/use-cases"
    rm -rf "$ucdir"; mkdir -p "$ucdir"
    local ucs; ucs=$(awk -F'\t' '$1!=""{u="none"; if(match($1,/^UC[0-9]+/)) u=substr($1,RSTART,RLENGTH); print u}' "$subs" | LC_ALL=C sort -u)
    local npages=0 uc ucslug metric mlabel rows n title
    for uc in $ucs; do
        ucslug=$(printf '%s' "$uc" | tr '[:upper:]' '[:lower:]')
        for metric in total seen transfer server notseen error ok; do
            case $metric in
                total)    mlabel="Total configured" ;;
                seen)     mlabel="Seen (in the transfer or server logs)" ;;
                transfer) mlabel="Transfer (seen in the transfer logs)" ;;
                server)   mlabel="Server (server-log only)" ;;
                notseen)  mlabel="Not seen (configured, never seen)" ;;
                error)    mlabel="Error (last transfer)" ;;
                ok)       mlabel="OK (last transfer)" ;;
            esac
            rows=$(awk -F'\t' -v sm="$smap" -v UC="$uc" -v M="$metric" \
                       -v fdf="$DATA/flow-manager/xref/_subscriptions-flowdir.tsv" '
                function e(s){ gsub(/&/,"\\&amp;",s); gsub(/</,"\\&lt;",s); gsub(/>/,"\\&gt;",s); gsub(/"/,"\\&quot;",s); return s }
                BEGIN {
                    while ((getline l < sm) > 0) { k=split(l,a,"\t"); if (k>=2) slug[a[1]]=a[2] }
                    # a row here IS a subscription, so its FILE MOVEMENT is its
                    # own flowdir — no union needed (Direction = out/in)
                    while ((getline l < fdf) > 0) { k=split(l,a,"\t"); if (k>=2) fmv[a[1]]=a[2] }
                }
                $1 != "" {
                    name=$1; dir=$2; res=$3
                    u="none"; if (match(name,/^UC[0-9]+/)) u=substr(name,RSTART,RLENGTH)
                    if (u != UC) next
                    isfake=(res=="blue")   # server-log-only: base result==blue (bin/build/seen-in-server-log.sh)
                    keep=0
                    if (M=="total") keep=1
                    else if (M=="seen"     && (isfake || res=="green" || res=="red")) keep=1
                    else if (M=="transfer" && (res=="green" || res=="red")) keep=1
                    else if (M=="server"  && isfake) keep=1
                    else if (M=="notseen" && !isfake && res=="orange") keep=1
                    else if (M=="error"   && !isfake && res=="red")    keep=1
                    else if (M=="ok"      && !isfake && res=="green")  keep=1
                    if (!keep) next
                    col    = isfake ? "blue" : (res=="green"?"green":(res=="orange"?"orange":(res=="red"?"red":"")))
                    status = isfake ? "Server" : (res=="green"?"OK":(res=="orange"?"Not seen":(res=="red"?"Error":"\xe2\x80\x94")))
                    # Direction = the CONNECTION/MOVEMENT pair (out/in), lowercase
                    # — the dirfold in render_rpt.awk does that for every .rpt report;
                    # this table is hand-written, so it does it here.
                    c = (dir=="out"||dir=="in"||dir=="both") ? dir : "?"
                    m = (name in fmv && fmv[name]!="") ? fmv[name] : "?"
                    d = (c=="?" && m=="?") ? "" : (c "/" m)
                    nm = e(name)
                    if (name in slug) nm = "<a href=\"../details/subscriptions/" slug[name] ".html\">" nm "</a>"
                    tr = (col!="") ? "<tr data-res=\"" col "\">" : "<tr>"
                    printf "%s<td>%s</td><td>%s</td><td>%s</td></tr>\n", tr, nm, d, status
                }
            ' "$subs")
            [ -n "$rows" ] || continue
            n=$(printf '%s\n' "$rows" | grep -c .)
            title="$uc — $mlabel"
            {
                html_head "$title" "../assets/style.css" "" "HOME" "use-cases"
                esc "$title"; printf '<h1>%s</h1>\n' "$ESC"
                printf '<p class="range"><a href="../analyses/use-cases.html">&larr; Back to Use Case traffic</a> &mdash; the subscriptions counted in this cell of the Use Case traffic table.</p>\n'
                printf '<p class="range">Row colors: <strong>light green</strong> = last transfer OK &middot; <strong>light orange</strong> = configured but never seen &middot; <strong>light red</strong> = last transfer Error (or server-log errors after it) &middot; <strong>light blue</strong> = surfaced only by the Server &rarr; Transfer step.</p>\n'
                printf '<div class="tablewrap"><table class="index fit">\n'
                printf '<tr><th>Subscription</th><th>Direction</th><th>Status</th></tr>\n'
                printf '%s\n' "$rows"
                printf '<tr class="total"><td>Total (%d)</td><td></td><td></td></tr>\n' "$n"
                printf '</table></div>\n</body>\n</html>\n'
            } > "$ucdir/$ucslug-$metric.html"
            npages=$((npages + 1))
        done
    done
    echo "Wrote $npages use-case cell page(s) to docs/use-cases/." >&2
}

# The Use-cases GROUP (use-cases / use-case-definitions / use-case-patterns /
# the UC status report): one tab row shared by the pages, the current one
# active. UC status moved here from the Boxes group 2026-08 — its four tabbed
# pages get this row injected after render_subs_group_pages.
_ucgroup_tabs() {   # $1 = active page key: counts | defs | patterns | status
    printf '<p class="tabs">'
    local ent key rest lbl file
    for ent in 'counts|Use Case traffic|use-cases.html' 'defs|Use Case definitions|use-case-definitions.html' 'patterns|Use Case patterns|use-case-patterns.html' 'status|Use Case Status|uc-status-uc1.html'; do
        key=${ent%%|*}; rest=${ent#*|}; lbl=${rest%%|*}; file=${rest#*|}
        if [ "$key" = "$1" ]; then printf '<span class="tab active">%s</span>' "$lbl"
        else printf '<a class="tab" href="%s">%s</a>' "$file" "$lbl"; fi
    done
    printf '</p>\n'
}

# The DOUBLE Direction of a use case, the site-wide XXX/YYY convention the
# detail-page titles use: CONNECTION side / FILE-MOVEMENT side. Both come from
# uc_meta, so this page can never disagree with the definitions tab:
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

# ---- the Use cases page (docs/analyses/use-cases.html) — the OPERATIONAL view:
# per UC prefix the status counts (Total / Server / Not seen / Error / OK) plus
# each UC's one-line Description for context. The definition columns (Trigger,
# We are, We) and the direction-vs-prefix consistency check live on
# the Use Case definitions tab (write_use_case_definitions_page).
write_use_cases_page() {
    local out="$ADIR/use-cases.html" subs="$DATA/flow-manager/base/_subscriptions.tsv"
    [ -f "$subs" ] || { rm -f "$out"; return 0; }
    local rows
    rows=$(awk -F'\t' '
        $1 != "" {
            name = $1; res = $3
            uc = "(none)"; if (match(name, /^UC[0-9]+/)) uc = substr(name, RSTART, RLENGTH)
            tot[uc]++; seen[uc] = 1
            if (res == "blue")           srv[uc]++
            else if (res == "green")     ok[uc]++
            else if (res == "orange")    ns[uc]++
            else if (res == "red")       err[uc]++
        }
        END { for (u in seen) print u "\t" tot[u] "\t" (srv[u]+0) "\t" (ns[u]+0) "\t" (err[u]+0) "\t" (ok[u]+0) }
    ' "$subs" | LC_ALL=C sort -V)
    # UNION with the template catalog: a UC whose template is published but has
    # no subscriptions yet (today UC6/UC7) still gets a row — all-zero counts.
    local tmpl="$DATA/flow-manager/xref/_templates.tsv"
    if [ -s "$tmpl" ]; then
        rows=$({ printf '%s\n' "$rows"
                 awk -F'\t' -v have="$(printf '%s\n' "$rows" | cut -f1 | tr '\n' ' ')" '
                     BEGIN { n = split(have, H, " "); for (i = 1; i <= n; i++) seen[H[i]] = 1 }
                     $2 != "" && !($2 in seen) && !dup[$2]++ { print $2 "\t0\t0\t0\t0\t0" }
                 ' "$tmpl"; } | LC_ALL=C sort -V)
    fi
    {
        html_head "Use Case traffic" "../assets/style.css" "" "" "use-cases" "" "" "sort-fresh"
        printf '<h1>Use Case traffic</h1>\n'
        analyses_group_tabs use-cases.html
        printf '<p class="subtitle">The configured subscriptions grouped by their UC&lt;n&gt; prefix &mdash; the status columns of the Flow manager Entities table. <strong>Direction</strong> is the pair the detail-page titles use, <em>connection side</em>/<em>file movement</em>: who dials whom, then which way the file travels &mdash; so <strong>out/in</strong> means we connect out to the partner and the file comes towards us. <strong>Seen</strong> = Transfer + Server; <strong>Transfer</strong> = seen in the transfer logs (its subscriptions end the period <strong>Error</strong> or <strong>Ok</strong> by their last transfer); <strong>Server</strong> = surfaced only by the Server&rarr;Transfer step; <strong>Warning</strong> = configured but never seen &mdash; Total = Server + Error + Warning + Ok. Every nonzero count links the list of subscriptions it counts. Every use case with a <strong>published FlowManager template</strong> is listed &mdash; one with no subscriptions yet shows blank counts. What each UC means &mdash; who connects, which way the file travels, what triggers it &mdash; is on the <strong>Use Case definitions</strong> tab.</p>\n'
        _ucgroup_tabs counts
        printf '<div class="tablewrap"><table class="index fit" data-nosearch="1">\n'
        printf '<tr><th>Use Case</th><th>Direction</th><th class="num">Total</th><th class="num">Seen</th><th class="num">Transfer</th><th class="num">Server</th><th class="num">Error</th><th class="num">Warning</th><th class="num">Ok</th><th>Description</th></tr>\n'
        local uc t sv ns er okc sn trn Tt=0 Tsv=0 Tns=0 Ter=0 Tok=0 Tsn=0 Ttr=0
        while IFS=$'\t' read -r uc t sv ns er okc; do
            [ -n "$uc" ] || continue
            local ucfrom ucto weare we human exp trigger
            # read on \036 (RS, not IFS whitespace) so an EMPTY middle field keeps
            # its place — UC8's `exp` is empty, and a plain IFS=$'\t' read would
            # collapse it, shifting the trigger (OpsWise) into `exp` and blanking it.
            IFS=$'\036' read -r ucfrom ucto weare we human exp trigger <<< "$(uc_meta "$uc" | tr '\t' '\036')"
            trn=$((er + okc)); sn=$((trn + sv))   # Transfer = Error + Ok; Seen = Transfer + Server
            local ucslug; ucslug=$(printf '%s' "$uc" | tr '[:upper:]' '[:lower:]' | tr -d '()')
            # every count links its own docs/use-cases/ detail page; the column
            # set, order and tints mirror the analyses Entities status table
            # (Warning = the not-seen subscriptions, so it links the same list)
            printf '<tr>'
            _uclink "$uc"      "../use-cases/$ucslug-total.html"
            printf '<td>%s</td>' "$(_uc_direction "$weare" "$we")"
            _uccell "$t"   "num"          "../use-cases/$ucslug-total.html"
            _uccell "$sn"  "num"          "../use-cases/$ucslug-seen.html"
            _uccell "$trn" "num"          "../use-cases/$ucslug-transfer.html"
            _uccell "$sv"  "num res-blue" "../use-cases/$ucslug-server.html"
            _uccell "$er"  "num st-err"   "../use-cases/$ucslug-error.html"
            _uccell "$ns"  "num st-warn"  "../use-cases/$ucslug-notseen.html"
            _uccell "$okc" "num st-ok"    "../use-cases/$ucslug-ok.html"
            esc "$human"; printf '<td>%s</td>' "$ESC"
            printf '</tr>\n'
            Tt=$((Tt+t)); Tsv=$((Tsv+sv)); Tns=$((Tns+ns)); Ter=$((Ter+er)); Tok=$((Tok+okc)); Tsn=$((Tsn+sn)); Ttr=$((Ttr+trn))
        done <<< "$rows"
        printf '<tr class="total"><td>Total</td><td></td><td class="num">%s</td><td class="num">%s</td><td class="num">%s</td><td class="num">%s</td><td class="num">%s</td><td class="num">%s</td><td class="num">%s</td><td></td></tr>\n' \
            "$(dotify "$Tt")" "$(dotify "$Tsn")" "$(dotify "$Ttr")" "$(dotify "$Tsv")" "$(dotify "$Ter")" "$(dotify "$Tns")" "$(dotify "$Tok")"
        printf '</table></div>\n'
        printf '</body>\n</html>\n'
    } > "$out"
}

# ---- the Use Case definitions page (docs/analyses/use-case-definitions.html):
# what each UC prefix MEANS — Trigger, We are, We and the Description,
# straight from bin/uc-cases.sh's uc_meta (shared with the Subscription detail
# pages, so the two never disagree) — one row per UC present in the config,
# plus the direction-vs-prefix consistency check (a definitional property, so
# it lives here, not on the counts tab).
write_use_case_definitions_page() {
    local out="$ADIR/use-case-definitions.html" subs="$DATA/flow-manager/base/_subscriptions.tsv"
    [ -f "$subs" ] || { rm -f "$out"; return 0; }
    local rows
    rows=$(awk -F'\t' '
        $1 != "" {
            uc = "(none)"; if (match($1, /^UC[0-9]+/)) uc = substr($1, RSTART, RLENGTH)
            seen[uc] = 1
            if ($2 == "out") dout[uc]++; else if ($2 == "in") din[uc]++; else doth[uc]++
        }
        END { for (u in seen) print u "\t" (dout[u]+0) "\t" (din[u]+0) "\t" (doth[u]+0) }
    ' "$subs" | LC_ALL=C sort -V)
    # UNION with the template catalog — every UC with a published template gets
    # a definition row, subscriptions or not (see write_use_cases_page).
    local tmpl="$DATA/flow-manager/xref/_templates.tsv"
    if [ -s "$tmpl" ]; then
        rows=$({ printf '%s\n' "$rows"
                 awk -F'\t' -v have="$(printf '%s\n' "$rows" | cut -f1 | tr '\n' ' ')" '
                     BEGIN { n = split(have, H, " "); for (i = 1; i <= n; i++) seen[H[i]] = 1 }
                     $2 != "" && !($2 in seen) && !dup[$2]++ { print $2 "\t0\t0\t0" }
                 ' "$tmpl"; } | LC_ALL=C sort -V)
    fi
    {
        html_head "Use Case definitions" "../assets/style.css" "" "" "use-cases"
        printf '<h1>Use Case definitions</h1>\n'
        analyses_group_tabs use-cases.html
        printf '<p class="subtitle">What each UC&lt;n&gt; prefix means. <strong>UC1&ndash;UC4</strong> bridge one partner to our internal application; <strong>UC5&ndash;UC8</strong> are direct relays with no CFT leg, one per source/target push-pull combination &mdash; each links <strong>two partners</strong>, which is why a relay account is named <code>domain_partner_partner</code> rather than the <code>domain_application_partner</code> of UC1&ndash;UC4; UC6 and UC7 have a <strong>published template but no subscriptions yet</strong> (their rows are template-derived). <strong>Trigger</strong> is what starts the flow: <em>OpsWise</em> = our OpsWise automation initiates (UC1, UC8), <em>Partner</em> = the partner connects in (UC2, UC4, UC7), <em>Cronjob</em> = a Quartz receive scheduler polls the partner (UC3, and the pull side of UC5/UC6). The operational counts per use case are on the <strong>Use Case traffic</strong> tab; the flow templates behind them are in the <strong>Templates</strong> table below.</p>\n'
        _ucgroup_tabs defs
        printf '<div class="tablewrap"><table class="index fit" data-nosearch="1">\n'
        printf '<tr><th>Use Case</th><th>Trigger</th><th>We are</th><th>We</th><th>Description</th></tr>\n'
        local uc dout din doth n=0 Tmm=0
        while IFS=$'\t' read -r uc dout din doth; do
            [ -n "$uc" ] || continue
            local ucfrom ucto weare we human exp trigger mm=0
            # \036 read — see write_use_cases_page (UC8 has an empty exp field)
            IFS=$'\036' read -r ucfrom ucto weare we human exp trigger <<< "$(uc_meta "$uc" | tr '\t' '\036')"
            case $exp in out) mm=$((din + doth)) ;; in) mm=$((dout + doth)) ;; esac
            Tmm=$((Tmm + mm))
            local ucslug; ucslug=$(printf '%s' "$uc" | tr '[:upper:]' '[:lower:]' | tr -d '()')
            # every cell points at the UC's subscription list (the Total page)
            printf '<tr>'
            _uclink "$uc"      "../use-cases/$ucslug-total.html"
            _uclink "$trigger" "../use-cases/$ucslug-total.html"
            _uclink "$weare"   "../use-cases/$ucslug-total.html"
            _uclink "$we"      "../use-cases/$ucslug-total.html"
            esc "$human"; printf '<td>%s</td>' "$ESC"
            printf '</tr>\n'
            n=$((n + 1))
        done <<< "$rows"
        printf '<tr class="total"><td>Total (%d use cases)</td><td></td><td></td><td></td><td></td></tr>\n' "$n"
        printf '</table></div>\n'
        if [ "$Tmm" -gt 0 ]; then
            printf '<p class="range"><strong>&#9888; %d subscription(s)</strong> are configured with a direction that disagrees with their UC prefix &mdash; a naming or configuration error.</p>\n' "$Tmm"
        else
            printf '<p class="range">Consistency check: every configured subscription&rsquo;s direction matches its UC prefix (UC1/UC3/UC5 outbound, UC2/UC4/UC7 inbound; the mixed relays UC6/UC8 are exempt) &mdash; <strong>no exceptions</strong>.</p>\n'
        fi
        # ---- the Templates table: the FlowManager flow templates behind the UCs
        # (xref/_templates.tsv). Route = the template's flowPatternName — the
        # transport chain a subscription instantiates; Subscriptions = the
        # configured subscriptions created from the template, joined on
        # patternName (_subscriptions-patterns.tsv col 2). UC1/UC3 have TWO
        # variants each (relayed through ST vs handled by the CFT hub directly),
        # so their template counts split what the counts tab shows as one UC.
        if [ -s "$tmpl" ]; then
            local pmap="$DATA/flow-manager/xref/_subscriptions-patterns.tsv"; [ -f "$pmap" ] || pmap=/dev/null
            # the UC cell links its subscription-list page only when it exists
            local havepages; havepages=$(cd "$DOCS/use-cases" 2>/dev/null && ls ./*-total.html 2>/dev/null | tr '\n' ' ' || true)
            printf '<h2>Templates</h2>\n'
            printf '<p class="range">The published FlowManager flow templates named <code>UC*</code> &mdash; what a new subscription is created from. <strong>Route</strong> is the template&rsquo;s flow pattern: the transport chain, source leg &rarr; SecureTransport/CFT &rarr; target leg. <strong>Subscriptions</strong> counts the configured subscriptions built from the template (matched on the subscription&rsquo;s pattern). <strong>UC1</strong> and <strong>UC3</strong> exist in two variants &mdash; relayed through SecureTransport (<code>ST</code>) or handled by the internal CFT hub directly (<code>CFT</code>) &mdash; so their template counts split what the Use Case traffic tab shows as one row. The &#128279; icon opens the template in FlowManager.</p>\n'
            printf '<div class="tablewrap"><table class="index fit" data-nosearch="1">\n'
            printf '<tr><th>Template</th><th>Use Case</th><th>Route</th><th class="num">Subscriptions</th><th>Status</th><th>Last modified</th></tr>\n'
            LC_ALL=C sort -t"$(printf '\t')" -k2,2 -k1,1 "$tmpl" | awk -F'\t' -v have="$havepages" '
                function e(s) { gsub(/&/,"\\&amp;",s); gsub(/</,"\\&lt;",s); gsub(/>/,"\\&gt;",s); gsub(/"/,"\\&quot;",s); return s }
                NR == FNR { if ($2 != "") cnt[$2]++; next }
                $2 != "" {
                    n = cnt[$4] + 0; tot += n; nt++
                    ucslug = tolower($2); ucc = e($2)
                    if (index(have, "./" ucslug "-total.html ") > 0)
                        ucc = "<a href=\"../use-cases/" ucslug "-total.html\">" ucc "</a>"
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

# ---- the Use Case patterns page (docs/analyses/use-case-patterns.html) ------
# The ACCOUNTS grouped by their subscription MIX: per account, count its
# configured subscriptions per UC prefix and write the multiset as a pattern
# string — account SI-VPS-VDN with subscriptions UC2_SI-VPS-VDN_SI-VPS-VDN and
# UC4_SI-VPS-VDN_SI-VPS-VDN patterns as "UC2 (1) UC4 (1)". One table row per
# distinct pattern (most accounts first), the sharing accounts listed one per
# line in a COLLAPSED <details> cell — collapsed it shows one "nn accounts"
# summary line (the partner coverage pages' member-cell mechanism, native
# disclosure, no JS), each account linked to its detail page via the accounts
# slugmap, the td carrying data-sortval so the column sorts by count. Reads
# the data/flow-manager/xref account->subscription pair cache; a subscription
# without a UC prefix counts under a "(none)" token, an account without any
# subscription has no pattern and is not listed. No dates, no drills.
write_use_case_patterns_page() {
    local out="$ADIR/use-case-patterns.html" xref="$DATA/flow-manager/xref/_accounts-subscriptions.tsv"
    [ -s "$xref" ] || { rm -f "$out"; return 0; }
    local agg
    agg=$(LC_ALL=C sort -t"$(printf '\t')" -k1,1 -k2,2 "$xref" | awk -F'\t' '
        # per account: c[n] = its subscriptions with prefix UC<n> (c[0] = no UC prefix)
        function flush(   i, pat) {
            if (acct == "") return
            pat = ""
            for (i = 1; i <= maxu; i++) if (i in c) pat = pat (pat == "" ? "" : " ") "UC" i " (" c[i] ")"
            if (0 in c) pat = pat (pat == "" ? "" : " ") "(none) (" c[0] ")"
            n[pat]++
            # NOTE mawk mis-parses the one-line ternary-in-concat form here
            # (a leading \037 appeared); the explicit if/else is unambiguous.
            if (pat in m) m[pat] = m[pat] "\037" acct         # input is account-sorted, so members stay A-Z
            else          m[pat] = acct
            split("", c); maxu = 0
        }
        $1 != "" && $2 != "" {
            if ($1 != acct) { flush(); acct = $1 }
            u = 0
            if (match($2, /^UC[0-9]+/)) u = substr($2, 3, RLENGTH - 2) + 0
            c[u]++; if (u > maxu) maxu = u
        }
        END { flush(); for (p in n) printf "%d\t%s\t%s\n", n[p], p, m[p] }   # hash order; sorted below
    ' | LC_ALL=C sort -t"$(printf '\t')" -k1,1nr -k2,2)
    [ -n "$agg" ] || { rm -f "$out"; return 0; }
    {
        html_head "Use Case patterns" "../assets/style.css" "" "" "use-case-patterns"
        printf '<h1>Use Case patterns</h1>\n'
        analyses_group_tabs use-cases.html
        printf '<p class="subtitle">Every account grouped by its <strong>Use Case pattern</strong> &mdash; the mix of its configured subscriptions per UC prefix: an account with one UC2 and one UC4 subscription has the pattern <code>UC2 (1) UC4 (1)</code>. One row per distinct pattern, most accounts first; <strong>Accounts</strong> shows how many accounts share it &mdash; <strong>click the count</strong> to expand the alphabetical list, each account linked to its detail page.</p>\n'
        _ucgroup_tabs patterns
        printf '<div class="tablewrap"><table class="index fit">\n'
        printf '<tr><th>Pattern</th><th>Accounts</th></tr>\n'
        local smap="$DATA/transfer/reports/details/accounts/_slugmap.tsv"; [ -f "$smap" ] || smap=/dev/null
        printf '%s\n' "$agg" | awk -F'\t' -v sm="$smap" '
            function e(s) { gsub(/&/,"\\&amp;",s); gsub(/</,"\\&lt;",s); gsub(/>/,"\\&gt;",s); gsub(/"/,"\\&quot;",s); return s }
            # accounts slugmap, keys UPPERCASED (config vs logged spellings differ only in case)
            BEGIN { while ((getline l < sm) > 0) { t = index(l, "\t"); if (t > 1) slug[toupper(substr(l, 1, t - 1))] = substr(l, t + 1) } close(sm) }
            {
                nm = split($3, A, "\037")
                cell = ""
                for (i = 1; i <= nm; i++) {
                    v = e(A[i])
                    if (toupper(A[i]) in slug) v = "<a href=\"../details/accounts/" slug[toupper(A[i])] ".html\">" v "</a>"
                    cell = cell (i > 1 ? "<br>" : "") v
                }
                printf "<tr><td>%s</td><td class=\"wrap\" data-sortval=\"%d\"><details><summary>%d account%s</summary>%s</details></td></tr>\n", \
                       e($2), nm, nm, (nm == 1 ? "" : "s"), cell
                tot += $1
            }
            END { printf "<tr class=\"total\"><td>Total (%d patterns)</td><td>%d accounts</td></tr>\n", NR, tot }
        '
        printf '</table></div>\n'
        printf '<p class="note">Patterns count <strong>configured</strong> subscriptions (the FlowManager export), whether seen in the logs or not; an account without any subscription is not listed.</p>\n'
        # template-only UCs (published template, zero subscriptions): they can
        # appear in no account pattern, so say so rather than leave a silent gap
        local tmpl="$DATA/flow-manager/xref/_templates.tsv" subsbase="$DATA/flow-manager/base/_subscriptions.tsv"
        if [ -s "$tmpl" ] && [ -f "$subsbase" ]; then
            local unused
            unused=$(awk -F'\t' '
                NR == FNR { if (match($1, /^UC[0-9]+/)) seen[substr($1, RSTART, RLENGTH)] = 1; next }
                $2 != "" && !($2 in seen) && !dup[$2]++ { out = out (out == "" ? "" : ", ") $2 }
                END { print out }
            ' "$subsbase" "$tmpl")
            [ -n "$unused" ] && printf '<p class="note">FlowManager also publishes flow templates for <strong>%s</strong> &mdash; no subscription (and so no account pattern) uses them yet; see the <a href="use-case-definitions.html">Use Case definitions</a> tab.</p>\n' "$unused"
        fi
        printf '</body>\n</html>\n'
    } > "$out"
}

# ---- the Subscriptions page (docs/analyses/subscriptions.html) --------------
# The per-subscription configuration mapping (2026-08-30, user request): EVERY
# configured subscription on one row with its FlowID (customAttribute_
# FlowIdentifier), use case (the UC<n> name prefix, else the flow-manager
# DERIVED one), account, endpoint (the login the partner connects in with, or
# the remote host we dial out to), BL tag (the subscriptions.json tags[] entry
# starting with "BL" — the _subscriptions-bl xref cache, since 2026-08-31 a
# full entity whose cell links its detail page) and the derived Logical / Partner / Domain /
# Application groups — the config caches joined onto one row each. Every name
# links its detail page; rows tint by the subscription result. The roster is
# the pristine configured snapshot (base/.configured.tsv — the base cache
# gains discovered names after the build's append steps), falling back to the
# base cache minus the parse-synthetic UCx_ names on a pre-snapshot tree.
write_subscriptions_page() {
    local out="$ADIR/subscriptions.html" S="$FM_CONFIG_DIR/subscriptions.json"
    local B="$DATA/flow-manager/base" X="$DATA/flow-manager/xref" DET="$DATA/transfer/reports/details"
    [ -f "$B/_subscriptions.tsv" ] || { rm -f "$out"; return 0; }
    local conf="$B/.configured.tsv"; [ -f "$conf" ] || conf=""
    local args=() f d
    for f in _subscriptions-profiles _subscriptions-ucderived _subscriptions-accounts \
             _subscriptions-logins _subscriptions-hosts _subscriptions-logicals \
             _subscriptions-partners _subscriptions-domains _subscriptions-apps \
             _subscriptions-bl; do
        [ -f "$X/$f.tsv" ] && args+=("$X/$f.tsv")
    done
    for d in subscriptions accounts logins hosts logicals partners domains applications bl; do
        [ -f "$DET/$d/_slugmap.tsv" ] && args+=("$DET/$d/_slugmap.tsv")
    done
    local rows
    rows=$(LC_ALL=C awk -F'\t' -v CONF="$conf" '
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
        BEGIN { US = sprintf("%c", 31)
            if (CONF != "") { while ((getline l < CONF) > 0) { n = split(l, a, "\t")
                    if (n >= 2 && a[1] == "_subscriptions" && a[2] != "" && !(toupper(a[2]) in seenr)) { seenr[toupper(a[2])] = 1; RN[++nr] = a[2] } }
                close(CONF) }
        }
        FILENAME ~ /base\/_subscriptions\.tsv$/ { RES[toupper($1)] = $3
            if (CONF == "" && $1 !~ /^UCx_/ && $1 != "" && !(toupper($1) in seenr)) { seenr[toupper($1)] = 1; RN[++nr] = $1 }
            next }
        FILENAME ~ /details\/subscriptions\/_slugmap\.tsv$/ { SLUG["subscriptions" SUBSEP toupper($1)] = $2; next }
        FILENAME ~ /details\/accounts\/_slugmap\.tsv$/      { SLUG["accounts"      SUBSEP toupper($1)] = $2; next }
        FILENAME ~ /details\/logins\/_slugmap\.tsv$/        { SLUG["logins"        SUBSEP toupper($1)] = $2; next }
        FILENAME ~ /details\/hosts\/_slugmap\.tsv$/         { SLUG["hosts"         SUBSEP toupper($1)] = $2; next }
        FILENAME ~ /details\/logicals\/_slugmap\.tsv$/      { SLUG["logicals"      SUBSEP toupper($1)] = $2; next }
        FILENAME ~ /details\/partners\/_slugmap\.tsv$/      { SLUG["partners"      SUBSEP toupper($1)] = $2; next }
        FILENAME ~ /details\/domains\/_slugmap\.tsv$/       { SLUG["domains"       SUBSEP toupper($1)] = $2; next }
        FILENAME ~ /details\/applications\/_slugmap\.tsv$/  { SLUG["applications"  SUBSEP toupper($1)] = $2; next }
        FILENAME ~ /details\/bl\/_slugmap\.tsv$/            { SLUG["bl"            SUBSEP toupper($1)] = $2; next }
        FILENAME ~ /_subscriptions-profiles\.tsv$/  { addv(FID, "f", $1, $2); next }
        FILENAME ~ /_subscriptions-ucderived\.tsv$/ { if ($1 != "" && $2 != "") UCD[toupper($1)] = $2; next }
        FILENAME ~ /_subscriptions-accounts\.tsv$/  { addv(ACC, "a", $1, $2); next }
        FILENAME ~ /_subscriptions-logins\.tsv$/    { addv(LGN, "l", $1, $2); next }
        FILENAME ~ /_subscriptions-hosts\.tsv$/     { addv(HST, "h", $1, $2); next }
        FILENAME ~ /_subscriptions-logicals\.tsv$/  { addv(LGC, "g", $1, $2); next }
        FILENAME ~ /_subscriptions-partners\.tsv$/  { addv(PTN, "p", $1, $2); next }
        FILENAME ~ /_subscriptions-domains\.tsv$/   { addv(DOM, "d", $1, $2); next }
        FILENAME ~ /_subscriptions-apps\.tsv$/      { addv(APP, "z", $1, $2); next }
        FILENAME ~ /_subscriptions-bl\.tsv$/        { addv(BLE, "b", $1, $2); next }
        END {
            for (i = 1; i <= nr; i++) { nm = RN[i]; k = toupper(nm)
                # UCx: the name prefix wins; else the flow-manager derived one
                uc = ""
                if (match(nm, /^UC[0-9]+/)) uc = substr(nm, RSTART, RLENGTH)
                else if (k in UCD) uc = UCD[k]
                ep = cell("logins", (k in LGN) ? LGN[k] : "")
                hp = cell("hosts",  (k in HST) ? HST[k] : "")
                epc = ep ((ep != "" && hp != "") ? ", " : "") hp
                res = (k in RES) ? RES[k] : ""
                tr = "<tr"
                if (res == "green" || res == "orange" || res == "red" || res == "blue") tr = tr " data-res=\"" res "\""
                # the Subscription cell (2026-08-30, user request): the
                # FlowID text, linking the subscription detail page — the
                # row identity. Baked order: UCx, then the PLAIN FlowID text
                # (the anchor would sort every row on the shared href
                # prefix), name as tiebreak.
                fidtxt = cell("", (k in FID) ? FID[k] : "")
                fid = fidtxt
                if (fid != "" && ("subscriptions" SUBSEP k) in SLUG)
                    fid = "<a href=\"../details/subscriptions/" SLUG["subscriptions" SUBSEP k] ".html\">" fidtxt "</a>"
                print toupper(uc) "\t" toupper(fidtxt == "" ? nm : fidtxt) "\t" k "\t" tr ">" \
                    "<td>" uc "</td>" \
                    "<td>" fid "</td>" \
                    "<td class=\"wrap\">" cell("accounts", (k in ACC) ? ACC[k] : "") "</td>" \
                    "<td>" cell("logicals", (k in LGC) ? LGC[k] : "") "</td>" \
                    "<td class=\"wrap\">" cell("partners", (k in PTN) ? PTN[k] : "") "</td>" \
                    "<td>" cell("domains", (k in DOM) ? DOM[k] : "") "</td>" \
                    "<td>" cell("applications", (k in APP) ? APP[k] : "") "</td>" \
                    "<td class=\"wrap\">" epc "</td>" \
                    "<td>" cell("bl", (k in BLE) ? BLE[k] : "") "</td></tr>"
            }
        }' ${args[@]+"${args[@]}"} "$B/_subscriptions.tsv" \
        | LC_ALL=C sort -t"$(printf '\t')" -k1,1 -k2,2 -k3,3 | cut -f4-)
    local n; n=$(printf '%s' "$rows" | grep -c '<tr' || true)
    {
        html_head "Subscriptions" "../assets/style.css" "" "" "subscriptions" "" "" "sort-fresh"
        printf '<h1>Subscriptions</h1>\n'
        analyses_group_tabs subscriptions.html
        printf '<p class="subtitle">Every configured subscription on one row, ordered by <strong>use case</strong> (the <code>UC&lt;n&gt;</code> name prefix, else the derived one). The <strong>Subscription</strong> column shows the flow&rsquo;s <strong>FlowID</strong> (the <code>customAttribute_FlowIdentifier</code>) and links the subscription&rsquo;s own detail page &mdash; a flow&rsquo;s UC subscriptions share one FlowID, so a FlowID can carry several rows. Then the <strong>account</strong> and the derived <strong>Logical</strong> / <strong>Partner</strong> / <strong>Domain</strong> / <strong>Application</strong> groups, the <strong>endpoint</strong> (the login the partner connects in with, or the remote host we dial out to) and the <strong>BL</strong> tag (the export&rsquo;s <code>tags</code> entry starting with <code>BL</code>). Every other name links its detail page too; rows tint by the subscription&rsquo;s result &mdash; <strong>green</strong> last transfer OK, <strong>orange</strong> never seen, <strong>red</strong> last transfer Error, <strong>blue</strong> server-log only.</p>\n'
        printf '<div class="tablewrap"><table class="index fit">\n'
        printf '<tr><th>UCx</th><th>Subscription</th><th>Account</th><th>Logical</th><th>Partner</th><th>Domain</th><th>Application</th><th>Endpoint</th><th>BL</th></tr>\n'
        [ -n "$rows" ] && printf '%s\n' "$rows"
        printf '<tr class="total"><td>Total (%s)</td><td></td><td></td><td></td><td></td><td></td><td></td><td></td><td></td></tr>\n' "$n"
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

    # ---- naming rule: an INCOMING account separates its name parts with "-",
    # an OUTGOING one with "_". The primary separator is decided exactly as
    # bin/flow-manager.sh's pda_split does — "_" wins UNLESS splitting on "-"
    # yields MORE parts, which is the documented AIM-FIN_TREASURY-… case (an
    # internal "-" inside a part must not be read as the separator). Accounts
    # with neither separator (a bare code like P00922) cannot be judged and are
    # counted apart rather than reported as breaking the rule.
    local nm_rows nm_bad nm_ok nm_none
    nm_rows=$(awk -F'\t' '$1!="#" && $1!="" && ($2=="in" || $2=="out") {
            nu = split($1, u, "_"); nd = split($1, d, "-")
            prim = (nu > 1 && nu >= nd) ? "_" : ((nd > 1) ? "-" : "")
            want = ($2 == "in") ? "-" : "_"
            if (prim == "") { none++; next }
            if (prim != want) { bad++; printf "%s\t%s\t%s\t%s\t%s\n", $1, $2, prim, want, $3 }
            else ok++
        } END { printf "#\t%d\t%d\t%d\n", ok+0, bad+0, none+0 }' "$DATA/flow-manager/base/_accounts.tsv")
    IFS=$'\t' read -r _ nm_ok nm_bad nm_none <<< "$(printf '%s\n' "$nm_rows" | grep '^#')"
    nm_rows=$(printf '%s\n' "$nm_rows" | grep -v '^#' || true)

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
        FILENAME ~ /-domains/  { D[toupper($1)] = $2; next }
        FILENAME ~ /-apps/     { A[toupper($1)] = $2; next }
        FILENAME ~ /-partners/ { P[toupper($1)] = $2; next }
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
                   (k in D ? D[k] : ""), (k in A ? A[k] : ""), (k in P ? P[k] : ""), miss, why, $3
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
    local hc_nattr hc_nhosts
    hc_nattr=$(printf '%s' "$hc_stream" | awk -F'\t' 'NF && !($1 in a){a[$1]=1;n++} END{print n+0}')
    hc_nhosts=$(printf '%s' "$hc_stream" | awk -F'\t' 'NF && !($3 in h){h[$3]=1;n++} END{print n+0}')
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
    local wc_nattr wc_nips
    wc_nattr=$(printf '%s' "$wc_stream" | awk -F'\t' 'NF && !($1 in a){a[$1]=1;n++} END{print n+0}')
    wc_nips=$(printf '%s' "$wc_stream" | awk -F'\t' 'NF && !($3 in h){h[$3]=1;n++} END{print n+0}')
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
        html_head "Accounts" "../assets/style.css" "" "" "accounts" "" "" "sort-fresh"
        printf '<h1>Accounts</h1>\n'
        analyses_group_tabs accounts.html
        printf '<p class="subtitle">An <strong>account</strong> (a partner in the FlowManager config) talks to us through one or more <strong>communication profiles</strong>, each defining how one endpoint connects. This page checks the accounts, their login names and their profiles for configuration slips. A profile name is coded <code>&lt;TYPE&gt;_&lt;partner&gt;_&lt;AUTH&gt;</code>: the <strong>prefix</strong> is the connection type &mdash; <code>SCP</code>/<code>SSCP</code> = server (ST connects out to the partner), <code>CCP</code> = client (the partner connects in) &mdash; and the <strong>suffix</strong> is the authentication &mdash; <code>PWD</code> = password, <code>KEY</code> = public key. Below, both are checked against each profile&rsquo;s real <code>type</code> and <code>clientAuthentication</code>, followed by the account &amp; login checks.</p>\n'
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
        printf '%s\n' "$prefix_rows" | while IFS=$'\t' read -r tok n typ; do
            [ -n "$tok" ] || continue
            case $tok in SCP) mean="Server comm profile" ;; SSCP) mean="Secure server comm profile" ;; CCP) mean="Client comm profile" ;; *) mean="&mdash;" ;; esac
            esc "$tok"; te=$ESC; esc "$typ"; tye=$ESC
            printf '<tr><td>%s</td><td>%s</td><td class="num">%s</td><td>%s</td></tr>\n' "$te" "$mean" "$(dotify "$n")" "$tye"
        done
        printf '</table></div>\n'
        printf '<p class="range">Every profile&rsquo;s prefix matches its configured <code>type</code> &mdash; <strong>%s of %s consistent</strong>, no exceptions.</p>\n' "$(dotify "$total")" "$(dotify "$total")"
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
            printf '<p class="range">These %s profiles are named for one authentication method but configured for another &mdash; a naming or configuration slip worth reconciling.</p>\n' "$nmm"
        else
            printf '<p class="range">No inconsistencies &mdash; every profile&rsquo;s auth suffix matches its configured authentication.</p>\n'
        fi
        printf '<h2>Breaking naming rules (%s)</h2>\n' "$(dotify "${nm_bad:-0}")"
        printf '<p class="range">An <strong>incoming</strong> account (the partner connects to us) separates its name parts with <code>-</code>; an <strong>outgoing</strong> one (we connect to the partner) uses <code>_</code>. The same flow configured both ways therefore appears twice, once in each spelling &mdash; <code>DPL-AXINI-AO-IMPRESS</code> inbound and <code>DPL_AXINI-AO_IMPRESS</code> outbound. The separator is read <code>_</code>-primary: <code>_</code> wins unless splitting on <code>-</code> yields more parts, so an internal hyphen inside one part (<code>AIM-FIN_TREASURY-SP</code>) is not mistaken for the separator. (A NAMING audit only &mdash; since the logical-based derivation the partner/domain/application entities no longer come from account names.)</p>\n'
        if [ "${nm_bad:-0}" -gt 0 ]; then
            printf '<div class="tablewrap"><table class="index fit">\n<tr><th>Account</th><th>Direction</th><th>Separator used</th><th>Expected</th></tr>\n'
            printf '%s\n' "$nm_rows" | tr '\t' '\037' | while IFS=$'\037' read -r nm dir prim want res; do
                [ -n "$nm" ] || continue
                esc "$nm"; nme=$ESC
                printf '<tr data-res="%s"><td><code>%s</code></td><td>%s</td><td><code>%s</code></td><td><code>%s</code></td></tr>\n' \
                    "${res:-orange}" "$nme" "$( [ "$dir" = in ] && printf 'incoming' || printf 'outgoing' )" "$prim" "$want"   # lowercase Direction, site-wide rule
            done
            printf '</table></div>\n'
            printf '<p class="range">%s of %s directional accounts follow the rule.%s A break is a naming slip rather than a fault &mdash; the flow still works &mdash; but it hides the pairing: the twin spelling is how an incoming and an outgoing half of the same flow are recognised as one route.</p>\n' \
                "$(dotify "${nm_ok:-0}")" "$(dotify "$(( ${nm_ok:-0} + ${nm_bad:-0} ))")" \
                "$( [ "${nm_none:-0}" -gt 0 ] && printf ' %s account(s) carry no separator at all and cannot be judged.' "${nm_none}" )"
        else
            printf '<p class="range">No breaks &mdash; all %s directional accounts follow the rule.</p>\n' "$(dotify "${nm_ok:-0}")"
        fi
        printf '<h2>Not clear domain-application-partner (%s)</h2>\n' "$(dotify "${pda_bad:-0}")"
        printf '<p class="range">An account is meant to be connected to a <strong>logical flow</strong>, whose three-part name reads <strong>domain_application_partner</strong> &mdash; <code>ODV_MAIA_AKZO</code> is domain <code>ODV</code>, application <code>MAIA</code>, partner <code>AKZO</code>. These accounts could not be resolved into all three. The check does not re-read any names: it asks the derivation itself what it managed to assign, so a blank column is a value the rest of the site genuinely does not have for that account.</p>\n'
        if [ "${pda_bad:-0}" -gt 0 ]; then
            printf '<div class="tablewrap"><table class="index fit">\n<tr><th>Account</th><th>Domain</th><th>Application</th><th>Partner</th><th>Missing</th><th>Why</th></tr>\n'
            # \037, not TAB: a TAB is IFS whitespace, so consecutive empty
            # fields (a missing domain/application/partner is exactly that)
            # collapse on read and shift every later column.
            printf '%s\n' "$pda_rows" | tr '\t' '\037' | while IFS=$'\037' read -r nm dm ap pt miss why res; do
                [ -n "$nm" ] || continue
                esc "$nm"; nme=$ESC; esc "$dm"; dme=$ESC; esc "$ap"; ape=$ESC; esc "$pt"; pte=$ESC
                esc "$miss"; mse=$ESC; esc "$why"; whe=$ESC
                printf '<tr data-res="%s"><td><code>%s</code></td><td>%s</td><td>%s</td><td>%s</td><td>%s</td><td>%s</td></tr>\n' \
                    "${res:-orange}" "$nme" "${dme:-&mdash;}" "${ape:-&mdash;}" "${pte:-&mdash;}" "$mse" "$whe"
            done
            printf '</table></div>\n'
            printf '<p class="range">%s of %s accounts resolve to all three. A gap is not a fault &mdash; the flow works either way &mdash; but the account is then absent from that entity&rsquo;s Files, coverage and cross-reference figures, so a partner can look quieter than it is.</p>\n' \
                "$(dotify "${pda_ok:-0}")" "$(dotify "$(( ${pda_ok:-0} + ${pda_bad:-0} ))")"
        else
            printf '<p class="range">All %s accounts resolve to a domain, an application and a partner.</p>\n' "$(dotify "${pda_ok:-0}")"
        fi
        printf '<h2>FTP endpoints (%s) &mdash; insecure</h2>\n' "$(dotify "$nftp")"
        printf '<p class="range"><strong>FTP transfers credentials and data in clear text</strong> and cannot use a public key, so these are the site&rsquo;s only insecure profiles. They are also exactly the %s profiles outside the <code>PWD</code>/<code>KEY</code> naming convention above (their name ends in a partner tag and their <code>clientAuthentication</code> is unset). Migrating them to SFTP would close the last plaintext links.</p>\n' "$(dotify "$nftp")"
        printf '<div class="tablewrap"><table class="index fit">\n<tr><th>Communication profile</th><th>Name suffix</th><th>Authentication</th></tr>\n'
        printf '%s\n' "$ftp_rows" | while IFS=$'\t' read -r nm suf auth; do
            [ -n "$nm" ] || continue
            esc "$nm"; nme=$ESC; esc "$suf"; sfe=$ESC; esc "$auth"; ae=$ESC
            printf '<tr data-res="red"><td><code>%s</code></td><td>%s</td><td>%s</td></tr>\n' "$nme" "$sfe" "$ae"
        done
        printf '</table></div>\n'
        printf '<h2>Incoming partners without IP whitelisting (%s)</h2>\n' "$(dotify "$niw")"
        if [ "$niw" -gt 0 ]; then
            printf '<p class="range">An <strong>incoming</strong> partner (a CLIENT profile &mdash; it connects in to us) should be restricted by an <code>AllowIP</code> whitelist. The following %s have none, so any source IP could attempt to connect, relying on authentication alone (weakest when that is a password).</p>\n' "$(dotify "$niw")"
            printf '<div class="tablewrap"><table class="index fit">\n<tr><th>Partner</th><th>Protocol</th><th>Authentication</th><th>Status</th></tr>\n'
            printf '%s\n' "$iw_rows" | while IFS=$'\t' read -r p proto auth; do
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
        printf '<h2>Remote hosts with conflicting setup</h2>\n'
        if [ -n "$hc_stream" ]; then
            printf '<p class="range">A remote host reached from more than one profile should be configured the same way everywhere. Checking <strong>every</strong> host-intrinsic connection attribute, <strong>%s host(s)</strong> differ across <strong>%s attribute(s)</strong> &mdash; one table per differing attribute below. A port pair means one is probably stale; a host-key pair (verification or stored key) is a security gap: one connection is protected against a man-in-the-middle, the other is not. Per-account client credentials are excluded (they are not a property of the host). Each distinct value is a row, grouped by host.</p>\n' "$(dotify "$hc_nhosts")" "$(dotify "$hc_nattr")"
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
                printf '%s\n' "$arows" | while IFS=$'\t' read -r h v pf; do
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
            printf '<p class="range">The inbound mirror of the check above: a source IP whitelisted for more than one incoming (CLIENT) partner should present the same way. Checking <strong>every</strong> incoming attribute, <strong>%s IP(s)</strong> differ across <strong>%s attribute(s)</strong> &mdash; one table per differing attribute below. Often deliberate (one source, per-account credentials), but worth confirming. Per-account logins are excluded. Each distinct value is a row, grouped by IP.</p>\n' "$(dotify "$wc_nips")" "$(dotify "$wc_nattr")"
            local waspec warows wanh previp
            for waspec in "clientAuthentication|Authentication" "protocol|Protocol" "fipsEnabled|FIPS mode" "enabled|Profile enabled"; do
                wfield=${waspec%%|*}; wlabel=${waspec#*|}
                warows=$(printf '%s\n' "$wc_stream" | awk -F'\t' -v f="$wfield" '$1==f{print $3"\t"$4"\t"$5}')
                [ -n "$warows" ] || continue
                wanh=$(printf '%s\n' "$warows" | awk -F'\t' 'NF && !($1 in h){h[$1]=1;n++} END{print n+0}')
                esc "$wlabel"
                printf '<h3>%s (%s IP(s))</h3>\n<div class="tablewrap"><table class="index fit">\n<tr><th>Whitelisted IP</th><th>Value</th><th>Partners</th></tr>\n' "$ESC" "$(dotify "$wanh")"
                previp=""
                printf '%s\n' "$warows" | while IFS=$'\t' read -r ip v pf; do
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
        printf '<p class="subtitle">Configuration checks on the accounts and the login names their communication profiles use.</p>\n'
        # 1. non-standard login names
        printf '<h3>Non-standard login names (%s)</h3>\n' "$(dotify "$nnsl")"
        if [ "$nnsl" -gt 0 ]; then
            printf '<p class="range">A partner connecting in (a CLIENT profile) authenticates with a provisioned <code>FE&lt;digits&gt;</code> login. These %s use a different login name.</p>\n' "$(dotify "$nnsl")"
            printf '<div class="tablewrap"><table class="index fit">\n<tr><th>Account</th><th>Communication profile</th><th>Login</th></tr>\n'
            printf '%s\n' "$nsl_rows" | while IFS=$'\t' read -r a p l; do
                [ -n "$a" ] || continue; esc "$a"; ae=$ESC; esc "$p"; pe=$ESC; esc "$l"; le=$ESC
                printf '<tr data-res="orange"><td>%s</td><td><code>%s</code></td><td><code>%s</code></td></tr>\n' "$ae" "$pe" "$le"
            done
            printf '</table></div>\n'
        else printf '<p class="range">Every incoming login is a standard <code>FE&lt;digits&gt;</code> name.</p>\n'; fi
        # 2. one login on more than one account
        printf '<h3>Login used by more than one account (%s)</h3>\n' "$(dotify "$nshl")"
        if [ "$nshl" -gt 0 ]; then
            printf '<p class="range">A login should belong to one account. These %s are configured on several &mdash; often <code>-</code>/<code>_</code> spelling twins of the same partner, but worth confirming.</p>\n' "$(dotify "$nshl")"
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
            printf '<p class="range">A server endpoint should resolve to exactly one host. These %s list several.</p>\n' "$(dotify "$nmh")"
            printf '<div class="tablewrap"><table class="index fit">\n<tr><th>Account</th><th>Communication profile</th><th class="num">Hosts</th><th>Host list</th></tr>\n'
            printf '%s\n' "$mh_rows" | while IFS=$'\t' read -r a p n hl; do
                [ -n "$a" ] || continue; esc "$a"; ae=$ESC; esc "$p"; pe=$ESC; esc "$hl"; hle=$ESC
                printf '<tr data-res="orange"><td>%s</td><td><code>%s</code></td><td class="num">%s</td><td>%s</td></tr>\n' "$ae" "$pe" "$n" "$hle"
            done
            printf '</table></div>\n'
        else printf '<p class="range">Every communication profile resolves to a single host.</p>\n'; fi
        # 4. incoming password profiles with no stored password
        printf '<h3>Incoming password profiles with no stored password (%s)</h3>\n' "$(dotify "$nnpw")"
        if [ "$nnpw" -gt 0 ]; then
            printf '<p class="range">These %s incoming (CLIENT) profiles are set to <strong>password</strong> authentication, yet the login credential holds no password (<code>hasPassword=false</code>). Many rely on IP whitelisting instead &mdash; still worth confirming the authentication is what was intended.</p>\n' "$(dotify "$nnpw")"
            printf '<div class="tablewrap"><table class="index fit">\n<tr><th>Account</th><th>Communication profile</th><th>Login</th></tr>\n'
            printf '%s\n' "$npw_rows" | while IFS=$'\t' read -r a p l; do
                [ -n "$a" ] || continue; esc "$a"; ae=$ESC; esc "$p"; pe=$ESC; esc "$l"; le=$ESC
                printf '<tr data-res="orange"><td>%s</td><td><code>%s</code></td><td><code>%s</code></td></tr>\n' "$ae" "$pe" "$le"
            done
            printf '</table></div>\n'
        else printf '<p class="range">Every incoming password profile has a stored password.</p>\n'; fi
        # 5. accounts with more than one communication profile
        printf '<h3>Accounts with more than one communication profile (%s)</h3>\n' "$(dotify "$nmcp")"
        if [ "$nmcp" -gt 0 ]; then
            printf '<p class="range">An account normally has one endpoint. These %s carry several &mdash; confirm they are intentional (a profile named for a <em>different</em> account is a likely mix-up).</p>\n' "$(dotify "$nmcp")"
            printf '<div class="tablewrap"><table class="index fit">\n<tr><th>Account</th><th class="num">Profiles</th><th>Communication profiles</th></tr>\n'
            printf '%s\n' "$mcp_rows" | while IFS=$'\t' read -r a n ps; do
                [ -n "$a" ] || continue; esc "$a"; ae=$ESC; esc "$ps"; pse=$ESC
                printf '<tr data-res="orange"><td>%s</td><td class="num">%s</td><td><code>%s</code></td></tr>\n' "$ae" "$n" "$pse"
            done
            printf '</table></div>\n'
        else printf '<p class="range">Every account has exactly one communication profile.</p>\n'; fi
        # 6. login vs loginName mismatch
        printf '<h3>Login / login-name mismatch (%s)</h3>\n' "$(dotify "$nlnm")"
        if [ "$nlnm" -gt 0 ]; then
            printf '<p class="range">A profile&rsquo;s <code>login</code> and its display <code>loginName</code> should match. These %s differ.</p>\n' "$(dotify "$nlnm")"
            printf '<div class="tablewrap"><table class="index fit">\n<tr><th>Account</th><th>Communication profile</th><th>login</th><th>loginName</th></tr>\n'
            printf '%s\n' "$lnm_rows" | while IFS=$'\t' read -r a p l ln; do
                [ -n "$a" ] || continue; esc "$a"; ae=$ESC; esc "$p"; pe=$ESC; esc "$l"; le=$ESC; esc "$ln"; lne=$ESC
                printf '<tr data-res="orange"><td>%s</td><td><code>%s</code></td><td><code>%s</code></td><td><code>%s</code></td></tr>\n' "$ae" "$pe" "$le" "$lne"
            done
            printf '</table></div>\n'
        else printf '<p class="range">Every <code>login</code> matches its <code>loginName</code>.</p>\n'; fi
        printf '</body>\n</html>\n'
    } > "$out"
}

# ---- the Cronjobs page (docs/analyses/cronjobs.html) ------------------------
# The polling schedules configured in subscriptions.json. Every one is a UC3
# subscription — ST is the CLIENT: it connects to the partner's server on a
# timer and pulls whatever is waiting. The schedule is a Quartz 6-field cron
# expression (sec min hour day-of-month month day-of-week) in
# .parameters.hybrid_partner_{sftp,ftp}_relay0_receive_scheduler_cron_expression;
# bin/cron2human.awk (shared with the Subscription detail-page Summary)
# translates it to plain English — a deterministic parse, no AI and no token
# cost, so it works on a fresh clone. Skipped if the config export is absent.
write_cronjobs_page() {
    local out="$ADIR/cronjobs.html" S="$FM_CONFIG_DIR/subscriptions.json"   # SKIP-filtered when present
    [ -f "$S" ] || { rm -f "$out"; return 0; }
    local rows total sftp ftp distinct
    rows=$(jq -r '
        .[] | . as $s
        | (["sftp","ftp"][] as $p
           | ($s.parameters["hybrid_partner_\($p)_relay0_receive_scheduler_cron_expression"]) as $c
           | select($c != null and $c != "")
           | [ $s.name, ($p|ascii_upcase), $c ] | @tsv)
      ' "$S" | awk -F'\t' -v CF=3 -f bin/cron2human.awk | LC_ALL=C sort -f)
    # `grep -c .` exits 1 on zero matches — an env with NO cron-scheduled
    # subscriptions (the production example data) must not abort the publish
    # under set -e, so every count carries `|| true`.
    total=$(printf '%s\n' "$rows" | grep -c . || true)
    sftp=$(printf '%s\n' "$rows" | awk -F'\t' '$2=="SFTP"' | grep -c . || true)
    ftp=$(printf '%s\n' "$rows"  | awk -F'\t' '$2=="FTP"'  | grep -c . || true)
    distinct=$(printf '%s\n' "$rows" | cut -f3 | LC_ALL=C sort -u | grep -c . || true)
    # Tint each configured row by the subscription's RESULT (base cache col 3:
    # green/orange/red — and blue where it exists only via the Server->Transfer
    # step, bin/build/seen-in-server-log.sh). Appended as a 5th field AFTER the counts above.
    local csubs="$DATA/flow-manager/base/_subscriptions.tsv"; [ -f "$csubs" ] || csubs=/dev/null
    # the "never completes a poll" rows (Observed "-"), collected by the row
    # awk into a temp and rendered as the page's bottom table
    local extmp; extmp=$(mktemp "${TMPDIR:-/tmp}/cronjobs-extra.XXXXXX")
    rows=$(printf '%s\n' "$rows" | awk -F'\t' -v sf="$csubs" '
        BEGIN {
            while ((getline l < sf) > 0) { n = split(l, a, "\t"); if (n >= 3) res[toupper(a[1])] = a[3] }
        }
        NF { k = toupper($1)
             c = (res[k]=="green"||res[k]=="orange"||res[k]=="red"||res[k]=="blue") ? res[k] : ""
             print $0 "\t" c }')
    {
        html_head "Cronjobs" "../assets/style.css" "" "" "cronjobs" "" "" "sort-fresh"
        printf '<h1>Cronjobs</h1>\n'
        analyses_group_tabs cronjobs.html
        printf '<p class="subtitle">The client polling schedules in <code>subscriptions.json</code>, joined against what actually happens. Where we are the <strong>client</strong> and pull from the partner (<strong>UC3</strong>, and <strong>UC5</strong>&rsquo;s pull side), ST connects to the partner&rsquo;s server on a timer and collects whatever is waiting; the schedule is a <a href="https://www.quartz-scheduler.org/documentation/quartz-2.3.0/tutorials/crontrigger.html" target="_blank" rel="noopener">Quartz</a> cron expression (<code>sec min hour day-of-month month day-of-week</code>), translated to plain English in the <strong>Schedule</strong> column. (UC1 is a client use case too, but pushes on directory scanning &mdash; no cron.) The <strong>Observed</strong> column says when the schedule actually fires: from the server log&rsquo;s poll lines where they exist, else from the file arrivals.</p>\n'
        # Configured cronjobs + the observed firing (the former Schedule vs
        # reality page, merged here 2026-08), each row tinted by its
        # subscription result.
        printf '<h2>Configured cronjobs</h2>\n'
        printf '<p class="range"><strong>%s</strong> polling schedules &mdash; %s SFTP, %s FTP &mdash; across <strong>%s</strong> distinct cron expressions. All are enabled; none skip holidays. Rows are tinted by the subscription&rsquo;s last-transfer result &mdash; <strong>green</strong> OK, <strong>orange</strong> never seen, <strong>red</strong> Error, <strong>blue</strong> seen only in the server log.</p>\n' \
            "$(dotify "$total")" "$(dotify "$sftp")" "$(dotify "$ftp")" "$(dotify "$distinct")"
        printf '<div class="tablewrap"><table class="index fit">\n'
        printf '<tr><th>Subscription</th><th>Cron expression</th><th>Schedule</th><th>Observed</th><th class="num">Polls</th><th class="num">Active days</th></tr>\n'
        printf '%s\n' "$rows" | awk -F'\t' \
            -v PUNCT="$DATA/transfer/reports/punctuality.rpt" \
            -v POLLT="$DATA/server/reports/poll-times.tsv" \
            -v PF="$DATA/server/reports/poll-failures.tsv" \
            -v XSH="$DATA/flow-manager/xref/_subscriptions-hosts.tsv" \
            -v EX="$extmp" \
            -v SSM="$DATA/transfer/reports/details/subscriptions/_slugmap.tsv" '
            function e(s) { gsub(/&/, "\\&amp;", s); gsub(/</, "\\&lt;", s); gsub(/>/, "\\&gt;", s); gsub(/"/, "\\&quot;", s); return s }
            # one numeric cron field -> "count:min" (how many values it fires
            # at per cycle, and the smallest) — the Observed-vs-Schedule check
            function finfo(fld, cycle,   a, np, parts, i, seg, b, x, k, set, cnt, mn, st, step) {
                if (fld == "*" || fld == "?") return cycle ":0"
                if (fld ~ /^[0-9]+$/) return "1:" (fld+0)
                if (fld ~ /^([0-9]+|\*)\/[0-9]+$/) { split(fld, a, "/"); step = a[2]+0; st = (a[1] == "*" ? 0 : a[1]+0)
                    if (step <= 0) return "1:" st
                    cnt = 0; for (k = st; k < cycle; k += step) cnt++
                    return cnt ":" st }
                split("", set)
                np = split(fld, parts, ",")
                for (i = 1; i <= np; i++) { seg = parts[i]
                    if (seg ~ /-/) { split(seg, a, "-"); b = a[1]+0; x = a[2]+0; for (k = b; k <= x; k++) set[k] = 1 }
                    else set[seg+0] = 1 }
                cnt = 0; mn = -1
                for (k = 0; k < cycle; k++) if (k in set) { cnt++; if (mn < 0) mn = k }
                return (cnt ? cnt : 1) ":" (mn < 0 ? 0 : mn)
            }
            # circular minute-of-day distance
            function mdist(a, b,   d) { d = a - b; if (d < 0) d = -d; if (1440 - d < d) d = 1440 - d; return d }
            # prefix either way (the server truncates long site names)
            function pfx(a, b) { return substr(a, 1, length(b)) == b || substr(b, 1, length(a)) == a }
            BEGIN {
                US = sprintf("%c", 31)
                while ((getline l < SSM) > 0) { split(l, a, "\t"); if (a[1] != "") SL[toupper(a[1])] = a[2] } close(SSM)
                # punctuality rows: site, days, typical, window, class — the
                # file-arrival fallback for schedules with no poll line
                while ((getline l < PUNCT) > 0) {
                    n = split(l, a, "\t")
                    if (a[1] != "ROW" || a[2] ~ /^@\{colspan/) continue
                    u = toupper(a[2])
                    if (!(u in PD) || a[3]+0 > PD[u]) { PD[u] = a[3]+0; PT[u] = a[4]; PW[u] = a[5]; PC[u] = a[6] }
                } close(PUNCT)
                npu = 0; for (u in PD) { npu++; PU[npu] = u }
                # poll-times.tsv (remote-poll.sh): name, polls, days, typical,
                # spread(min), class, polls/day — the schedule firing in the
                # SERVER log, empty polls included
                while ((getline l < POLLT) > 0) {
                    n = split(l, a, "\t")
                    if (n < 7 || a[1] == "") continue
                    u = toupper(a[1])
                    if (!(u in QN) || a[2]+0 > QN[u]) { QN[u] = a[2]+0; QD[u] = a[3]+0
                        QT[u] = a[4]; QW[u] = a[5]+0; QC[u] = a[6]; QPD[u] = a[7]+0 }
                } close(POLLT)
                nqu = 0; for (u in QN) { nqu++; QU[nqu] = u }
                # poll-failures.tsv (remote-poll.sh): S/C/L rows keyed by site,
                # A rows by HOST — per key the total count + the dominant reason
                while ((getline l < PF) > 0) { n = split(l, a, "\t")
                    if (n < 3) continue
                    if (a[1] == "S")      { u = toupper(a[2]); if (PS[u] == "") PSU[++nps] = u; PS[u] += a[3] }
                    else if (a[1] == "C") { u = toupper(a[2]); if (PC2[u] == "") PCU[++npc] = u
                                            PC2[u] += a[3]; if (a[3]+0 > PCB[u]+0) { PCB[u] = a[3]+0; PCR[u] = a[4] } }
                    else if (a[1] == "L") { u = toupper(a[2]); if (PL2[u] == "") PLU[++npl] = u
                                            PL2[u] += a[3]; if (a[3]+0 > PLB[u]+0) { PLB[u] = a[3]+0; PLR[u] = a[4] } }
                    else if (a[1] == "A") { PA2[a[2]] += a[3]
                                            if (a[3]+0 > PAB[a[2]]+0) { PAB[a[2]] = a[3]+0; PAR[a[2]] = a[4] } }
                } close(PF)
                # subscription -> configured host(s), for the host-keyed A rows
                while ((getline l < XSH) > 0) { split(l, a, "\t")
                    if (a[1] != "" && a[2] != "") HS[toupper(a[1])] = HS[toupper(a[1])] " " a[2] }
                close(XSH)
            }
            NF {
                name = $1; cronx = $3; human = $4; color = $5
                un = toupper(name)
                # the schedule as numbers: expected firings/day E and the
                # earliest daily fire (minute-of-day), unioned over the row'\''s
                # cron expression(s) — dow only picks DAYS, so it is ignored
                # (observed rates are per ACTIVE day too)
                E = 0; early = -1
                nx = split(cronx, CX, US)
                for (i = 1; i <= nx; i++) {
                    if (split(CX[i], CF2, /[ \t]+/) < 3) continue
                    split(finfo(CF2[2], 60), A2, ":"); split(finfo(CF2[3], 24), A3, ":")
                    E += A2[1] * A3[1]
                    em = A3[2] * 60 + A2[2]
                    if (early < 0 || em < early) early = em
                }
                # file-arrival observation (largest active-days prefix match)
                odays = 0; otyp = ""; owin = ""; ocls = ""
                for (i = 1; i <= npu; i++) { u = PU[i]
                    if (substr(u, 1, length(un)) == un && PD[u] > odays) { odays = PD[u]; otyp = PT[u]; owin = PW[u]; ocls = PC[u] } }
                # the poll footprint (prefix BOTH ways — the server truncates
                # long site names); an exact name always wins
                polls = 0
                if (un in QN) qk = un
                else {
                    qk = ""
                    for (i = 1; i <= nqu; i++) { u = QU[i]
                        if ((substr(u, 1, length(un)) == un || substr(un, 1, length(u)) == u) && QN[u] > polls) { qk = u; polls = QN[u] } }
                }
                if (qk != "") { polls = QN[qk]
                    if (polls > 0) { odays = QD[qk]
                        ocell = (QPD[qk] <= 3) ? sprintf("%s &plusmn; %d min", QT[qk], QW[qk]) \
                                               : sprintf("~%d polls/day", QPD[qk]) }
                }
                if (polls == 0) ocell = (otyp != "") ? e(otyp " " owin " (" ocls ")") " &middot; files" : "-"
                # Observed vs Schedule: dark-red the cell when the evidence
                # CONTRADICTS the cron — a slot schedule (<=3/day) whose median
                # first poll sits off the earliest scheduled fire, a rate more
                # than 3x off the expected one, or a continuous schedule seen
                # only as a daily slot. File-arrival evidence is compared only
                # for slot schedules (an interval poll collects whenever data
                # appears); a "-" (never observed) is absence, not contradiction.
                bad = 0
                if (E > 0 && early >= 0) {
                    if (polls > 0) {
                        if (QPD[qk] > 3) { if (E <= 3 || QPD[qk] * 3 < E || QPD[qk] > E * 3) bad = 1 }
                        else if (E > 3) bad = 1
                        else { split(QT[qk], TT, ":")
                               tol = 2 * QW[qk] + 5; if (tol < 20) tol = 20
                               if (mdist(TT[1] * 60 + TT[2], early) > tol) bad = 1 }
                    } else if (otyp != "" && E <= 3) {
                        split(otyp, TT, ":")
                        if (mdist(TT[1] * 60 + TT[2], early) > 30) bad = 1
                    }
                }
                nm = e(name); if (un in SL) nm = "<a href=\"../details/subscriptions/" SL[un] ".html\">" nm "</a>"
                ec = e(cronx); gsub(US, "</code><br><code>", ec)   # multi-line cron -> stacked
                # an Observed "-" row: collect its failure evidence for the
                # bottom table (once per subscription — protocols share it)
                if (polls == 0 && otyp == "" && !(un in NEV)) {
                    NEV[un] = 1
                    st2 = 0; cf2 = 0; lf2 = 0; af2 = 0; best = 0; why = ""
                    for (i = 1; i <= nps; i++) { u = PSU[i]
                        if (pfx(u, un) && PS[u] > st2) st2 = PS[u] }
                    for (i = 1; i <= npc; i++) { u = PCU[i]
                        if (pfx(u, un)) { cf2 += PC2[u]
                            if (PCB[u]+0 > best) { best = PCB[u]+0; why = PCR[u] } } }
                    for (i = 1; i <= npl; i++) { u = PLU[i]
                        if (pfx(u, un)) { lf2 += PL2[u]
                            if (PLB[u]+0 > best) { best = PLB[u]+0; why = PLR[u] " (after connecting)" } } }
                    nh2 = split(HS[un], HH, " ")
                    for (i = 1; i <= nh2; i++) { h2 = HH[i]
                        if (h2 != "" && (h2 in PA2)) { af2 += PA2[h2]
                            if (PAB[h2]+0 > best) { best = PAB[h2]+0; why = PAR[h2] } } }
                    tot2 = cf2 + lf2 + af2
                    printf "%d\t%d\t%s\n", tot2, st2, \
                        "<tr" (color != "" ? " data-res=\"" color "\"" : "") "><td class=\"cl\">" nm "</td><td class=\"num\">" (st2 ? st2 : "-") "</td><td class=\"num\">" (tot2 ? tot2 : "-") "</td><td>" (why != "" ? e(why) : "no failure line names this flow in the loaded logs") "</td></tr>" > EX
                }
                printf "<tr%s><td class=\"cl\">%s</td><td><code>%s</code></td><td>%s</td><td%s>%s</td><td class=\"num\">%s</td><td class=\"num\">%s</td></tr>\n", \
                    (color != "" ? " data-res=\"" color "\"" : ""), nm, ec, e(human), (bad ? " class=\"obsbad\"" : ""), ocell, (polls ? polls : "-"), (odays ? odays : "-")
            }'
        printf '<tr class="total"><td>Total (%s cronjobs)</td><td></td><td></td><td></td><td></td><td></td></tr>\n' "$(dotify "$total")"
        printf '</table></div>\n'
        printf '<p class="range">Observed slots come from the server log via the <a href="../server/remote-poll.html">Remote poll</a> report &mdash; the median of each day&rsquo;s FIRST poll, &plusmn; one standard deviation; a schedule firing more than 3&times; a day has no single slot and shows its poll rate instead. Slots marked <span class="mono">&middot; files</span> fall back to the transfer <strong>Punctuality</strong> report (same model over file arrivals) for schedules with no poll line. Matching is name-prefix, both ways (the server truncates long site names). A <span class="mono">-</span> means no poll and no File in the loaded logs &mdash; the schedule never fires. A <strong>dark red</strong> Observed cell contradicts its schedule: the observed slot sits off the scheduled time, the poll rate is more than 3&times; off the expected one, or a continuous schedule is only seen firing a few times a day.</p>\n'
        # ---- the bottom table: the Observed "-" rows, diagnosed -------------
        if [ -s "$extmp" ]; then
            local x_n x_st x_fail
            read -r x_n x_st x_fail <<< "$(awk -F'\t' '{ n++; f += $1; s += $2 } END { printf "%d %d %d", n+0, s+0, f+0 }' "$extmp")"
            printf '<h2>Schedules that never complete a poll</h2>\n'
            printf '<p class="range">The <strong>%s</strong> schedule(s) whose Observed column shows <span class="mono">-</span>: the server log holds <strong>no completed poll</strong> for them. Most DO fire &mdash; their setup lines appear right on the scheduled minutes (<strong>Poll starts</strong>) &mdash; but the poll dies before the listing. <strong>What goes wrong</strong> is the dominant failure line the server log pairs with the flow; <strong>Failure lines</strong> counts them all.</p>\n' \
                "$(dotify "$x_n")"
            printf '<div class="tablewrap"><table class="index fit">\n'
            printf '<tr><th>Subscription</th><th class="num">Poll starts</th><th class="num">Failure lines</th><th>What goes wrong</th></tr>\n'
            LC_ALL=C sort -t$'\t' -k1,1nr -k2,2nr -k3,3 "$extmp" | cut -f3-
            printf '<tr class="total"><td>Total (%s subscription(s))</td><td class="num">%s</td><td class="num">%s</td><td></td></tr>\n' \
                "$(dotify "$x_n")" "$(dotify "$x_st")" "$(dotify "$x_fail")"
            printf '</table></div>\n'
            printf '<p class="range">Connection and listing failures name the subscription in the log and are counted directly. <strong>Authentication failures name only host + user</strong>, so they are matched through the subscription&rsquo;s configured host and can be shared between that host&rsquo;s flows. A row with neither starts nor failure lines never fires at all in the loaded logs. The evidence comes from the same server-log pass as the <a href="../server/remote-poll.html">Remote poll</a> report.</p>\n'
        fi
        printf '</body>\n</html>\n'
    } > "$out"
    rm -f "$extmp"
}


# ---- the analyses catalog page (docs/analyses/index.html) -------------------
# One line per analysis, like the transfer/server index pages — the two local
# coverage tables plus the Cross References group (rendered in the transfer
# area). Labels/descriptions come from the .rpt TITLE/DESC where one exists.
render_coverage_pages   # the 3 PDA Configured cell pages (linked from the home)
write_analyses_index() {
    local out="$ADIR/index.html"
    {
        html_head "Analyses" "../assets/style.css" "" "ANALYSES" "index"
        printf '<h1>Analyses</h1>\n'
        printf '<p class="subtitle">Configuration vs reality, across both logs: which configured names are actually seen, and what belongs together.</p>\n'
        # one section header per GROUP (matching ANALYSES_MENU and the pages'
        # analyses_group_tabs rows), the group's members under it
        # data-nosort: the index is a hand-ordered catalog with colspan group
        # bands — report.js's fallback sort would collapse it into stacked
        # headers + one alphabetized list AND persist that in sessionStorage
        printf '<div class="tablewrap"><table class="index" data-nosort="1">\n'
        local rpt base t d
        printf '<tr><th colspan="2">Coverage &amp; seen</th></tr>\n'
        [ -f "$DOCS/transfer/entity-coverage-accounts.html" ] && printf '<tr><td><a href="../transfer/entity-coverage-accounts.html">Entity coverage</a></td><td class="desc">Per account, partner, domain or application: does each configured direction actually work &mdash; proven by real transferred Files, successful SSH logons (In) or successful UC3 remote polls (Out).</td></tr>\n'
        [ -f "$ADIR/first-seen.html" ] && printf '<tr><td><a href="first-seen.html">First seen</a></td><td class="desc">On what day each logical flow, partner, subscription, account, login and remote host was first seen in the transfer logs &mdash; the configured names never seen there on top; every count links its item list.</td></tr>\n'
        [ -f "$ADIR/data-diff.html" ] && printf '<tr><td><a href="data-diff.html">Since yesterday</a></td><td class="desc">The data diff against the newest log day: new red flips, flows that just crossed the quiet threshold, recoveries, first-seen entities by name and new server-log-only names.</td></tr>\n'
        [ -f "$DOCS/file-search-24-hours.html" ] && printf '<tr><td><a href="../file-search-24-hours.html">File search</a></td><td class="desc">Find a File by its file name &mdash; date, subscription, size and CoreId, OK rows green and Error rows red; six windows (24 hours through a month), each searched with its own Search button and the query carried between them.</td></tr>\n'
        [ -f "$DOCS/transfer/seen-in-server-log.html" ] && printf '<tr><td><a href="../transfer/seen-in-server-log.html">Seen in server log</a></td><td class="desc">The entities that appear in the SERVER log only (blue): their seed messages, what happened, and the status rollups with the blue deltas.</td></tr>\n'
        printf '<tr><th colspan="2">Configuration</th></tr>\n'
        [ -f "$ADIR/use-cases.html" ] && printf '<tr><td><a href="use-cases.html">Use cases</a></td><td class="desc">The configured subscriptions grouped by their UC&lt;n&gt; prefix &mdash; Total, Server (server-log only), Not seen, Error and OK per use case; tabs for the <strong>Use Case definitions</strong> (who connects, which way the file travels, what triggers it) and the <strong>Use Case patterns</strong> (the accounts grouped by their subscription mix, e.g. <code>UC2 (1) UC4 (1)</code>).</td></tr>\n'
        [ -f "$ADIR/uc2-visits.html" ] && printf '<tr><td><a href="uc2-visits.html">UC2 pickup visits</a></td><td class="desc">What each UC2 partner actually does when it connects: collected, two-way exchange, delivery-only (the UC4 twin) or empty-handed visits.</td></tr>\n'
        [ -f "$ADIR/subscriptions.html" ] && printf '<tr><td><a href="subscriptions.html">Subscriptions</a></td><td class="desc">Every configured subscription on one row: FlowID, use case, account, endpoint, BL tag and the derived Logical / Partner / Domain / Application groups.</td></tr>\n'
        [ -f "$ADIR/accounts.html" ] && printf '<tr><td><a href="accounts.html">Accounts</a></td><td class="desc">The accounts (partners) and their communication profiles &mdash; naming vs configured type/auth, insecure and unrestricted endpoints, conflicting host/whitelist setup, plus account &amp; login integrity checks (non-standard or shared logins, password profiles without a password, and more).</td></tr>\n'
        [ -f "$ADIR/account-sharing.html" ] && printf '<tr><td><a href="account-sharing.html">Account sharing</a></td><td class="desc">Which accounts serve more than one subscription, and in what shape: UC2+UC4 mailbox pairs, UC1+UC3 outbound pairs, fan-outs and both-directions accounts.</td></tr>\n'
        [ -f "$ADIR/twins.html" ] && printf '<tr><td><a href="twins.html">Twins</a></td><td class="desc">Every twin pair on one page: subscriptions that are the same flow configured the opposite way (naming slips highlighted) and the accounts spelled with both separators.</td></tr>\n'
        [ -f "$ADIR/cronjobs.html" ] && printf '<tr><td><a href="cronjobs.html">Cronjobs</a></td><td class="desc">The configured polling schedules (UC3 &mdash; ST pulls from the partner), each Quartz cron expression translated to plain English.</td></tr>\n'
        [ -f "$ADIR/config-hygiene.html" ] && printf '<tr><td><a href="config-hygiene.html">Config hygiene</a></td><td class="desc">The cleanup backlog: likely-duplicate twins (case / separator folds) and orphaned objects nothing references.</td></tr>\n'
        [ -f "$ADIR/whitelist-audit.html" ] && printf '<tr><td><a href="whitelist-audit.html">Whitelist audit</a></td><td class="desc">Whitelisted partner IPs vs the addresses actually connecting: used, connect-only, never seen (prunable), and the sources without any whitelist entry.</td></tr>\n'
        [ -f "$DOCS/transfer/sources-and-targets.html" ] && printf '<tr><td><a href="../transfer/sources-and-targets.html">Sources and Targets</a></td><td class="desc">The From/To folder paths of every subscription (shown &ldquo;path @ host&rdquo; for remote endpoints, like Search): values used as both a source and a target, and sources/targets shared by more than one subscription.</td></tr>\n'
        [ -f "$DOCS/transfer/skipped.html" ] && printf '<tr><td><a href="../transfer/skipped.html">Skipped</a></td><td class="desc">The accounts and subscriptions ignored because their name matches the skip list (<code>input/skip.txt</code>) &mdash; removed from the config and both logs so no report counts them &mdash; plus the skipped transfer/server log-line counts.</td></tr>\n'
        [ -f "$DOCS/transfer/not-in-flow-manager.html" ] && printf '<tr><td><a href="../transfer/not-in-flow-manager.html">Not in Flow Manager</a></td><td class="desc">Every entity value seen in the transfer logs that the current FlowManager configuration does not know &mdash; all eight entity lists checked.</td></tr>\n'
        printf '<tr><td><a href="%s">Cross References</a></td><td class="desc">Every pair of the eight entities cross-tabulated, both ways &mdash; which values appear together on at least one transfer, the configured-but-never-seen pairs flagged.</td></tr>\n' "$(group_home cross)"
        [ -f "$ADIR/cleanup-backlog.html" ] && printf '<tr><td><a href="cleanup-backlog.html">Cleanup backlog</a></td><td class="desc">Every cleanup signal merged into one ranked decommission-candidate list, safest first &mdash; config orphans, never-seen subscriptions, unused whitelist addresses, cron-less polls and long-quiet entities.</td></tr>\n'
        printf '<tr><th colspan="2">Partners</th></tr>\n'
        [ -f "$ADIR/partner-scorecard.html" ] && printf '<tr><td><a href="partner-scorecard.html">Partner scorecard</a></td><td class="desc">One composite health score per partner relation, worst first &mdash; error share, trend, pickup wait, security posture, endpoint redundancy and silence, every component its own column, with the traffic-concentration panel.</td></tr>\n'
        [ -f "$ADIR/blast-radius.html" ] && printf '<tr><td><a href="blast-radius.html">Blast radius</a></td><td class="desc">What stops when a remote host dies: the Files, subscriptions, applications and partners behind every outbound endpoint, sole-endpoint partners flagged.</td></tr>\n'
        [ -f "$ADIR/app-partners.html" ] && printf '<tr><td><a href="app-partners.html">Application dependencies</a></td><td class="desc">Which external partners each internal application exchanges Files with &mdash; the dependency matrix with traffic weights and dead pairs at 100%% Error.</td></tr>\n'
        [ -f "$ADIR/partner-lifecycle.html" ] && printf '<tr><td><a href="partner-lifecycle.html">Partner lifecycle</a></td><td class="desc">The quiet failure modes of a partner relation: configured but never live, gone quiet after real history, and still transferring on ever fewer flows.</td></tr>\n'
        printf '<tr><th colspan="2">Boxes</th></tr>\n'
        [ -f "$ADIR/accounts-in-boxes.html" ] && printf '<tr><td><a href="accounts-in-boxes.html">Accounts in boxes</a></td><td class="desc">Every configured account boxed by what is true of the subscriptions connected to it &mdash; the account view of Subscriptions in boxes, joined through the FlowManager configuration rather than by name.</td></tr>\n'
        [ -f "$ADIR/subscriptions-in-boxes.html" ] && printf '<tr><td><a href="subscriptions-in-boxes.html">Subscriptions in boxes</a></td><td class="desc">Every subscription boxed by what is true of it &mdash; its status (OK, Seen, Not seen, Error, Server log only) or any of fifteen problem signals &mdash; one column per box, each cell linking into its report or entity view.</td></tr>\n'
        [ -f "$ADIR/triage.html" ] && printf '<tr><td><a href="triage.html">Triage</a></td><td class="desc">The ranked action list: every subscription that is red, holds staged Files about to expire, or just fell silent &mdash; newest flips on the busiest flows first; the per-symptom pages stay the deep-dives.</td></tr>\n'
        printf '<tr><th colspan="2">Errors</th></tr>\n'
        [ -f "$ADIR/failed.html" ] && printf '<tr><td><a href="failed.html">Failed Subscriptions</a></td><td class="desc">Every failing subscription with its evidence &mdash; the newest failed File of each (drilling into its transfer legs and server log), plus the flows failing in the server log only; view buttons switch to per-leg-count and full-history views.</td></tr>\n'
        [ -f "$ADIR/failing-reasons.html" ] && printf '<tr><td><a href="failing-reasons.html">Error reasons</a></td><td class="desc">Every possible Reason of the Failed Subscriptions pages &mdash; how many currently red subscriptions carry it and the newest occurrence; a nonzero row opens the red subscriptions behind it.</td></tr>\n'
        printf '<tr><th colspan="2">Acceptance vs production</th></tr>\n'
        # acc-vs-prod is built post-loop (a cross-env report — see the note near
        # the bottom of this script); bin/build.sh always produces it, so link it
        # unconditionally like ANALYSES_MENU and the sitemap already do.
        printf '<tr><td><a href="acc-vs-prod-summary.html">Acceptance vs production</a></td><td class="desc">The two environments&rsquo; entities compared by name, per type &mdash; only in Acceptance, in both (one linked column per environment, with each side&rsquo;s Files/volume), or only in Production &mdash; opening on the Summary.</td></tr>\n'
        printf '</table></div>\n'
        printf '</body>\n</html>\n'
    } > "$out"
}

render_use_case_pages   # docs/use-cases/*.html, before the Use cases table links them
render_first_seen_pages # docs/first-seen/*.html, before the First seen table links them
write_use_cases_page
write_use_case_definitions_page
write_use_case_patterns_page
write_subscriptions_page
write_accounts_page
write_cronjobs_page
write_first_seen_page 1
write_first_seen_page 2
# The Acceptance-vs-production pages are a CROSS-env report — they need BOTH
# env trees complete, which only holds AFTER the per-env loop. So they are NOT
# built here (inside the loop the other env is stale, or absent entirely on a
# fresh build); bin/build.sh runs publish-accvsprod.sh once per env after the
# loop with complete data. To regenerate them standalone, run
# bin/analyses/publish-accvsprod.sh yourself (for each env) after both trees exist.
"$SCRIPT_DIR/publish-insights.sh"    # the insight pages (cronjobs data, whitelist-audit, config-hygiene, expired, the boxes)
# The SUBS_GROUP_REPORTS pages (four Configuration-group reports whose DATA is
# transfer/server but whose PAGES belong here). Rendered from THIS script (not
# the area publishes, which run earlier — the rm -f above would wipe their
# output) and AFTER publish-insights.sh, which renders into the same tree.
render_subs_group_pages

# The Failed Subscriptions VIEW pages (failed-<sel>-<fil>.rpt, written by
# bin/transfer/reports/failed.sh beside the default failed.rpt, which
# render_subs_group_pages just rendered as a Boxes-group member): five
# variants, not in any order — no menu, sitemap or finder entry, reached
# only through the selector row below — rendered as the SAME report: the
# analyses Boxes group row with Failed Subscriptions active (injected after the
# h1, like every subs-group page gets), the "failed" help slug and the
# "failed" search/sort persistence key (like a tabbed report's pages, so a
# typed search survives a view switch).
rm -f "$ADIR"/failed-all-*-data.js   # the retired search-on-demand payloads (2026-08)
_fgrow=$(analyses_group_tabs_ctx "failed.html" analyses) || _fgrow=""
_fsaved_dates=${CUR_DATES:-}; CUR_DATES=$TRANSFER_DATES
for _frpt in "$DATA"/transfer/reports/failed-*.rpt; do
    [ -f "$_frpt" ] || continue
    _fname=${_frpt##*/}; _fname=${_fname%.rpt}
    render_rpt "$_frpt" "$ADIR/$_fname.html" "../assets/style.css" "index.html" \
        "TRANSFER - Failed Subscriptions" 1 "failed" "failed"
    [ -n "$_fgrow" ] && _inject_after_h1 "$ADIR/$_fname.html" "$_fgrow"
done
CUR_DATES=$_fsaved_dates

# The Error reasons DRILL pages (failing-reasons-<slug>.rpt, one per reason
# with currently red subscriptions): rendered like the Failed Subscriptions
# variants — the Errors group row with Error reasons active, the
# "failing-reasons" help slug and persistence key. The main page renders via
# render_subs_group_pages (analyses:failing-reasons).
_ergrow=$(analyses_group_tabs_ctx "failing-reasons.html" analyses) || _ergrow=""
_ersaved_dates=${CUR_DATES:-}; CUR_DATES=$TRANSFER_DATES
for _errpt in "$ARPT"/failing-reasons-*.rpt; do
    [ -f "$_errpt" ] || continue
    _ername=${_errpt##*/}; _ername=${_ername%.rpt}
    render_rpt "$_errpt" "$ADIR/$_ername.html" "../assets/style.css" "index.html" \
        "ANALYSES - Error reasons" 1 "failing-reasons" "failing-reasons"
    [ -n "$_ergrow" ] && _inject_after_h1 "$ADIR/$_ername.html" "$_ergrow"
done
CUR_DATES=$_ersaved_dates

# THE VIEW SELECTOR ROW on the four Error reasons mains (the failed pages'
# undertabs pattern — this page has no date fields, so the row simply sits
# above the table). Two groups, a tabsep gap between: the UNIT
# (Subscriptions = flows counted once / Errors = every failed File) and the
# SCOPE (Current = the still-failing estate / History = everything ever) —
# switching one keeps the other, the default (Subscriptions x Current)
# being failing-reasons.html itself.
_frpage() {   # $1 unit (subs|errors)  $2 scope (current|history) -> page basename
    case "$1-$2" in
        subs-current)   echo "failing-reasons.html" ;;
        subs-history)   echo "failing-reasons-history.html" ;;
        errors-current) echo "failing-reasons-errors.html" ;;
        errors-history) echo "failing-reasons-errors-history.html" ;;
    esac
}
for _fru in subs errors; do
    for _frsc in current history; do
        _frf="$ADIR/$(_frpage "$_fru" "$_frsc")"
        [ -f "$_frf" ] || continue
        _frrow='<p class="tabs undertabs">'
        for _frs in subs:Subscriptions errors:Errors; do
            _frk=${_frs%%:*}; _frl=${_frs#*:}
            if [ "$_frk" = "$_fru" ]; then _frrow+="<span class=\"tab active\">$_frl</span>"
            else _frrow+="<a class=\"tab\" href=\"$(_frpage "$_frk" "$_frsc")\">$_frl</a>"; fi
        done
        _frrow+='<span class="tabsep"></span>'
        for _frs in current:Current history:History; do
            _frk=${_frs%%:*}; _frl=${_frs#*:}
            if [ "$_frk" = "$_frsc" ]; then _frrow+="<span class=\"tab active\">$_frl</span>"
            else _frrow+="<a class=\"tab\" href=\"$(_frpage "$_fru" "$_frk")\">$_frl</a>"; fi
        done
        _frrow+='</p>'
        _inject_before_table "$_frf" "$_frrow"
    done
done

# THE VIEW SELECTOR ROW, injected into all six Failed Subscriptions pages BELOW
# the From/To date controls (report.js hoists its controls anchor back over a
# p.tabs.undertabs row, so the baked tablewrap-adjacent row comes out
# controls -> row -> table). Two button groups in one row, a tabsep gap
# between: the SELECTION (All / Subscription) and the
# FILTER (All / Still failing) — switching one keeps the other, each
# combination its own page, the default (Subscription x Still failing) being
# failed.html itself.
_fpage() {   # $1 sel  $2 fil -> page basename
    if [ "$1" = sub ] && [ "$2" = failing ]; then echo "failed.html"
    else echo "failed-$1-$2.html"; fi
}
for _fsel in all sub; do
    for _ffil in failing all; do
        _ff="$ADIR/$(_fpage "$_fsel" "$_ffil")"
        [ -f "$_ff" ] || continue
        _frow='<p class="tabs undertabs">'
        for _fs in all:All sub:Subscription; do
            _fk=${_fs%%:*}; _flbl=${_fs#*:}
            if [ "$_fk" = "$_fsel" ]; then _frow+="<span class=\"tab active\">$_flbl</span>"
            else _frow+="<a class=\"tab\" href=\"$(_fpage "$_fk" "$_ffil")\">$_flbl</a>"; fi
        done
        _frow+='<span class="tabsep"></span>'
        for _fs in "all:All" "failing:Still failing"; do
            _fk=${_fs%%:*}; _flbl=${_fs#*:}
            if [ "$_fk" = "$_ffil" ]; then _frow+="<span class=\"tab active\">$_flbl</span>"
            else _frow+="<a class=\"tab\" href=\"$(_fpage "$_fsel" "$_fk")\">$_flbl</a>"; fi
        done
        _frow+='</p>'
        _inject_before_table "$_ff" "$_frow"
    done
done

# The SIX File search pages (2026-08): one per window x outcome
# (48-hours/week/month x errors/ok), each with its OWN data file. Since the
# compact v2 payload (2026-08) the report script writes the sidecar itself
# (file-search-<key>-data.js, dictionary-coded data — ~95 B/row where the
# lifted <tr> markup ran 300-525 B/row): the .rpt renders an EMPTY table and
# this block copies the sidecar beside the page, injecting its tag AND the
# DEDICATED engine docs/assets/file-search.js (a Search button, the NAV row
# carrying ?q= between the windows), each with its own cksum ?v=, before
# report.js (defer order). CUR_DATES cleared: no date filter; DLINK_BASE for
# any residual site cell.
rm -f "$DOCS/file-search.html" "$DOCS/file-search-data.js"
# the 2026-08 Errors/OK page pair — swept so no stale twin survives the merge
for _fs_k in 48-hours-errors 48-hours-ok week-errors week-ok 2-weeks-errors 2-weeks-ok 3-weeks-errors 3-weeks-ok month-errors month-ok; do
    rm -f "$DOCS/file-search-$_fs_k.html" "$DOCS/file-search-$_fs_k-data.js"
done
_fs_n=0
_fs_jsv=$(cksum < docs/assets/file-search.js 2>/dev/null | awk '{print $1}')   # publish_lib cd'd to the repo root
for _fs_k in 24-hours 48-hours week 2-weeks 3-weeks month; do
    if [ ! -f "$ARPT/file-search-$_fs_k.rpt" ] || [ ! -f "$ARPT/file-search-$_fs_k-data.js" ]; then
        rm -f "$DOCS/file-search-$_fs_k.html" "$DOCS/file-search-$_fs_k-data.js"
        continue
    fi
    _fs_sd=${CUR_DATES:-}; CUR_DATES=""; _fs_dl=${DLINK_BASE:-}; DLINK_BASE="details/"
    render_rpt "$ARPT/file-search-$_fs_k.rpt" "$DOCS/file-search-$_fs_k.html" "assets/style.css" "index.html" \
        "ANALYSES - File search" 1 "file-search" "file-search-$_fs_k"
    DLINK_BASE=$_fs_dl; CUR_DATES=$_fs_sd
    cp "$ARPT/file-search-$_fs_k-data.js" "$DOCS/file-search-$_fs_k-data.js"
    _fs_dver=$(cksum < "$DOCS/file-search-$_fs_k-data.js" | awk '{print $1}')
    awk -v d="<script src=\"file-search-$_fs_k-data.js?v=$_fs_dver\" defer></script>" \
        -v e="<script src=\"../assets/file-search.js?v=$_fs_jsv\" defer></script>" \
        '/<script src=[^>]*report\.js/ && !done { print d; print e; done = 1 } { print }' \
        "$DOCS/file-search-$_fs_k.html" > "$DOCS/file-search-$_fs_k.html.tmp.$$" \
        && mv "$DOCS/file-search-$_fs_k.html.tmp.$$" "$DOCS/file-search-$_fs_k.html"
    _fs_n=$((_fs_n + 1))
done
[ "$_fs_n" -gt 0 ] && echo "Wrote $_fs_n File search page(s) (+ per-page data files)." >&2
write_analyses_index

echo "Wrote docs/analyses (index + the analysis pages)." >&2

publish_stamp "$STAMP"
