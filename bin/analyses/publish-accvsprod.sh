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
# detail-page slugmaps, so every configured OR logged name counts. NAME-ONLY
# pages since 2026-08-30 (user choice — the FlowID look family-wide): no Files
# columns and no result tints anywhere; each cell still links that env's own
# detail page where the type has them. Names are matched case aside;
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
            sub(/class="h2row">Logical, Partners, Domains/, "class=\"h2row\">" envcap ": Logical, Partners, Domains")
            print
            if (depth <= 0) exit
        }
    ' docs/index.html
}

# ---- Logical: since 2026-08-31 a FULL entity — the derivation (FlowIDs
# condensed into logical flow groups, input/<env>/logical.txt pins honoured) lives
# in bin/flow-manager.sh, which writes base/_logicals.tsv (the name list this
# page family reads like every other base) and the FlowID -> Logical map
# xref/_profiles-logicals.tsv. The Logical pages link detail pages
# (details/logicals/) and take activity from logical.rpt like the PDA types.
# ---- BL (2026-08-31, user request): the subscriptions.json tags entry
# starting with BL, a full entity too — base/_bl.tsv, details/bl/ and bl.rpt
# feed its pages exactly like Logical.

write_acc_vs_prod_pages() {
    # whitelist: NO detail pages/slugmap — the name set is each env's
    # base/_white.tsv itself (NOSLUG mode below: unlinked cells, IPv4 keys
    # padded so addresses compare and sort in address order)
    # (the FlowID type was REMOVED 2026-08-30, user request — Logical, its
    # condensed successor and a full entity, covers the flow comparison; no
    # raw profile value surfaces anywhere any more)
    # logicals: the FlowIDs condensed into LOGICAL flow groups —
    # since 2026-08-31 a real base cache (base/_logicals.tsv, derived by
    # bin/flow-manager.sh) with detail pages and its own entity report,
    # so it renders like the PDA types (linked cells, activity split).
    local types=(accounts subscriptions logins hosts partners domains applications whitelist logicals bl)
    local labels=("Accounts" "Subscriptions" "Logins" "Hosts" "Partners" "Domains" "Applications" "Whitelist" "Logical" "BL")
    local bases=(_accounts _subscriptions _logins _hosts _partners _domains _apps _white _logicals _bl)
    # ACTIVITY per env: each name's Files/Volume from that env's entity summary
    # .rpt (first-table ROWs — the same source ranking.sh lifts from), matched
    # case aside. Since 2026-08-30 the activity feeds ONLY the Summary page's
    # dormancy split — the entity pages themselves render name-only.
    local rpts=(account subscription login remote-host partner domain application "" logical bl)
    # difference (2026-08-29): the Only-acceptance and Only-production sets
    # side by side as two independent name-sorted columns of ONE table — the
    # promotion diff at a glance. Its tab sits AFTER Summary in the view row.
    # all (2026-08-30, user request; relaid same day): the FIRST view button —
    # the union of both sets in the DIFFERENCE layout: one row per name, the
    # Acceptance/Production column(s) filled where the name exists — a
    # Both-set row fills BOTH sides (the ✔/✘ sign form lasted a morning).
    # acc / prd (2026-08-30, user request): ONE environment's FULL
    # set (its only-set plus the Both set), the single-env layout; the
    # existing -acceptance/-production pages stay the ONLY-sets under their
    # old URLs, relabelled "Only Acceptance"/"Only Production" (spelled out,
    # not ACC/PRD). The Both view stays the Entities default.
    local views=(all acc acceptance both production prd difference)
    local vlabels=("All" "Acceptance" "Only Acceptance" "Both" "Only Production" "Production" "Difference")
    # the FAMILY NAV (2026-08-30, user choice): row 1 everywhere is
    # Summary / Entities / Subscriptions vs partners; the type row (this
    # order) and the view row show ONLY inside Entities, whose landing —
    # and the view row's default — is Subscriptions at the Both view.
    local taborder=(subscriptions logicals accounts logins hosts partners domains applications bl whitelist)
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
        local noslug=0; case $t in whitelist) noslug=1 ;; esac
        # the _/- SEPARATOR FOLD was REMOVED (2026-08-31, user request):
        # names match on the REAL spelling (case aside, the site-wide rule)
        # and display verbatim — _ and - are different names again, so a
        # cross-env spelling difference shows as two Only-rows instead of
        # one matched row.
        local fold=0
        # one line per name (case-folded key, real spelling kept): cls a|b|p, KEY,
        # acceptance name/slug/result, production name/slug/result, then the
        # activity columns: acceptance files/volume, production files/volume
        awk -v OFS='\t' -v AM="$am" -v PM="$pm" -v AB="$ab" -v PB="$pb" -v NOSLUG="$noslug" -v AR="$ar" -v PR="$pr" -v FOLD="$fold" '
            function sepfold(v) { if (FOLD) gsub(/-/, "_", v); return v }   # identity since 2026-08-31 (fold=0 always): the REAL spelling
            function nkey(v) { return toupper(sepfold(v)) }                # the MATCH key: case folded only
            function padkey(v,   o) {   # IPv4 -> zero-padded octets (address order); else UPPER
                if (v ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) { split(v, o, "."); return sprintf("%03d%03d%03d%03d", o[1], o[2], o[3], o[4]) }
                return toupper(v)
            }
            # the NOSLUG key: padkey for the whitelist (addresses sort in
            # address order); nkey otherwise
            function lkey(v) { return FOLD ? nkey(v) : padkey(v) }
            function load(map, f,   l, a) { if (f == "") return
                while ((getline l < f) > 0) { split(l, a, "\t"); if (a[1] != "") map[nkey(a[1])] = a[1] "\t" a[2] }
                close(f) }
            # NOSLUG (whitelist): the base cache IS the name list — no slug
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
                    # (the whitelist rows ordered by result COLOR first until
                    # 2026-08-30, when the colors left the family — plain
                    # key order now, which for the whitelist is address order)
                    sk = k
                    # display in the REAL spelling;
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
            # every view button carries "- nnn" — that page's row count for
            # THIS type (2026-08-30, user request; the "(nnn)" form lasted an
            # hour): All = the union, Acceptance/Production = that env's full
            # set, Difference = the two only-sets together
            # the view row DISPLAY order (2026-08-30, user choice): three
            # sections split by a .tabsep gap — the union cuts (All /
            # Difference), then the full per-env sets (Acceptance /
            # Production), then the disjoint split (Only Acceptance / Both /
            # Only Production)
            local vorder=(all difference @gap acc prd @gap acceptance both production)
            vrow=""
            local vcnt vt vti
            for vt in "${vorder[@]}"; do
                if [ "$vt" = "@gap" ]; then vrow+="<span class=\"tabsep\"></span>"; continue; fi
                for vti in "${!views[@]}"; do [ "${views[$vti]}" = "$vt" ] && break; done
                case $vt in
                    all)        vcnt=$((na + nb + np)) ;;
                    acc)        vcnt=$((na + nb)) ;;
                    acceptance) vcnt=$na ;;
                    both)       vcnt=$nb ;;
                    production) vcnt=$np ;;
                    prd)        vcnt=$((nb + np)) ;;
                    difference) vcnt=$((na + np)) ;;
                esac
                vl="${vlabels[$vti]} - $vcnt"
                if [ "$vt" = "$v" ]; then vrow+="<span class=\"tab active\">$vl</span>"
                else vrow+="<a class=\"tab\" href=\"acc-vs-prod-$t-$vt.html\">$vl</a>"; fi
            done
            {
                html_head "Acceptance vs production" "../assets/style.css" "" "ANALYSES" "acc-vs-prod"
                printf '<h1>Acceptance vs production</h1>\n'
                local foldnote=""
                # The button rows go DIRECTLY under the <h1>, above the prose —
                # navigation first, everywhere on the site (see the group tab
                # bar rule in CLAUDE.md). This family carries its own type/view
                # rows instead of a _analyses_groups row, but the position rule
                # is the same.
                printf '<p class="tabs">%s</p>\n' "$trow"
                printf '<p class="tabs">%s</p>\n' "$erow"
                printf '<p class="tabs">%s</p>\n' "$vrow"
                # logicals: its own subtitle — the derivation deserves a
                # sentence of its own
                if [ "$t" = logicals ]; then
                    printf '<p class="subtitle">The Logical flows known to each environment — the FlowIDs condensed into logical groups: numbered variants and per-label branches of one flow fold into a single name, normalized to three <code>_</code>-separated parts (a <code>-</code> inside a part marks parts the normalization combined). Only in Acceptance, in both, or only in Production. Every name links its own environment&#8217;s detail page.</p>\n'
                else
                    # name-only pages (2026-08-30, user choice — the FlowID
                    # look family-wide): no Files column, no result colors;
                    # the links to the detail pages stay (whitelist has none)
                    local linknote=""
                    [ "$noslug" = 0 ] && linknote=" Every name links its own environment&#8217;s detail page."
                    printf '<p class="subtitle">The %s known to each environment (configured or logged, matched by name): only in Acceptance, in both, or only in Production.%s%s</p>\n' "${labels[$ti]}" "$linknote" "$foldnote"
                fi
                printf '<div class="tablewrap"><table class="fit">\n'
                # (the ONE-column Both view went with the FlowID type — every
                # remaining type renders two linked columns)
                onecol=0
                if [ "$onecol" = 1 ] && [ "$v" = both ]; then
                    printf '<tr><th>%s</th></tr>\n' "${labels[$ti]}"
                elif [ "$v" = both ] || [ "$v" = difference ] || [ "$v" = all ]; then
                    printf '<tr><th>Acceptance</th><th>Production</th></tr>\n'
                else
                    printf '<tr><th>%s</th></tr>\n' "${labels[$ti]}"
                fi
                # NAME-ONLY rendering (2026-08-30, user choice — the FlowID
                # look family-wide): no Files cells, no result tints; every
                # cell still links its environment's own detail page where the
                # type has them. The activity in the stream ($9/$11) now feeds
                # only the Summary's dormancy split.
                awk -F'\t' -v view="$v" -v sub2="$t" -v onecol="$onecol" '
                    function e(s) { gsub(/&/, "\\&amp;", s); gsub(/</, "\\&lt;", s); gsub(/>/, "\\&gt;", s); gsub(/"/, "\\&quot;", s); return s }
                    function cell(env, name, slug,   inner) {
                        inner = e(name)
                        if (slug != "") inner = "<a href=\"../../" env "/details/" sub2 "/" slug ".html\">" inner "</a>"
                        return "<td class=\"cl\">" inner "</td>"
                    }
                    # the All view (relaid 2026-08-30, user request): the
                    # DIFFERENCE layout over the union — one row per name in
                    # the one global alphabet, each side filled where the name
                    # exists, so a Both-set row fills BOTH columns and an
                    # only-set row leaves the other side empty
                    view == "all" && $1 == "a" { n++
                        printf "<tr>%s<td class=\"cl\"></td></tr>\n", cell("acceptance", $3, $4); next }
                    view == "all" && $1 == "b" { n++
                        printf "<tr>%s%s</tr>\n", cell("acceptance", $3, $4), cell("production", $6, $7); next }
                    view == "all" && $1 == "p" { n++
                        printf "<tr><td class=\"cl\"></td>%s</tr>\n", cell("production", $6, $7); next }
                    view == "acceptance" && $1 == "a" { n++
                        printf "<tr>%s</tr>\n", cell("acceptance", $3, $4) }
                    view == "production" && $1 == "p" { n++
                        printf "<tr>%s</tr>\n", cell("production", $6, $7) }
                    # acc / prd: ONE environment'\''s FULL set (only-set + Both)
                    view == "acc" && ($1 == "a" || $1 == "b") { n++
                        printf "<tr>%s</tr>\n", cell("acceptance", $3, $4) }
                    view == "prd" && ($1 == "p" || $1 == "b") { n++
                        printf "<tr>%s</tr>\n", cell("production", $6, $7) }
                    view == "both" && $1 == "b" { n++
                        # onecol (retired with the FlowID type): the one shared spelling, once
                        if (onecol) printf "<tr>%s</tr>\n", cell("acceptance", $3, $4)
                        else printf "<tr>%s%s</tr>\n", cell("acceptance", $3, $4), cell("production", $6, $7) }
                    # difference: ONE ROW PER NAME — an entity exists in only
                    # ONE environment here, so its row fills only that side
                    # (the other column stays empty). The input stream is
                    # globally name-sorted, so the rows interleave in one
                    # alphabet, each name at its proper position.
                    view == "difference" && $1 == "a" { nA++
                        printf "<tr>%s<td class=\"cl\"></td></tr>\n", cell("acceptance", $3, $4) }
                    view == "difference" && $1 == "p" { nP++
                        printf "<tr><td class=\"cl\"></td>%s</tr>\n", cell("production", $6, $7) }
                    END {
                        if (view == "difference") {
                            printf "<tr class=\"total\"><td>Total (%d / %d)</td><td></td></tr>\n", nA + 0, nP + 0
                            exit
                        }
                        two = (view == "all" || (view == "both" && !onecol))
                        printf "<tr class=\"total\"><td>Total (%d)</td>%s</tr>\n", n + 0, (two ? "<td></td>" : "")
                    }' "$tmp"
                printf '</table></div>\n'
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
        # the Per-entity ROW order (2026-08-31, user choice: the home-page
        # order — the FM four, then the Logical/PDA group, Whitelist last) —
        # independent of the types[] array, which keeps driving the pages
        # and the tab row
        local sumorder=(subscriptions accounts hosts logins logicals partners domains applications bl whitelist)
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
                    lc("num gsepw", z(na+nb), "acc"), lc("num", z(nb+np), "prd"), \
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
# the family: case folded, real spellings since 2026-08-31) whose PARTNER sets differ between
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
        function sepfold(v) { return v }   # the _/- fold was REMOVED 2026-08-31: real spellings
        function nkey(v) { return toupper(v) }   # the MATCH key: case folded only
        function e(s) { gsub(/&/, "\\&amp;", s); gsub(/</, "\\&lt;", s); gsub(/>/, "\\&gt;", s); gsub(/"/, "\\&quot;", s); return s }
        function loadmap(map, f,   l, a) { if (f == "") return
            while ((getline l < f) > 0) { split(l, a, "\t"); if (a[1] != "") map[nkey(a[1])] = a[1] "\t" a[2] }
            close(f) }
        # subscription -> value pairs: per case-folded subscription key the
        # DISTINCT values, display names kept in first-seen spelling
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
