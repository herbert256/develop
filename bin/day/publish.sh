#!/usr/bin/env bash
#
# bin/day/publish.sh — render the PER-DAY page specs (data/day/reports/*.rpt,
# written by bin/day/reports.sh) into docs/day/*.html: ONE page per date, from
# ONE .rpt per date covering BOTH logs (2026-07 — the per-area
# transfer-<date>/server-<date> specs are gone, and with them everything the
# page never rendered: the table blocks, the non-hero chart cards and the
# unselected KPIs). Every directive in the .rpt lands on the page.
#
# Page layout: h1 → nav row (prev/next day) → ONE KPI card row (the five
# headline cards: Files / File error rate / Volume / Server records
# / Server error rate) → the hero chart (the SIX shared 30-minute slot views:
# Duration hero + OK Files/Error % Files/Volume/PeSIT — same labels as the
# dashboards overview, so the picked view carries between the pages) → the two
# problem lists (server, then transfer) → Remarkable facts, which CLOSE the
# page. Day pages carry NO From/To filter: the page IS a date filter.
#
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../publish_lib.sh"   # cd's to the repo root; esc/html_head/menus/field1
source "$SCRIPT_DIR/../dashboards/charts_lib.sh"   # kpi_card/card_open/svg_* + the CH_* palette

DRPT="$DATA/day/reports"
DDIR="$DOCS/day"
CSSREL="../assets/style.css"
ensure_assets   # topbar-data.js (the top bar's data file)

mkdir -p "$DDIR"
rm -f "$DDIR"/*.html

# esc + **bold** for H1/FACT prose (render_rpt.awk does the same for its
# own INTRO/NOTE lines; the day header lines never pass through it), plus
# the two link tokens of the FACT lines (2026-09-30 audit A4-12 / A5-14):
#   [[<sub>/<name>]]      an entity name -> its detail page, resolved through
#                         data/transfer/reports/details/<sub>/_slugmap.tsv (no
#                         entry = no page = the plain name) — render_rpt's
#                         prose() rule
#   [[files/<coreid>|<label>]]  a File page; bin/day/reports.sh emits it only
#                         for a CoreId of the published set (_filepages.tsv)
prose() {
    printf '%s' "$1" | LC_ALL=C awk -v SMD="$DATA/transfer/reports/details" '
    function esc(s) { gsub(/&/, "\\&amp;", s); gsub(/</, "\\&lt;", s); gsub(/>/, "\\&gt;", s); gsub(/"/, "\\&quot;", s); return s }
    function slugfor(sd, nm,   f, l, a) {
        if (!(sd in LOADED)) { LOADED[sd] = 1; f = SMD "/" sd "/_slugmap.tsv"
            while ((getline l < f) > 0) { split(l, a, "\t"); if (a[1] != "" && a[2] != "") SL[sd SUBSEP a[1]] = a[2] }
            close(f) }
        return ((sd SUBSEP nm) in SL) ? SL[sd SUBSEP nm] : ""
    }
    {
        s = $0; out = ""
        while ((i = index(s, "[[")) > 0) {
            j = index(substr(s, i + 2), "]]"); if (j == 0) break
            tok = substr(s, i + 2, j - 1); out = out esc(substr(s, 1, i - 1))
            p = index(tok, "/"); sd = (p > 1) ? substr(tok, 1, p - 1) : ""; nm = (p > 1) ? substr(tok, p + 1) : tok
            if (sd == "files" && (q = index(nm, "|")) > 1)
                out = out "<a href=\"../files/" substr(nm, 1, q - 1) ".html\">" esc(substr(nm, q + 1)) "</a>"
            else if (sd != "" && (sl = slugfor(sd, nm)) != "")
                out = out "<a href=\"../details/" sd "/" sl ".html\">" esc(nm) "</a>"
            else out = out esc(nm)
            s = substr(s, i + j + 3)
        }
        $0 = out esc(s)
        while (match($0, /\*\*[^*]+\*\*/)) {
            inner = substr($0, RSTART + 2, RLENGTH - 4)
            $0 = substr($0, 1, RSTART - 1) "<strong>" inner "</strong>" substr($0, RSTART + RLENGTH)
        }
        print
    }'
}

