#!/usr/bin/env bash
#
# bin/build/publish.sh — write the index pages of the site:
#   docs/index.html            the root landing page (all parts centered):
#                              the two result-status tables and the per-day
#                              table — one environment per checkout since
#                              2026-09-11, so ONE block; the title carries the
#                              environment label (input/environment.txt)
#   docs/reports/index.html    the Reports start page (every group, 2026-09-29 —
#                              it replaced the transfer/, server/ and analyses/
#                              catalogs)
#   docs/tools/                What is new, the site map
#   docs/404.html              the not-found page
# then the group rows + tags on every member page (apply_report_groups).
#
# Labels/descriptions come from _report_groups and each report's DESC
# (rg_desc). This reads the .rpt files, not the rendered HTML, so it does not
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

ensure_assets   # topbar-data.js (the menus' data file)

# Give the hand-authored help pages the EXACT site top bar (the user asked for
# one consistent interface). The help BODY stays hand-authored; only the chrome
# is regenerated — render_shared_topbar. (The footer bar went 2026-07; no help
# page carries one any more.)
# This is the one publish step that writes into docs/help/ (see CLAUDE.md).
apply_help_chrome() {
    local tb f tmp
    tb=$(render_shared_topbar "../" "index")
    for f in docs/help/*.html; do
        [ -f "$f" ] || continue
        tmp=$(mktemp "${TMPDIR:-/tmp}/help.XXXXXX")
        awk -v tb="$tb" '
            /^<div class="topbar"><a class="brand"/         { print tb; next }
            { print }
        ' "$f" > "$tmp" && mv "$tmp" "$f"
    done
}

# THE REPORTS START PAGE (docs/reports/index.html, 2026-09-29, user request:
# one Reports pulldown instead of Transfer reports / Server reports /
# Analyses / Goodies — it replaced their three start pages transfer/,
# server/ and analyses/index.html): every report under its group, the
# _report_groups order, each with its one-line description. The menu's
# "Start page" line opens it.
# rg_desc MEMBER -> RG_DESC, the member's one-line description: the report's
# DESC, or the fixed text of a hand-written page (they carry no .rpt). Sets a
# global instead of echoing, and reads the DESC lines of every .rpt in ONE awk
# pass on first use — the start page and the finder asked ~100 times, each a
# subshell plus a field1 fork (2026-09-29 audit: ~1 s). The DESCs land in one
# variable per .rpt, RGD_<path escaped injectively like wn_meta_cached's memo>
# (bash 3.2 has no associative arrays, and a glob match over one big string of
# them took ~0.2 s per lookup in a UTF-8 locale).
RG_DESC_LOADED=0
rg_key() {   # $1 path -> RG_KEY, a variable-name-safe injective escape ("" = unsafe path)
    local k=$1
    case $k in *[!A-Za-z0-9/_.-]*) RG_KEY=""; return 0 ;; esac
    k=${k//_/_u}; k=${k//-/_h}; k=${k//\//_s}; k=${k//./_d}; RG_KEY=$k
}
rg_desc_load() {
    local x fs=()
    RG_DESC_LOADED=1
    for x in "$DATA"/transfer/reports/*.rpt "$DATA"/transfer/reports/entities/*.rpt "$DATA"/server/reports/*.rpt "$DATA"/analyses/reports/*.rpt; do
        [ -f "$x" ] && fs+=("$x")
    done
    [ ${#fs[@]} -gt 0 ] || return 0
    # the FIRST DESC line of each file (field1's rule), read with getline so a
    # file stops at its DESC (line 2) instead of being read whole
    local p d
    while IFS=$'\t' read -r p d; do
        [ -n "$p" ] || continue
        rg_key "$p"; [ -n "$RG_KEY" ] && printf -v "RGD_$RG_KEY" '%s' "$d"
    done < <(LC_ALL=C awk 'BEGIN { for (i = 1; i < ARGC; i++) { f = ARGV[i]
        while ((getline l < f) > 0) if (substr(l, 1, 5) == "DESC\t") { print f "\t" substr(l, 6); break }
        close(f) } exit }' "${fs[@]}")
    return 0
}
rg_desc() {
    local m=$1 dir=${1%/*} stem=${1##*/} rpt="" spec
    RG_DESC=""
    case $stem in
        use-cases) RG_DESC="Every use case on one row: who connects, which way the file travels and what triggers it, the configured subscriptions per use case by status — each count opening the Subscriptions page filtered to it — and the FlowManager templates behind them."; return ;;
        subscriptions) RG_DESC="Every configured subscription on one row, the skip-listed ones included: active or not, its result colour and direction, its Logical, Account, Partner, Domain, Application and BL groups, the endpoint and the From / To folders."; return ;;
        logical-detection) RG_DESC="How every configured FlowID detected to its Logical flow group — the rule trail the derivation applied, per FlowID."; return ;;
        accounts) RG_DESC="The accounts (partners) and their communication profiles — naming vs configured type and authentication, insecure and unrestricted endpoints, conflicting host / whitelist setup, and the account and login integrity checks."; return ;;
        first-seen) RG_DESC="On what day each logical flow, partner, subscription, account, login and remote host was first seen in the transfer logs — the configured names never seen on top; every count links its item list."; return ;;
        cross) RG_DESC="Every pair of the nine entities cross-tabulated — which values appear together on at least one transfer, the configured-but-never-seen pairs flagged."; return ;;
        this)                   [ "$dir" = transfer/month-stats ] && { RG_DESC="The nine entities counted over the Files that started this month or the previous one: total, in and out Files, Errors, automatic retries, resubmits OK and Error, Waiting and Expired."; return; } ;;
    esac
    case $dir in
        transfer/entities) rpt="$DATA/transfer/reports/entities/$stem.rpt" ;;
        transfer|server)   rpt="$DATA/$dir/reports/$stem.rpt" ;;
        analyses)          for spec in $SUBS_GROUP_REPORTS; do   # subs_report_area, without its subshell
                               [ "${spec#*:}" = "$stem" ] && { rpt="$DATA/${spec%%:*}/reports/$stem.rpt"; break; }
                           done ;;
    esac
    [ -n "$rpt" ] && [ -f "$rpt" ] || return 0
    [ "$RG_DESC_LOADED" = 1 ] || rg_desc_load
    rg_key "$rpt"
    if [ -n "$RG_KEY" ]; then eval "RG_DESC=\${RGD_$RG_KEY-}"
    else RG_DESC=$(field1 DESC "$rpt"); fi
    return 0
}
write_reports_index() {
    local out="$DOCS/reports/index.html" line e m lbl d el
    local -a arr
    mkdir -p "$DOCS/reports"
    {
        html_head "Reports" "../assets/style.css" "" "" "index"
        printf '<h1>Reports</h1>\n'
        printf '<p class="subtitle">Every report under its group &mdash; the groups of the Reports menu. On a report page the first row of buttons switches between the reports of its group.</p>\n'
        # data-nosort: a hand-ordered catalog with colspan group bands —
        # report.js's fallback sort would collapse it (and persist that);
        # data-nocolmove: the bands span both columns, nothing to reorder.
        # The FIELD header row comes first: report.js headerRow() takes the
        # first flat th row — without one it took the "Overview" band (the
        # csv hotspot sat there, the CSV header read "Overview" and a search
        # left that band standing over no rows)
        printf '<div class="tablewrap"><table class="index" data-nosort="1" data-nocolmove="1">\n'
        printf '<tr><th>Report</th><th>Description</th></tr>\n'
        while IFS= read -r line; do
            [ -n "$line" ] || continue
            esc "${line%%|*}"; printf '<tr><th colspan="2">%s</th></tr>\n' "$ESC"
            IFS='|' read -r -a arr <<< "${line#*|}"
            for e in "${arr[@]}"; do
                m=${e%%=*}; lbl=${e#*=}
                rg_landing "$m"; rg_rel "reports/index.html" "$RG_LANDING"
                rg_desc "$m"; d=$RG_DESC
                esc "$lbl"; el=$ESC; esc "$d"
                printf '<tr><td><a href="%s">%s</a></td><td class="desc">%s</td></tr>\n' "$RG_REL" "$el" "$ESC"
            done
        done < <(_report_groups)
        printf '</table></div>\n'
        printf '</body>\n</html>\n'
    } > "$out"
}

# Per-day figures for the root index's log table: the Files group (transfer
# topview.rpt per-day table, ROW fields 5-8; the Cured figure = its Recovered
# group's Automatic + Manual, fields 9-10, since 2026-09-12), the
# duration percentiles (duration.rpt) and the five per-day First-seen counts
# (analyses first-seen.rpt, joined by date; its SEEN/NOTSEEN lines are not
# day ROWs and stay out). The transfer topview.rpt sets the DAYS (see below).
# $1 = the data root (data). One
# "date<TAB>count<TAB>ok<TAB>err<TAB>err%<TAB>4x(class,value) duration
# <TAB>5 first-seen counts" line per date. FILENAME (not FNR==NR) keys the
# source (path segment, env-agnostic), so a missing file just drops its
# columns.
daily_loglines_tsv() {   # $1 = the data root (data)
    # The day list is the TRANSFER topview's days only: all four data groups
    # (Transfers / Files / UC2 state / Duration / First seen) are transfer-derived,
    # so a server-only day — the server export runs a day ahead of the
    # transfer export — would render a fully empty row under the Date spine.
    local trpt="$1/transfer/reports/topview.rpt"
    local drpt="$1/transfer/reports/duration.rpt" frpt="$1/analyses/reports/first-seen.rpt" files=()
    # (The Red/Green switch group and its docs/switches/ pages went 2026-09-06;
    # the flip walk that still fed them — a full sort of _files.tsv every
    # build — went 2026-09-29. Its two output fields stay as "-" placeholders
    # so the reader's field positions hold.)
    local fc_="$1/transfer/cache/_files.tsv"
    # the In/Out split of the Files group: per DAY, how many Files MOVED in
    # and how many out (_files.tsv col 17, the movement direction). A File of
    # an UNCONFIGURED subscription (or none — "Unknown") has no movement:
    # it counts by its connection side (col 16), so In + Out = Ok + Error on
    # every day (2026-09-28 fix: those Files were in neither column)
    local iof=""
    if [ -f "$fc_" ]; then
        iof=$(mktemp "${TMPDIR:-/tmp}/axinout.XXXXXX")
        awk -F'\t' '$4 ~ /^[0-9][0-9][0-9][0-9]-/ {
                mv = ($17 != "") ? $17 : $16
                if (mv == "in") fi_[$4]++; else if (mv == "out") fo_[$4]++
                d[$4] = 1 }
            END { for (k in d) printf "%s\t%d\t%d\n", k, fi_[k] + 0, fo_[k] + 0 }' "$fc_" > "$iof"
        files+=("$iof")
    fi
    [ -f "$trpt" ] && files+=("$trpt")
    [ -f "$drpt" ] && files+=("$drpt")
    [ -f "$frpt" ] && files+=("$frpt")
    # return 0 EXPLICITLY: a bare `return` hands back $? — and with no switch
    # file the [ -n "$swf" ] guard just FAILED, so the bare form returned 1 and
    # set -e killed the whole publish. Only reachable when NO source file
    # exists, i.e. the OTHER env's tree is still cold — which is exactly when
    # the production chain's index-pages pass runs against a mid-parse
    # acceptance tree (found by the 2026-08-20 fresh build).
    if [ ${#files[@]} -eq 0 ]; then [ -z "$iof" ] || rm -f "$iof"; return 0; fi
    awk -F'\t' '
        function nz(v) { return v == "" ? "-" : v }
        # a duration cell "@{class=dur-s}3 s" -> its class / its text ("-" when absent)
        function dcls(v) { if (v !~ /^@\{class=/) return "-"; sub(/^@\{class=/, "", v); sub(/\}.*/, "", v); return v }
        function dtxt(v) { sub(/^@\{[^}]*\}/, "", v); return v == "" ? "-" : v }
        # the Duration group: p50/p75/p90/p95/p99 (cols 6/7/8/9/11) from the
        # "Duration per day" table of duration.rpt (Processed Files only);
        # the overall percentiles come from its TOTAL line — never summed here
        FILENAME ~ /duration\.rpt$/ {
            if ($1 == "TABLE") intab = ($2 == "Duration per day — percentiles")   # the FIRST of the two side-by-side tables (2026-09-13)
            if (!intab) next
            if ($1 == "TOTAL") for (p = 0; p < 5; p++) { c = (p==4 ? 11 : 6+p); dtc[p] = dcls($c); dtv[p] = dtxt($c) }
            if ($1 != "ROW") next
            dd = $2; sub(/^@\{[^}]*\}/, "", dd)
            if (dd !~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$/) next
            for (p = 0; p < 5; p++) { c = (p==4 ? 11 : 6+p); dc[dd,p] = dcls($c); dv[dd,p] = dtxt($c) }
            hasdur[dd] = 1
            next
        }
        # the First seen group: one count per entity type (Logicals Partners
        # Subscriptions Accounts Logins Hosts, ROW fields 3-8) joined by
        # date; the SEEN/NOTSEEN summary lines fail the ROW match
        FILENAME ~ /first-seen\.rpt$/ {
            if ($1 != "ROW" || $2 !~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$/) next
            for (p = 0; p < 6; p++) fs[$2, p] = $(3+p)
            hasfs = 1
            next
        }
        # the Files In/Out split (the axinout temp file): date, in, out
        FILENAME ~ /axinout/ {
            if ($1 ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$/) { fin[$1] = $2; fout[$1] = $3; hasio = 1 }
            next
        }
        $1 != "ROW" { next }
        { dd = $2; sub(/^@\{[^}]*\}/, "", dd) }
        # the transfer topview ROW (bin/transfer/reports/topview.sh HEAD, six groups since 2026-09-12): the Files group
        # (Count Ok Error Error%) is cols 5-8, per-CoreId figures; the Recovered group (Automatic Manual, amber cells blank
        # on 0) cols 9-10 — the home Cured cell is their sum; the Resubmit group (Ok Failed) cols 11-12 (not shown here)
        FILENAME ~ /\/transfer\// && dd ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]/ { d=substr(dd,1,10); fc[d]=nz($5); fok[d]=nz($6); fer[d]=nz($7); fpc[d]=nz($8); seen[d]=1
            frv[d] = ($9+0) + ($10+0)
            # the Transfers group (Count Ok Error Error%, cols 13-16) and the Waiting/Expired of the State group (cols 19-20; Expired may carry an @{href} prefix) — 2026-09-06, user request
            tcn[d]=nz($13); tok[d]=nz($14); ter[d]=nz($15); tpc[d]=nz($16)
            tw=$19; sub(/^@\{[^}]*\}/, "", tw); twt[d]=nz(tw); tex=$20; sub(/^@\{[^}]*\}/, "", tex); txp[d]=nz(tex) }
        END {
            n=0; for (k in seen) a[n++]=k
            # newest date first (descending); the index table shows recent days on top
            for (i=0;i<n;i++) for (j=i+1;j<n;j++) if (a[j]>a[i]) { t=a[i]; a[i]=a[j]; a[j]=t }
            # Emit "-" (not empty) for a missing field: the shell reader uses a
            # tab IFS (whitespace), so an empty middle field would collapse and
            # shift the columns. The renderer maps "-" back to a dash.
            for (i=0;i<n;i++) {
                d = a[i]
                if (d in fc) printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s", d, fc[d], \
                    (hasio && (d in fin) ? fin[d] : "-"), (hasio && (d in fout) ? fout[d] : "-"), \
                    fok[d], (d in frv ? frv[d] : "-"), fer[d], fpc[d]
                else         printf "%s\t-\t-\t-\t-\t-\t-\t-", d
                if (d in hasdur) printf "\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s", dc[d,0], dv[d,0], dc[d,1], dv[d,1], dc[d,2], dv[d,2], dc[d,3], dv[d,3], dc[d,4], dv[d,4]
                else             printf "\t-\t-\t-\t-\t-\t-\t-\t-\t-\t-"
                # a day the first-seen report does not list (or a missing
                # report) renders like a 0: blank cells
                for (p = 0; p < 6; p++) printf "\t%s", (hasfs && (d, p) in fs ? fs[d, p] : "-")
                printf "\t-\t-"   # the retired Red/Green switch fields (placeholders — the reader'"'"'s positions)
                # the Transfers + State groups (trailing fields, 2026-09-06)
                if (d in fc) printf "\t%s\t%s\t%s\t%s\t%s\t%s", tcn[d], tok[d], ter[d], tpc[d], twt[d], txp[d]
                else         printf "\t-\t-\t-\t-\t-\t-"
                printf "\n"
            }
            # the Duration TOTAL as a sentinel LAST line (the shell reader
            # stores it for the Total row and skips it as a day)
            printf "TOTAL\t-\t-\t-\t-\t-\t-\t-"
            for (p = 0; p < 5; p++) printf "\t%s\t%s", (dtv[p] == "" ? "-" : dtc[p]), (dtv[p] == "" ? "-" : dtv[p])
            printf "\t-\t-\t-\t-\t-\t-\t-\t-\t-\t-\t-\t-\t-\t-\n"
        }
    ' "${files[@]}"
    [ -n "$iof" ] && rm -f "$iof"
    return 0
}

