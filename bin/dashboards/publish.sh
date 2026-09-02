#!/usr/bin/env bash
#
# bin/dashboards/publish.sh — render the DASHBOARDS page-spec .rpt files
# (data/dashboards/reports/*.rpt, written by bin/dashboards/reports.sh) into
# docs/dashboards/*.html: big-number KPI cards + inline-SVG charts.
#
# Each .rpt is one page: TITLE (html_head title) / H1 / INTRO + one KPI line
# per card (value, label, sub, accent, href) and one CARD line per chart
# (title, sub, href, span, chart type, up to 7 chart args — CH_* color
# tokens resolve here, so a palette change needs only a re-publish);
# optional PAGE (output basename, default = the .rpt basename) and FOOT
# (override of the standard closing line). Run AFTER the per-area publishes
# is not required — dashboards live in their own docs/dashboards/ dir — but
# BEFORE bin/build/publish.sh, whose root Dashboards card checks the index exists.
#
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../publish_lib.sh"   # cd's to the repo root; esc/html_head/menus/footer
# the overview spans BOTH logs: the From/To day list is their union
# `|| true`: with both date lists empty (config-only estate) grep matches
# nothing and would kill the script via pipefail — an empty union is valid
OV_DATES=$(printf '%s,%s' "${TRANSFER_DATES:-}" "${SERVER_DATES:-}" | tr ',' '\n' | { command grep -v '^$' || true; } | LC_ALL=C sort -u | paste -sd, -)
source "$SCRIPT_DIR/charts_lib.sh"              # kpi_card/card_open/svg_* + the CH_* palette

DRPT="$DATA/dashboards/reports"
DDIR="$DOCS/dashboards"
CSSREL="../assets/style.css"
ensure_assets   # ALWAYS — see the note in bin/transfer/publish.sh

STAMP="$PUBLISH_STAMP_DIR/dashboards.stamp"
if publish_is_fresh "$STAMP" "$DDIR" "${BASH_SOURCE[0]}" \
       "$SCRIPT_DIR/charts_lib.sh" "$DRPT"; then
    echo "docs/$SITE_ENV/dashboards/ is up to date; skipping." >&2
    exit 0
fi

