#!/usr/bin/env bash
#
# bin/build/publish.sh — write the index pages of the site:
#   docs/index.html            the root landing page (all parts centered):
#                              the two result-status tables and the per-day
#                              table — one environment per checkout since
#                              2026-09-11, so ONE block; the title carries the
#                              environment label (input/environment.txt)
#   docs/404.html              the not-found page
# then the group rows + tags on every member page (apply_report_groups).
# (The Reports start page and the site map went 2026-09-30, user request.)
# Labels come from _report_groups. This reads the .rpt files, not the
# rendered HTML, so it does not
# depend on the report pages existing — but because the per-area publish scripts
# clear docs/<area>/*.html (which includes a previously written index), run this
# LAST: after bin/transfer/publish.sh, bin/server/publish.sh and
# bin/analyses/publish.sh. The analyses pages themselves — the Entities and Partners,
# Domains & Applications coverage tables and the docs/coverage/ cell pages —
# are rendered by bin/analyses/publish.sh, not here.
#
# Usage:  bin/build/publish.sh    (run after the per-area publish scripts)
#
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../publish_lib.sh"   # cd's to the repo root; defines html_head / _report_groups / …
source "$SCRIPT_DIR/../awklib.sh"       # $AWKLIB: the shared awk helpers (html_esc, …)

ensure_assets   # topbar-data.js (the menus' data file)

# THE HELP PAGES (2026-09-30, the lean round): assets/help/<slug>.html is a
# FRAGMENT — the page body from its <h1> on (an optional first line
# "<!-- help: back=page -->" words the back link "Back to the page" instead of
# "Back to the report") — and THIS is the one place its chrome comes from: the
# head (the no-cache trio, the stylesheet + top-bar scripts with their ?v=
# busters), the top-bar placeholder (assets/topbar.js fills it, like on every
# page; the "?" opens the generic help), the back + Generic help links (not on
# general.html itself) and the tail; the <title> is "Help: <the h1 text> —
# Axway ST reports". Read from assets/help/ (the source), written to
# docs/help/, so a re-run is idempotent. (Until 2026-09-30 every source carried
# the full page with a baked bar that render_shared_topbar re-stamped.) This is
# the one publish step that writes into docs/help/ (see CLAUDE.md).
apply_help_chrome() {
    local f out
    HC_SCRIPTS=$(topbar_scripts "../") HC_BAR=$(topbar_placeholder "../" "general")
    export HC_SCRIPTS HC_BAR
    for f in assets/help/*.html; do
        [ -f "$f" ] || continue
        out="docs/help/${f##*/}"
        awk -v av="${ASSET_VER:-}" -v gen="$([ "${f##*/}" = general.html ] && echo 0 || echo 1)" '
            NR == 1 && $0 == "<!-- help: back=page -->" { back = "page"; next }
            { body[++n] = $0
              if (title == "" && match($0, /<h1>.*<\/h1>/)) { title = substr($0, RSTART + 4, RLENGTH - 9); gsub(/<[^>]*>/, "", title) } }
            END {
                printf "<!doctype html>\n<html lang=\"en\">\n<head>\n<meta charset=\"UTF-8\">\n<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">\n"
                printf "<meta http-equiv=\"Cache-Control\" content=\"no-cache, no-store, must-revalidate\">\n<meta http-equiv=\"Pragma\" content=\"no-cache\">\n<meta http-equiv=\"Expires\" content=\"0\">\n"
                printf "<title>Help: %s — Axway ST reports</title>\n", title
                printf "<link rel=\"stylesheet\" href=\"../assets/style.css%s\">\n", (av != "" ? "?v=" av : "")
                printf "%s\n</head>\n<body>\n%s\n<main class=\"help-content\">\n", ENVIRON["HC_SCRIPTS"], ENVIRON["HC_BAR"]
                printf "<a class=\"help-back\" href=\"../index.html\" onclick=\"if(history.length>1){history.back();return false}\">&larr; Back to the %s</a>\n", (back == "page" ? "page" : "report")
                if (gen) printf "<a class=\"help-back help-generic\" href=\"general.html\">Generic help</a>\n"
                for (i = 1; i <= n; i++) print body[i]
                printf "</main>\n</body>\n</html>\n"
            }' "$f" > "$out.tmp" && mv "$out.tmp" "$out"
    done
}

# (THE REPORTS START PAGE — docs/reports/index.html, 2026-09-29, every report
# under its group with its one-line DESC, rg_desc — and THE SITE MAP —
# docs/tools/sitemap.html, one card per group + Dashboards + Tools — went
# 2026-09-30, user request: "remove the sitemap and the reports start page";
# the top bar reaches every group, help/general.html the build report.)