# the card renderer is charts_lib.sh render_card (shared with the dashboards,
# 2026-09-30): a day page shows 30-minute slots by default and no
# "full report" corner link
RC_BASEIV=30; RC_MORE=0

# ---- fragment builders (each reads one or more .rpt) -------------------------

# page-scoped card-id counter, so every chart on a page gets a UNIQUE id (the
# combined page mixes transfer + server cards, whose ids would otherwise
# clash). Incremented INLINE at the call sites — the former $(cid) helper ran
# its increment inside a command-substitution SUBSHELL, so the counter never
# advanced and all six hero charts shared data-cid="ch1" (duplicate <desc>
# ids; five charts' aria-describedby resolved to the first chart's).
CIDN=0

# The ONE KPI row above the hero graph — every KPI line of the day .rpt, in
# file order: Files / File error rate / Volume (the transfer
# pass) then Server records / Server error rate (the server pass). The .rpt
# carries exactly these five, under the labels shown, so nothing is selected
# here. A KPI line's optional 7th field is the same-weekday delta (e.g. +30% /
# -10%), rendered as a small span tucked behind the value.
kpis_html() {   # $1 day rpt
    local h="" kval klab ksub kcol khref kdelta
    [ -f "$1" ] || return 0
    while IFS=$'\037' read -r _ kval klab ksub kcol khref kdelta; do
        [ -n "$klab" ] || continue
        if [ -n "$kdelta" ]; then
            # No up/down/flat modifier class: none of the three was ever styled
            # (style.css has .kpi-delta only), so all three rendered identically.
            # The sign is in the value itself and the title says what it compares.
            kval="$kval<span class=\"kpi-delta\" title=\"vs the same weekday's average\">$kdelta</span>"
        fi
        h+="$(kpi_card "$kval" "$klab" "$ksub" "$kcol" "$khref")"
    done < <(grep '^KPI'$'\t' "$1" | tr '\t' '\037' || true)
    if [ -n "$h" ]; then printf '<div class="kpi-row">%s</div>' "$h"; fi
}

# Remarkable-facts <ul> from the FACT lines of the day rpt (the transfer
# pass wrote its own first, the server pass appended its own after them).
facts_html() {
    local rpt f="" line
    for rpt in "$@"; do
        [ -f "$rpt" ] || continue
        while IFS= read -r line; do f+="<li>$(prose "$line")</li>"; done < <(grep '^FACT'$'\t' "$rpt" | cut -f2- || true)
    done
    # `if` (not `[ -n ] && printf`): a day rpt with no FACT lines must leave the
    # function returning 0, else the `FACTS_H=$(facts_html …)` caller aborts under set -e.
    if [ -n "$f" ]; then printf '<h2>Remarkable facts</h2><ul class="dayboxlist dayfacts">%s</ul>' "$f"; fi
}

# The HERO card (first CARD) + its CARDALT alternates of ONE rpt ($1) — on a
# transfer day that is the SIX shared slot views (Duration hero + Files
# processed/Error % Files/Volume/PeSIT), same labels as the dashboards overview.
# The former server Errors/Warnings-per-hour folding is GONE (2026-07): those
# render as plain grid cards again. Sets HERO_CARD / ALT_CARDS / ALT_BTNS.
hero_html() {
    local rpt=$1 chn=0 altn=0 blab
    HERO_CARD=""; ALT_CARDS=""; ALT_BTNS=""
    [ -f "$rpt" ] || return 0
    while IFS=$'\037' read -r _ ctit csub chref cspan cchart a1 a2 a3 a4 a5 a6; do
        chn=$((chn + 1)); [ "$chn" -eq 1 ] || continue
        CIDN=$((CIDN + 1))
        render_card "ch$CIDN" "$ctit" "$csub" "$chref" "$cspan" "$cchart" "$a1" "$a2" "$a3" "$a4" "$a5" "$a6"; HERO_CARD="$RC_OUT"
    done < <(rc_cards CARD "$rpt")   # (series compacted — charts_lib rc_cards)
    while IFS=$'\037' read -r _ blab ctit csub chref cspan cchart a1 a2 a3 a4 a5 a6; do
        altn=$((altn + 1))
        CIDN=$((CIDN + 1))
        render_card "ch$CIDN" "$ctit" "$csub" "$chref" "${cspan:+$cspan }althero" "$cchart" "$a1" "$a2" "$a3" "$a4" "$a5" "$a6"; ALT_CARDS+="$RC_OUT"
        esc "$blab"; ALT_BTNS+="<span class=\"tab\" data-hero=\"$ESC\">$ESC</span>"
    done < <(rc_cards CARDALT "$rpt")
}

