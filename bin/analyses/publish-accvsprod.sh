#!/usr/bin/env bash
#
# bin/analyses/publish-accvsprod.sh — render the Acceptance-vs-production
# pages (docs/<env>/analyses/acc-vs-prod-<type>-<view>.html) for the CURRENT
# env (AXWAY_ENV). Split out of bin/analyses/publish.sh because the pages
# compare BOTH env trees: bin/build.sh reruns this for each env AFTER the
# env-major loop (before crosslink), so each copy sees the other env's
# COMPLETE data — inside the loop the acceptance pass would read
# production's previous build, or nothing at all on a fresh build.
# bin/analyses/publish.sh still calls it in-loop so the pages exist when the
# analyses index checks for them. No arguments; runs from any directory.
#
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../publish_lib.sh"   # cd's to the repo root; html_head/…

# an env that was never published (no FM exports -> build skipped it) gets no pages
[ -d "$DOCS/analyses" ] || { echo "publish-accvsprod: $DOCS/analyses does not exist; skipping." >&2; exit 0; }
ADIR="$DOCS/analyses"

# It compares BOTH env trees, and its pages live in a dir the analyses publish
# CLEARS — so the two .publish stamp dirs are a dep as well as the data it
# reads (each env's detail slugmaps, entity .rpt and base caches).
STAMP="$PUBLISH_STAMP_DIR/accvsprod.stamp"
if [ -n "$(find "$ADIR" -name 'acc-vs-prod-*.html' -print -quit 2>/dev/null)" ] \
   && publish_is_fresh "$STAMP" "$ADIR" "${BASH_SOURCE[0]}" \
       $(publish_area_stamps) \
       data/acceptance/transfer/reports data/production/transfer/reports \
       data/acceptance/flow-manager/base data/production/flow-manager/base \
       data/acceptance/flow-manager/xref data/production/flow-manager/xref; then
    echo "docs/$SITE_ENV/analyses/acc-vs-prod-* is up to date; skipping." >&2
    exit 0
fi

# ---- Acceptance vs production (docs/analyses/acc-vs-prod-<type>-<view>.html) --
# The two environments' entity name sets compared per type — the comprehensive
# detail-page slugmaps, so every configured OR logged name counts. Three views:
# Only acceptance / Both / Only production; the Both view shows one column per
# environment, EACH cell linked to that env's own detail page and tinted by
# that env's result (td.res-*); the single-env views tint the whole row
# (tr[data-res]) from that env's base caches. Names are matched case aside;
# each column shows its env's own spelling. NOTE each env's copy is generated
# in that env's publish pass, reading the OTHER env's caches as they are on
# disk — in a full build the production copy is fully fresh and the acceptance
# copy sees production's previous build (self-heals every build).
# The home page's two status tables (Flow manager entities & Partners,
# Domains & Applications) for one env, EXTRACTED from the rendered
# home itself — the summary must carry the same figures and the same links
# (parity by construction, like check_status_consistency proves it for the
# home), so the block is lifted verbatim and only the hrefs are re-rooted
# from the docs root to this page's depth (docs/<env>/analyses/). Following
# a link therefore switches to that figure's own environment. The
# "including server log" toggle keeps working: report.js binds every
# button.srvtoggle on any page. A missing/older home (the in-loop call on a
# fresh build) renders nothing here — the post-barrier rerun self-heals,
# like the rest of this script.
_home_status_block() {   # $1 = acceptance | production
    [ -f "docs/index.html" ] || return 0
    awk -v env="$1" '
        !inblk && index($0, "<div class=\"envblock env-" env "\"") { inblk=1; next }
        inblk && !insxs {
            if (index($0, "<div class=\"sxs\">")) { insxs=1 } else next
        }
        insxs {
            depth += gsub(/<div/, "<div") - gsub(/<\/div>/, "</div>")
            gsub(/href="/, "href=\"../../")
            # the env name is PREPENDED to the table titles (2026-08-29: the
            # home titles lost their Axway:/Achmea: prefixes, so there is
            # nothing to replace any more — the summary still needs to say
            # whose figures a table shows)
            envcap = (env == "acceptance") ? "Acceptance" : "Production"
            sub(/class="h2row">Flow manager entities/, "class=\"h2row\">" envcap ": Flow manager entities")
            sub(/class="h2row">Partners, Domains/, "class=\"h2row\">" envcap ": Partners, Domains")
            print
            if (depth <= 0) exit
        }
    ' docs/index.html
}