# Per-day figures for the home's per-day table (2026-09-29, user request:
# "Remove the Transfers, UC2 state, First seen subtables, remove the columns
# In & Out in the Files subtable … have only 14 days in the Date tables"):
# the Files group from the transfer topview.rpt per-day table (ROW fields
# 3-6; the Cured figure = its Recovered group's Automatic + Manual, fields
# 7-8 — the First / Last columns went 2026-09-30) and the Duration group from duration.rpt's "Duration per day —
# percentiles" table (Processed Files only). The transfer topview's days set
# the rows — the newest HOME_DAYS of them, newest first (a server-only day,
# the server export running a day ahead, would be a fully empty row). One
#   date ⇥ count ⇥ ok ⇥ cured ⇥ err ⇥ err% ⇥ 5 × (class ⇥ value)
# line per day, "-" for a missing field (the reader splits on a whitespace
# IFS, so an empty middle field would collapse). (The TOTAL sentinel — the
# shown days' own percentiles for the Total row — went with that row,
# 2026-09-29.)
HOME_DAYS=14
daily_loglines_tsv() {   # $1 = the data root (data)
    local trpt="$1/transfer/reports/topview.rpt" drpt="$1/transfer/reports/duration.rpt"
    [ -f "$trpt" ] || return 0
    local files=("$trpt"); [ -f "$drpt" ] && files+=("$drpt")
    local dl
    dl=$(awk -F'\t' -v N="$HOME_DAYS" '
        function nz(v) { return v == "" ? "-" : v }
        # a duration cell "@{class=dur-s}3 s" -> its class / its text ("-" when absent)
        function dcls(v) { if (v !~ /^@\{class=/) return "-"; sub(/^@\{class=/, "", v); sub(/\}.*/, "", v); return v }
        function dtxt(v) { sub(/^@\{[^}]*\}/, "", v); return v == "" ? "-" : v }
        function pv(v) { sub(/^@\{[^}]*\}/, "", v); return v }
        # the Duration group: p50/p75/p90/p95/p99 (ROW fields 8/9/10/11/13 — the
        # Average / Median columns before the percentiles since 2026-09-30) of the
        # "Duration per day — percentiles" table (the FIRST of its two
        # side-by-side tables)
        FILENAME ~ /duration\.rpt$/ {
            if ($1 == "TABLE") intab = ($2 == "Duration per day — percentiles")
            if (!intab || $1 != "ROW") next
            dd = $2; sub(/^@\{[^}]*\}/, "", dd)
            if (dd !~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$/) next
            for (p = 0; p < 5; p++) { c = (p == 4 ? 13 : 8 + p); dc[dd, p] = dcls($c); dv[dd, p] = dtxt($c) }
            hasdur[dd] = 1
            next
        }
        $1 != "ROW" { next }
        { dd = $2; sub(/^@\{[^}]*\}/, "", dd) }
        # the transfer topview ROW (bin/transfer/reports/topview.sh): the Files
        # group (Count Ok Error Error%) fields 3-6, the Recovered group
        # (Automatic Manual) fields 7-8 — Cured is their sum. A day cell that
        # links (Error, Automatic, Manual — 2026-10-01) leads with @{href=…}:
        # pv() takes the value behind it
        dd ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]/ { d = substr(dd, 1, 10)
            fc[d] = nz(pv($3)); fok[d] = nz(pv($4)); fer[d] = nz(pv($5)); fpc[d] = nz(pv($6)); frv[d] = (pv($7) + 0) + (pv($8) + 0); seen[d] = 1 }
        END {
            n = 0; for (k in seen) a[n++] = k
            for (i = 0; i < n; i++) for (j = i + 1; j < n; j++) if (a[j] > a[i]) { t = a[i]; a[i] = a[j]; a[j] = t }   # newest first
            for (i = 0; i < n && i < N; i++) {
                d = a[i]
                printf "%s\t%s\t%s\t%s\t%s\t%s", d, fc[d], fok[d], frv[d], fer[d], fpc[d]
                for (p = 0; p < 5; p++) printf "\t%s\t%s", ((d in hasdur) ? dc[d, p] : "-"), ((d in hasdur) ? dv[d, p] : "-")
                printf "\n"
            }
        }' "${files[@]}")
    [ -n "$dl" ] && printf '%s\n' "$dl"
    return 0
}

# One Status cell: a 0 renders blank; a nonzero value links its list page
# (an Entities view) when that page exists. $3 = the href RELATIVE TO THE DOCS
# ROOT (the home lives at the docs root), so the existence check is against
# docs/.
_stcell() {   # $1 value  $2 class  [$3 href, docs-root-relative]
    if [ "${1:-0}" = 0 ]; then printf '<td class="%s"></td>' "$2"; return 0; fi
    dotify_v "$1"
    if [ -n "${3:-}" ] && [ -f "docs/$3" ]; then
        printf '<td class="%s"><a href="%s">%s</a></td>' "$2" "$3" "$DOT"
    else
        printf '<td class="%s">%s</td>' "$2" "$DOT"
    fi
}

# The PERCENTAGE columns link the same page as the count they are a share of,
# so EVERY figure in a row is clickable — a share of a list is that list. A 0 %
# still renders (unlike a 0 count, which blanks): it is a real reading.
# Written tight ("71%") like every other percentage cell on the site
# (2026-09-30 audit L-14; "71&nbsp;%" before), under the "Seen %" / "OK %"
# headers (D-12: "Seen" / "OK" beside the count column "Ok" read as twins).
_pctvar() {   # $1 percentage  [$2 href, docs-root-relative]
    if [ -n "${2:-}" ] && [ -f "docs/$2" ]; then printf '<a href="%s">%s%%</a>' "$2" "$1"
    else printf '%s%%' "$1"; fi
}