# One Status cell (mirrors bin/analyses/publish.sh's st_cell): a 0 renders
# blank; a nonzero value links its coverage cell page when that page exists.
# $3 = the coverage href RELATIVE TO THE DOCS ROOT — the shared home's hrefs
# carry the docs-root prefix ("coverage/…"), so the existence check is
# against docs/, never the env-scoped $DOCS.
_stcell() {   # $1 value  $2 class  [$3 coverage href, docs-root-relative]
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
_pctvar() {   # $1 percentage  [$2 href, docs-root-relative]
    if [ -n "${2:-}" ] && [ -f "docs/$2" ]; then printf '<a href="%s">%s&nbsp;%%</a>' "$2" "$1"
    else printf '%s&nbsp;%%' "$1"; fi
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
    printf '<tr><th>Entity</th><th class="num">Total</th><th class="num">Seen</th><th class="num">OK</th><th class="num">Error</th><th class="num">Warning</th><th class="num">Ok</th></tr>\n'
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
        # Every Entity label (the classic four AND the PDA trio) links its
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
        if [ -n "$ebase" ] && [ -f "docs/$ent-all.html" ]; then
            printf '<tr><td><a href="%s">%s</a></td>' "$ent-all.html" "$ESC"
        else
            printf '<tr><td>%s</td>' "$ESC"
        fi
        # WHERE THE FIGURES LINK. BOTH tables send every figure into its
        # Transfer > Entities view (2026-07: the PDA rows too — Partners,
        # Domains and Applications are Entities reports like the classic four,
        # so their figures have a view of their own) — the view whose row count
        # IS this figure (All / Seen / OK / Warning / Error, each carrying
        # datereset so it opens at the full date range). A member with NO
        # Entities report (none today) would fall back to its coverage cell
        # pages.
        local h_tot h_seen h_err h_warn h_ok
        if [ -n "$ebase" ]; then
            h_tot="$ent-all.html"
            # ...EXCEPT the Logical + three PDA rows, whose Total keeps its own
            # COVERAGE CELL page (restored 2026-07): the configured logical
            # flows / partners / applications / domains with their direction, member accounts,
            # result and last transfer. The Entities All view is a different
            # list — it counts what the logs carry — so Total needs the
            # configured-side page. Falls back to the Entities view when the
            # cell page is absent (an env with no PDA coverage TSVs).
            case $member in
                logicals|partners|applications|domains|bl)
                    [ -f "docs/$cov$member-configured.html" ] && h_tot="$cov$member-configured.html" ;;
            esac
            h_seen="$ent-seen.html"
            h_err="$ent-error.html"
            h_warn="$ent-warning.html"
            h_ok="$ent-ok.html"
        else
            h_tot="$cov$member-configured.html";     h_seen="$cov$member-seen.html"
            h_err="$cov$member-status-error.html"
            h_warn="$cov$member-status-warning.html"; h_ok="$cov$member-status-ok.html"
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
    # The per-day figures: the column groups of ONE table (Transfers / Files /
    # UC2 state / Duration / First seen) further down — one data pass feeds
    # them all.
    local dl; dl=$(daily_loglines_tsv "$HOME_ENV_DATA")
    # (the Red/Green switch group and its per-day switch pages are gone —
    # 2026-09-06, user request)
    # ONLY with TRANSFERS (2026-08-29): dl always carries the Duration TOTAL
    # sentinel, so a bare non-empty test rendered the four titled tables as
    # empty header-only shells on a config-only env (production). The row of
    # five renders only when at least one DAY line carries transfer Files
    # (field 2 — "-" on a server-only day).
    local _hastx=""
    [ -n "$dl" ] && _hastx=$(printf '%s\n' "$dl" | awk -F'\t' '$1!="" && $1!="TOTAL" && $2!="" && $2!="-" { print 1; exit }')
    if [ -n "$_hastx" ]; then
        # THE PER-DAY TABLE (2026-08-31, user request — ONE table again):
        # Transfers / Files / UC2 state / Duration / First seen are column GROUPS
        # of one wide table, a gband banner row over a shared Date column
        # (its cells link the day's combined dashboard). The 2026-08 five-
        # table flex row (a Date spine + four data tables) is gone: one
        # table cannot fall out of row-sync, which the spine did whenever a
        # header's height changed (the csv-hotspot regression). The group
        # dividers are SPACER columns (th/td.spc — no borders, page
        # background), one before each group, so each group has its own
        # table-like edges and the row lines stop at the gaps.
        #
        # EVERY DAY SHOWS (2026-09-29, user request: the 14-day cap and its
        # "Show all" button are gone — "just show all"). The Total row only
        # from 10 days up (2026-08): a short table's sums add nothing a glance
        # does not already give. data-nosort: the rows stay newest first.
        local dcount
        dcount=$(printf '%s\n' "$dl" | awk -F'\t' '$1!="" && $1!="TOTAL"' | wc -l | tr -d ' ')
        local d fc fin fout fok frv fer fpc c v fsum=0 finsum=0 foutsum=0 foksum=0 frvsum=0 fersum=0
        local dc50 dv50 dc75 dv75 dc90 dv90 dc95 dv95 dc99 dv99 dtot=""
        local fsp fss fsa fsl fsh fsps=0 fsss=0 fsas=0 fsls=0 fshs=0
        local swr swg swrs=0 swgs=0 dcc=""
        # every cell of the Duration group — banner, p-headers, day cells, Total — opens
        # transfer/duration.html at the FULL date range (2026-09-14, user request): the
        # banner, p-headers and Total with ?axway_date=all (report.js: the All button's
        # range), each day's five cells with ?axway_row=<that date> — the row marked, the
        # range full. data-href on the cell; report.js setupCellLinks navigates there and
        # outranks the row link
        local DURGO=""; [ -f docs/transfer/duration.html ] && DURGO=' data-href="transfer/duration.html?axway_date=all"'
        printf '<div class="tablewrap perday"><table class="index fit dayrows" data-nosearch="1" data-nosort="1">\n'
        # groups (2026-09-06, user request): Transfers (Ok Error Error%) before Files, UC2 state (Waiting Expired — staged pickups) before Duration, First seen without Logical/Accounts; Recovered reads Cured; the Red/Green switch group is gone
        # the groups are separated by SPACER columns (th/td.spc: no borders,
        # page background — the root index pattern), so every group keeps its
        # own left/right/bottom edges like a table of its own and no row line
        # crosses the gap (2026-09-06, user request; before: a thick
        # page-coloured left border that the row lines ran through)
        printf '<tr class="gbrow"><th></th>%s<th class="gband" colspan="3">Transfers</th>%s<th class="gband" colspan="6">Files</th>%s<th class="gband" colspan="2">UC2 state</th>%s<th class="gband" colspan="5"'"$DURGO"'>Duration</th>%s<th class="gband" colspan="2">First seen</th></tr>\n' \
            '<th class="spc"></th>' '<th class="spc"></th>' '<th class="spc"></th>' '<th class="spc"></th>' '<th class="spc"></th>'
        printf '<tr><th>Date</th>%s<th class="num">Ok</th><th class="num">Error</th><th class="num">Error %%</th>%s<th class="num">In</th><th class="num">Out</th><th class="num">Ok</th><th class="num">Cured</th><th class="num">Error</th><th class="num">Error %%</th>%s<th class="num">Waiting</th><th class="num">Expired</th>%s<th class="num"'"$DURGO"'>p50</th><th class="num"'"$DURGO"'>p75</th><th class="num"'"$DURGO"'>p90</th><th class="num"'"$DURGO"'>p95</th><th class="num"'"$DURGO"'>p99</th>%s<th class="num">Partners</th><th class="num">Subscriptions</th></tr>\n' \
            '<th class="spc"></th>' '<th class="spc"></th>' '<th class="spc"></th>' '<th class="spc"></th>' '<th class="spc"></th>'
        local tcn tok ter tpc twt txp tcnsum=0 toksum=0 tersum=0 twtsum=0 txpsum=0
        while IFS=$'\t' read -r d fc fin fout fok frv fer fpc dc50 dv50 dc75 dv75 dc90 dv90 dc95 dv95 dc99 dv99 fsg fsp fss fsa fsl fsh swr swg tcn tok ter tpc twt txp; do
            [ -n "$d" ] || continue
            # the sentinel LAST line: the overall duration percentiles for
            # the Total row (a percentile cannot be summed)
            if [ "$d" = "TOTAL" ]; then
                dtot=""
                for c in "$dc50:$dv50" "$dc75:$dv75" "$dc90:$dv90" "$dc95:$dv95" "$dc99:$dv99"; do   # p99 last (2026-09-13, user request)
                    dtot="$dtot$(_durcell "${c%%:*}" "${c#*:}")"
                done
                continue
            fi
            _daycell "$d"
            printf '<tr><td>%s</td><td class="spc"></td>' "$dcc"
            # —— Transfers (from transfer/topview.html, the Transfers band):
            # technical rows, Ok/Error tinted like that page (okc/errc), a 0
            # blank ——
            if [ "$tok" = "-" ] || [ "$tok" = 0 ] || [ -z "$tok" ]; then printf '<td class="num okc z"></td>'; else
                dotify_v "$tok"; esc "$DOT"; printf '<td class="num okc">%s</td>' "$ESC"; toksum=$((toksum + tok)); fi
            if [ "$ter" = "-" ] || [ "$ter" = 0 ] || [ -z "$ter" ]; then printf '<td class="num errc z"></td>'; else
                dotify_v "$ter"; esc "$DOT"; printf '<td class="num errc">%s</td>' "$ESC"; tersum=$((tersum + ter)); fi
            if [ "$tpc" = "-" ] || [ -z "$tpc" ]; then printf '<td class="num"></td>'; else esc "$tpc"; printf '<td class="num">%s</td>' "$ESC"; fi
            [ "$tcn" != "-" ] && [ -n "$tcn" ] && tcnsum=$((tcnsum + tcn))
            printf '<td class="spc"></td>'
            # —— Files (from transfer/topview.html) ——
            # Ok/Error tint like topview's cells, a 0 rendering as an empty
            # cell (the render_rpt.awk convention). A nonzero Error cell
            # links the Entities Subscriptions/ALL view narrowed to that day
            # (?axway_date — report.js sets From=To and persists it like a
            # user selection), sorted by its Error column (axway_sort=7:-1 — display index 7 since the Retry · Resubmit columns, 2026-09-12; 6 with the single Cured column of 2026-09-10):
            # there the Error column total equals this cell exactly, and the
            # row tints say which of the flows are still red — the ERROR view
            # cannot show that (2026-08: 24 of a day's 25 errors belonged to
            # a flow that recovered the same evening, green and absent there,
            # so the cell said 25 and its target showed 1).
            if [ "$fc" != "-" ] && [ -n "$fc" ]; then
                fsum=$((fsum + fc))   # the Files COUNT column is gone (2026-08: In + Out carries it); fsum stays for Error %
                # the In/Out split (movement direction; In + Out = Count)
                if [ "$fin" = "-" ] || [ "$fin" = 0 ] || [ -z "$fin" ]; then printf '<td class="num"></td>'; else
                    dotify_v "$fin"; esc "$DOT"; printf '<td class="num">%s</td>' "$ESC"; finsum=$((finsum + fin)); fi
                if [ "$fout" = "-" ] || [ "$fout" = 0 ] || [ -z "$fout" ]; then printf '<td class="num"></td>'; else
                    dotify_v "$fout"; esc "$DOT"; printf '<td class="num">%s</td>' "$ESC"; foutsum=$((foutsum + fout)); fi
                if [ "$fok" = "-" ] || [ "$fok" = 0 ]; then printf '<td class="num processed z"></td>'; else
                    dotify_v "$fok"; esc "$DOT"; printf '<td class="num processed">%s</td>' "$ESC"; fi
                # Recovered, amber like topview's cell; a 0/blank cell stays
                # untinted (td.warn:empty). A nonzero cell opens the Recovered
                # files report narrowed to that day (2026-09-01, user
                # request), the way the Error cell beside it opens its view.
                if [ "$frv" = "-" ] || [ "$frv" = 0 ] || [ -z "$frv" ]; then printf '<td class="num warn"></td>'; else
                    dotify_v "$frv"; esc "$DOT"
                    if [ -f "docs/transfer/retries-recovered-files.html" ]; then
                        printf '<td class="num warn"><a href="transfer/retries-recovered-files.html?axway_date=%s">%s</a></td>' "$d" "$ESC"
                    else printf '<td class="num warn">%s</td>' "$ESC"; fi
                    frvsum=$((frvsum + frv)); fi
                if [ "$fer" = "-" ] || [ "$fer" = 0 ]; then printf '<td class="num failed z"></td>'; else
                    dotify_v "$fer"; esc "$DOT"
                    # 2026-09-14 (user request): the cell opens the FAILED FILES
                    # list narrowed to its day — one row per File it counts
                    # (Failed or Expired, on the start day), with reason,
                    # CoreId and file name; the Entities view is the fallback
                    if [ -f "docs/transfer/failed-files.html" ]; then
                        printf '<td class="num failed"><a href="transfer/failed-files.html?axway_date=%s&amp;axway_search=">%s</a></td>' "$d" "$ESC"
                    elif [ -f "docs/transfer/entities/subscription-all.html" ]; then
                        printf '<td class="num failed"><a href="transfer/entities/subscription-all.html?axway_date=%s&amp;axway_sort=Error:-1&amp;axway_column=Error">%s</a></td>' "$d" "$ESC"
                    else printf '<td class="num failed">%s</td>' "$ESC"; fi; fi
                [ "$fok" != "-" ] && foksum=$((foksum + fok)); [ "$fer" != "-" ] && fersum=$((fersum + fer))
                if [ "$fpc" = "-" ]; then printf '<td class="num"></td>'; else
                    esc "$fpc"; printf '<td class="num">%s</td>' "$ESC"; fi
            else
                printf '<td class="num"></td><td class="num"></td><td class="num processed"></td><td class="num warn"></td><td class="num failed"></td><td class="num"></td>'
            fi
            printf '<td class="spc"></td>'
            # —— UC2 state (the topview State band): Waiting (amber) and Expired
            # (red) Files of the day; a nonzero cell opens the report ——
            if [ "$twt" = "-" ] || [ "$twt" = 0 ] || [ -z "$twt" ]; then printf '<td class="num warn"></td>'; else
                dotify_v "$twt"; esc "$DOT"
                if [ -f "docs/transfer/waiting.html" ]; then printf '<td class="num warn"><a href="transfer/waiting.html">%s</a></td>' "$ESC"
                else printf '<td class="num warn">%s</td>' "$ESC"; fi
                twtsum=$((twtsum + twt)); fi
            if [ "$txp" = "-" ] || [ "$txp" = 0 ] || [ -z "$txp" ]; then printf '<td class="num errc z"></td>'; else
                dotify_v "$txp"; esc "$DOT"
                if [ -f "docs/transfer/expired.html" ]; then printf '<td class="num errc"><a href="transfer/expired.html">%s</a></td>' "$ESC"
                else printf '<td class="num errc">%s</td>' "$ESC"; fi
                txpsum=$((txpsum + txp)); fi
            printf '<td class="spc"></td>'
            # —— Duration (from transfer/duration.html): the day's
            # p50/p75/p90/p95/p99, tinted like that page's cells ——
            # the day's own link: that row marked on the Duration page (the shared
            # DURGO restored right after, for the Total and the next row)
            local _durgo_all=$DURGO
            [ -n "$DURGO" ] && DURGO=" data-href=\"transfer/duration.html?axway_row=$d\""
            _durcell "$dc50" "$dv50"; _durcell "$dc75" "$dv75"
            _durcell "$dc90" "$dv90"; _durcell "$dc95" "$dv95"; _durcell "$dc99" "$dv99"   # p99 last (2026-09-13, user request)
            DURGO=$_durgo_all
            printf '<td class="spc"></td>'
            # —— First seen (from analyses/first-seen.html): a count links
            # that day's first-seen list when the page exists (a page exists
            # only for a day with names); 0 renders blank ——
            for c in "partners:$fsp" "subscriptions:$fss"; do   # Logical and Accounts dropped (2026-09-06, user request)
                v=${c#*:}
                if [ "$v" = "-" ] || [ "$v" = 0 ] || [ -z "$v" ]; then printf '<td class="num"></td>'; continue; fi
                dotify_v "$v"; esc "$DOT"
                if [ -f "docs/first-seen/${c%%:*}-$d.html" ]; then
                    printf '<td class="num"><a href="first-seen/%s-%s.html">%s</a></td>' "${c%%:*}" "$d" "$ESC"
                else printf '<td class="num">%s</td>' "$ESC"; fi
            done
            printf '</tr>\n'
        done <<< "$dl"
        # —— the ONE Total row (from 10 days up) ——
        dotify_v "$fsum"; esc "$DOT"; local fst=$ESC
        dotify_v "$foksum"; esc "$DOT"; local fokt=$ESC; dotify_v "$fersum"; esc "$DOT"; local fert=$ESC
        local fpct=""
        [ "$fsum" -gt 0 ] && fpct=$(awk -v e="$fersum" -v n="$fsum" 'BEGIN{printf "%.1f%%", 100*e/n}')
        local fint="" foutt=""
        if [ "$finsum" -gt 0 ]; then dotify_v "$finsum"; esc "$DOT"; fint=$ESC; fi
        if [ "$foutsum" -gt 0 ]; then dotify_v "$foutsum"; esc "$DOT"; foutt=$ESC; fi
        local frvt=""
        if [ "$frvsum" -gt 0 ]; then dotify_v "$frvsum"; esc "$DOT"; frvt=$ESC
            # the whole-window Recovered total opens the report unnarrowed
            [ -f "docs/transfer/retries-recovered-files.html" ] && frvt="<a href=\"transfer/retries-recovered-files.html\">$ESC</a>"; fi
        # the whole-window Error total opens the Failed files list unnarrowed (2026-09-14);
        # the empty ?axway_search= on both home links (2026-09-15) clears a search the
        # subscription pages' Error cells left remembered for the page
        if [ "$fersum" -gt 0 ] && [ -f "docs/transfer/failed-files.html" ]; then fert="<a href=\"transfer/failed-files.html?axway_search=\">$fert</a>"; fi
        # the Duration total = the report's own overall percentiles (a
        # percentile cannot be summed); empty cells when the report is absent
        [ -n "$dtot" ] || dtot='<td class="num"></td><td class="num"></td><td class="num"></td><td class="num"></td><td class="num"></td>'   # five: p50 p75 p90 p95 p99
        # the First-seen totals: the report's SEEN line — the SAME figure as
        # the status tables' Seen column (the day cells
        # above plus the report's no-date bucket sum to it); each links its
        # <type>-seen list, whose row count IS that figure
        # an env without the report (2026-09-03, production runtime: the build
        # died on "fsgs: unbound variable" under set -u) shows empty cells
        local fsgs="" fsps="" fsss="" fsas="" fsls="" fshs="" c
        if [ -f "$HOME_ENV_DATA/analyses/reports/first-seen.rpt" ]; then
            IFS=$'\t' read -r c fsgs fsps fsss fsas fsls fshs \
                <<< "$(awk -F'\t' '$1=="SEEN"{print; exit}' "$HOME_ENV_DATA/analyses/reports/first-seen.rpt")"
        fi
        local fstot=""
        for c in "partners:$fsps" "subscriptions:$fsss"; do
            v=${c#*:}
            if [ -z "$v" ] || [ "$v" = 0 ]; then fstot="$fstot<td class=\"num\"></td>"; continue; fi
            dotify_v "$v"; esc "$DOT"
            if [ -f "docs/first-seen/${c%%:*}-seen.html" ]; then
                fstot="$fstot<td class=\"num\"><a href=\"first-seen/${c%%:*}-seen.html\">$ESC</a></td>"
            else fstot="$fstot<td class=\"num\">$ESC</td>"; fi
        done
        # the Transfers and State totals (2026-09-06)
        local tokt="" tert="" tpct="" twtt="" txpt=""
        if [ "$toksum" -gt 0 ]; then dotify_v "$toksum"; esc "$DOT"; tokt=$ESC; fi
        if [ "$tersum" -gt 0 ]; then dotify_v "$tersum"; esc "$DOT"; tert=$ESC; fi
        [ "$tcnsum" -gt 0 ] && tpct=$(awk -v e="$tersum" -v n="$tcnsum" 'BEGIN{printf "%.1f%%", 100*e/n}')
        if [ "$twtsum" -gt 0 ]; then dotify_v "$twtsum"; esc "$DOT"; twtt=$ESC; fi
        if [ "$txpsum" -gt 0 ]; then dotify_v "$txpsum"; esc "$DOT"; txpt=$ESC; fi
        [ "$dcount" -ge 10 ] && printf '<tr class="total"><td>Total</td><td class="spc"></td><td class="num okc">%s</td><td class="num errc">%s</td><td class="num">%s</td><td class="spc"></td><td class="num">%s</td><td class="num">%s</td><td class="num processed">%s</td><td class="num warn">%s</td><td class="num failed">%s</td><td class="num">%s</td><td class="spc"></td><td class="num warn">%s</td><td class="num errc">%s</td><td class="spc"></td>%s<td class="spc"></td>%s</tr>\n' \
            "$tokt" "$tert" "$tpct" "$fint" "$foutt" "$fokt" "$frvt" "$fert" "$fpct" "$twtt" "$txpt" "$dtot" "$fstot"
        printf '</table></div>\n'
    fi
}

# (The Report finder — docs/tools/report-finder.html, its FINDER_AWK row
# builder and report.js setupReportFinder + the Ctrl+K palette that read it —
# went 2026-09-29, user request; the KEYWORDS .rpt lines only it read went too.)

# ---- The Site map (docs/tools/sitemap.html) ----------------------------------
# The whole environment on one page: one CARD per group of _report_groups
# (the Reports pulldown, 2026-09-29), its members tree-listed beneath, then
# the Dashboards card and the Tools card — all alike, one flow (2026-09-29).
# A docs/tools/ page (css depth 1, 2026-09-12) linked from the top-bar map icon.
sm_href() {   # $1 area  $2 basename -> env-root-relative page
    local fp; fp=$(first_page "$2")
    # the Subscriptions group renders into docs/analyses/, whichever area
    # its DATA comes from
    if is_subs_report "$2"; then printf 'analyses/%s' "$fp"; return; fi
    if [ "$1" = server ]; then printf 'server/%s' "$fp"; return; fi
    case $2 in
        entity-search) printf 'search/search.html' ;;
        cross-*)       printf 'analyses/xref/%s' "$fp" ;;
        *)             printf 'transfer/%s' "$fp" ;;
    esac
}
write_sitemap() {
    local out="$DOCS/tools/sitemap.html"   # under docs/tools/ since 2026-09-12 (user request) — every link carries ../, the sibling tools ./
    mkdir -p "$DOCS/tools"   # before the redirected block below opens $out
    {
        html_head "Site Map" "../assets/style.css" "" "" "sitemap"
        printf '<h1>Site Map</h1>\n'
        printf '<p class="range">Everything in this environment on one page: one card per report <strong>group</strong> of the Reports menu &mdash; the group name on top, its reports beneath, in the menu order &mdash; then the dashboards and the tools.</p>\n'
        # ONE FLOW OF CARDS (2026-09-29, user request: "No different sections
        # for Reports, Dashboards, Tools, all parts are the same"): the Start
        # page, one card per group of publish_lib _report_groups, the
        # Dashboards card and the Tools card, all alike, in one multi-column
        # flow (.smcols). The "Data pages & tools" section became the one
        # Tools card (its Per-day and Entity detail cards went).
        printf '<div class="smcols">\n'
        printf '<div class="smcard"><h3><a href="../reports/index.html">Start page</a></h3></div>\n'
        local gline gent
        local -a garr
        while IFS= read -r gline; do
            [ -n "$gline" ] || continue
            IFS='|' read -r -a garr <<< "${gline#*|}"
            esc "${gline%%|*}"
            printf '<div class="smcard"><h3>%s <span class="smcount">%d</span></h3><ul>\n' "$ESC" "${#garr[@]}"
            for gent in "${garr[@]}"; do
                rg_landing "${gent%%=*}"; esc "${gent#*=}"
                printf '<li><a href="../%s">%s</a></li>\n' "$RG_LANDING" "$ESC"
            done
            printf '</ul></div>\n'
        done < <(_report_groups)
        # ONE dashboard (2026-07) + the Monitor dashboard where the env has
        # monitor data (the rpt is the flag) — this line is also what keeps
        # monitor.html REACHABLE for linkcheck (its top-bar link is runtime-only)
        printf '<div class="smcard"><h3>Dashboards</h3><ul>\n'
        printf '<li><a href="../dashboards/index.html">Dashboard</a></li>\n'
        [ -f "$DATA/dashboards/reports/monitor.rpt" ] && printf '<li><a href="../dashboards/monitor.html">Monitor</a></li>\n'
        printf '</ul></div>\n'
        printf '<div class="smcard"><h3>Tools</h3><ul>\n'
        printf '<li><a href="../index.html">Home</a> — the shared landing page</li>\n'
        printf '<li><a href="../search/search.html">Search</a> — find any entity by name</li>\n'
        printf '<li><a href="../search/all-files.html">All files search</a> — find a File among all the Files of the transfer logs</li>\n'
        # the sibling tools (docs/tools/, 2026-09-12): ./ links — the ../ rule
        # above is for everything outside this directory
        printf '<li><a href="./whats-new.html">What is new</a> — new and changed reports</li>\n'
        printf '<li><a href="../help/index.html">Help</a> — how to read the report catalogs (per-report help sits behind each page'\''s <b>?</b> button)</li>\n'
        # THE BUILD REPORT (2026-09-12, user request): back on the site as
        # docs/tools/build.html — bin/build.sh writes it LAST, from its EXIT
        # trap, so the link points at the report of the build that wrote this
        # page (it left docs/ 2026-08-29 and was local-only until now)
        printf '<li><a href="./build.html">Build report</a> — the run that built this site: steps and timings, the inbox, the log files</li>\n'
        printf '</ul></div>\n'
        printf '</div>\n</body>\n</html>\n'
    } > "$out"
}

