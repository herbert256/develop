#!/usr/bin/env bash
#
# bin/dashboards/publish.sh — render the DASHBOARDS page-spec .rpt files
# (data/dashboards/reports/*.rpt, written by bin/dashboards/reports.sh) into
# docs/dashboards/*.html: big-number KPI cards + inline-SVG charts.
#
# Each .rpt is one page: TITLE (html_head title) / H1 + one KPI line
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
ensure_assets   # topbar-data.js (the menus' data file)

mkdir -p "$DDIR"
rm -f "$DDIR"/*.html

# the card renderer is charts_lib.sh render_card (shared with the day pages,
# 2026-09-30): the overview shows 6-hour slots by default and the
# bottom-right "full report" link on non-slots cards
RC_BASEIV=360; RC_MORE=1

npages=0
for rpt in "$DRPT"/*.rpt; do
    [ -f "$rpt" ] || continue
    title=$(field1 TITLE "$rpt"); h1=$(field1 H1 "$rpt")   # (no INTRO: the help page explains, 2026-09-30)
    page=$(field1 PAGE "$rpt"); foot=$(field1 FOOT "$rpt")
    base=${rpt##*/}; base=${base%.rpt}
    out="$DDIR/${page:-$base}.html"
    # button 0 of the hero row names the FIRST CARD's view: Duration (the day
    # pages hardcode it too; the HERO0 directive and the Monitor dashboard's own
    # help slug went 2026-09-30 with that dashboard)
    hero0=Duration
    hslug=dashboards

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
            render_card "ch$chn" "$ctit" "$csub" "$chref" "$cspan" "$cchart" "$a1" "$a2" "$a3" "$a4" "$a5" "$a6" "$a7" "$a8"; hero="$RC_OUT"
        else
            render_card "ch$chn" "$ctit" "$csub" "$chref" "$cspan" "$cchart" "$a1" "$a2" "$a3" "$a4" "$a5" "$a6" "$a7" "$a8"; cards+="$RC_OUT"
        fi
    done < <(rc_cards CARD "$rpt")   # (series compacted — charts_lib rc_cards)
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
        render_card "ch$chn" "$ctit" "$csub" "$chref" "${cspan:+$cspan }althero" "$cchart" "$a1" "$a2" "$a3" "$a4" "$a5" "$a6" "$a7" "$a8"; alts+="$RC_OUT"
        esc "$blab"; altbtns+="<span class=\"tab\" data-hero=\"$ESC\">$ESC</span>"
    done < <(rc_cards CARDALT "$rpt")
    # the six Top-5 tables (the overview): TOP lines in the day pages'
    # protocol, rendered by publish_lib's shared top_table into the same
    # .daytop grid — partners left, subscriptions right, one metric per row
    topcards=""
    while IFS=$'\t' read -r _ tkind ttit tunit thref trows tslugs; do
        [ -n "$trows" ] || continue
        topcards+="$(top_table "$tkind" "$ttit" "$tunit" "$thref" "$trows" "$tslugs")" || continue
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
            render_card "ch$chn" "$ctit" "$csub" "$chref" "${cspan:+$cspan }althero" "$cchart" "$a1" "$a2" "$a3" "$a4" "$a5" "$a6" "$a7" "$a8"; alts+="$RC_OUT"
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