# One result-status table (Total / Seen % / OK % / Error / Warning / Ok per
# member) — the analyses Status group as a standalone table. EVERY figure is
# the row count of the list page its cell links, so a number and its list can
# never disagree: every row links the Transfer > Entities views of that name
# (2026-07). (Until 2026-09-27 an "including server log" switch added the
# Transfer / Server columns — the BLUE server-log-only status, removed.)
#   $1 = coverage href prefix (docs-relative, e.g. "coverage/")
#   $2 = <h2> title   rest = label:member:basefile
# (the former $3 "rpt kind" is gone: both tables now read the SAME home.rpt,
# keyed by member, and every cell links the member's own Entities views)
_status_table() {
    local cov=$1 title=$2; shift 2
    printf '<div class="sxscol"><h2>%s</h2>\n<div class="tablewrap"><table class="index fit" data-nosearch="1">\n' "$title"
    printf '<tr><th>Entity</th><th class="num">Total</th><th class="num">Seen %%</th><th class="num">OK %%</th><th class="num">Error</th><th class="num">Warning</th><th class="num">Ok</th></tr>\n'
    # The figures are CALCULATED from the sources — Total / Error / Warning /
    # Ok from the base result column, Seen from home.rpt (one line per
    # member). They are NEVER lifted from the linked pages: the pages must
    # independently list the same rows, and check_status_consistency (run
    # after the home is written) warns LOUDLY on any figure/page divergence —
    # agreement is the proof, never the input.
    local spec label member bf n r o g seen
    local srpt="$HOME_ENV_DATA/analyses/reports/home.rpt"
    for spec in "$@"; do
        IFS=: read -r label member bf <<< "$spec"
        n=0; r=0; o=0; g=0
        if [ -f "$HOME_ENV_DATA/flow-manager/base/$bf.tsv" ]; then
            read -r n r o g <<< "$(awk -F'\t' '
                { n++; c[$3]++ }
                END { print n+0, c["red"]+0, c["orange"]+0, c["green"]+0 }' \
                "$HOME_ENV_DATA/flow-manager/base/$bf.tsv")"
        fi
        # Seen is the ONE figure the base caches cannot give: the configured
        # names that actually appear in the logs. bin/analyses/reports/home.sh
        # writes it per member (2026-07 — it replaced the 12-/16-figure
        # entities.rpt and pda.rpt, whose page is gone; the classic four lift
        # it from Show Seen, the PDA three re-run their both-ways merge).
        seen=0
        [ -f "$srpt" ] && seen=$(awk -F'\t' -v m="$member" '$1=="SEEN" && $2==m {print $3; exit}' "$srpt")
        seen=${seen:-0}
        # rounded percentages (of Total): Seen % and OK % (green). n/2 rounds.
        local seenp=0 okp=0
        if [ "$n" -gt 0 ]; then
            seenp=$(( (100 * seen + n / 2) / n ))
            okp=$(( (100 * g + n / 2) / n ))
        fi
        # Every Entity label of the classic four links its
        # Entities ALL view (transfer/entities/<name>-all.html — every Entities
        # view carries datereset, so it opens at the full date range even when a
        # From/To is active). The former PDA ENTITY HOME pages
        # (docs/entity/) were REMOVED 2026-07; their URLs 404.
        esc "$label"
        local ebase=""
        case $member in
            subscriptions) ebase=subscription ;; accounts) ebase=account ;;
            hosts) ebase=remote-host ;;         logins) ebase=login ;;
            logicals) ebase=logical ;;
            partners) ebase=partner ;;          applications) ebase=application ;;
            domains) ebase=domain ;;            bl) ebase=bl ;;
        esac
        local ent="${cov%coverage/}transfer/entities/$ebase"
        # ...EXCEPT the Logical + four PDA rows (2026-09-30, user request —
        # the Entity and Total links SWITCHED): their label links the
        # configured-side COVERAGE CELL page (falls back to the Entities All
        # view when that page is absent), and Total links the Entities All
        # view (below).
        local elink=""
        [ -n "$ebase" ] && [ -f "docs/$ent-all.html" ] && elink="$ent-all.html"
        case $member in
            logicals|partners|applications|domains|bl)
                [ -f "docs/$cov$member-configured.html" ] && elink="$cov$member-configured.html" ;;
        esac
        if [ -n "$elink" ]; then
            printf '<tr><td><a href="%s">%s</a></td>' "$elink" "$ESC"
        else
            printf '<tr><td>%s</td>' "$ESC"
        fi
        # WHERE THE FIGURES LINK. BOTH tables send every figure into its
        # Transfer > Entities view (2026-07: the PDA rows too — Partners,
        # Domains and Applications are Entities reports like the classic four,
        # so their figures have a view of their own) — the view whose row count
        # IS this figure (All / Seen / OK / Warning / Error, each carrying
        # datereset so it opens at the full date range). A member with NO
        # Entities report (none today) renders its figures unlinked (the
        # coverage-cell fallback went 2026-09-30 — those pages are gone).
        local h_tot="" h_seen="" h_err="" h_warn="" h_ok=""
        if [ -n "$ebase" ]; then
            h_tot="$ent-all.html"
            # (The Logical + four PDA rows' Total linked their COVERAGE CELL
            # page 2026-07..09-30; that page is now their Entity label's
            # link, see above.)
            h_seen="$ent-seen.html"
            h_err="$ent-error.html"
            h_warn="$ent-warning.html"
            h_ok="$ent-ok.html"
        fi
        # Total first, then the two % columns: Seen %, then OK % (green/Total).
        # EVERY figure in the row is a link, the percentages included — each
        # to the page its count links (a share of a list opens that list). Only
        # a 0, which renders as an EMPTY cell, has no link: there is no figure
        # to click.
        _stcell  "$n"             "num"                 "$h_tot"
        printf '<td class="num">%s</td>' "$(_pctvar "$seenp" "$h_seen")"
        printf '<td class="num">%s</td>' "$(_pctvar "$okp" "$h_ok")"
        _stcell  "$r"             "num st-err"          "$h_err"
        _stcell  "$o"             "num st-warn"         "$h_warn"
        _stcell  "$g"             "num st-ok"           "$h_ok"
        printf '</tr>\n'
    done
    printf '</table></div></div>\n'
}

# The two result-status tables side by side (sxs: titles aligned on one row),
# for the root index. $1 = coverage href prefix (docs-relative).
write_status_pair() {
    local cov=$1
    printf '<div class="sxs">\n'
    _status_table "$cov" "Flow manager entities" \
        "Subscriptions:subscriptions:_subscriptions" \
        "Accounts:accounts:_accounts" "Hosts:hosts:_hosts" "Logins:logins:_logins"
    _status_table "$cov" "Logical, Partners, Domains, Applications &amp; BL" \
        "Logical:logicals:_logicals" \
        "Partners:partners:_partners" "Domains:domains:_domains" "Applications:applications:_apps" \
        "BL:bl:_bl"
    printf '</div>\n'
}

# One Duration cell: keeps the .rpt's dur-s/m/h tint class; "-" (no data or
# no class) renders an empty/plain num cell. Prints the <td>.
_durcell() {   # $1 class-or-"-"  $2 value-or-"-"
    if [ "$2" = "-" ]; then printf '<td class="num"%s></td>' "${DURGO:-}"; return 0; fi   # DURGO: the home Duration group link (2026-09-13)
    esc "$2"
    if [ "$1" = "-" ]; then printf '<td class="num"%s>%s</td>' "${DURGO:-}" "$ESC"
    else printf '<td class="num %s"%s>%s</td>' "$1" "${DURGO:-}" "$ESC"; fi
}

# One per-day Date cell (the four per-day tables): sets $dcc to the escaped
# date, linked to the day's combined dashboard when that page exists.
_daycell() {   # $1 = date
    esc "$1"; dcc=$ESC
    [ -f "docs/day/$1.html" ] && dcc="<a href=\"day/$1.html\">$ESC</a>"
    return 0
}

# (The home page's red worklists — "Failing transfers" / "Failing
# subscriptions in Server log", write_failing_now — and "The log exports"
# facts table, write_log_facts, went 2026-09-29, user request: the Failed
# Subscriptions page and the build report carry them.)