# ---- What is new (docs/tools/whats-new.html) ---------------------------------
# Two tables from the GIT history of the report scripts (transfer/server/
# analyses bin/reports/): the 10 most recently ADDED reports, and the 10 most
# recently CHANGED ones. Linked ONLY from the Site Map's Tools card. Degrades
# to empty tables when git is unavailable.
# Two rules keep the Changed table meaningful (2026-07): a commit counts only
# when it is ABOUT ONE REPORT (it modified exactly one generator — see the awk
# below), and a report the New table already lists is not repeated, since
# "added" and "changed on the day it was added" are the same news.
# A short one-liner from a report INTRO: drop **bold** markers, keep the first
# sentence, cap the length — the "New reports" Description column.
# Sets WN_SHORT rather than echoing: every call sat inside $( ), and a subshell
# per listed report is one of the six forks this function used to cost.
wn_short() {
    local s=$1
    s=${s//\*\*/}
    s=${s%%. *}
    [ ${#s} -gt 150 ] && s="${s:0:147}…"
    WN_SHORT=$s
}
wn_meta() {   # $1 script path  $2 basename -> "title<TAB>area<TAB>href<TAB>intro" lines ("" = not a published report)
    local area=transfer rpt t i
    case $2 in
        details|showseen|coverage|entities|partners-domains-applications|incoming-connections) return 0 ;;
        merge-duration-dwell) wn_meta "$1" duration-dwell; return $? ;;   # the 2026-09-05 merged page IS a new report: read its own .rpt (the generator name differs from the page name)
        first-seen)      printf 'First seen\tAnalyses\tanalyses/first-seen.html\tOn what day each logical flow, partner, subscription, account, login and remote host was first seen in the transfer logs.\n'; return 0 ;;
        # Month stats: 18 pages in their own directory, no month-stats.rpt at the
        # reports root (2026-09-29: it could never be listed)
        month-stats)     printf 'Month stats\tTransfer\ttransfer/month-stats/this-subscription.html\tThe nine entities counted over the Files that started this month or the previous one.\n'; return 0 ;;
        cross-reference) printf 'Cross References\tAnalyses\tanalyses/xref/cross-account-subscriptions.html\tEvery pair of the nine entities cross-tabulated both ways — which appear together on a transfer, which are configured but never seen.\n'; return 0 ;;
        # the analyses PUBLISH writers render several pages each — one row per
        # page that exists (the insight pages have no .rpt to read a title from)
        publish-insights) return 0 ;;   # a sidecar writer since its three insight pages went (2026-09-29)
    esac
    case $1 in bin/server/*|server/bin/*) area=server ;; esac   # (the pre-2026-07 path too — see write_whats_new)
    # the Subscriptions group scripts all live in bin/analyses/reports/, so the
    # path says nothing about which area holds their .rpt — ask the group table
    local sa; if sa=$(subs_report_area "$2"); then area=$sa; fi
    # A PAGELESS report (publish_lib PAGELESS_REPORTS: a merged-report
    # component or a data producer) has no page of its own — but a CHANGE to
    # it is a change to the page that shows its data, so map it to that
    # parent and recurse (2026-08-15: was a plain skip, which hid every
    # extended component — e.g. the seven-table server batch — from the
    # Changed table). Retired components (no parent page) still return 0.
    if is_pageless_report "$2"; then
        local wn_parent=""
        case $2 in
            weekly|hourly|weekday)                                  wn_parent=activity ;;   # (day: a pageless data producer since Activity dropped it — the default skip below)
            retry|attempts|resubmissions|recovered-files)           wn_parent=retries ;;
            recovered)                                              wn_parent=episodes ;;   # 2026-09-29
            patterns|legs-count|protocol-journey)                   wn_parent=file-journey ;;
            uc4-to-uc2|file-in-file-out-src)                        wn_parent=file-in-file-out ;;   # 2026-09-29
            errors-day)                                             wn_parent=topview ;;   # 2026-09-29: rides the server Top view
            deploy-errors)                                          wn_parent=routing-errors ;;
            from-green-to-red|only-red)                             wn_parent=failed ;;   # 2026-09-29: their columns ride Failed Subscriptions   # 2026-09-29: its page went (the Routing errors page lists the lines)
            error-timing|error-reasons|top-messages)                wn_parent=errors ;;
            unknown-sites|unknown-accounts|unknown-hosts|unknown-whitelisting|unknown-logins) wn_parent=missing-entities ;;   # the Missing entities page (retired and brought back 2026-09-29)
            inbound-connections|connection-diagnostics)             wn_parent=connections ;;
            logon|auth-activity)                                    wn_parent=logons ;;
            ssh-crypto|ssh-sessions)                                wn_parent=ssh-security ;;
            uc1-status|uc2-status|uc3-status|uc4-status|remote-poll|uc3-polling|uc2-visits|pickups|no-remote-dir|no-remote-files) wn_parent=uc-status ;;   # the UC2 / UC3 tabs (2026-09-29)   # uc2-visits/pickups: the UC2 tab (2026-09-29)   # remote-poll/uc3-polling: the UC3 tab (2026-09-05)
            missing-cronjobs)                                       wn_parent=polling ;;   # 2026-09-29: its rows are the Polling rows marked "no cron"
            went-quiet-src|stale-accounts)                          wn_parent=went-quiet ;;
            duration-distribution|dwell-time)                       wn_parent=duration-dwell ;;   # 2026-09-05 merge
            size-dist|file-type|duplicate-files|top-transfers|size-profile) wn_parent=files ;;
            *) return 0 ;;   # no page shows its data (day, event-queue, site-failures, …)
        esac
        wn_meta "bin/$area/reports/$wn_parent.sh" "$wn_parent"
        return $?
    fi
    rpt="$DATA/$area/reports/$2.rpt"
    [ -f "$rpt" ] || return 0
    # the one-line DESC (2026-09-29: was the INTRO — blank or a data sentence
    # for many reports; the DESC is what the finder and the start page show)
    { read -r t; read -r i2; } <<<"$(field2 "$rpt" TITLE DESC)"   # one awk, both directives
    [ -n "$t" ] || t=$2
    wn_short "$i2"; i=$WN_SHORT
    if is_subs_report "$2"; then printf '%s\tAnalyses\t%s\t%s\n' "$t" "$(sm_href "$area" "$2")" "$i"
    elif [ "$area" = server ]; then printf '%s\tServer\t%s\t%s\n' "$t" "$(sm_href server "$2")" "$i"
    else printf '%s\tTransfer\t%s\t%s\n' "$t" "$(sm_href transfer "$2")" "$i"
    fi
}
# WN_META = wn_meta PATH BASENAME, computed ONCE per generator path: the
# history names ~150 generators over ~300 rows, and every uncached call was a
# subshell plus its own awk / sm_href forks (2026-09-29 audit: ~2 s). Bash 3.2
# has no associative arrays, so the memo is a variable per path, its name the
# path escaped injectively (rg_key: _ -> _u first, then - / . -> _h _s _d); a
# path with any other character is simply not cached.
wn_meta_cached() {   # $1 script path  $2 basename -> WN_META
    rg_key "$1"
    if [ -z "$RG_KEY" ]; then WN_META=$(wn_meta "$1" "$2") || WN_META=""; return 0; fi
    local k=$RG_KEY
    if eval "[ -n \"\${WNM_$k+x}\" ]"; then eval "WN_META=\$WNM_$k"; return 0; fi
    WN_META=$(wn_meta "$1" "$2") || WN_META=""
    eval "WNM_$k=\$WN_META"
}
write_whats_new() {
    local out="$DOCS/tools/whats-new.html"   # under docs/tools/ since 2026-09-12 (user request) — the row hrefs carry ../
    mkdir -p "$DOCS/tools"   # before the redirected block below opens $out
    # The generator dirs, CURRENT and pre-2026-07 (the tool sets moved from
    # <area>/bin/ to bin/<area>/): git log's path limiting does not follow a
    # rename, so without the legacy paths every report's history would start at
    # the move commit — the catalog went empty the first time this ran after it.
    local dirs=(bin/transfer/reports bin/server/reports bin/analyses/reports \
                bin/analyses/publish-insights.sh \
                transfer/bin/reports server/bin/reports analyses/bin/reports \
                analyses/bin/publish-insights.sh)
    # Over ALL history: per generator, its ADD date (a "new" report) and its
    # latest MODIFY date + that commit's subject (a "changed" report — the
    # subject is the "what changed" message). The "site update" build commits
    # only touch docs/, not these script dirs, so they never appear here.
    # Keyed on the script's BASENAME, not its path, so the two spellings of a
    # moved generator are ONE report; the newest path seen wins for the lookup
    # below (git log is newest-first), which is what wn_meta reads the area from.
    # A CHANGE is listed per MODIFIED generator, for commits that modified at
    # most 8 of them (2026-08-15: was exactly-one — that skipped genuine
    # feature batches like "extend six server reports with new tables", so
    # none of the extended reports ever surfaced). A LARGER sweep — "perf:
    # every report renders its rows in the agg awk END" — is about the site,
    # not about any one report, and stays skipped: dozens of rows repeating
    # one subject is what filled this table with noise. ADDED generators
    # never disqualify a commit (they are the New table's news) and never
    # emit a C line themselves. Deduped per report later (each report shows
    # its NEWEST qualifying change).
    # THE HISTORY IS DERIVED IN DEVELOP AND SHIPPED (2026-09-12, user report:
    # "whats-new is not updated anymore"): the runtime checkouts get bin/ by
    # rsync and their own git log holds one commit touching the generators —
    # the 2026-09-11 import — so there every report was "new" that day and
    # nothing ever changed. The develop build (the .sample-estate marker)
    # runs the git pipeline below and writes bin/build/whats-new-history.tsv
    # (committed, synced with bin/ by acc.sh/prd.sh); every build — develop
    # and runtime — then renders the page from that file, with the titles
    # and intros of its own .rpt files.
    local hist histf="bin/build/whats-new-history.tsv"
    if [ -f input/.sample-estate ]; then
    git log --format='@@@%x09%as%x09%s' --name-status -M -- "${dirs[@]}" 2>/dev/null | awk -F'\t' -v CMAX=100 '
        function bn(p) { sub(/^.*\//, "", p); return p }
        # emit the commit just finished: one C line per MODIFIED generator
        # (cp[i] == "" marks an ADD — news for the New table, not a change),
        # for commits modifying at most 8; more = a site-wide sweep, skipped
        function flush(   i, m) {
            m = 0
            for (i = 1; i <= nc; i++) if (cp[i] != "") m++
            if (m >= 1 && m <= 8 && ncom < CMAX) {
                for (i = 1; i <= nc; i++) if (cp[i] != "") print "C\t" d "\t" ncom "\t" cp[i] "\t" subj
                ncom++
            }
            nc = 0
        }
        $1 == "@@@" { flush(); d = $2; subj = $3; next }
        $1 == "A" { k = bn($2); if (!(k in pth)) pth[k] = $2
                    if (!(k in add) || d < add[k]) add[k] = d
                    cp[++nc] = ""; next }
        $1 == "M" { k = bn($2); if (!(k in pth)) pth[k] = $2
                    cp[++nc] = $2; next }
        # a rename (git mv, -M) is "R<score>\told\tnew". A RENAMED report (the
        # basename changed) counts as a CHANGE of the new name, dated at the
        # rename commit — without that it would vanish from the catalog until
        # its next plain edit. A pure MOVE (same basename, another directory —
        # the 2026-07 bin/ move) is no change at all: it would have flagged
        # every report as "changed" on one day and buried the real history (and
        # it must not count toward nc either, or a move commit looks specific).
        $1 ~ /^R/ { ko = bn($2); kn = bn($3); if (!(kn in pth)) pth[kn] = $3
                    if (ko == kn) next
                    cp[++nc] = $3; next }
        END { flush(); for (k in add) print "N\t" add[k] "\t0\t" pth[k] "\t" }' | LC_ALL=C sort -t"$(printf '\t')" -k1,1 -k2,2 -k3,3n -k4,4 > "$histf.tmp" && mv "$histf.tmp" "$histf" || rm -f "$histf.tmp"
    fi
    hist=$( [ -f "$histf" ] && cat "$histf" || true )
    local kind date seq path subj nm meta t a href desc rows_new="" rows_chg="" et ea eh ed
    while IFS=$'\t' read -r kind date seq path subj; do
        [ -n "$path" ] || continue
        nm=${path##*/}; nm=${nm%.sh}
        wn_meta_cached "$path" "$nm"; meta=$WN_META
        [ -n "$meta" ] || continue
        # a multi-page writer (publish-insights.sh renders three insight pages)
        # emits several meta lines, so a CHANGE to it names no single report —
        # unless the commit SUBJECT does. Keep the page whose slug or title the
        # subject mentions; drop the commit when that is not exactly one page
        # (a commit touching one shared writer would otherwise stamp its
        # message onto every page it feeds).
        if [ "$kind" = C ]; then
            meta=$(printf '%s\n' "$meta" | awk -F'\t' -v s="$subj" '
                function fold(x) { x = tolower(x); gsub(/[^a-z0-9]/, "", x); return x }
                BEGIN { fs = fold(s) }
                NF > 1 { nl++; last = $0
                         k = $3; sub(/^.*\//, "", k); sub(/\.html$/, "", k)
                         if (index(fs, fold(k)) || index(fs, fold($1))) hit[++n] = $0 }
                END { if (nl == 1) print last; else if (n == 1) print hit[1] }')
            [ -n "$meta" ] || continue
        fi
        while IFS=$'\t' read -r t a href desc; do
            [ -n "$t" ] || continue
            # the Group column (2026-09-29: was the Transfer / Server /
            # Analyses area) — the report group of the Reports menu
            # — a page in no group (the All files search) reads "Search", never a
            # retired area name
            rg_group_for "$href"
            if [ -n "$RG_GROUP" ]; then a=$RG_GROUP
            else case $href in search/*) a=Search ;; tools/*) a=Tools ;; *) a="" ;; esac; fi
            esc "$t"; et=$ESC; esc "$a"; ea=$ESC; esc "$href"; eh=$ESC
            if [ "$kind" = N ]; then
                esc "$desc"; ed=$ESC
                rows_new+="$date"$'\t'"$seq"$'\t'"$eh"$'\t'"<tr><td>$date</td><td><a href=\"../$eh\">$et</a></td><td>$ea</td><td class=\"desc\">$ed</td></tr>"$'\n'
            else
                esc "$subj"; ed=$ESC
                rows_chg+="$date"$'\t'"$seq"$'\t'"$eh"$'\t'"<tr><td>$date</td><td><a href=\"../$eh\">$et</a></td><td>$ea</td><td class=\"desc\">$ed</td></tr>"$'\n'
            fi
        done <<< "$meta"
    done <<< "$hist"
    # New: the 25 newest adds. Changed: the 25 newest qualifying commits, ONE
    # row per report (its latest) and never a report the New table already
    # lists — "new" and "changed on the day it was added" are the same news.
    local ntop="" ctop="" keyf
    if [ -n "$rows_new" ]; then
        ntop=$(printf '%s' "$rows_new" | LC_ALL=C sort -t$'\t' -k1,1r -k2,2n | awk -F'\t' '!seen[$3]++ && n++ < 25')
    fi
    if [ -n "$rows_chg" ]; then
        keyf=$(mktemp "${TMPDIR:-/tmp}/wn.XXXXXX")
        printf '%s\n' "$ntop" | cut -f3 > "$keyf"
        ctop=$(printf '%s' "$rows_chg" | LC_ALL=C sort -t$'\t' -k1,1r -k2,2n | awk -F'\t' -v kf="$keyf" '
            BEGIN { while ((getline l < kf) > 0) if (l != "") nw[l] = 1 }
            ($3 in nw) { next }
            seen[$3]++ { next }
            n++ < 25')
        rm -f "$keyf"
    fi
    {
        html_head "What is new" "../assets/style.css" "" "" "whats-new"   # its help page (2026-09-13: every page carries one)
        printf '<h1>What is new</h1>\n'
        printf '<p class="range">The report catalog’s history, from the generators’ git log: the <strong>25 most recently added</strong> reports and the <strong>25 most recently changed</strong> ones. A change is listed only when its commit was about <strong>a few reports</strong> (up to eight — a sweep across more is about the site, not about any one of them), and a report the New table already names is not repeated below it. Newest first; Description is a new report’s one-line description, Change a changed report’s latest change (its commit message).</p>\n'
        printf '<h2>New reports</h2>\n'
        printf '<div class="tablewrap"><table class="index fit">\n<tr><th>Date</th><th>Report</th><th>Group</th><th>Description</th></tr>\n'
        if [ -n "$ntop" ]; then printf '%s\n' "$ntop" | cut -f4-
        else printf '<tr><td></td><td>(none)</td><td></td><td></td></tr>\n'; fi
        printf '</table></div>\n'
        printf '<h2>Changed reports</h2>\n'
        # "Change", not "Description" (2026-09-29): the cell is the commit
        # subject of the report's latest qualifying change, never its DESC
        printf '<div class="tablewrap"><table class="index fit">\n<tr><th>Date</th><th>Report</th><th>Group</th><th>Change</th></tr>\n'
        if [ -n "$ctop" ]; then printf '%s\n' "$ctop" | cut -f4-
        else printf '<tr><td></td><td>(none)</td><td></td><td></td></tr>\n'; fi
        printf '</table></div>\n'
        printf '</body>\n</html>\n'
    } > "$out"
}

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
    # Files table) and switches/ (2026-09-06: the home Red/Green switch pages)
    dirs="${dirs:+$dirs|}errors|latest|switches"
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
        # reports — so the page offers the Reports start page beside the home
        printf '<p>Reports are renamed, merged or retired now and then (the Transfer / Server / Analyses start pages became one <strong>Reports</strong> page in 2026-09), and the site dropped its environment level in 2026-09 (<code>production/&hellip;</code> became <code>&hellip;</code>), so an older bookmark may need updating.</p>\n'
        printf '<p><a id="homelink" href="/"><strong>Go to the home page</strong></a> &nbsp;&middot;&nbsp; <a id="reportslink" href="/"><strong>All reports</strong></a></p>\n'
        printf '<script>(function(){var p=location.pathname,m=p.match(/^(.*?\\/)(?:%s)\\//);var r=m?m[1]:p.replace(/[^/]*$/,"");r=r.replace(/(?:acceptance|production)\\/$/,"");document.getElementById("homelink").href=r+"index.html";document.getElementById("reportslink").href=r+"reports/index.html";})();</script>\n' "$dirs"
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
        printf '</body>\n</html>\n'
    } > "$out"
}

# The home status tables' figures are CALCULATED (base caches + analyses
# rpts) while their cells link a LIST page — a Transfer > Entities view, or a
# coverage cell page for the five derived Totals — two INDEPENDENT
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
    done < <(perl -ne 'while (m{<a href="((?:transfer/entities|coverage)/[a-z0-9-]+)\.html">([\d.]+)</a>}g) { print "$1\t$2\n" }' docs/index.html 2>/dev/null)
    # (the coverage/ alternation, 2026-08-31 audit: the five derived Totals —
    # Logical / Partners / Domains / Applications / BL — link a coverage cell
    # page instead of an Entities view and escaped this gate; their pages
    # carry the same tinted rows + "Total (N)" footer, so the comparison
    # above applies unchanged)
    if [ "$mism" -gt 0 ]; then
        echo "CONSISTENCY WARNING: $mism home status figure(s) disagree with their linked pages — investigate, do not mask." >&2
    else
        echo "Home status figures verified against their linked pages." >&2
    fi
}

# laps (2026-09-27): TIME lines on the build console, like the other steps
_bpl0=$(date +%s)
_bplap() { local _t1; _t1=$(date +%s); printf 'TIME %5ds  index pages: %s\n' "$((_t1 - _bpl0))" "$1" >&2; _bpl0=$_t1; }
write_reports_index
_bplap "reports start page"
write_whats_new
_bplap "write_whats_new"
write_sitemap
_bplap "write_sitemap"
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