# The problem lists — links (each with the date filter already set, via the
# hrefs' ?axway_date) into the reports that DETAIL this day's problems, so the
# notable items are one central click away instead of buried across reports.
# TWO sections (2026-07), one per LOG — "Server log problems this day" then
# "Transfer log problems this day" — each its own boxed list, and a side with
# nothing to report renders no heading at all. Every row comes from a PROBLEM
# line of the day .rpt, whose SIDE field picks the list.
prob_row() {   # $1 href  $2 headline  $3 description
    esc "$2"; local h=$ESC
    printf '<li><a class="problink" href="%s">%s</a> <span class="probdesc">%s</span></li>' "$1" "$h" "$(prose "$3")"
}
# PROBLEM<TAB>side<TAB>href<TAB>headline<TAB>desc — one line per non-zero
# signal (transfer failures, pirates, waiting/expired files, logon screening
# failures, connection failures, scheduler overruns, PeSIT ceiling, …),
# the anomaly scan included — that one is emitted only for the days the scan
# actually flagged (2026-08), so a clean day can now leave the transfer list
# empty, and then its heading is dropped like the server side's.
problems_html() {   # $1 day rpt
    local rpt=$1 pside phref phead pdesc trows="" srows="" out=""
    if [ -f "$rpt" ]; then
        while IFS=$'\t' read -r _ pside phref phead pdesc; do
            [ -n "$phref" ] || continue
            if [ "$pside" = server ]; then srows+="$(prob_row "$phref" "$phead" "$pdesc")"
            else                           trows+="$(prob_row "$phref" "$phead" "$pdesc")"; fi
        done < <(grep '^PROBLEM'$'\t' "$rpt" || true)
    fi
    [ -n "$srows" ] && out+="$(printf '<h2>Server log problems this day</h2><ul class="dayboxlist dayproblems">%s</ul>' "$srows")"
    [ -n "$trows" ] && out+="$(printf '<h2>Transfer log problems this day</h2><ul class="dayboxlist dayproblems">%s</ul>' "$trows")"
    printf '%s' "$out"
}

# ---- the six Top-5 tables ---------------------------------------------------
# TOP<TAB>kind<TAB>title<TAB>unit<TAB>href<TAB>name US value US … (US = \x1f)
# Six small two-column tables: this day's five biggest PARTNERS and
# SUBSCRIPTIONS by Files, by Volume and by Errors, each already sorted descending
# by bin/day/reports.sh. Laid out as a 2-column grid — partners left,
# subscriptions right, one metric per row. The card renderer is publish_lib's
# top_table (shared with the Overview dashboard, which shows the same six tables
# over the full period). Each table carries a "See more" link into the matching
# Transfer > Entities view, narrowed to this day and sorted descending on the
# same column.
tops_html() {   # $1 day rpt
    local rpt=$1 kind title unit href rows slugs tbl cards="" out=""
    if [ -f "$rpt" ]; then
        while IFS=$'\t' read -r _ kind title unit href rows slugs; do
            [ -n "$rows" ] || continue
            tbl=$(top_table "$kind" "$title" "$unit" "$href" "$rows" "$slugs") || continue
            cards+="$tbl"
        done < <(grep '^TOP'$'\t' "$rpt" || true)
    fi
    [ -n "$cards" ] && out+="$(printf '<div class="daytop">%s</div>' "$cards")"
    # `if`, not `[ -n ] &&`: a day with no TOP lines must leave this returning 0
    if [ -n "$out" ]; then printf '<h2>Busiest this day</h2>%s' "$out"; fi
}

# (the "Grand overview" cross-link row was removed 2026-07 — the top bar's
# Dashboard link covers it; its no-op daylinks_html went 2026-09-29)