# The home-page content: the status pair and the per-day table, all links
# docs-root-relative (the home lives at the docs root). Reads $HOME_ENV_DATA
# (set by the caller).
write_home_block() {
    # The two result-status tables (copied from the Flow manager Entities /
    # Logical, Partners, Domains, Applications & BL analyses pages), side by side with
    # coverage links — a status snapshot at the TOP of the landing page.
    if [ -f "$HOME_ENV_DATA/analyses/reports/home.rpt" ] || [ -f "$HOME_ENV_DATA/flow-manager/base/_subscriptions.tsv" ]; then
        write_status_pair "coverage/"
    fi
    # The per-day figures: the Files and Duration groups of ONE table, and
    # beside it the Errors table (2026-09-29, user request).
    local dl; dl=$(daily_loglines_tsv "$HOME_ENV_DATA")
    # ONLY with TRANSFERS (2026-08-29): the table renders only when at least
    # one DAY line carries transfer Files (field 2); a config-only estate
    # gets none.
    local _hastx=""
    [ -n "$dl" ] && _hastx=$(printf '%s\n' "$dl" | awk -F'\t' '$1!="" && $2!="" && $2!="-" { print 1; exit }')
    [ -n "$_hastx" ] || return 0
    # THE PER-DAY TABLE (2026-08-31, user request — ONE table): the Files
    # and Duration groups (the Transfers, UC2 state and First seen groups and
    # the Files In / Out columns went 2026-09-29, user request) are column
    # GROUPS of one table, a gband banner row over a shared Date column (its
    # cells link the day's page). The group dividers are SPACER columns
    # (th/td.spc — no borders, page background), one before each group, so
    # each group has its own table-like edges and the row lines stop at the
    # gaps.
    #
    # THE NEWEST 14 DAYS (HOME_DAYS; 2026-09-29, user request "have only 14
    # days in the Date tables" — the same morning every day showed), and NO
    # Total row (later that day, user request "remove the Total row in the
    # date tables"). The Duration banner / p-headers open the report at the
    # same FROM..TO range. data-nosort: the rows stay newest first.
    local dfrom dto
    dto=$(printf '%s\n' "$dl" | awk -F'\t' '$1!="" { print $1; exit }')
    dfrom=$(printf '%s\n' "$dl" | awk -F'\t' '$1!="" { d = $1 } END { print d }')
    local rng="$dfrom..$dto"
    local d fc fok frv fer fpc
    local dc50 dv50 dc75 dv75 dc90 dv90 dc95 dv95 dc99 dv99 dcc=""
    # every cell of the Duration group opens transfer/duration.html (2026-09-14,
    # user request): the banner and the p-headers at the shown FROM..TO
    # range, each day's five cells with ?axway_row=<that date> — the
    # row marked. data-href on the cell; report.js setupCellLinks navigates
    # there and outranks the row link
    local DURGO=""; [ -f docs/transfer/duration.html ] && DURGO=" data-href=\"transfer/duration.html?axway_date=$rng\""
    printf '<div class="sxs homeday">\n<div class="sxscol">\n'
    printf '<div class="tablewrap perday"><table class="index fit dayrows" data-nosearch="1" data-nosort="1">\n'
    printf '<tr class="gbrow"><th></th><th class="spc"></th><th class="gband" colspan="4">Files</th><th class="spc"></th><th class="gband" colspan="5"%s>Duration</th></tr>\n' "$DURGO"
    printf '<tr><th>Date</th><th class="spc"></th><th class="num">Ok</th><th class="num">Cured</th><th class="num">Error</th><th class="num">Error %%</th><th class="spc"></th><th class="num"%s>p50</th><th class="num"%s>p75</th><th class="num"%s>p90</th><th class="num"%s>p95</th><th class="num"%s>p99</th></tr>\n' \
        "$DURGO" "$DURGO" "$DURGO" "$DURGO" "$DURGO"
    while IFS=$'\t' read -r d fc fok frv fer fpc dc50 dv50 dc75 dv75 dc90 dv90 dc95 dv95 dc99 dv99; do
        [ -n "$d" ] || continue
        _daycell "$d"
        printf '<tr><td>%s</td><td class="spc"></td>' "$dcc"
        # —— Files (from transfer/topview.html): Ok / Cured / Error tinted
        # like that page's cells, a 0 an empty cell (the render_rpt.awk
        # convention) ——
        if [ "$fc" != "-" ] && [ -n "$fc" ]; then
            if [ "$fok" = "-" ] || [ "$fok" = 0 ]; then printf '<td class="num processed z"></td>'; else
                dotify_v "$fok"; esc "$DOT"; printf '<td class="num processed">%s</td>' "$ESC"; fi
            # Cured, amber like topview's Recovered cells; a nonzero cell
            # opens the Recovered files report narrowed to that day
            # (2026-09-01, user request)
            if [ "$frv" = "-" ] || [ "$frv" = 0 ] || [ -z "$frv" ]; then printf '<td class="num warn"></td>'; else
                dotify_v "$frv"; esc "$DOT"
                if [ -f "docs/transfer/retries-recovered-files.html" ]; then
                    printf '<td class="num warn"><a href="transfer/retries-recovered-files.html?axway_date=%s">%s</a></td>' "$d" "$ESC"
                else printf '<td class="num warn">%s</td>' "$ESC"; fi; fi
            # Error opens the FAILED FILES list narrowed to its day
            # (2026-09-14, user request); the empty ?axway_search= clears a
            # search the subscription pages' Error cells left remembered
            if [ "$fer" = "-" ] || [ "$fer" = 0 ]; then printf '<td class="num failed z"></td>'; else
                dotify_v "$fer"; esc "$DOT"
                if [ -f "docs/transfer/failed-files.html" ]; then
                    printf '<td class="num failed"><a href="transfer/failed-files.html?axway_date=%s&amp;axway_search=">%s</a></td>' "$d" "$ESC"
                else printf '<td class="num failed">%s</td>' "$ESC"; fi; fi
            if [ "$fpc" = "-" ]; then printf '<td class="num"></td>'; else
                esc "$fpc"; printf '<td class="num">%s</td>' "$ESC"; fi
        else
            printf '<td class="num processed"></td><td class="num warn"></td><td class="num failed"></td><td class="num"></td>'
        fi
        printf '<td class="spc"></td>'
        # —— Duration (from transfer/duration.html): the day's p50 … p99,
        # tinted like that page's cells; the day's own link marks that row
        local _durgo_rng=$DURGO
        [ -n "$DURGO" ] && DURGO=" data-href=\"transfer/duration.html?axway_row=$d\""
        _durcell "$dc50" "$dv50"; _durcell "$dc75" "$dv75"
        _durcell "$dc90" "$dv90"; _durcell "$dc95" "$dv95"; _durcell "$dc99" "$dv99"
        DURGO=$_durgo_rng
        printf '</tr>\n'
    done <<< "$dl"
    # (the Total row went 2026-09-29, user request: "remove the Total row in
    # the date tables")
    printf '</table></div>\n</div>\n'
    printf '<div class="sxscol">\n'
    write_home_errors
    printf '</div>\n</div>\n'
}