mkdir -p "$DDIR"
rm -f "$DDIR"/*.html

# swap CH_* palette tokens in a chart arg for their hex values (charts_lib)
resolve_ch() {
    local s=$1
    s=${s//CH_BLUE/$CH_BLUE}; s=${s//CH_GREEN/$CH_GREEN}; s=${s//CH_RED/$CH_RED}
    s=${s//CH_AMBER/$CH_AMBER}; s=${s//CH_PURPLE/$CH_PURPLE}; s=${s//CH_TEAL/$CH_TEAL}
    printf '%s' "$s"
}

# one CARD line -> card html; dispatches the chart type to its charts_lib
# generator with the trailing-empty args dropped (an EMBEDDED empty arg —
# svg_area's unused data2/color2 before a unit suffix — is passed through).
# $1 is the chart's page-unique id: exported with the card title as
# CH_ID/CH_TITLE so the generator (a $() grandchild) can emit the accessible
# root <title>/<desc> + aria-labelledby and the chart-data table.
render_card() {   # $1 chart id  $2 title  $3 sub  $4 href  $5 span  $6 chart  $7..$14 args
    local cid=$1; shift
    local title=$1 sub=$2 href=$3 span=$4 chart=$5; shift 5
    export CH_ID="$cid" CH_TITLE="$title"
    local args=() a n
    for a in "$@"; do args+=("$(resolve_ch "$a")"); done
    n=${#args[@]}
    while [ "$n" -gt 0 ] && [ -z "${args[n-1]}" ]; do unset "args[$((n-1))]"; n=$((n-1)); done
    local svg=""
    case $chart in
        area)  svg=$(svg_area  ${args[@]+"${args[@]}"}) ;;
        donut) svg=$(svg_donut ${args[@]+"${args[@]}"}) ;;
        hbar)  svg=$(svg_hbar  ${args[@]+"${args[@]}"}) ;;
        vbar)  svg=$(svg_vbar  ${args[@]+"${args[@]}"}) ;;
        stack) svg=$(svg_stack ${args[@]+"${args[@]}"}) ;;
        heat)  svg=$(svg_heat  ${args[@]+"${args[@]}"}) ;;
        gauge) svg=$(svg_gauge ${args[@]+"${args[@]}"}) ;;
        slots)
            local BASEIV=360   # the visible default resolution, in minutes
            # CLIENT-SIDE since 2026-07: the card is one placeholder carrying
            # the series, and docs/assets/slotchart.js draws the SVG + data
            # table for the picked style/interval.
            # args: a1 KIND, a2 the BASE series, a3 the {} link pattern, then
            # any number of "<minutes>:<series>" EXTRA resolutions (a4..a8).
            # Each becomes data-iv<minutes>; the base takes data-base and its
            # own data-iv<minutes>. The interval row is built from the tags
            # present, ascending — so the overview offers 1h/2h/4h/6h/12h/1 day
            # and a day page 15/30 min/1 hour, from the same code.
            local slink=${args[2]:-}; [ -n "$slink" ] || slink=$href
            esc "$title"; local ctit=$ESC
            esc "$slink"; local clink=$ESC
            local ivlist="$BASEIV" a2 tag ser
            svg="<div class=\"slotchart\" data-kind=\"${args[0]}\" data-cid=\"$cid\" data-title=\"$ctit\" data-link=\"$clink\" data-base=\"$BASEIV\""
            esc "${args[1]:-}"; svg+=" data-iv$BASEIV=\"$ESC\""
            for a2 in "${args[@]:3}"; do
                [ -n "$a2" ] || continue
                tag=${a2%%:*}; ser=${a2#*:}
                [ -n "$ser" ] || continue
                ivlist="$ivlist $tag"
                esc "$ser"; svg+=" data-iv$tag=\"$ESC\""
            done
            svg+="></div>"
            svg+='<div class="chartbtns">'
            if [ "$(printf '%s\n' $ivlist | wc -l)" -gt 1 ]; then
                svg+='<p class="tabs ivbtns">'
                for tag in $(printf '%s\n' $ivlist | sort -n); do
                    case $tag in
                        15) lbl="15 min" ;; 30) lbl="30 min" ;; 60) lbl="1 hour" ;;
                        120) lbl="2 hours" ;; 240) lbl="4 hours" ;; 360) lbl="6 hours" ;; 720) lbl="12 hours" ;;
                        1440) lbl="1 day" ;; *) lbl="$tag min" ;;
                    esac
                    if [ "$tag" = "$BASEIV" ]; then svg+="<span class=\"tab active\" data-civ=\"$tag\">$lbl</span>"
                    else svg+="<span class=\"tab\" data-civ=\"$tag\">$lbl</span>"; fi
                done
                svg+='</p>'
            fi
            # Linear/Log (2026-08): a few series swing over three orders of
            # magnitude and flatten every ordinary slot against the floor on a
            # linear axis. NOT offered on the duration kinds — their ms..h axis
            # is already non-linear, so the toggle would be a dead button.
            case ${args[0]} in
                dur|durfit) ;;
                seen) svg+='<p class="tabs scalebtns"><span class="tab active" data-cscale="lin">Linear</span><span class="tab" data-cscale="log">Log</span></p>' ;;   # the seen graphs open LINEAR (2026-09-03, user request; slotchart.js scaleFor)
                *) svg+='<p class="tabs scalebtns"><span class="tab" data-cscale="lin">Linear</span><span class="tab active" data-cscale="log">Log</span></p>' ;;
            esac
            svg+='<p class="tabs stylebtns"><span class="tab" data-cstyle="line">Line</span><span class="tab" data-cstyle="bar">Bar</span><span class="tab active" data-cstyle="solid">Solid</span></p>'
            svg+='</div>'
            ;;
    esac
    # a chart with per-point links (area + link pattern) raises its chartbox
    # above the whole-card stretched title link (style.css .ptlinks), so the
    # day columns win the click inside the plot and the card link elsewhere
    local cardcls=$span
    if [ "$chart" = "area" ] && [ -n "${args[5]:-}" ]; then cardcls="${cardcls:+$cardcls }ptlinks"; fi
    # slots cards ALWAYS raise the chartbox: the stretched title link would
    # otherwise eat the tooltip mousemoves and the style buttons, links or not
    if [ "$chart" = "slots" ]; then cardcls="${cardcls:+$cardcls }ptlinks"; fi
    # the bottom-right "full report" link inside the chart (style.css
    # .card-more): the card href surfaced visibly — the best-fitting
    # transfer/server/analyses report for this graph. NOT on slots cards:
    # the linked title covers the report link and the corner belongs to the
    # Line/Bar/Solid switcher.
    local more=""
    if [ "$chart" != "slots" ] && [ -n "$href" ]; then esc "$href"; more="<a class=\"card-more\" href=\"$ESC\">full report &#8594;</a>"; fi
    if [ -n "$cardcls" ]; then
        printf '%s%s%s%s' "$(card_open "$title" "$sub" "$href" "$cardcls")" "$svg" "$more" "$(card_end)"
    else
        printf '%s%s%s%s' "$(card_open "$title" "$sub" "$href")" "$svg" "$more" "$(card_end)"
    fi
}

npages=0
for rpt in "$DRPT"/*.rpt; do
    [ -f "$rpt" ] || continue
    title=$(field1 TITLE "$rpt"); h1=$(field1 H1 "$rpt"); intro=$(field1 INTRO "$rpt")
    page=$(field1 PAGE "$rpt"); foot=$(field1 FOOT "$rpt")
    base=${rpt##*/}; base=${base%.rpt}
    out="$DDIR/${page:-$base}.html"
    # button 0 of the hero row names the FIRST CARD's view; the overview keeps
    # its hardcoded Duration (the day pages hardcode it too), other pages (the
    # Monitor dashboard) name theirs via the optional HERO0 directive
    hero0=$(field1 HERO0 "$rpt"); : "${hero0:=Duration}"
    # every dashboards page shares the dashboards help page except the Monitor
    # dashboard, which has its own
    hslug=dashboards; [ "${page:-$base}" = monitor ] && hslug=monitor

    # a TAB is IFS whitespace, so `read` would collapse EMPTY middle fields
    # (a card without a sub or span) and shift the columns — swap the tabs
    # for \x1f (non-whitespace) first, like the detail writer's sentinel note
    kpis=""
    while IFS=$'\037' read -r _ kval klab ksub kcol khref; do
        kpis+="$(kpi_card "$kval" "$klab" "$ksub" "$kcol" "$khref")"
    done < <(grep '^KPI'$'\t' "$rpt" | tr '\t' '\037' || true)

    # CARD lines render in order; when the rpt ALSO carries CARDALT lines (the
    # overview's hero alternates, the day-pages mechanism), the FIRST card is
    # the hero: the alternates render CSS-hidden (.althero) right behind it
    # and a .herotabs button row precedes the grid — report.js
    # setupHeroToggle swaps them (button i <-> grid child i).
    cards=""; hero="" alts="" altbtns=""
    chn=0
    while IFS=$'\037' read -r _ ctit csub chref cspan cchart a1 a2 a3 a4 a5 a6 a7 a8; do
        chn=$((chn + 1))
        if [ "$chn" -eq 1 ]; then
            hero="$(render_card "ch$chn" "$ctit" "$csub" "$chref" "$cspan" "$cchart" "$a1" "$a2" "$a3" "$a4" "$a5" "$a6" "$a7" "$a8")"
        else
            cards+="$(render_card "ch$chn" "$ctit" "$csub" "$chref" "$cspan" "$cchart" "$a1" "$a2" "$a3" "$a4" "$a5" "$a6" "$a7" "$a8")"
        fi
    done < <(grep '^CARD'$'\t' "$rpt" | tr '\t' '\037' || true)
    # A CARDALT button label may name a GROUP as "<group>|<member>" (2026-08):
    # those views move OFF the first button row into a SECOND row that appears
    # only while their group is picked — the row-1 button carries the group
    # name and no data-hero of its own. Grouped alts render LAST in the grid,
    # in group order, so the DOM order of the [data-hero] buttons (row 1, then
    # each group's row 2) still matches the card order index for index, which
    # is the contract setupHeroToggle relies on.
    galts=""; grpnames=""; grprows=""
    while IFS=$'\037' read -r _ blab ctit csub chref cspan cchart a1 a2 a3 a4 a5 a6 a7 a8; do
        case $blab in
            *"|"*) galts+="$blab"$'\037'"$ctit"$'\037'"$csub"$'\037'"$chref"$'\037'"$cspan"$'\037'"$cchart"$'\037'"$a1"$'\037'"$a2"$'\037'"$a3"$'\037'"$a4"$'\037'"$a5"$'\037'"$a6"$'\037'"$a7"$'\037'"$a8"$'\n'
                   g=${blab%%|*}
                   case "|$grpnames|" in *"|$g|"*) ;; *) grpnames="${grpnames:+$grpnames|}$g" ;; esac
                   continue ;;
        esac
        chn=$((chn + 1))
        alts+="$(render_card "ch$chn" "$ctit" "$csub" "$chref" "${cspan:+$cspan }althero" "$cchart" "$a1" "$a2" "$a3" "$a4" "$a5" "$a6" "$a7" "$a8")"
        esc "$blab"; altbtns+="<span class=\"tab\" data-hero=\"$ESC\">$ESC</span>"
    done < <(grep '^CARDALT'$'\t' "$rpt" | tr '\t' '\037' || true)
    # the six Top-5 tables (the overview): TOP lines in the day pages'
    # protocol, rendered by publish_lib's shared top_table into the same
    # .daytop grid — partners left, subscriptions right, one metric per row
    topcards=""
    while IFS=$'\t' read -r _ tkind ttit tunit thref trows; do
        [ -n "$trows" ] || continue
        topcards+="$(top_table "$tkind" "$ttit" "$tunit" "$thref" "$trows")" || continue
    done < <(grep '^TOP'$'\t' "$rpt" || true)
    # the daily series -> the raw-text payload report.js setupDaytop reads
    # to follow the From/To range: TOPDATA lines (per entity — the Top 5
    # re-selection) keep kind/name/series, K lines (per day — the five KPI
    # cards) pass whole. Emitted verbatim into a non-JS <script>, whose
    # content the parser takes raw — the one hazard is a literal "</script"
    # or "<" in an entity name, so such a line is dropped defensively
    # (config names never carry one).
    topdata=$(awk -F'\t' '$0 ~ /^(TOPDATA|K)\t/ && $0 !~ /</ {sub(/^TOPDATA\t/, ""); print}' "$rpt")

    # the group buttons (row 1) and their member rows (row 2), group by group
    IFSSAVE=$IFS
    IFS='|'; for g in $grpnames; do
        IFS=$IFSSAVE
        esc "$g"; glab=$ESC
        altbtns+="<span class=\"tab\" data-herogroup=\"$glab\">$glab</span>"
        rowbtns=""
        while IFS=$'\037' read -r blab ctit csub chref cspan cchart a1 a2 a3 a4 a5 a6 a7 a8; do
            [ "${blab%%|*}" = "$g" ] || continue
            chn=$((chn + 1))
            alts+="$(render_card "ch$chn" "$ctit" "$csub" "$chref" "${cspan:+$cspan }althero" "$cchart" "$a1" "$a2" "$a3" "$a4" "$a5" "$a6" "$a7" "$a8")"
            gmem=${blab#*|}
            esc "$blab"; fulllab=$ESC
            esc "$gmem"
            rowbtns+="<span class=\"tab\" data-hero=\"$fulllab\">$ESC</span>"
        done < <(printf '%s' "$galts")
        grprows+="<p class=\"tabs herotabs2\" data-herogrouprow=\"$glab\">$rowbtns</p>"$'\n'
        IFS='|'
    done
    IFS=$IFSSAVE

    {
        # the date-list meta (2026-08): the union of both areas' day lists, so
        # report.js builds its From/To selectors and the charts clip to them
        html_head "$title" "$CSSREL" "$OV_DATES" "" "$hslug" "dashboards" "" "" "slotchart.js"
        printf '<main class="dash">\n'
        printf '<h1>%s</h1>\n' "$h1"
        [ -n "$intro" ] && printf '<p class="dash-intro">%s</p>\n' "$intro"
        if [ -n "$kpis" ]; then printf '<div class="kpi-row">%s</div>\n' "$kpis"; fi
        # the herotabs row must be the grid's IMMEDIATE previous sibling
        # (setupHeroToggle: grid = bar.nextElementSibling); button 0 = the
        # hero card's view (like the day pages' hardcoded "Duration")
        if [ -n "$alts" ]; then
            esc "$hero0"
            printf '<p class="tabs herotabs"><span class="tab active" data-hero="%s">%s</span>%s</p>\n' "$ESC" "$ESC" "$altbtns"
            # the optional SECOND rows, one per group; report.js shows the
            # active group's row and hides the rest (all hidden by default —
            # the grid must still be the LAST element before it, so these sit
            # between the two and setupHeroToggle looks the grid up by class)
            [ -n "$grprows" ] && printf '%s' "$grprows"
        fi
        printf '<div class="dash-grid">%s%s%s</div>\n' "$hero" "$alts" "$cards"
        # the six Top-5 tables close the page, below the hero: numbers ->
        # shape -> who was busiest (the day pages' order, full-period here;
        # the payload makes them follow the From/To range client-side)
        if [ -n "$topcards" ]; then
            printf '<h2>Busiest this period</h2><div class="daytop">%s</div>\n' "$topcards"
        fi
        [ -n "$topdata" ] && printf '<script type="text/x-daytop" id="daytopdata">\n%s\n</script>\n' "$topdata"
        printf '<p class="dash-foot">%s</p>\n' "${foot:-Figures are for the full log period; open the matching report for the searchable table and the From/To date filter.}"
        printf '</main>\n</body>\n</html>\n'
    } > "$out"
    npages=$((npages + 1))
done
# consolidation (2026-07): ONE dashboard — the old per-topic URLs 404
# (their redirect stubs were removed 2026-07, no backwards compatibility)
echo "Wrote $npages dashboard page(s) to docs/dashboards/." >&2

publish_stamp "$STAMP"