# ---- the page writer --------------------------------------------------------
# Consumes the globals set by the caller: OUT TITLE H1 NAVLINE
# KPIS_H HERO_CARD ALT_CARDS ALT_BTNS TOPS_H FACTS_H PROBLEMS_H.
write_page() {
    # nav row: NAVROW<TAB>prev<TAB>next (each "label|href"; empty href = inactive)
    local prevbtn="" nextbtn="" navn=0 nlab nhref btn
    if [ -n "$NAVLINE" ]; then
        while IFS='|' read -r nlab nhref; do
            [ -n "$nlab" ] || continue
            navn=$((navn + 1)); esc "$nlab"
            if [ -n "$nhref" ]; then btn="<a class=\"daybtn\" href=\"$nhref\">$ESC</a>"; else btn="<span class=\"daybtn disabled\">$ESC</span>"; fi
            if [ "$navn" = 1 ]; then prevbtn="$btn"; else nextbtn="$btn"; fi
        done < <(printf '%s\n' "${NAVLINE#NAVROW$'\t'}" | tr '\t' '\n')
    fi
    {
        html_head "$TITLE" "$CSSREL" "" "" "daily" "" "" "" "slotchart.js"
        printf '<div class="daynav">%s<h1>%s</h1>%s</div>\n' "$prevbtn" "$(prose "$H1")" "$nextbtn"
        printf '<main class="dash">\n'
        printf '%s\n' "$KPIS_H"
        if [ -n "$HERO_CARD" ] && [ -n "$ALT_CARDS" ]; then
            printf '<p class="tabs herotabs"><span class="tab active" data-hero="Duration">Duration</span>%s</p>\n' "$ALT_BTNS"
            printf '<div class="dash-grid">%s%s</div>\n' "$HERO_CARD" "$ALT_CARDS"
        elif [ -n "$HERO_CARD" ]; then
            printf '<div class="dash-grid">%s</div>\n' "$HERO_CARD"
        fi
        # The problem lists ABOVE Remarkable facts — matched boxed lists (same
        # .dayboxlist layout), all inside .dash so they align vertically.
        [ -n "$PROBLEMS_H" ] && printf '%s\n' "$PROBLEMS_H"
        [ -n "$FACTS_H" ] && printf '%s\n' "$FACTS_H"
        # The six Top-5 tables CLOSE the page, below Remarkable facts: KPIs
        # (numbers) -> hero (shape) -> what went wrong -> facts -> who was busiest.
        # Still no graphs below the hero (2026-07) — these are text tables.
        [ -n "$TOPS_H" ] && printf '%s\n' "$TOPS_H"
        printf '</main>\n'
        printf '</body>\n</html>\n'
    } > "$OUT"
}

# ---- generate the pages -----------------------------------------------------

# ONE .rpt per day (both logs), named after the date
dates=$(for f in "$DRPT"/*.rpt; do
    [ -f "$f" ] || continue; b=${f##*/}; echo "${b%.rpt}"
done | LC_ALL=C sort -u)

# ONE day page. A function so the pool can render several at once: every name it
# touches is a scratch global, and in a child those are private copies — which is
# exactly the isolation the serial version got from overwriting them each pass.
_day_page() {   # $1 = date
    local date=$1 rpt="$DRPT/$1.rpt"
    CIDN=0
    TITLE=$(field1 TITLE "$rpt"); H1=$(field1 H1 "$rpt")
    NAVLINE=$(grep -m1 '^NAVROW'$'\t' "$rpt" || true)
    KPIS_H=$(kpis_html "$rpt")
    hero_html "$rpt"
    FACTS_H=$(facts_html "$rpt")
    PROBLEMS_H=$(problems_html "$rpt")
    TOPS_H=$(tops_html "$rpt")
    OUT="$DDIR/$date.html"; write_page
}

for date in $dates; do
    pub_run _day_page "$date"
done
pub_wait
# counted from the output: the increment used to live in the loop body, which now
# runs in a child where it could not propagate.
npages=$(find "$DDIR" -name '*.html' 2>/dev/null | wc -l | tr -d ' ')
echo "Wrote $npages combined day page(s) to docs/day/." >&2