# THE ERRORS TABLE beside the per-day table (2026-09-29, user request: "Have a
# table Errors side by side to the Date table — the columns Subscription /
# Date/time / Reason from /analyses/failed.html"): every RED row of Failed
# Subscriptions (data/transfer/reports/failed.rpt, its one table — the
# orange ones left out, same day's request), newest first, red-tinted like
# that page. The Subscription cell opens what the row
# opens there — the File's (or the server-failing flow's) page under files/ —
# and an unpaged row's name its detail page; the banner opens the report.
# PLUS THE RED HOSTS AND LOGINS (2026-10-01, user request: "Hosts with
# problems, eq the rows on /transfer/entities/remote-host-error.html must also
# be showed in the Errors table on the homepage. If the host is the endpoint
# of an UC1 or UC3 subscription that is already in the Error table then do not
# show it" — the same for logins and UC2 / UC4; "Rename Subscriptions to
# Entity"): home_err_entities below; the first column reads "Entity".
write_home_errors() {
    local rpt="$HOME_ENV_DATA/transfer/reports/failed.rpt"
    local smap="$HOME_ENV_DATA/transfer/reports/details/subscriptions/_slugmap.tsv"
    [ -f "$rpt" ] || return 0
    # the banner opens the report the way the Duration banner does (data-href,
    # report.js setupCellLinks) — a plain link would take the header's white
    local ban=""; [ -f docs/analyses/failed.html ] && ban=' data-href="analyses/failed.html"'
    printf '<div class="tablewrap perday"><table class="index fit dayrows homeerr" data-nosearch="1" data-nosort="1" data-restint="1">\n'
    printf '<tr class="gbrow"><th class="gband" colspan="3"%s>Errors</th></tr>\n' "$ban"
    printf '<tr><th>Entity</th><th>Date/time</th><th>Reason</th></tr>\n'
    [ -f "$smap" ] || smap=/dev/null
    # one stream of "stamp TAB name TAB href TAB reason TAB colour" lines: the
    # subscription rows, then the host / login rows — sorted together, newest
    # first (a row without a stamp sorts last)
    { LC_ALL=C awk -F'\t' -v SMAP="$smap" '
        BEGIN { while ((getline l < SMAP) > 0) { split(l, m, "\t"); if (m[1] != "") { SL[m[1]] = m[2]; if (!(toupper(m[1]) in SU)) SU[toupper(m[1])] = m[2] } } close(SMAP) }
        $1 == "TABLE" { t++ }
        t != 1 || $1 != "ROW" { next }
        {   nm = $2; href = ""
            if (substr(nm, 1, 2) == "@{") { at = substr(nm, 3, index(nm, "}") - 3); nm = substr(nm, index(nm, "}") + 1)
                na = split(at, A, ","); for (i = 1; i <= na; i++) if (substr(A[i], 1, 5) == "href=") href = substr(A[i], 6) }
            sub(/^\.\.\//, "", href)
            if (href == "") { sg = (nm in SL) ? SL[nm] : ((toupper(nm) in SU) ? SU[toupper(nm)] : ""); if (sg != "") href = "details/subscriptions/" sg ".html" }
            res = ""; for (i = 3; i <= NF; i++) if (substr($i, 1, 10) == "@data:res=") res = substr($i, 11)
            if (res != "red") next   # the RED rows only (2026-09-29, user request: "show only the Errors (red) and not the warnings (orange)")
            print $3 "\t" nm "\t" href "\t" $4 "\t" res }' "$rpt"
      home_err_entities "$HOME_ENV_DATA"
    } | LC_ALL=C sort -t$'\t' -k1,1r -k2,2 \
    | awk -F'\t' "$AWKLIB"'
        { c = ($3 != "") ? "<a href=\"" html_esc($3) "\">" html_esc($2) "</a>" : html_esc($2)
          # Date/time to the minute (2026-09-29, user request: "only hh:mm,
          # no ss.mmm") — the rows still sort on the full stamp above
          t = $1; if (t ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]/) t = substr(t, 1, 16)
          printf "<tr%s><td>%s</td><td>%s</td><td>%s</td></tr>\n", ($5 ~ /^(green|orange|red)$/ ? " data-res=\"" $5 "\"" : ""), c, html_esc(t), html_esc($4) }'
    printf '</table></div>\n'
}