write_acc_vs_prod_pages() {
    # whitelist: NO detail pages/slugmap — the name set is each env's
    # base/_white.tsv itself (NOSLUG mode below: unlinked cells, IPv4 keys
    # padded so addresses compare and sort in address order)
    # flowids (2026-08-30, user request): the customAttribute_FlowIdentifier
    # VALUES of each env's subscriptions.json, read from the config cache
    # base/_profiles.tsv — the ONE page family where a profile surfaces (the
    # CLAUDE.md transfer-profile gotcha names this exception). NOSLUG like the
    # whitelist (no detail pages), name-only (no activity report) and untinted
    # (the profiles' result column stays "unknown").
    local types=(accounts subscriptions logins hosts partners domains applications whitelist flowids)
    local labels=("Accounts" "Subscriptions" "Logins" "Hosts" "Partners" "Domains" "Applications" "Whitelist" "FlowID")
    local bases=(_accounts _subscriptions _logins _hosts _partners _domains _apps _white _profiles)
    # ACTIVITY per env: each name's Files/Volume from that env's entity summary
    # .rpt (first-table ROWs — the same source ranking.sh lifts from), matched
    # case aside. Whitelist (no entity report) has no activity source and keeps
    # the name-only layout.
    local rpts=(account subscription login remote-host partner domain application "" "")
    # difference (2026-08-29): the Only-acceptance and Only-production sets
    # side by side as two independent name-sorted columns of ONE table — the
    # promotion diff at a glance. Its tab sits AFTER Summary in the view row.
    local views=(acceptance both production difference)
    local vlabels=("Only ACC" "Both" "Only PRD" "Difference")
    # the FAMILY NAV (2026-08-30, user choice): row 1 everywhere is
    # Summary / Entities / Subscriptions vs partners; the type row (this
    # order) and the view row show ONLY inside Entities, whose landing —
    # and the view row's default — is Subscriptions at the Both view.
    local taborder=(subscriptions flowids accounts logins hosts partners domains applications whitelist)
    local ent_home="acc-vs-prod-subscriptions-both.html"
    local ti vi tj t v tmp na nb np am pm ab pb trow vrow vl out
    local sumtmp; sumtmp=$(mktemp)   # per-type counts + active-name lists for the Summary page
    # no slugmaps at all (fresh clone before the transfer reports) -> no pages
    [ -d "data/acceptance/transfer/reports/details" ] || [ -d "data/production/transfer/reports/details" ] || return 0
    tmp=$(mktemp)
    for ti in "${!types[@]}"; do
        t=${types[$ti]}
        am="data/acceptance/transfer/reports/details/$t/_slugmap.tsv"; [ -f "$am" ] || am=""
        pm="data/production/transfer/reports/details/$t/_slugmap.tsv"; [ -f "$pm" ] || pm=""
        ab="data/acceptance/flow-manager/base/${bases[$ti]}.tsv"; [ -f "$ab" ] || ab=""
        pb="data/production/flow-manager/base/${bases[$ti]}.tsv"; [ -f "$pb" ] || pb=""
        local ar="" pr=""
        if [ -n "${rpts[$ti]}" ]; then
            ar="data/acceptance/transfer/reports/${rpts[$ti]}.rpt"; [ -f "$ar" ] || ar=""
            pr="data/production/transfer/reports/${rpts[$ti]}.rpt"; [ -f "$pr" ] || pr=""
        elif [ "$t" = whitelist ]; then
            # the whitelist has no entity report; its activity is the per-IP
            # inbound Files sidecar showseen.sh writes (ip<TAB>Files,
            # coverage/whitelist-files.tsv — 2026-08-29), so the dormancy
            # split works for it like for every other type
            ar="data/acceptance/transfer/reports/coverage/whitelist-files.tsv"; [ -f "$ar" ] || ar=""
            pr="data/production/transfer/reports/coverage/whitelist-files.tsv"; [ -f "$pr" ] || pr=""
        fi
        local hasact=0; { [ -n "$ar" ] || [ -n "$pr" ]; } && hasact=1
        local noslug=0; case $t in whitelist|flowids) noslug=1 ;; esac
        # whitelist only: NOSLUG rows order by result color first; flowids —
        # the other NOSLUG type — has no result and keeps plain name order
        local csort=0; [ "$t" = whitelist ] && csort=1
        # _/- SEPARATOR FOLD (2026-08-29, user decision — THIS report family
        # only; site-wide the separator stays an identity): the two envs
        # spell one flow's name with _ or - interchangeably, so the cross-env
        # match folds - onto _ (on top of the case fold) and every name
        # DISPLAYS in the _ spelling; links keep each env's own raw slug.
        # NOT for hosts (DNS names — the hyphen is the real character) or
        # whitelist (IP addresses).
        local fold=1; case $t in hosts|whitelist) fold=0 ;; esac
        # one line per name (case- and separator-folded): cls a|b|p, KEY,
        # acceptance name/slug/result, production name/slug/result, then the
        # activity columns: acceptance files/volume, production files/volume
        awk -v OFS='\t' -v AM="$am" -v PM="$pm" -v AB="$ab" -v PB="$pb" -v NOSLUG="$noslug" -v CSORT="$csort" -v AR="$ar" -v PR="$pr" -v FOLD="$fold" '
            function sepfold(v) { if (FOLD) gsub(/-/, "_", v); return v }   # the DISPLAY spelling: every - shown as _
            function nkey(v) { return toupper(sepfold(v)) }                # the MATCH key: case + separator folded
            function padkey(v,   o) {   # IPv4 -> zero-padded octets (address order); else UPPER
                if (v ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) { split(v, o, "."); return sprintf("%03d%03d%03d%03d", o[1], o[2], o[3], o[4]) }
                return toupper(v)
            }
            # the NOSLUG key: padkey for the whitelist (FOLD=0 — addresses),
            # nkey for flowids (FOLD=1 — the same fold the linked types use)
            function lkey(v) { return FOLD ? nkey(v) : padkey(v) }
            function load(map, f,   l, a) { if (f == "") return
                while ((getline l < f) > 0) { split(l, a, "\t"); if (a[1] != "") map[nkey(a[1])] = a[1] "\t" a[2] }
                close(f) }
            # NOSLUG (whitelist, flowids): the base cache IS the name list — no slug
            function loadnames(map, f,   l, a) { if (f == "") return
                while ((getline l < f) > 0) { split(l, a, "\t"); if (a[1] != "") map[lkey(a[1])] = a[1] "\t" }
                close(f) }
            function loadres(map, f,   l, a) { if (f == "") return
                while ((getline l < f) > 0) { split(l, a, "\t"); if (a[1] != "") map[NOSLUG ? lkey(a[1]) : nkey(a[1])] = a[3] }
                close(f) }
            # the env entity summary .rpt: first-table ROWs -> Files ($3) and
            # the humanized Volume ($6) per folded name key. Files SUM on a
            # key collision (two separator spellings in one env are one
            # entity for this comparison); Volume keeps last-wins — it is no
            # longer rendered (the column was removed 2026-08-29).
            function loadact(fm, vm, f,   l, a, tc, k2) { if (f == "") return
                tc = 0
                while ((getline l < f) > 0) { split(l, a, "\t")
                    if (a[1] == "TABLE") { tc++; if (tc > 1) break }
                    if (tc == 1 && a[1] == "ROW" && a[2] != "") { k2 = nkey(a[2])
                        if (a[3] != "") fm[k2] += a[3] + 0
                        vm[k2] = a[6] } }
                close(f) }
            # NOSLUG (whitelist) activity: the 2-column ip<TAB>Files sidecar,
            # keyed like the name maps (padkey — address order)
            function loadwl(fm, f,   l, a) { if (f == "") return
                while ((getline l < f) > 0) { split(l, a, "\t")
                    if (a[1] != "" && a[2] != "") fm[padkey(a[1])] += a[2] + 0 }
                close(f) }
            BEGIN {
                if (NOSLUG) { loadnames(A, AB); loadnames(P, PB); loadwl(AF, AR); loadwl(PF, PR) }
                else { load(A, AM); load(P, PM); loadact(AF, AV, AR); loadact(PF, PV, PR) }
                loadres(RA, AB); loadres(RP, PB)
                for (k in A) seen[k] = 1
                for (k in P) seen[k] = 1
                for (k in seen) {
                    cls = (k in A) ? ((k in P) ? "b" : "a") : "p"
                    na = ns = pn = ps = ""
                    if (k in A) { split(A[k], aa, "\t"); na = aa[1]; ns = aa[2] }
                    if (k in P) { split(P[k], pp, "\t"); pn = pp[1]; ps = pp[2] }
                    # CSORT (whitelist): rows order by RESULT color — red,
                    # green, blue, orange (unknown last) — then address order
                    sk = k
                    if (CSORT) { r5 = (cls == "p") ? RP[k] : RA[k]
                        sk = ((r5 == "red") ? 0 : (r5 == "green") ? 1 : (r5 == "blue") ? 2 : (r5 == "orange") ? 3 : 4) k }
                    # display in the _ spelling (sepfold; raw for hosts/IPs);
                    # the slugs stay each env raw ones, so links keep working.
                    # Activity is keyed on the SAME folded key as the maps.
                    print cls, sk, sepfold(na), ns, RA[k], sepfold(pn), ps, RP[k], (k in AF ? AF[k] : ""), AV[k], (k in PF ? PF[k] : ""), PV[k]
                }
            }' /dev/null | LC_ALL=C sort -t"$(printf '\t')" -k2,2 > "$tmp"
        na=$(grep -c $'^a\t' "$tmp" || true)
        nb=$(grep -c $'^b\t' "$tmp" || true)
        np=$(grep -c $'^p\t' "$tmp" || true)
        # Summary feed: dormancy split of the Both set (active in exactly one
        awk -F'\t' -v OFS='\t' -v T="$t" -v HASACT="$hasact" '
            $1 == "b" { if (HASACT) { if ($9 > 0 && $11 + 0 == 0) ba++; else if ($11 > 0 && $9 + 0 == 0) bp++; else if ($9 > 0 && $11 > 0) bb++ } }
            END { print "SUM", T, (HASACT ? ba+0 : "-"), (HASACT ? bp+0 : "-"), (HASACT ? bb+0 : "-") }
        ' "$tmp" >> "$sumtmp"
        echo "CNT|$t|$na|$nb|$np" >> "$sumtmp"
        for vi in "${!views[@]}"; do
            v=${views[$vi]}
            out="$ADIR/acc-vs-prod-$t-$v.html"
            # ROW 1 (2026-08-30): Summary / Entities / Subscriptions vs
            # partners — Entities is the ACTIVE one on every per-type page
            trow="<a class=\"tab\" href=\"acc-vs-prod-summary.html\">Summary</a>"
            trow+="<span class=\"tab active\">Entities</span>"
            trow+="<a class=\"tab\" href=\"acc-vs-prod-subs-partners.html\">Subscriptions vs partners</a>"
            # ROW 2 (Entities only): the entity types in the taborder, the
            # current one active; switching type KEEPS the current view
            erow=""
            for t2 in "${taborder[@]}"; do
                for t2i in "${!types[@]}"; do [ "${types[$t2i]}" = "$t2" ] && break; done
                if [ "$t2" = "$t" ]; then erow+="<span class=\"tab active\">${labels[$t2i]}</span>"
                else erow+="<a class=\"tab\" href=\"acc-vs-prod-$t2-$v.html\">${labels[$t2i]}</a>"; fi
            done
            vrow=""
            for tj in 0 1 2; do
                vl="${vlabels[$tj]}"   # plain labels — no counts on the view buttons (2026-08-29)
                if [ "$tj" = "$vi" ]; then vrow+="<span class=\"tab active\">$vl</span>"
                else vrow+="<a class=\"tab\" href=\"acc-vs-prod-$t-${views[$tj]}.html\">$vl</a>"; fi
            done
            if [ "$v" = difference ]; then vrow+="<span class=\"tab active\">${vlabels[3]}</span>"
            else vrow+="<a class=\"tab\" href=\"acc-vs-prod-$t-difference.html\">${vlabels[3]}</a>"; fi
            {
                html_head "Acceptance vs production" "../assets/style.css" "" "ANALYSES" "acc-vs-prod"
                printf '<h1>Acceptance vs production</h1>\n'
                local actnote="" foldnote=""
                [ "$hasact" = 1 ] && actnote=" The Files column shows each environment's own logged activity over its data window — a name in both environments that is busy in one and blank in the other is dormant there."
                [ "$fold" = 1 ] && foldnote=" The <code>_</code> and <code>-</code> separators are treated as the same character: names are matched across the environments ignoring the difference and are all shown in the <code>_</code> spelling (each link still opens that environment's own page)."
                # The button rows go DIRECTLY under the <h1>, above the prose —
                # navigation first, everywhere on the site (see the group tab
                # bar rule in CLAUDE.md). This family carries its own type/view
                # rows instead of a _analyses_groups row, but the position rule
                # is the same.
                printf '<p class="tabs">%s</p>\n' "$trow"
                printf '<p class="tabs">%s</p>\n' "$erow"
                printf '<p class="tabs">%s</p>\n' "$vrow"
                # flowids: its own subtitle — configured-only (no logged
                # names), no row colors and no links, so the standard text
                # would promise what these rows do not have
                if [ "$t" = flowids ]; then
                    # its own fold note too: the shared one promises links
                    printf '<p class="subtitle">The FlowIDs known to each environment — the <code>customAttribute_FlowIdentifier</code> values of its configured subscriptions: only in Acceptance, in both, or only in Production. A flow&#8217;s UC subscriptions share one FlowID, so this compares the environments by flow rather than by subscription. The <code>_</code> and <code>-</code> separators are treated as the same character: names are matched across the environments ignoring the difference and are all shown in the <code>_</code> spelling.</p>\n'
                else
                    printf '<p class="subtitle">The %s known to each environment (configured or logged, matched by name): only in Acceptance, in both, or only in Production. Row colors are the standard entity results; in the Both view each column links and tints its own environment.%s%s</p>\n' "${labels[$ti]}" "$foldnote" "$actnote"
                fi
                printf '<div class="tablewrap"><table class="fit">\n'
                if [ "$hasact" = 1 ]; then
                    if [ "$v" = both ] || [ "$v" = difference ]; then
                        printf '<tr><th>Acceptance</th><th class="num">Files</th><th>Production</th><th class="num">Files</th></tr>\n'
                    else
                        printf '<tr><th>%s</th><th class="num">Files</th></tr>\n' "${labels[$ti]}"
                    fi
                elif [ "$t" = flowids ] && [ "$v" = both ]; then
                    # ONE column (2026-08-30, user request): a FlowID in the
                    # Both set is the SAME string on both sides — no slug, no
                    # tint, both displayed in the folded `_` spelling — so two
                    # identical columns said nothing
                    printf '<tr><th>FlowID</th></tr>\n'
                elif [ "$v" = both ] || [ "$v" = difference ]; then
                    printf '<tr><th>Acceptance</th><th>Production</th></tr>\n'
                else
                    printf '<tr><th>%s</th></tr>\n' "${labels[$ti]}"
                fi
                onecol=0; [ "$t" = flowids ] && onecol=1
                awk -F'\t' -v view="$v" -v sub2="$t" -v hasact="$hasact" -v onecol="$onecol" '
                    function e(s) { gsub(/&/, "\\&amp;", s); gsub(/</, "\\&lt;", s); gsub(/>/, "\\&gt;", s); gsub(/"/, "\\&quot;", s); return s }
                    function isres(r) { return r == "green" || r == "orange" || r == "red" || r == "blue" }
                    function cell(env, name, slug, res,   cls, inner) {
                        inner = e(name)
                        if (slug != "") inner = "<a href=\"../../" env "/details/" sub2 "/" slug ".html\">" inner "</a>"
                        cls = "cl"; if (isres(res)) cls = cls " res-" res
                        return "<td class=\"" cls "\">" inner "</td>"
                    }
                    # the ACTIVITY cell (Files) of one env; a name with no
                    # logged activity in that env renders blank (the Volume
                    # column was removed 2026-08-29)
                    function act(f) {
                        if (!hasact) return ""
                        return "<td class=\"num\">" e(f) "</td>"
                    }
                    view == "acceptance" && $1 == "a" {
                        printf "<tr%s>%s%s</tr>\n", (isres($5) ? " data-res=\"" $5 "\"" : ""), cell("acceptance", $3, $4, ""), act($9); af += $9; n++ }
                    view == "production" && $1 == "p" {
                        printf "<tr%s>%s%s</tr>\n", (isres($8) ? " data-res=\"" $8 "\"" : ""), cell("production", $6, $7, ""), act($11); pf += $11; n++ }
                    view == "both" && $1 == "b" {
                        # onecol (flowids): the one shared spelling, once
                        if (onecol) printf "<tr>%s</tr>\n", cell("acceptance", $3, $4, $5)
                        else printf "<tr>%s%s%s%s</tr>\n", cell("acceptance", $3, $4, $5), act($9), cell("production", $6, $7, $8), act($11)
                        af += $9; pf += $11; n++ }
                    # difference: ONE ROW PER NAME — an entity exists in only
                    # ONE environment here, so its row fills only that side
                    # (the other column stays empty). The input stream is
                    # globally name-sorted, so the rows interleave in one
                    # alphabet, each name at its proper position.
                    view == "difference" && $1 == "a" { nA++; af += $9
                        printf "<tr>%s%s<td class=\"cl\"></td>%s</tr>\n", cell("acceptance", $3, $4, $5), act($9), (hasact ? "<td class=\"num\"></td>" : "") }
                    view == "difference" && $1 == "p" { nP++; pf += $11
                        printf "<tr>%s%s%s%s</tr>\n", "<td class=\"cl\"></td>", (hasact ? "<td class=\"num\"></td>" : ""), cell("production", $6, $7, $8), act($11) }
                    END {
                        if (view == "difference") {
                            if (hasact)
                                printf "<tr class=\"total\"><td>Total (%d / %d)</td><td class=\"num\">%d</td><td></td><td class=\"num\">%d</td></tr>\n", nA + 0, nP + 0, af, pf
                            else
                                printf "<tr class=\"total\"><td>Total (%d / %d)</td><td></td></tr>\n", nA + 0, nP + 0
                            exit
                        }
                        if (!hasact) { printf "<tr class=\"total\"><td>Total (%d)</td>%s</tr>\n", n + 0, (view == "both" && !onecol ? "<td></td>" : ""); exit }
                        if (view == "both")
                            printf "<tr class=\"total\"><td>Total (%d)</td><td class=\"num\">%d</td><td></td><td class=\"num\">%d</td></tr>\n", n + 0, af, pf
                        else
                            printf "<tr class=\"total\"><td>Total (%d)</td><td class=\"num\">%d</td></tr>\n", n + 0, (view == "acceptance" ? af : pf)
                    }' "$tmp"
                printf '</table></div>\n'
                [ "$t" = flowids ] || printf '<p class="range">Row colors: <strong>light green</strong> = last transfer OK &middot; <strong>light orange</strong> = configured but never seen &middot; <strong>light red</strong> = last transfer Error (or server-log errors after it) &middot; <strong>light blue</strong> = seen in the server log only. An untinted name was logged but is not configured.</p>\n'
                printf '</body>\n</html>\n'
            } > "$out"
        done
    done
    rm -f "$tmp"

    # ---- the Summary page (acc-vs-prod-summary.html): the home status tables of both envs + the per-type set/dormancy figures
    # Per type the three set sizes plus the Both set's ACTIVITY split (busy in
    # both / busy in exactly one env = dormant in the other). The group's
    # DEFAULT page (2026-08-29): the Analyses menu, index card and finder land
    # here. (The two promotion-gap tables were removed the same day — the
    # Difference view carries the full only-sets per type.)
    out="$ADIR/acc-vs-prod-summary.html"
    {
        html_head "Acceptance vs production" "../assets/style.css" "" "ANALYSES" "acc-vs-prod"
        printf '<h1>Acceptance vs production — summary</h1>\n'
        # ROW 1 only (2026-08-30): Summary ACTIVE / Entities (landing on the
        # default Subscriptions-Both view) / Subscriptions vs partners — the
        # type and view rows show only inside Entities.
        trow="<span class=\"tab active\">Summary</span>"
        trow+="<a class=\"tab\" href=\"$ent_home\">Entities</a>"
        trow+="<a class=\"tab\" href=\"acc-vs-prod-subs-partners.html\">Subscriptions vs partners</a>"
        printf '<p class="tabs">%s</p>\n' "$trow"
        # (no subtitle — removed 2026-08-29 with the "Per type" heading and
        # the activity foot note: the summary is tables only)
        # the HOME status tables of both environments lead the page (2026-08-29):
        # the same figures and the same links as the home — a link opens that
        # environment's own view, so following one can switch the environment.
        # CONDENSED: no standalone env headings — the env name rides in the
        # table titles themselves (prepended to the home titles)
        _home_status_block acceptance
        _home_status_block production
        # data-nosort: the row order is PRESCRIBED (sumorder below), and a
        # remembered column sort — stored per ENV — made the two env copies
        # of this one logical page show different sequences (2026-08-29)
        printf '<h2>Per entity</h2>\n<div class="tablewrap"><table class="fit" data-nosort="1">\n'
        printf '<tr><th>Type</th><th class="num gsepw">ACC</th><th class="num">PRD</th><th class="num gsepw">Only ACC</th><th class="num">Both</th><th class="num">Only PRD</th><th class="num gsepw">Both: active acc only</th><th class="num">Both: active in both</th><th class="num">Both: active prod only</th></tr>\n'
        # the Per-entity ROW order (2026-08-29, user choice; FlowID after
        # Subscriptions 2026-08-30) — independent of the types[] array, which
        # keeps driving the pages and the tab row
        local sumorder=(subscriptions flowids partners accounts logins hosts domains applications whitelist)
        for t in "${sumorder[@]}"; do
            for ti in "${!types[@]}"; do [ "${types[$ti]}" = "$t" ] && break; done
            awk -F'\t' -v FS2='|' -v T="$t" -v LBL="${labels[$ti]}" '
                function e(s) { gsub(/&/, "\\&amp;", s); gsub(/</, "\\&lt;", s); gsub(/>/, "\\&gt;", s); return s }
                # a zero renders as an EMPTY cell (2026-08-29); "-" (whitelist:
                # no activity data) stays a dash
                function z(v) { return (v + 0 == 0) ? "" : v }
                function nz(v) { return (v == "" || v == "-") ? "-" : z(v) }
                # every FILLED cell opens the per-type page nearest its figure
                # (2026-08-30): the env totals and only-sets their side'\''s view,
                # the Both set and its activity split the Both view; an empty
                # or dashed cell stays inert, the home-table convention
                function lc(cls, v, view) {
                    if (v == "" || v == "-") return "<td class=\"" cls "\">" v "</td>"
                    return "<td class=\"" cls "\"><a href=\"acc-vs-prod-" T "-" view ".html\">" v "</a></td>"
                }
                $1 == "SUM" && $2 == T { ba = $3; bp = $4; bb = $5 }
                index($0, "CNT|" T "|") == 1 { split($0, c, "|"); na = c[3]; nb = c[4]; np = c[5] }
                END { printf "<tr><td><a href=\"acc-vs-prod-%s-both.html\">%s</a></td>%s%s%s%s%s%s%s%s</tr>\n", \
                    T, e(LBL), \
                    lc("num gsepw", z(na+nb), "acceptance"), lc("num", z(nb+np), "production"), \
                    lc("num gsepw", z(na+0), "acceptance"), lc("num", z(nb+0), "both"), lc("num", z(np+0), "production"), \
                    lc("num gsepw", nz(ba), "both"), lc("num", nz(bb), "both"), lc("num", nz(bp), "both") }
            ' "$sumtmp"
        done
        printf '</table></div>\n'

        # (the two promotion-gap tables — "Untestable" and "Never promoted" —
        # were REMOVED 2026-08-29 on request; the Difference view carries the
        # full only-sets per type)
        printf '</body>\n</html>\n'
    } > "$out"
    rm -f "$sumtmp"
    echo "Wrote the Acceptance-vs-production pages to $ADIR." >&2
}

# ---- Subscriptions vs partners (acc-vs-prod-subs-partners.html, 2026-08-29):
# the subscriptions present in BOTH environments (matched like the rest of
# the family: case + separator folded) whose PARTNER sets differ between
# the environments, with each environment's own partner(s) and account(s).
# Sets compare on the folded partner names; every name links its own
# environment's detail page. The audit's finding 6 context: a differing
# partner here can be a real configuration difference OR the per-env
# partner-group naming (one merged group vs two single groups).
write_subs_partners_page() {
    local asm="data/acceptance/transfer/reports/details/subscriptions/_slugmap.tsv"
    local psm="data/production/transfer/reports/details/subscriptions/_slugmap.tsv"
    [ -f "$asm" ] && [ -f "$psm" ] || return 0
    local out="$ADIR/acc-vs-prod-subs-partners.html"
    # ROW 1 only (2026-08-30): Summary / Entities (the default
    # Subscriptions-Both landing) / Subscriptions vs partners ACTIVE — the
    # type and view rows show only inside Entities.
    local trow="<a class=\"tab\" href=\"acc-vs-prod-summary.html\">Summary</a>"
    trow+="<a class=\"tab\" href=\"acc-vs-prod-subscriptions-both.html\">Entities</a>"
    trow+="<span class=\"tab active\">Subscriptions vs partners</span>"
    local rows; rows=$(mktemp)
    awk -v OFS='\t' \
        -v ASM="$asm" -v PSM="$psm" \
        -v APX="data/acceptance/flow-manager/xref/_subscriptions-partners.tsv" \
        -v PPX="data/production/flow-manager/xref/_subscriptions-partners.tsv" \
        -v AAX="data/acceptance/flow-manager/xref/_subscriptions-accounts.tsv" \
        -v PAX="data/production/flow-manager/xref/_subscriptions-accounts.tsv" \
        -v APS="data/acceptance/transfer/reports/details/partners/_slugmap.tsv" \
        -v PPS="data/production/transfer/reports/details/partners/_slugmap.tsv" \
        -v AAS="data/acceptance/transfer/reports/details/accounts/_slugmap.tsv" \
        -v PAS="data/production/transfer/reports/details/accounts/_slugmap.tsv" '
        function sepfold(v) { gsub(/-/, "_", v); return v }
        function nkey(v) { return toupper(sepfold(v)) }
        function e(s) { gsub(/&/, "\\&amp;", s); gsub(/</, "\\&lt;", s); gsub(/>/, "\\&gt;", s); gsub(/"/, "\\&quot;", s); return s }
        function loadmap(map, f,   l, a) { if (f == "") return
            while ((getline l < f) > 0) { split(l, a, "\t"); if (a[1] != "") map[nkey(a[1])] = a[1] "\t" a[2] }
            close(f) }
        # subscription -> value pairs: per folded subscription key the DISTINCT
        # values (folded), display names kept in first-seen spelling
        function loadpairs(names, keys, dup, f,   l, a, sk, vk) { if (f == "") return
            while ((getline l < f) > 0) { split(l, a, "\t"); if (a[1] == "" || a[2] == "") continue
                sk = nkey(a[1]); vk = nkey(a[2])
                if (!((sk SUBSEP vk) in dup)) { dup[sk SUBSEP vk] = 1
                    names[sk] = names[sk] US a[2]; keys[sk] = keys[sk] US vk } }
            close(f) }
        # the US-separated token set, insertion-sorted — the canonical form two
        # sets compare and display in
        function sortedset(s,   A2, n2, i2, j2, t3, r2) {
            if (s == "") return ""
            n2 = split(substr(s, 2), A2, US)
            for (i2 = 2; i2 <= n2; i2++) { t3 = A2[i2]
                for (j2 = i2 - 1; j2 >= 1 && A2[j2] > t3; j2--) A2[j2+1] = A2[j2]
                A2[j2+1] = t3 }
            r2 = ""; for (i2 = 1; i2 <= n2; i2++) r2 = r2 US A2[i2]
            return r2 }
        # one cell: the env own names, _ display spelling, sorted, each linked
        # to that env detail page when its slugmap knows the name
        function cellset(env, sub2, names, slugmap,   A2, n2, i2, j2, t3, o2, nm, k2, inner, sa2) {
            if (names == "") return "<td class=\"cl\"></td>"
            n2 = split(substr(names, 2), A2, US)
            for (i2 = 2; i2 <= n2; i2++) { t3 = A2[i2]
                for (j2 = i2 - 1; j2 >= 1 && nkey(A2[j2]) > nkey(t3); j2--) A2[j2+1] = A2[j2]
                A2[j2+1] = t3 }
            o2 = ""
            for (i2 = 1; i2 <= n2; i2++) { nm = A2[i2]; k2 = nkey(nm); inner = e(sepfold(nm))
                if (k2 in slugmap) { split(slugmap[k2], sa2, "\t")
                    if (sa2[2] != "") inner = "<a href=\"../../" env "/details/" sub2 "/" sa2[2] ".html\">" inner "</a>" }
                o2 = o2 (o2 == "" ? "" : " / ") inner }
            return "<td class=\"cl\">" o2 "</td>" }
        BEGIN { US = sprintf("%c", 31)
            loadmap(AS, ASM); loadmap(PS, PSM)
            loadmap(PSL, APS); loadmap(PSLP, PPS); loadmap(ASL, AAS); loadmap(ASLP, PAS)
            loadpairs(APN, APK, D1, APX); loadpairs(PPN, PPK, D2, PPX)
            loadpairs(AAN, AAK, D3, AAX); loadpairs(PAN, PAK, D4, PAX)
            for (k in AS) { if (!(k in PS)) continue
                pa = sortedset((k in APK) ? APK[k] : "")
                pb = sortedset((k in PPK) ? PPK[k] : "")
                if (pa == pb) continue
                split(AS[k], aa, "\t"); split(PS[k], pp, "\t")
                inner = e(sepfold(aa[1]))
                if (aa[2] != "") inner = "<a href=\"../../acceptance/details/subscriptions/" aa[2] ".html\">" inner "</a>"
                else if (pp[2] != "") inner = "<a href=\"../../production/details/subscriptions/" pp[2] ".html\">" inner "</a>"
                print k, "<tr><td class=\"cl\">" inner "</td>" \
                    cellset("acceptance", "partners", (k in APN) ? APN[k] : "", PSL) \
                    cellset("production", "partners", (k in PPN) ? PPN[k] : "", PSLP) \
                    cellset("acceptance", "accounts", (k in AAN) ? AAN[k] : "", ASL) \
                    cellset("production", "accounts", (k in PAN) ? PAN[k] : "", ASLP) "</tr>"
            }
        }' /dev/null | LC_ALL=C sort -t"$(printf '\t')" -k1,1 | cut -f2- > "$rows"
    local n; n=$(wc -l < "$rows" | tr -d ' ')
    {
        html_head "Acceptance vs production" "../assets/style.css" "" "ANALYSES" "acc-vs-prod"
        printf '<h1>Acceptance vs production</h1>\n'
        printf '<p class="tabs">%s</p>\n' "$trow"
        printf '<p class="subtitle">The subscriptions present in <strong>both</strong> environments (matched ignoring case and the <code>_</code>/<code>-</code> difference) whose <strong>partners differ</strong> between Acceptance and Production, with each environment&#8217;s own partner(s) and account(s). Every name links its own environment&#8217;s detail page. A difference can be a real configuration gap — or the per-environment partner grouping: one merged group on one side, separate partners on the other.</p>\n'
        printf '<div class="tablewrap"><table class="fit">\n'
        printf '<tr><th>Subscription</th><th>Partners ACC</th><th>Partners PRD</th><th>Account ACC</th><th>Account PRD</th></tr>\n'
        cat "$rows"
        printf '<tr class="total"><td>Total (%d)</td><td></td><td></td><td></td><td></td></tr>\n' "$n"
        printf '</table></div>\n'
        printf '</body>\n</html>\n'
    } > "$out"
    rm -f "$rows"
}

write_acc_vs_prod_pages
write_subs_partners_page

# Tag our own h1 breadcrumbs: this script runs AFTER the env loop's
# bin/build/publish.sh (build.sh's post-loop step — it needs both env trees), so
# the tag sweeps there never see these pages. _tag_h1 is idempotent.
for f in "$DOCS/analyses/"acc-vs-prod-*.html; do
    [ -f "$f" ] || continue
    _tag_h1 "$f" "Acceptance vs production" "Analyses"
done

publish_stamp "$STAMP"