# THE RED HOSTS AND LOGINS of the home Errors table (2026-10-01, user
# request — see write_home_errors): every row of the Entities Remote hosts /
# Logins Error views (base/_hosts.tsv / _logins.tsv col 3 = red) EXCEPT a host
# that is the endpoint of a UC1 or UC3 subscription — a login the user of a
# UC2 or UC4 subscription — that already has its row in the table (a red row
# of failed.rpt). A subscription's use case: its name prefix UC1..UC4, else
# the derived one (xref/_subscriptions-ucderived.tsv — the Partners in / out
# rule). "Connected" = the colour rollup's own pairs (bin/build/result.sh):
# the configured xref/_<kind>-subscriptions.tsv plus the observed ones
# (colour/_observed-<kind>.tsv) — for a host also every subscription whose
# OUT-connection File went through it (colour/_hostlegs.tsv col 4), so a
# discovered host is matched to the flows it served.
# The row: the name, linking its detail page (details/<kind>/<slug>.html —
# the table is an index table, so the WHOLE row opens it), and the NEWEST
# piece of the evidence that made it red, the stamp and its reason:
#   - the E-level server-log line attributable to no flow that the entity's
#     own ring kept (colour/_ringorphan.tsv — result.sh orphan_red), its
#     reason classified from the ring line (bin/flip-reason.awk; "Server log
#     error" when nothing matches);
#   - a HOST with no configured subscription: its last OUT-connection File
#     when that one Failed (result.sh host_own_unpaired), the reason of
#     failed-files.rpt for it;
#   - a connected RED subscription whose use case did not exclude the row:
#     that subscription's newest red failed.rpt row (stamp and reason).
# Same five-field lines as the subscription rows: stamp, name, href, reason,
# colour.
home_err_entities() {   # $1 = the data root
    local d=$1 kind tab pairs uc red evid
    local fr="$d/transfer/reports/failed.rpt" ff="$d/transfer/reports/failed-files.rpt"
    local ucd="$d/flow-manager/xref/_subscriptions-ucderived.tsv" legs="$d/colour/_hostlegs.tsv"
    local orph="$d/colour/_ringorphan.tsv" iph="input/ip/ip-hosts.tsv"
    [ -f "$fr" ] || return 0
    [ -f "$ff" ] || ff=/dev/null; [ -f "$ucd" ] || ucd=/dev/null; [ -f "$legs" ] || legs=/dev/null
    [ -f "$orph" ] || orph=/dev/null; [ -f "$iph" ] || iph=/dev/null
    for kind in hosts logins; do
        [ -f "$d/flow-manager/base/_$kind.tsv" ] || continue
        case $kind in hosts) uc="UC1 UC3" ;; logins) uc="UC2 UC4" ;; esac
        pairs="$d/flow-manager/xref/_$kind-subscriptions.tsv"; [ -f "$pairs" ] || pairs=/dev/null
        local obs="$d/colour/_observed-$kind.tsv"; [ -f "$obs" ] || obs=/dev/null
        local smap="$d/transfer/reports/details/$kind/_slugmap.tsv"; [ -f "$smap" ] || smap=/dev/null
        local klegs=/dev/null; [ "$kind" = hosts ] && klegs=$legs
        LC_ALL=C awk -F'\t' -v KIND="$kind" -v UCS="$uc" -v FR="$fr" -v FF="$ff" -v UCD="$ucd" \
            -v PAIRS="$pairs" -v OBS="$obs" -v LEGS="$klegs" -v ORPH="$orph" -v IPH="$iph" -v SMAP="$smap" \
            -v RINGS="$d/server/cache/$kind" "$(cat bin/flip-reason.awk)"'
            function uco(s,   u) { u = toupper(s); if (u ~ /^UC[1-4][-_]/) return substr(u, 1, 3); return (u in UD) ? UD[u] : "" }
            function strip(c) { sub(/^@\{[^}]*\}/, "", c); return c }
            function cand(t, st, why) { if (st > EST[k] || !(k in EST)) { EST[k] = st; EWH[k] = why } }
            BEGIN {
                n = split(UCS, a, " "); for (i = 1; i <= n; i++) WANT[a[i]] = 1
                while ((getline l < UCD) > 0) { split(l, a, "\t"); if (a[1] != "") UD[toupper(a[1])] = a[2] } close(UCD)
                # the subscriptions IN the table (the red failed.rpt rows) and
                # the newest red row of each: its stamp and reason
                while ((getline l < FR) > 0) { m = split(l, a, "\t")
                    if (a[1] == "TABLE") tb++
                    if (tb != 1 || a[1] != "ROW") continue
                    r = 0; for (i = 3; i <= m; i++) if (a[i] == "@data:res=red") r = 1
                    if (!r) continue
                    u = toupper(strip(a[2])); INT[u] = 1
                    if (!(u in SST) || a[3] > SST[u]) { SST[u] = a[3]; SWH[u] = a[4] } }
                close(FR)
                while ((getline l < SMAP) > 0) { split(l, a, "\t"); if (a[1] != "" && !(toupper(a[1]) in SLG)) SLG[toupper(a[1])] = a[2] } close(SMAP)
            }
            FILENAME == ARGV[1] { if ($3 == "red") { RED[toupper($1)] = $1 } next }            # base/_<kind>.tsv
            FILENAME == ARGV[2] || FILENAME == ARGV[3] {                                      # configured + observed pairs
                k = toupper($1); if (!(k in RED) || $2 == "") next
                if (FILENAME == ARGV[2]) CONF[k] = 1
                PS[k, toupper($2)] = 1; next }
            FILENAME == ARGV[4] {                                                             # hosts: the leg pairs + the last OUT File
                k = toupper($1); if (!(k in RED)) next
                if ($4 != "") PS[k, toupper($4)] = 1
                if ($2 >= LSK[k]) { LSK[k] = $2; LOC[k] = $3; LSU[k] = $4 }
                next }
            END {
                for (k in RED) {
                    # EXCLUDED: connected to a subscription of the wanted use
                    # cases that already has its row in the table
                    skip = 0
                    for (p in PS) { split(p, q, SUBSEP); if (q[1] != k) continue
                        if ((q[2] in INT) && (uco(q[2]) in WANT)) { skip = 1; break }
                        if ((q[2] in INT) && (!(k in SEV) || SST[q[2]] > SEV[k])) { SEV[k] = SST[q[2]]; SRW[k] = SWH[q[2]] } }
                    if (skip) continue
                    KEEP[k] = 1
                    if (k in SEV) cand(k, SEV[k], SRW[k])
                    # a host with no configured subscription whose last OUT File failed
                    if (KIND == "hosts" && !(k in CONF) && LOC[k] == "Failed") {
                        st = substr(LSK[k], 1, 4) "-" substr(LSK[k], 5, 2) "-" substr(LSK[k], 7, 2) " " substr(LSK[k], 9)
                        NEEDF[toupper(LSU[k]) SUBSEP st] = k; FST[k] = st }
                }
                # the reason of that File (failed-files.rpt: Subscription,
                # Date/time, Error reason — the File start to the millisecond)
                if (length(NEEDF) > 0) {
                    while ((getline l < FF) > 0) { split(l, a, "\t"); if (a[1] != "ROW") continue
                        key = toupper(strip(a[2])) SUBSEP a[3]; if (key in NEEDF) FRS[NEEDF[key]] = strip(a[4]) }
                    close(FF) }
                for (k in FST) cand(k, FST[k], ((k in FRS) && FRS[k] != "" && FRS[k] != "-") ? FRS[k] : "Failed File")
                # the orphan server-log line (result.sh orphan_red): its stamp,
                # the reason classified from the ring line itself — the
                # endpoint ring itself or the ring of one of its forward addresses
                kk = (KIND == "hosts") ? "hosts" : "logins"
                while ((getline l < ORPH) > 0) { split(l, a, "\t"); if (a[1] == kk && (toupper(a[2]) in KEEP)) OST[toupper(a[2])] = a[3] } close(ORPH)
                if (KIND == "hosts") { while ((getline l < IPH) > 0) { split(l, a, "\t"); if (a[1] != "" && (toupper(a[2]) in OST)) ALT[toupper(a[2])] = ALT[toupper(a[2])] " " a[1] } close(IPH) }
                for (k in OST) {
                    why = ""; n = split(RED[k] ALT[k], F, " ")
                    for (i = 1; i <= n && why == ""; i++) { f = RINGS "/" F[i] "_err_warn.tsv"
                        while ((getline l < f) > 0) { split(l, a, "\t"); if (a[3] == "E" && a[1] " " a[2] == OST[k]) { why = flip_reason(a[5]); if (why == "") why = "Server log error"; break } }
                        close(f) }
                    cand(k, OST[k], (why != "") ? why : "Server log error") }
                for (k in KEEP) {
                    h = (k in SLG) ? "details/" KIND "/" SLG[k] ".html" : ""
                    printf "%s\t%s\t%s\t%s\tred\n", ((k in EST) ? EST[k] : ""), RED[k], h, ((k in EWH) ? EWH[k] : "") }
            }' "$d/flow-manager/base/_$kind.tsv" "$pairs" "$obs" "$klegs"
    done
}

# (The Report finder — docs/tools/report-finder.html, its FINDER_AWK row
# builder and report.js setupReportFinder + the Ctrl+K palette that read it —
# went 2026-09-29, user request; the KEYWORDS .rpt lines only it read went too.)


# (What is new — docs/tools/whats-new.html, write_whats_new and its wn_*
# helpers, built from git log into the tracked bin/build/whats-new-history.tsv
# — went 2026-09-29, user request: "remove /tools/whats-new.html".)

# The 404 page (docs/404.html) — what GitHub Pages (and any webserver
# configured for it) serves for a URL that matches nothing at all, instead of
# the stock error page. SELF-CONTAINED on purpose: Pages serves this page AT
# THE REQUESTED URL (any depth), so relative hrefs — stylesheet included —
# would resolve against the missing page's directory and 404 too. Inline
# style only, and the home link is derived at runtime: the path before the
# FIRST known top-level directory of the site (the list is taken from docs/
# as it stands when this runs — last of the publishes), else the missing
# URL's own directory; a trailing acceptance/ or production/ segment is
# stripped either way (the pre-2026-09 bookmarks) — base-path-free, so the
# same page works at /develop/, a Pages project base or a server root.
write_root_404() {
    local out="docs/404.html" dirs
    dirs=$(cd docs && ls -d */ 2>/dev/null | sed 's#/$##' | LC_ALL=C sort | tr '\n' '|' | sed 's/|$//')
    # the RETIRED top-level dirs stay KNOWN, so an old bookmark into one still
    # finds the home link: errors/ (2026-09-21: its pages moved into files/),
    # latest/ (2026-09-29: the Latest files pages, now the subscription pages'
    # Files table), switches/ (2026-09-06: the home Red/Green switch pages) and
    # reports/ (2026-09-30: the Reports start page) — and tools/, which holds
    # only the build report now, written by bin/build.sh's EXIT trap AFTER
    # this runs (the site map that created it here went 2026-09-30; audit A4-01)
    dirs="${dirs:+$dirs|}errors|latest|switches|reports|tools"
    {
        printf '<!DOCTYPE html>\n<html lang="en">\n<head>\n<meta charset="utf-8">\n'
        printf '<meta name="viewport" content="width=device-width, initial-scale=1">\n'
        # never cache (2026-09-12) — the same trio html_head bakes into every page
        printf '<meta http-equiv="Cache-Control" content="no-cache, no-store, must-revalidate">\n<meta http-equiv="Pragma" content="no-cache">\n<meta http-equiv="Expires" content="0">\n'
        printf '<title>Page not found — Axway ST reports</title>\n'
        printf '<style>body{font-family:Arial,Helvetica,sans-serif;background:#f7f7f9;color:#222;text-align:center;padding:5rem 2rem}h1{color:#20344a}a{color:#1a5dab}</style>\n'
        printf '</head>\n<body>\n'
        printf '<h1>Page not found</h1>\n'
        printf '<p>There is no page at this address.</p>\n'
        # (2026-09-29) the likeliest dead bookmark is a retired report — the
        # 2026-09-29 consolidation removed the area start pages and many
        # reports — so the page explains it (its "All reports" link to the Reports
        # start page went 2026-09-30 with that page; the home link stays)
        printf '<p>Reports are renamed, merged or retired now and then, and the site dropped its environment level in 2026-09 (<code>production/&hellip;</code> became <code>&hellip;</code>), so an older bookmark may need updating: the top bar of the home page opens every report group.</p>\n'
        printf '<p><a id="homelink" href="/"><strong>Go to the home page</strong></a></p>\n'
        printf '<script>(function(){var p=location.pathname,m=p.match(/^(.*?\\/)(?:%s)\\//);var r=m?m[1]:p.replace(/[^/]*$/,"");r=r.replace(/(?:acceptance|production)\\/$/,"");document.getElementById("homelink").href=r+"index.html";})();</script>\n' "$dirs"
        printf '</body>\n</html>\n'
    } > "$out"
}

# The root landing page — everything centered (body class "home", style.css):
# the status snapshot and the per-day table of THIS checkout's one environment
# (2026-09-11; the per-env .envblock toggle went with the env split). The title
# carries the environment label. Navigation is the top bar.
write_root_index() {
    local out="docs/index.html" title="Axway ST reports"
    [ -n "${ENV_LABEL:-}" ] && title="Axway ST reports — $ENV_LABEL"
    {
        html_head "$title" "assets/style.css" "" "" "home" "" "" "home"   # its own help page (2026-09-29: it opened the Reports-menu help)
        esc "$title"; printf '<h1>%s</h1>\n' "$ESC"
        HOME_ENV_DATA="data"
        write_home_block
        # the BUILD STAMP at the bottom (2026-09-30, user request: "Have at the
        # bottom of the home page a link \"Build on yyyy-mm-dd hh:mm:ss\" that
        # points to the build.html page") — the build's start, bin/build.sh
        # AXWAY_BUILD_START; a publish run on its own knows no build and says so
        if [ -n "${AXWAY_BUILD_START:-}" ]; then
            esc "Build on $AXWAY_BUILD_START"
        else
            esc "Build report"
        fi
        printf '<p class="buildstamp"><a href="tools/build.html">%s</a></p>\n' "$ESC"
        printf '</body>\n</html>\n'
    } > "$out"
}

# The home status tables' figures are CALCULATED (base caches + analyses
# rpts) while their cells link a LIST page — a Transfer > Entities view, or
# (the five derived members' Entity label) a coverage cell page whose rows the
# row's Total counts — two INDEPENDENT
# derivations that must agree.
# Verify every linked figure against its page's row count (the cell rpt's ROW
# lines / the rendered view's "Total (N …)" footer) and warn LOUDLY on any
# divergence: a mismatch means a real bug in one of the derivations (never
# paper it over by lifting the number from the page).
check_status_consistency() {
    local mism=0 href num rows page
    while IFS=$'\t' read -r href num; do
        # EVERY home figure links a Transfer > Entities VIEW (2026-07 — the
        # coverage cell pages are gone, with the branch that checked them).
        # The home figures count CONFIGURED entities (the base caches), while a
        # view also lists the names that were logged but are not in FlowManager
        # — untinted rows, no data-res. So the comparable figure is the view's
        # TINTED row count; only where a view carries no tint at all (Not seen:
        # its rows are name-only) does the "Total (N …)" footer stand in.
        page="docs/$href.html"
        [ -f "$page" ] || { echo "CONSISTENCY WARNING: home links $href.html ($num) but the page is missing" >&2; mism=$((mism+1)); continue; }
        # (|| true: a view with no tinted row makes grep exit 1, which
        # pipefail would turn into a script exit)
        rows=$( { grep -o 'data-res="[a-z]*"' "$page" || true; } | wc -l | tr -d ' ')
        # the page's own "Total (N …)" footer — the figure the VIEWER reads.
        # Compared unconditionally (2026-08-15 audit finding A2): an untinted
        # logged-but-unconfigured row passes the tinted-row count silently,
        # yet the visible footer then contradicts the home cell.
        foot=$(perl -ne 'if (m{<tr class="total"><td>Total \(([\d.,]+)}) { $n = $1; $n =~ s/[.,]//g; print "$n\n"; exit }' "$page")
        [ "${rows:-0}" = 0 ] && rows=$foot
        if [ "${rows:-}" != "${num//./}" ]; then
            echo "CONSISTENCY WARNING: home shows $num for $href but the page lists ${rows:-no} row(s)" >&2
            mism=$((mism+1))
        elif [ -n "${foot:-}" ] && [ "$foot" != "${num//./}" ]; then
            # NAME the culprits (2026-08-31): the data rows without a
            # data-res tint — the base cache has no row for them, so the
            # log says which name leaked instead of sending the reader to
            # the page to look for an uncoloured row
            # (perl stops at five itself: a `| head -5` could SIGPIPE perl,
            # and under pipefail + set -e that killed the last publish step)
            leak=$(perl -ne 'next if !/<tr\b/ || /class="total"/ || /data-res=/ || /<th/; if (m{<td[^>]*>(?:<a[^>]*>)?([^<]+)}) { print "$1\n"; exit if ++$n >= 5 }' "$page" | tr '\n' ' ')
            echo "CONSISTENCY WARNING: home shows $num for $href but the page's Total footer says $foot — an untinted (unconfigured) row leaked into the view: ${leak:-(name not extracted)}" >&2
            mism=$((mism+1))
        fi
    done < <(perl -ne 'while (m{<a href="((?:transfer/entities|coverage)/[a-z0-9-]+)\.html">([\d.]+)</a>}g) { print "$1\t$2\n" }
        while (m{<tr><td><a href="(coverage/[a-z0-9-]+)\.html">[^<]*</a></td><td class="num"><a href="[^"]*">([\d.]+)</a>}g) { print "$1\t$2\n" }' docs/index.html 2>/dev/null)
    # (the coverage/ pages, 2026-08-31 audit: the five derived members —
    # Logical / Partners / Domains / Applications / BL — link a coverage cell
    # page and escaped this gate; their pages carry the same tinted rows +
    # "Total (N)" footer, so the comparison above applies unchanged. Since
    # 2026-09-30 that page is the ENTITY LABEL's link, not the Total's: the
    # second perl match pairs it with the row's Total figure)
    if [ "$mism" -gt 0 ]; then
        echo "CONSISTENCY WARNING: $mism home status figure(s) disagree with their linked pages — investigate, do not mask." >&2
    else
        echo "Home status figures verified against their linked pages." >&2
    fi
}

# laps (2026-09-27): TIME lines on the build console, like the other steps
_bpl0=$(date +%s)
_bplap() { local _t1; _t1=$(date +%s); printf 'TIME %5ds  index pages: %s\n' "$((_t1 - _bpl0))" "$1" >&2; _bpl0=$_t1; }
write_root_index
_bplap "write_root_index"
write_root_404
_bplap "write_root_404"
check_status_consistency
_bplap "check_status_consistency"

# Every report page is rendered by now (this runs LAST), so give every page of
# every report group its FIRST ROW (the group's members) and its h1 group tag
# "&larr; Group" — publish_lib apply_report_groups, the _report_groups table.
apply_report_groups
_bplap "apply_report_groups (the group rows + h1 tags)"

# The shared help pages' chrome (the site top bar on every help page).
apply_help_chrome
_bplap "apply_help_chrome"

echo "Wrote index pages (root + the Reports start page)." >&2
