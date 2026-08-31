#!/usr/bin/env bash
#
# bin/build/publish.sh — write the index pages of the site:
#   docs/index.html                   the ONE SHARED root landing page (all
#                                     parts centered): per ENVIRONMENT
#                                     (acceptance + production) an .envblock
#                                     holding the two result-status tables and
#                                     the log-files table; the top-bar env
#                                     label toggles which block shows
#                                     (report.js, default acceptance).
#                                     Always rewritten reading BOTH envs from
#                                     disk, so per-env build passes are
#                                     idempotent.
#   docs/<env>/transfer/index.html    the active env's transfer report catalog
#
#   docs/<env>/server/index.html      the active env's server report catalog
#
# Labels/descriptions come from each report's TITLE/DESC (via publish_lib.sh's
# area_entries). This reads the .rpt files, not the rendered HTML, so it does not
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
source "$SCRIPT_DIR/../publish_lib.sh"   # cd's to the repo root; defines area_entries/html_head/…

ensure_assets   # ALWAYS — see the note in bin/transfer/publish.sh

# The index pages, the finder, the sitemap and the shared home are written from
# BOTH env trees, and the per-area publishes CLEAR the dirs the index pages
# live in — so this must re-run whenever any of them did. Their stamp files
# are the signal: data/<env>/.publish holds one per completed publish, so
# depending on both dirs says exactly "did anything get re-rendered".
# Also read directly: every area's .rpt (the index labels come from TITLE/DESC),
# docs/help/ (the sitemap's help card) and the git history (What is new).
STAMP="$PUBLISH_STAMP_DIR/index.stamp"
# the sitemap bakes the scope's build-report link, so the scope is part of this
# (PUBLISH_STAMP_EXTRA is no longer set here: the scope only mattered for the
# sitemap's Build-report link, gone 2026-08-29 with the docs/ build report)
if [ -f docs/index.html ] && publish_is_fresh "$STAMP" "$DOCS" "${BASH_SOURCE[0]}" \
       $(publish_area_stamps) \
       data/acceptance/transfer/reports data/production/transfer/reports \
       data/acceptance/server/reports data/production/server/reports \
       data/acceptance/dashboards/reports data/production/dashboards/reports \
       data/acceptance/analyses/reports data/production/analyses/reports \
       docs/help .git/HEAD .git/refs/heads .git/packed-refs; then
    echo "docs/$SITE_ENV index pages are up to date; skipping." >&2
    exit 0
fi

# Give the hand-authored help pages the EXACT site top bar + footer (the user
# asked for one consistent interface). The help BODY stays hand-authored; only
# the chrome is regenerated — render_shared_topbar, env-neutral (acceptance-
# rooted, inert env switch). Runs in the ACCEPTANCE pass only (the default env,
# like the shared home). A leftover footer bar from before its 2026-07 removal
# is DROPPED here, so the hand-authored help pages need no manual edit.
# This is the one publish step that writes into docs/help/ (see CLAUDE.md).
apply_help_chrome() {
    local tb f tmp
    tb=$(render_shared_topbar "../" "index")
    for f in docs/help/*.html; do
        [ -f "$f" ] || continue
        tmp=$(mktemp "${TMPDIR:-/tmp}/help.XXXXXX")
        awk -v tb="$tb" '
            /^<div class="topbar"><a class="brand"/         { print tb; next }
            /^<div class="footer"><span class="f-left"/     { next }
            { print }
        ' "$f" > "$tmp" && { cmp -s "$tmp" "$f" && rm -f "$tmp" || mv "$tmp" "$f"; }
        # content-compared: the chrome is regenerated identically on almost
        # every build, and docs/help/ is an INPUT of this script's freshness
        # check (and of the sitemap) — an unchanged rewrite must not bump its
        # mtime, or the check could never hold.
    done
}

write_area_index() {   # $1 area  $2 title ; remaining args = ordered basenames
    local area=$1 title=$2; shift 2
    local out="$DOCS/$area/index.html" name rpt t d labels
    mkdir -p "$DOCS/$area"
    local aup; aup=$(printf '%s' "$area" | tr '[:lower:]' '[:upper:]')   # top-bar right text: TRANSFER / SERVER
    {
        html_head "$title" "../assets/style.css" "" "$aup" "index"
        esc "$title"; printf '<h1>%s</h1>\n' "$ESC"
        # First/last record and the Files total for the whole dataset (from the
        # day.rpt non-rendered META lines) — shown here instead of on
        # every report page.
        local mfirst mlast mtransfers dayrpt
        dayrpt="$DATA/$area/reports/day.rpt"
        mfirst=$(meta_val "$dayrpt" first)
        if [ -n "$mfirst" ]; then
            mlast=$(meta_val "$dayrpt" last)
            mtransfers=$(meta_val "$dayrpt" transfers)
            # First/last shown to the minute (drop the :SS.mmm); counts grouped with dots.
            esc "${mfirst:0:16}"; local ef=$ESC; esc "${mlast:0:16}"; local el=$ESC
            esc "$(dotify "$mtransfers")"; local et=$ESC
            printf '<p class="range">First record: <strong>%s</strong> &nbsp;|&nbsp; Last record: <strong>%s</strong> &nbsp;|&nbsp; Files: <strong>%s</strong></p>\n' "$ef" "$el" "$et"
        elif [ -f "$DATA/$area/reports/topview.rpt" ]; then
            # No day report (the server area): compute first/last date and the
            # record total from the Top view's per-day ROWs (col 2 = date,
            # col 3 = records) instead — same figures, different source.
            local tvline tvf tvl tvn
            tvline=$(awk -F'\t' '
                $1 == "ROW" { d = $2; sub(/^@\{[^}]*\}/, "", d)
                    if (d !~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$/) next
                    if (first == "" || d < first) first = d
                    if (d > last) last = d
                    sum += $3
                }
                END { if (first != "") printf "%s\t%s\t%s", first, last, sum }
            ' "$DATA/$area/reports/topview.rpt")
            if [ -n "$tvline" ]; then
                IFS=$'\t' read -r tvf tvl tvn <<< "$tvline"
                esc "$tvf"; local ef=$ESC; esc "$tvl"; local el=$ESC
                esc "$(dotify "$tvn")"; local er=$ESC
                printf '<p class="range">First record: <strong>%s</strong> &nbsp;|&nbsp; Last record: <strong>%s</strong> &nbsp;|&nbsp; Records: <strong>%s</strong></p>\n' "$ef" "$el" "$er"
            fi
        fi
        # Server index: the transfer area's Search report covers this server data
        # too (its "Server values" column), so surface it here as well.
        if [ "$area" = server ] && [ -f "$DOCS/search.html" ]; then
            printf '<p class="range"><a href="../search.html"><strong>Search</strong></a> &mdash; find any account, subscription, login, host or flow; its Server Log column covers this server data.</p>\n'
        fi
        # Grouped catalog, like the Analyses index: one <th colspan=2> section
        # header per report GROUP, its member reports listed beneath (the group
        # machinery the menus/sitemap use); an ungrouped report gets its own row.
        # data-nosort: the index is a hand-ordered catalog with colspan group
        # bands — report.js's fallback sort would collapse it into stacked
        # headers + one alphabetized list AND persist that in sessionStorage
        printf '<div class="tablewrap"><table class="index" data-nosort="1">\n'
        local disp ed et href g glab m ml md seen=" "
        for name in "$@"; do
            if is_subs_report "$name"; then continue; fi   # listed on the Analyses index (Subscriptions)
            if is_boxes_only "$name"; then continue; fi    # reached from the two Boxes pages only
            rpt="$DATA/$area/reports/$name.rpt"; [ -f "$rpt" ] || continue
            g=$(group_of "$area" "$name")
            if [ -n "$g" ]; then
                case $seen in *" $g "*) continue ;; esac   # emit each group once, at its first member
                seen="$seen$g "
                glab=$(group_label "$g")
                esc "$glab"; printf '<tr><th colspan="2">%s</th></tr>\n' "$ESC"
                for m in $(group_members "$g"); do
                    [ -f "$DATA/$area/reports/$m.rpt" ] || continue
                    ml=$(member_label "$m"); [ -n "$ml" ] || ml=$(entry_label "$area" "$m")
                    md=$(field1 DESC "$DATA/$area/reports/$m.rpt")
                    href=$(first_page "$m")
                    esc "$ml"; et=$ESC; esc "$md"; ed=$ESC
                    printf '<tr><td><a href="%s">%s</a></td><td class="desc">%s</td></tr>\n' "$href" "$et" "$ed"
                done
            else
                md=$(field1 DESC "$rpt"); href=$(first_page "$name"); disp=$(entry_label "$area" "$name")
                esc "$disp"; et=$ESC; esc "$md"; ed=$ESC
                printf '<tr><td><a href="%s">%s</a></td><td class="desc">%s</td></tr>\n' "$href" "$et" "$ed"
            fi
        done
        printf '</table></div>\n'
        # (the transfer index's Entities table — one count row per entity
        # type — was REMOVED 2026-07; the Entities group line above covers it)
        printf '</body>\n</html>\n'
    } > "$out"
}

# Per-day figures for the root index's log table: the Files group (transfer
# topview.rpt per-day table, ROW fields 5-9 — its second "counted three ways"
# legend table has non-date ROWs, skipped by the date-anchored match), the
# duration percentiles (duration.rpt) and the five per-day First-seen counts
# (analyses first-seen.rpt, joined by date; its SEEN/NOTSEEN lines are not
# day ROWs and stay out). The server topview.rpt contributes only DAYS: the
# row set is the UNION of both logs' days, newest first. $1 = the ENV data
# root (data/<env>) — the shared home renders one table per environment. One
# "date<TAB>count<TAB>ok<TAB>err<TAB>err%<TAB>4x(class,value) duration
# <TAB>5 first-seen counts" line per date. FILENAME (not FNR==NR) keys the
# source (path segment, env-agnostic), so a missing file just drops its
# columns.
daily_loglines_tsv() {   # $1 = env data root, e.g. data/acceptance
    # The day list is the TRANSFER topview's days only: all four data groups
    # (Files / Duration / Red/Green switch / First seen) are transfer-derived,
    # so a server-only day — the server export runs a day ahead of the
    # transfer export — would render a fully empty row under the Date spine.
    local trpt="$1/transfer/reports/topview.rpt"
    local drpt="$1/transfer/reports/duration.rpt" frpt="$1/analyses/reports/first-seen.rpt" files=()
    # The Red/Green switch group: per DAY, how many subscriptions FLIPPED that
    # day. A flow's state after each File is the site-wide outcome policy —
    # Error = Failed or Expired, OK = anything else (Waiting counts as OK) — so
    # walking its Files in order and noting where that state changes gives the
    # flips. Red = green -> red that day, Green = red -> green. The FIRST File
    # of a flow only establishes its state; it is not a flip.
    # Computed here rather than in a report because it is a home-page figure
    # and needs one cheap pass; _files.tsv is CoreId-ordered, so the walk needs
    # its own (subscription, sortkey) sort.
    local fc_="$1/transfer/cache/_files.tsv" swf=""
    # THE NAMES behind each cell go to a side file the CALLER also derives (a
    # deterministic path: this function runs inside $(...), so it cannot hand a
    # variable back): "date <TAB> R|G <TAB> subscription", one line per flip.
    # The caller renders them into docs/<env>/switches/<date>.html and links
    # the day cells there (2026-08).
    local swn="${TMPDIR:-/tmp}/axswnames.$$.$(basename "$1")"
    : > "$swn"
    if [ -f "$fc_" ]; then
        swf=$(mktemp "${TMPDIR:-/tmp}/axswitch.XXXXXX")
        awk -F'\t' '$12 != "" && $4 != "" && $6 != "" { print toupper($12) "\t" $6 "\t" $4 "\t" $2 "\t" $12 }' "$fc_" \
            | LC_ALL=C sort -t"$(printf '\t')" -k1,1 -k2,2 \
            | awk -F'\t' -v NAMES="$swn" '
                # END-OF-DAY state, compared with the previous ACTIVE day. The
                # input is (subscription, sortkey) ascending, so the last File
                # of a day sets that day state; a flow that broke and recovered
                # inside one day ends it green and is NOT a flip. A day the flow
                # carried nothing keeps the state, so the flip lands on the day
                # the state actually changed.
                function flush(   ) {
                    if (curday == "") return
                    if (prev == "") prev = dayst                     # first active day: sets the state
                    else if (dayst != prev) {
                        if (dayst == "r") { red[curday]++; print curday "\tR\t" curraw > NAMES }
                        else              { grn[curday]++; print curday "\tG\t" curraw > NAMES }
                        prev = dayst }
                    curday = ""
                }
                { st = ($4 == "Failed" || $4 == "Expired") ? "r" : "g"
                  if ($1 != cur) { flush(); cur = $1; curraw = $5; prev = "" }
                  if ($3 != curday) { flush(); curday = $3 }
                  dayst = st }
                END { flush()
                      for (d in red) seen[d] = 1
                      for (d in grn) seen[d] = 1
                      for (d in seen) printf "%s\t%d\t%d\n", d, red[d] + 0, grn[d] + 0 }' \
            > "$swf"
    fi
    # the In/Out split of the Files group: per DAY, how many Files MOVED in
    # and how many out (_files.tsv col 17, the movement direction; every File
    # carries one, so In + Out = Count)
    local iof=""
    if [ -f "$fc_" ]; then
        iof=$(mktemp "${TMPDIR:-/tmp}/axinout.XXXXXX")
        awk -F'\t' '$4 ~ /^[0-9][0-9][0-9][0-9]-/ {
                if ($17 == "in") fi_[$4]++; else if ($17 == "out") fo_[$4]++
                d[$4] = 1 }
            END { for (k in d) printf "%s\t%d\t%d\n", k, fi_[k] + 0, fo_[k] + 0 }' "$fc_" > "$iof"
        files+=("$iof")
    fi
    [ -f "$trpt" ] && files+=("$trpt")
    [ -f "$drpt" ] && files+=("$drpt")
    [ -f "$frpt" ] && files+=("$frpt")
    [ -n "$swf" ] && files+=("$swf")
    # return 0 EXPLICITLY: a bare `return` hands back $? — and with no switch
    # file the [ -n "$swf" ] guard just FAILED, so the bare form returned 1 and
    # set -e killed the whole publish. Only reachable when NO source file
    # exists, i.e. the OTHER env's tree is still cold — which is exactly when
    # the production chain's index-pages pass runs against a mid-parse
    # acceptance tree (found by the 2026-08-20 fresh build).
    if [ ${#files[@]} -eq 0 ]; then [ -z "$swf" ] || rm -f "$swf"; [ -z "$iof" ] || rm -f "$iof"; return 0; fi
    awk -F'\t' '
        function nz(v) { return v == "" ? "-" : v }
        # a duration cell "@{class=dur-s}3 s" -> its class / its text ("-" when absent)
        function dcls(v) { if (v !~ /^@\{class=/) return "-"; sub(/^@\{class=/, "", v); sub(/\}.*/, "", v); return v }
        function dtxt(v) { sub(/^@\{[^}]*\}/, "", v); return v == "" ? "-" : v }
        # the Duration group: p50/p75/p90/p99 (cols 6/7/8/11) from the
        # "Duration per day" table of duration.rpt (Processed Files only);
        # the overall percentiles come from its TOTAL line — never summed here
        FILENAME ~ /duration\.rpt$/ {
            if ($1 == "TABLE") intab = ($2 == "Duration per day")
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
        # the Red/Green switch group (the temp file built above): date, reds,
        # greens. Matched on the basename, like the .rpt sources.
        FILENAME ~ /axswitch/ {
            if ($1 ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$/) { swr[$1] = $2; swg[$1] = $3; hassw = 1 }
            next
        }
        # the Files In/Out split (the axinout temp file): date, in, out
        FILENAME ~ /axinout/ {
            if ($1 ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$/) { fin[$1] = $2; fout[$1] = $3; hasio = 1 }
            next
        }
        $1 != "ROW" { next }
        { dd = $2; sub(/^@\{[^}]*\}/, "", dd) }
        # the Files group (Count Ok Recovered Error Error%) is cols 5-9, per-CoreId figures (field 7 = Recovered, not used here)
        FILENAME ~ /\/transfer\// && dd ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]/ { d=substr(dd,1,10); fc[d]=nz($5); fok[d]=nz($6); frv[d]=nz($7); fer[d]=nz($8); fpc[d]=nz($9); seen[d]=1 }
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
                    fok[d], frv[d], fer[d], fpc[d]
                else         printf "%s\t-\t-\t-\t-\t-\t-\t-", d
                if (d in hasdur) printf "\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s", dc[d,0], dv[d,0], dc[d,1], dv[d,1], dc[d,2], dv[d,2], dc[d,3], dv[d,3], dc[d,4], dv[d,4]
                else             printf "\t-\t-\t-\t-\t-\t-\t-\t-\t-\t-"
                # a day the first-seen report does not list (or a missing
                # report) renders like a 0: blank cells
                for (p = 0; p < 6; p++) printf "\t%s", (hasfs && (d, p) in fs ? fs[d, p] : "-")
                printf "\t%s\t%s", (hassw && (d in swr) ? swr[d] : "-"), (hassw && (d in swg) ? swg[d] : "-")
                printf "\n"
            }
            # the Duration TOTAL as a sentinel LAST line (the shell reader
            # stores it for the Total row and skips it as a day)
            printf "TOTAL\t-\t-\t-\t-\t-\t-\t-"
            for (p = 0; p < 5; p++) printf "\t%s\t%s", (dtv[p] == "" ? "-" : dtc[p]), (dtv[p] == "" ? "-" : dtv[p])
            printf "\t-\t-\t-\t-\t-\t-\t-\t-\n"
        }
    ' "${files[@]}"
    [ -n "$swf" ] && rm -f "$swf"
    [ -n "$iof" ] && rm -f "$iof"
    return 0
}

# One Status cell (mirrors bin/analyses/publish.sh's st_cell): a 0 renders
# blank; a nonzero value links its coverage cell page when that page exists.
# $3 = the coverage href RELATIVE TO THE DOCS ROOT — the shared home's hrefs
# carry the env prefix ("acceptance/coverage/…"), so the existence check is
# against docs/, never the env-scoped $DOCS.
_stcell() {   # $1 value  $2 class  [$3 coverage href, docs-root-relative]
    if [ "${1:-0}" = 0 ]; then printf '<td class="%s"></td>' "$2"; return 0; fi
    if [ -n "${3:-}" ] && [ -f "docs/$3" ]; then
        printf '<td class="%s"><a href="%s">%s</a></td>' "$2" "$3" "$(dotify "$1")"
    else
        printf '<td class="%s">%s</td>' "$2" "$(dotify "$1")"
    fi
}

# One toggle variant's cell CONTENT — link / plain text / empty (0).
_stvar() {   # $1 value  [$2 coverage href, docs-root-relative]
    [ "${1:-0}" = 0 ] && return 0
    if [ -n "${2:-}" ] && [ -f "docs/$2" ]; then
        printf '<a href="%s">%s</a>' "$2" "$(dotify "$1")"
    else
        printf '%s' "$(dotify "$1")"
    fi
}

# A DUAL-VALUE cell for the "including server log" switch: the .von span
# (server-log-inclusive figure) shows when the table's .sxscol carries
# .srvon, the .voff span (transfer-only figure) otherwise (style.css;
# report.js setupSrvToggle).
_stcell2() {   # $1 on-value  $2 off-value  $3 class  [$4 on-href]  [$5 off-href]
    # separate hrefs per variant: the coverage pages count blue as SEEN, so
    # only the server-log-INCLUSIVE (on) figures match them — a transfer-only
    # (off) figure with no matching list page renders unlinked
    printf '<td class="%s"><span class="von">%s</span><span class="voff">%s</span></td>' \
        "$3" "$(_stvar "$1" "${4:-}")" "$(_stvar "$2" "${5:-}")"
}

# The PERCENTAGE columns link the same page as the count they are a share of,
# so EVERY figure in a row is clickable — a share of a list is that list. A 0 %
# still renders (unlike a 0 count, which blanks): it is a real reading.
_pctvar() {   # $1 percentage  [$2 href, docs-root-relative]
    if [ -n "${2:-}" ] && [ -f "docs/$2" ]; then printf '<a href="%s">%s&nbsp;%%</a>' "$2" "$1"
    else printf '%s&nbsp;%%' "$1"; fi
}
_stpct2() {   # $1 on-%  $2 off-%  [$3 on-href]  [$4 off-href]
    printf '<td class="num"><span class="von">%s</span><span class="voff">%s</span></td>' \
        "$(_pctvar "$1" "${3:-}")" "$(_pctvar "$2" "${4:-}")"
}

# One result-status table (Total / Seen / Transfer / Server / Error / Warning /
# Ok per member) — the analyses Status group as a standalone table. EVERY
# figure is the row count of the list page its cell links, so a number and its
# list can never disagree: the Flow manager entities rows link the Transfer >
# Entities view of that name (2026-07) — the switch state picking the view's
# SCOPE, +Server pages when it is on, the -transfer ones when it is off — the
# PDA rows a coverage cell page, and the Server column (no Entities view lists
# the server-log-only names alone) its status-server coverage cell.
#   $1 = coverage href prefix (docs-relative, e.g. "coverage/")
#   $2 = <h2> title   rest = label:member:basefile
# (the former $3 "rpt kind" is gone: both tables now read the SAME home.rpt,
# keyed by member, and every cell links the member's own Entities views)
_status_table() {
    local cov=$1 title=$2; shift 2
    # the title row carries the "including server log" switch (default OFF:
    # the Transfer/Server columns hide, Seen/Warning show their transfer-only
    # figures — report.js setupSrvToggle flips .srvon on this .sxscol)
    printf '<div class="sxscol"><h2 class="h2row">%s<button type="button" class="srvtoggle" aria-pressed="false">including server log</button></h2>\n<div class="tablewrap"><table class="index fit" data-nosearch="1">\n' "$title"
    printf '<tr><th>Entity</th><th class="num">Total</th><th class="num">Seen</th><th class="num">OK</th><th class="num colsrv">Transfer</th><th class="num colsrv">Server</th><th class="num">Error</th><th class="num">Warning</th><th class="num">Ok</th></tr>\n'
    # The figures are CALCULATED from the sources — Total / Server / Error /
    # Warning / Ok from the base result column, Seen from home.rpt
    # (one line per member), Transfer = Seen - Server, and the
    # toggle-OFF variants derived (Not seen = Total - Transfer, Warning-off =
    # Warning + Server). They are NEVER lifted from the linked pages: the
    # pages must independently list the same rows, and
    # check_status_consistency (run after the home is written) warns LOUDLY
    # on any figure/page divergence — agreement is the proof, never the input.
    local spec label member bf n sv r o g seen tr_ nsoff nson woff
    local srpt="$HOME_ENV_DATA/analyses/reports/home.rpt"
    for spec in "$@"; do
        IFS=: read -r label member bf <<< "$spec"
        n=0; sv=0; r=0; o=0; g=0
        if [ -f "$HOME_ENV_DATA/flow-manager/base/$bf.tsv" ]; then
            read -r n sv r o g <<< "$(awk -F'\t' '
                { n++; c[$3]++ }
                END { print n+0, c["blue"]+0, c["red"]+0, c["orange"]+0, c["green"]+0 }' \
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
        tr_=$(( seen - sv )); nsoff=$(( n - tr_ )); woff=$(( o + sv )); nson=$(( n - seen ))
        # rounded percentages (of Total)         # name: Seen % toggles with the Seen count (server-inclusive vs
        # transfer-only via von/voff), OK % (green) is constant. n/2 rounds.
        local seenpon=0 seenpoff=0 okp=0
        if [ "$n" -gt 0 ]; then
            seenpon=$(( (100 * seen + n / 2) / n ))
            seenpoff=$(( (100 * tr_ + n / 2) / n ))
            okp=$(( (100 * g + n / 2) / n ))
        fi
        # Every Entity label (the classic four AND the PDA trio) links its
        # Entities ALL view (transfer/entities/<name>-all.html — every Entities
        # view carries datereset, so it opens at the full date range even when a
        # From/To is active). The former PDA ENTITY HOME pages
        # (docs/<env>/entity/) were REMOVED 2026-07; their URLs 404.
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
        # IS this figure (All / Seen / Not seen / OK / Warning / Error, each
        # carrying datereset so it opens at the full date range) in the SCOPE
        # this switch state means: +Server (bare page name) when it is on,
        # Transfer (-transfer) when it is off — for the three SCOPE-DEPENDENT
        # views. That covers the two figures that used to have no view of their
        # own — Not seen without the server-log-only names (Total - Transfer) IS
        # Not seen/Transfer, and Warning + Server IS Warning/Transfer.
        # Total/Error/Ok are the same list in either scope (one page, one link),
        # and Server is the +Server scope's own view. A member with NO Entities
        # report (none today) would fall back to its coverage cell pages.
        local h_tot h_seen h_seenoff h_ns h_tr h_srv h_err h_warn h_ok
        local h_nsoff="" h_warnoff=""
        if [ -n "$ebase" ]; then
            # The switch IS the Entities pages' scope tab (2026-07): ON links the
            # +Server pages (bare names), OFF the -transfer ones. Only the three
            # SCOPE-DEPENDENT views have both (Seen / Not seen / Warning) —
            # Total/Error/Ok list the same names in either scope and have ONE
            # page, so those cells keep a single link. The Server column links
            # the Server view (the blue names), which the +Server scope offers.
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
            h_seen="$ent-seen.html";     h_seenoff="$ent-seen-transfer.html"
            h_ns="$ent-not-seen.html";   h_nsoff="$ent-not-seen-transfer.html"
            h_tr="$ent-seen-transfer.html"
            h_srv="$ent-server.html"
            h_err="$ent-error.html"
            h_warn="$ent-warning.html";  h_warnoff="$ent-warning-transfer.html"
            h_ok="$ent-ok.html"
        else
            h_tot="$cov$member-configured.html";     h_seen="$cov$member-seen.html"
            h_seenoff="$cov$member-status-transfer.html"
            h_ns="$cov$member-notseen.html";         h_tr="$cov$member-status-transfer.html"
            h_srv="$cov$member-status-server.html";  h_err="$cov$member-status-error.html"
            h_warn="$cov$member-status-warning.html"; h_ok="$cov$member-status-ok.html"
        fi
        # Total first, then the two % columns: Seen % (matches the Seen count
        # under the toggle via von/voff), then OK % (green/Total, constant).
        # Total/Error/Ok hold the SAME figure in both toggle states and link the
        # ONE page that lists it, so they stay single cells. EVERY figure in the
        # row is a link, the percentages included — each to the page its count
        # links (a share of a list opens that list). Only a 0, which renders as
        # an EMPTY cell, has no link: there is no figure to click.
        _stcell  "$n"             "num"                 "$h_tot"
        _stpct2  "$seenpon" "$seenpoff"                 "$h_seen" "$h_seenoff"
        printf '<td class="num">%s</td>' "$(_pctvar "$okp" "$h_ok")"
        # the Seen / Not seen COUNT columns were removed 2026-08 (the Seen %
        # column keeps the seen figure's link in both toggle states)
        _stcell  "$tr_"           "num colsrv"          "$h_tr"
        _stcell  "$sv"            "num res-blue colsrv" "$h_srv"
        _stcell  "$r"             "num st-err"          "$h_err"
        _stcell2 "$o" "$woff"     "num st-warn"         "$h_warn" "${h_warnoff:-$cov$member-status-warning-server.html}"
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
    if [ "$2" = "-" ]; then printf '<td class="num"></td>'; return 0; fi
    esc "$2"
    if [ "$1" = "-" ]; then printf '<td class="num">%s</td>' "$ESC"
    else printf '<td class="num %s">%s</td>' "$1" "$ESC"; fi
}

# One per-day Date cell (the four per-day tables): sets $dcc to the escaped
# date, linked to the day's combined dashboard when that page exists. Reads
# $env from the caller (write_env_block).
_daycell() {   # $1 = date
    esc "$1"; dcc=$ESC
    [ -f "docs/$env/day/$1.html" ] && dcc="<a href=\"$env/day/$1.html\">$ESC</a>"
    return 0
}

# The log-exports facts table (the bottom of each env block): one row per
# log — how many raw export files feed the parse (the incremental manifests
# _parse.files / _transfers.files, one line per input), the total records,
# the first and last record stamp, the days with records and HOLES: calendar
# days inside the [first,last] span with no record at all. The per-day
# figures come from the two topview.rpt files (Date cells strip the
# @{href=…} attr first — the documented topview consumer rule); a day counts
# as covered only when its record count is nonzero. Reads $HOME_ENV_DATA.
# ---------------------------------------------------------------------------
# "Still failing", in TWO tables (2026-08). A red subscription is red for one
# of two reasons, and they want different columns and different destinations:
#
#   Failing transfers                 it is red BY ITS OWN FILES: a failed
#                                     File and NO server red-flip. The rows are
#                                     transfer/failed-sub-all.rpt's own, red only
#                                     and one per subscription (its newest —
#                                     the .rpt is newest-first, so the first row
#                                     of a subscription is it). Subscription,
#                                     the row's OWN Reason (the linked page's
#                                     verdict) and Started; no Legs.
#                                     The WHOLE row, the subscription cell
#                                     included, opens that file's error page.
#   Failing subscriptions in Server   everything else: red for something the
#   log                               transfer log cannot show — a server-log
#                                     error after the last delivery, a deploy
#                                     mistake, an expired pickup. These rows
#                                     carry the Reason and the evidence stamp;
#                                     a RED row opens the flow's OWN error page
#                                     (errors/<slug>.html, named by the
#                                     subscription — failed.sh writes one for
#                                     every table-2 red), a green early warning
#                                     its DETAIL page.
#
# Membership across the two is the RESULT COLOUR (bin/build/result.sh's third
# column), not a report's selection, so the two together are still every red
# flow — the split only decides which half a flow lands in.
#
# PLUS, in the second table (2026-08-22): the TROUBLE-AFTER-SUCCESS early
# warnings — the still-GREEN flows whose connected server logs carry an
# E-level line dated AFTER their last delivery (went-kaput.sh's
# _kaput-evidence.tsv, the same evidence that page shows) — EXCEPT the ones
# whose newest error classifies as a DEPLOY defect (Route stopped / Receive
# File As not set): a config mistake belongs on the Deploy errors report, not
# the failing worklist. Green rows tint green, their Reason is the classified
# newest E line (bin/flip-reason.awk, the shared vocabulary), and they open
# the detail page like the red rows. A warnings-only flow stays off (evidence
# col 5 empty), exactly like the went-kaput page itself.
#
# Two joins dress the second table, neither deciding membership: the Reason
# (analyses/reports/_subs-boxes.tsv, written by publish-insights.sh; the
# fresh kaput/red-flip verdicts outrank it) and the Last error stamp (the
# red-flip / kaput evidence line; _files.tsv only as a last resort).
# Both tables are class="index" + report.js setupIndexRows, which follows the
# row's first link.
#
# THE 15-ROW CAP (2026-08): each table opens showing only its newest 15 rows,
# the same mechanism as the per-day table above them — rows past 15 and the
# Total row carry class capx, hidden while the table carries cap14, and a
# "Show all" button directly after the .tablewrap (report.js setupShowAll
# reads its previousElementSibling) lifts the cap. Baked only when a table
# holds more than 15 rows. cap14 is the shared cap CLASS, not the count —
# the hidden set is whatever rows the publish marked capx.
# ---------------------------------------------------------------------------
write_failing_now() {   # $1 = env
    local env=$1 rows1 rows2
    local base="$HOME_ENV_DATA/flow-manager/base/_subscriptions.tsv"
    [ -f "$base" ] || return 0
    local boxes="$HOME_ENV_DATA/analyses/reports/_subs-boxes.tsv"
    local rpt="$HOME_ENV_DATA/transfer/reports/failed-sub-all.rpt"
    local filesc="$HOME_ENV_DATA/transfer/cache/_files.tsv"
    local kaput="$HOME_ENV_DATA/server/reports/_kaput-evidence.tsv"
    [ -f "$boxes" ]  || boxes=/dev/null
    [ -f "$rpt" ]    || rpt=/dev/null
    [ -f "$filesc" ] || filesc=/dev/null
    [ -f "$kaput" ]  || kaput=/dev/null

    # --- table 1: the red rows of failed-sub-all.rpt (one per subscription, its newest failure) ---
    # ROW layout there: Subscription | CoreId | Legs | Started | Reason, each
    # cell carrying the error page in an @{href=…} prefix, plus @data:res.
    # The Reason is THE ROW'S OWN field 6 — the verdict failed.sh baked
    # into the very page this row opens (its title suffix), so the home cell
    # and the page it lands on agree BY CONSTRUCTION. It used to join the
    # flow-level _subs-boxes.tsv verdict instead, and the two could disagree:
    # a one-legged file whose flow once had connection failures said
    # "Connection failures" here and "One-legged" on the page (2026-08-22).
    # A SERVER-REDDENED flow never sits here (2026-08-22): a blue/_redflip.tsv
    # entry means the flow's LAST transfer ended OK and the server log erred
    # AFTER it — so any failed File it still has on the Failed Subscriptions lists is older
    # history, and this row would open a stale error page while the real story
    # is the server log. Those flows go to table 2, whatever old failures they
    # keep listed.
    local redflip="$HOME_ENV_DATA/blue/_redflip.tsv"
    [ -f "$redflip" ] || redflip=/dev/null
    rows1=$(awk -F'\t' -v RF="$redflip" '
        BEGIN { while ((getline l < RF) > 0) { n = split(l, a, "\t")
                    if (n >= 1 && a[1] != "") rfs[toupper(a[1])] = 1 }
                close(RF) }
        $1 != "ROW" { next }
        # the failed-sub-all row is Subscription / Date/time / Reason since
        # 2026-08 — the CoreId lives only in the @data:href cell, and a
        # server-failing row carries @data:srv=1 (table 2 owns those)
        { red = 0; srv = 0; pg = ""
          for (i = 2; i <= NF; i++) {
              if ($i == "@data:res=red") red = 1
              if ($i == "@data:srv=1") srv = 1
              if (index($i, "@data:href=../errors/") == 1) pg = substr($i, 22)
          }
          if (!red || srv) next
          site = $2; sub(/^@\{[^}]*\}/, "", site)
          if (site == "" || (site in seen)) next          # newest-first: the first row wins
          if (toupper(site) in rfs) next                  # server-reddened: table 2 owns it
          seen[site] = 1
          if (pg == "") next
          sub(/\.html$/, "", pg)                          # -> the CoreId
          # "-" where a field would be empty: the reader below splits on TAB and
          # bash read() collapses a run of IFS whitespace, shifting the columns
          printf "%s\t%s\t%s\t%s\t%s\n", $3, site, ($4 != "" ? $4 : "-"), pg, $3 }
    ' "$rpt" | LC_ALL=C sort -r | cut -f2-)

    # --- table 2: every OTHER red subscription + the trouble-after-success
    # early warnings (still-green flows with a post-delivery E line, deploy
    # defects excluded — see the header) ------------------------------------
    rows2=$(awk -F'\t' -v BOXES="$boxes" -v FILESC="$filesc" -v KAP="$kaput" -v RF="$redflip" "$(cat bin/flip-reason.awk)"'
        BEGIN {
            while ((getline l < BOXES) > 0) { n = split(l, a, "\t")
                if (n >= 2 && a[1] != "") why[toupper(a[1])] = a[2] }
            close(BOXES)
            # the red-flip evidence stamps: the Last column shows the SERVER
            # LOG line the red verdict rests on, not the last transfer
            # (2026-08-22) — for a server-reddened flow the transfer date is
            # exactly the thing the server log outdates
            while ((getline l < RF) > 0) { n = split(l, a, "\t")
                if (n >= 2 && a[1] != "" && a[2] != "") rfst[toupper(a[1])] = a[2] }
            close(RF)
            while ((getline l < FILESC) > 0) { n = split(l, a, "\t")
                if (n < 12 || a[12] == "") continue
                k = toupper(a[12])
                if (a[6] > mx[k]) { mx[k] = a[6]; last[k] = a[4] " " a[5] } }
            close(FILESC)
            # the kaput evidence: name, latest stamp, sources, latest message,
            # newest E-LEVEL message (empty = warnings only, not listed). The
            # Reason is the classified newest E line; a DEPLOY verdict keeps
            # the flow off this table (its report is Deploy errors), and an
            # unclassifiable line still earns the generic label.
            while ((getline l < KAP) > 0) { n = split(l, a, "\t")
                if (n < 5 || a[1] == "" || a[5] == "") continue
                r = flip_reason(a[5])
                # kapall: the classified newest server E per flow, deploy
                # verdicts INCLUDED — the red rows prefer this fresh verdict
                # over the boxes join (a server-reddened flow must name the
                # server error, not an old box). kap keeps the deploy drop:
                # it gates which GREENS may enter the table at all.
                if (r != "") kapall[toupper(a[1])] = r
                kapts[toupper(a[1])] = a[2]     # the latest-evidence stamp (the green rows Last column)
                if (r == "Route stopped" || r == "Receive File As not set") continue
                kap[toupper(a[1])] = (r != "") ? r : "Trouble after success" }
            close(KAP)
        }
        FILENAME == ARGV[1] { if ($1 != "") intbl1[toupper($1)] = 1; next }   # the names table 1 took
        $1 == "" { next }
        toupper($1) in intbl1 { next }
        # sort key first (newest File first, never-transferred last, name
        # breaking the tie). Never leave a field EMPTY: the reader below
        # splits on TAB and bash read() collapses a run of IFS whitespace,
        # which would shift every later column — the blanks are dashes.
        $3 == "red" {
            k = toupper($1)
            # Last = the server-log evidence stamp (the red-flip line), never
            # the last transfer — the fallback covers a red with no flip entry
            st = (k in rfst) ? rfst[k] : ((k in last) ? last[k] : "-")
            printf "%s\t%s\t%s\t%s\tred\n", \
                (st != "-" ? st : "0000") "\t" $1, $1, st, \
                (k in kapall ? kapall[k] : (k in why ? why[k] : "-"))
            next }
        $3 == "green" && (toupper($1) in kap) {
            k = toupper($1)
            st = (k in kapts) ? kapts[k] : "-"
            printf "%s\t%s\t%s\t%s\tgreen\n", \
                (st != "-" ? st : "0000") "\t" $1, $1, st, kap[k] }' \
        <(printf '%s\n' "$rows1" | cut -f1) "$base" \
        | LC_ALL=C sort -t"$(printf '\t')" -k1,1r -k2,2 | cut -f3-)

    local n1=0 n2=0
    [ -n "$rows1" ] && n1=$(printf '%s\n' "$rows1" | wc -l | tr -d ' ')
    [ -n "$rows2" ] && n2=$(printf '%s\n' "$rows2" | wc -l | tr -d ' ')
    [ "$n1" -gt 0 ] || [ "$n2" -gt 0 ] || return 0

    local site cid started lastf reason href
    # the 15-row cap (see the header): baked only when a table has more to show
    local cap1="" totcap1="" cap2="" totcap2="" rown trc
    [ "$n1" -gt 15 ] && { cap1=" cap14"; totcap1=" capx"; }
    [ "$n2" -gt 15 ] && { cap2=" cap14"; totcap2=" capx"; }
    # SIDE BY SIDE: the same .sxs / .sxscol pair the .rpt renderer emits for a
    # sxs table (style.css: a flex row of content-sized columns that scrolls
    # horizontally rather than wrapping). Each column carries its own heading
    # and note. With only one table — production has no server-log-only reds —
    # the row simply holds one column.
    printf '<div class="sxs">\n'
    if [ "$n1" -gt 0 ]; then
        printf '<div class="sxscol">\n'
        printf '<h2>Failing transfers</h2>\n'
        # data-sort-init: newest LAST first. The rows are emitted in that order
        # anyway, but makeSortable re-sorts on load, so the default has to be
        # declared or the generic fallback would pick a different column.
        # The CoreId is NOT a column — it is only the row's destination, and the
        # error page names it in its own facts table.
        printf '<div class="tablewrap"><table class="index fit%s" data-nosearch="1" data-sort-init="2:-1">\n' "$cap1"
        printf '<tr><th>Subscription</th><th>Reason</th><th>Last</th></tr>\n'
        rown=0
        while IFS=$'\t' read -r site reason cid started; do
            [ -n "$site" ] || continue
            rown=$((rown + 1)); trc=""
            [ -n "$cap1" ] && [ "$rown" -gt 15 ] && trc=' class="capx"'
            href="$env/errors/$cid.html"
            [ "$reason" = "-" ] && reason=""
            esc "$site";    local hsite=$ESC
            esc "$reason";  local hreas=$ESC
            esc "${started:0:16}"; local hstart=$ESC   # minutes precision — no seconds/.mmm (2026-08)
            esc "$href";    local hhref=$ESC
            # every cell links the error page, the subscription included, so the
            # whole row has ONE destination and no cell goes somewhere else
            printf '<tr%s><td class="res-red"><a href="%s">%s</a></td><td><a href="%s">%s</a></td><td><a href="%s">%s</a></td></tr>\n' \
                "$trc" "$hhref" "$hsite" "$hhref" "$hreas" "$hhref" "$hstart"
        done <<< "$rows1"
        # the site-wide TOTAL footer (no numeric columns, so the count alone);
        # hidden while the cap stands, like the per-day table's Total — and
        # not emitted at all under 15 rows (2026-08: a small table's count is
        # visible at a glance, the footer just added noise)
        [ "$n1" -ge 15 ] && printf '<tr class="total%s"><td>Total (%s rows)</td><td></td><td></td></tr>\n' "$totcap1" "$n1"
        printf '</table></div>\n'
        [ -n "$cap1" ] && printf '<button class="showallbtn" type="button">Show all</button>\n'
        printf '</div>\n'
    fi
    if [ "$n2" -gt 0 ]; then
        printf '<div class="sxscol">\n'
        printf '<h2>Failing subscriptions in Server log</h2>\n'
        printf '<div class="tablewrap"><table class="index fit%s" data-nosearch="1" data-sort-init="2:-1">\n' "$cap2"
        printf '<tr><th>Subscription</th><th>Reason</th><th>Last</th></tr>\n'
        rown=0
        while IFS=$'\t' read -r site lastf reason colr; do
            [ -n "$site" ] || continue
            rown=$((rown + 1)); trc=""
            [ -n "$cap2" ] && [ "$rown" -gt 15 ] && trc=' class="capx"'
            # slugify mirrors the detail-page slug rule
            href="$env/details/subscriptions/$(slugify "$site").html"
            # A RED row opens the flow's OWN error page instead (2026-08):
            # errors/<slug>.html, named by the subscription — failed.sh
            # writes one for every table-2 red (server-reddened or file-less),
            # holding the very server-log evidence this row's verdict rests
            # on. Existence-checked (the error slugs suffix on a twin
            # collision); the green early warnings keep the detail page.
            [ "$lastf"  = "-" ] && lastf=""
            [ "$reason" = "-" ] && reason=""
            case $colr in red|green) ;; *) colr=red ;; esac
            if [ "$colr" = red ] && [ -f "docs/$env/errors/$(slugify "$site").html" ]; then
                href="$env/errors/$(slugify "$site").html"
            fi
            esc "$site";   local hsite2=$ESC
            esc "${lastf:0:16}"; local hlast=$ESC   # minutes precision — no seconds/.mmm (2026-08)
            esc "$href";   local hhref2=$ESC
            esc "$reason"; local hreason=$ESC
            printf '<tr%s><td class="res-%s"><a href="%s">%s</a></td><td>%s</td><td>%s</td></tr>\n' \
                "$trc" "$colr" "$hhref2" "$hsite2" "$hreason" "$hlast"
        done <<< "$rows2"
        # the site-wide TOTAL footer — same rules as table 1 (cap-hidden, and
        # not emitted at all under 15 rows)
        [ "$n2" -ge 15 ] && printf '<tr class="total%s"><td>Total (%s rows)</td><td></td><td></td></tr>\n' "$totcap2" "$n2"
        printf '</table></div>\n'
        [ -n "$cap2" ] && printf '<button class="showallbtn" type="button">Show all</button>\n'
        printf '</div>\n'
    fi
    printf '</div>\n'
}

write_log_facts() {
    local srpt="$HOME_ENV_DATA/server/reports/topview.rpt" trpt="$HOME_ENV_DATA/transfer/reports/topview.rpt"
    local smf="$HOME_ENV_DATA/server/cache/_parse.files" tmf="$HOME_ENV_DATA/transfer/cache/_transfers.files"
    local files=() facts
    [ -f "$srpt" ] && files+=("$srpt")
    [ -f "$trpt" ] && files+=("$trpt")
    [ ${#files[@]} -gt 0 ] || return 0
    local sfiles="" tfiles=""
    [ -f "$smf" ] && sfiles=$(awk 'END{print NR}' "$smf")
    [ -f "$tmf" ] && tfiles=$(awk 'END{print NR}' "$tmf")
    # One line per log: "tag<TAB>records<TAB>first<TAB>last<TAB>days<TAB>
    # holecount<TAB>holelist" — the hole walk is a Julian-day loop over the
    # span (the site's awk date arithmetic; never `date`).
    facts=$(awk -F'\t' '
        function jdn(y, m, d) { return int((1461*(y+4800+int((m-14)/12)))/4) \
            + int((367*(m-2-12*int((m-14)/12)))/12) \
            - int((3*int((y+4900+int((m-14)/12))/100))/4) + d - 32075 }
        function jdate(j,   l, n, i, k, y, m, d) {
            l=j+68569; n=int(4*l/146097); l-=int((146097*n+3)/4)
            i=int(4000*(l+1)/1461001); l=l-int(1461*i/4)+31; k=int(80*l/2447)
            d=l-int(2447*k/80); l=int(k/11); m=k+2-12*l; y=100*(n-49)+i+l
            return sprintf("%04d-%02d-%02d", y, m, d) }
        function j_of(ds) { split(ds, JP, "-"); return jdn(JP[1]+0, JP[2]+0, JP[3]+0) }
        $1 != "ROW" { next }
        { dd=$2; sub(/^@\{[^}]*\}/, "", dd) }
        dd !~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]/ { next }
        FILENAME ~ /\/server\// {
            d=substr(dd,1,10)
            if ($3+0 > 0) { sd[d]=1; spd++; ssum+=$3
                if (smin=="" || d<smin) { smin=d; sft=$12 }
                if (smax=="" || d>smax) { smax=d; slt=$13 } }
            next
        }
        # The transfer topview ROW (bin/transfer/reports/topview.sh HEAD):
        # 3=First 4=Last 5=Files 10=Transfers (physical log rows) 13=Transfers
        # Error %. Records = $10, the rows of the log itself — the server row
        # counts its lines the same way. (NO apostrophes here: this comment
        # sits INSIDE the single-quoted awk program.) NOT $13 (fixed 2026-08-31): that
        # summed the daily error PERCENTAGES as "records" and treated every
        # 0.0%-day as a day without records — a clean weekend became a "hole",
        # and an env with no failed transfer at all (production) lost its
        # Records / First / Last / Days cells entirely.
        FILENAME ~ /\/transfer\// {
            d=substr(dd,1,10)
            if ($10+0 > 0) { td[d]=1; tpd++; tsum+=$10
                if (tmin=="" || d<tmin) { tmin=d; tft=$3 }
                if (tmax=="" || d>tmax) { tmax=d; tlt=$4 } }
        }
        # "-" placeholders, never empty middle fields: the shell reader uses a
        # tab IFS (whitespace), so an empty field would collapse and shift the
        # columns (same rule as daily_loglines_tsv).
        function emit(tag, sum, dmin, ft, dmax, lt, present, A,   j, ds, n, miss) {
            if (dmin == "") { printf "%s\t0\t-\t-\t0\t0\t-\n", tag; return }
            n=0; miss=""
            for (j = j_of(dmin); j <= j_of(dmax); j++) {
                ds = jdate(j)
                if (!(ds in A)) { n++; miss = miss (miss=="" ? "" : ", ") ds }
            }
            printf "%s\t%d\t%s %s\t%s %s\t%d\t%d\t%s\n", tag, sum, dmin, ft, dmax, lt, present, n, (miss=="" ? "-" : miss)
        }
        END {
            emit("S", ssum+0, smin, sft, smax, slt, spd+0, sd)
            emit("T", tsum+0, tmin, tft, tmax, tlt, tpd+0, td)
        }
    ' "${files[@]}")
    printf '<h2>The log exports</h2>\n'
    printf '<div class="tablewrap"><table class="index fit" data-nosearch="1">\n'
    printf '<tr><th>Log</th><th class="num">Input files</th><th class="num">Records</th><th>First record</th><th>Last record</th><th class="num">Days</th><th>Holes</th></tr>\n'
    local tag sum first last present nholes holelist label nf rec hc
    while IFS=$'\t' read -r tag sum first last present nholes holelist; do
        [ -n "$tag" ] || continue
        if [ "$tag" = S ]; then label="Server"; nf=$sfiles; [ -f "$srpt" ] || continue
        else label="Transfer"; nf=$tfiles; [ -f "$trpt" ] || continue; fi
        rec=$(dotify "$sum")
        if [ "$sum" = 0 ]; then rec=""; first=""; last=""; present=""; fi
        # a hole is a coverage WARNING — the amber count tint; "none" stays muted
        if [ "$nholes" = 0 ]; then hc='<td>none</td>'
        else esc "$holelist"; hc="<td class=\"st-warn\">$nholes: $ESC</td>"; fi
        printf '<tr><td>%s</td><td class="num">%s</td><td class="num">%s</td><td>%s</td><td>%s</td><td class="num">%s</td>%s</tr>\n' \
            "$label" "$nf" "$rec" "$first" "$last" "${present:-}" "$hc"
    done <<< "$facts"
    printf '</table></div>\n'
}

# ONE environment's home-page content: the status pair + "The log files"
# table, all links prefixed "<env>/…" (docs-root-relative — the home lives at
# the docs root). $1 = the env name. Reads $HOME_ENV_DATA (set by the caller).
write_env_block() {
    local env=$1
    # The two result-status tables (copied from the Flow manager Entities /
    # Logical, Partners, Domains, Applications & BL analyses pages), side by side with
    # coverage links — a status snapshot at the TOP of the landing page.
    if [ -f "$HOME_ENV_DATA/analyses/reports/home.rpt" ] || [ -f "$HOME_ENV_DATA/flow-manager/base/_subscriptions.tsv" ]; then
        write_status_pair "$env/coverage/"
    fi
    # The per-day figures: FOUR titled tables (Files / Duration / Red/Green
    # switch / First seen), rendered side by side further down — one data
    # pass here feeds all four.
    local dl; dl=$(daily_loglines_tsv "$HOME_ENV_DATA")
    # THE SWITCH PAGES (2026-08): one page per day with flips, listing the
    # subscriptions behind the Red and Green cells — the cells link to it.
    # The names file is the side channel daily_loglines_tsv fills (same
    # deterministic path; the $(...) above cannot return a second value).
    local swn="${TMPDIR:-/tmp}/axswnames.$$.$(basename "$HOME_ENV_DATA")"
    local swdir="docs/$env/switches"   # publish.sh runs from the repo root (publish_lib cd)
    mkdir -p "$swdir"; rm -f "$swdir"/*.html
    if [ -s "$swn" ]; then
        local _swd _swsub _swdirn _swpage _swcol
        # missing-file guard (write_failing_now's pattern): on a FRESH data/
        # the OTHER env's chain renders this home first, before this env's
        # analyses publish has written _subs-boxes.tsv — awk over the missing
        # path exits 2 and set -e killed the whole index publish (2026-08-29)
        local _swbase="$HOME_ENV_DATA/flow-manager/base/_subscriptions.tsv"
        local _swboxes="$HOME_ENV_DATA/analyses/reports/_subs-boxes.tsv"
        [ -f "$_swbase" ]  || _swbase=/dev/null
        [ -f "$_swboxes" ] || _swboxes=/dev/null
        # one page per date; the reader below groups by the (sorted) date
        for _swd in $(cut -f1 "$swn" | LC_ALL=C sort -u); do
            _swpage="$swdir/$_swd.html"
            {
                esc "Red/Green switch $_swd"
                html_head "$ESC" "../../assets/style.css" "" "" "" "" ""
                printf '<main>\n<h1>Red/Green switch %s</h1>\n' "$_swd"
                printf '<p class="hnote">Subscriptions whose END-OF-DAY state changed on %s against their previous active day. Red = the day ended on an Error (a Failed or Expired File) where the previous one was OK; Green = the reverse. A flow that broke and recovered inside the day is not listed. Each row opens the subscription&rsquo;s detail page; the tint and the Reason are its CURRENT state — a flow that has recovered since shows green with no reason.</p>\n' "$_swd"
                # side by side: the same .sxs/.sxscol flex row the home red
                # tables use — each column carries its own heading + table
                printf '<div class="sxs">\n'
                for _swdirn in R G; do
                    printf '<div class="sxscol">\n'
                    if [ "$_swdirn" = R ]; then
                        printf '<h2 id="red">Went red</h2>\n'
                        printf '<div class="tablewrap"><table class="index fit" data-nosearch="1">\n<tr><th>Subscription</th><th>Reason</th></tr>\n'
                    else
                        printf '<h2 id="green">Went green</h2>\n'
                        printf '<div class="tablewrap"><table class="index fit" data-nosearch="1">\n<tr><th>Subscription</th></tr>\n'
                    fi
                    while IFS=$'\t' read -r _ _ _swsub; do
                        [ -n "$_swsub" ] || continue
                        _swcol=$(awk -F'\t' -v N="$_swsub" 'toupper($1)==toupper(N){print $3; exit}' "$_swbase")
                        case $_swcol in green|red|orange|blue) _swcol="res-$_swcol" ;; *) _swcol="" ;; esac
                        esc "$_swsub"
                        if [ "$_swdirn" = R ]; then
                            # the Reason: the boxes sidecar, the same value the
                            # home Failing-transfers table shows — the CURRENT
                            # diagnosis, so an old day may show none
                            _swreas=$(awk -F'\t' -v N="$_swsub" 'toupper($1)==toupper(N){print $2; exit}' "$_swboxes")
                            _swname=$ESC; esc "$_swreas"
                            printf '<tr><td class="%s"><a href="../details/subscriptions/%s.html">%s</a></td><td>%s</td></tr>\n' \
                                "$_swcol" "$(slugify "$_swsub")" "$_swname" "$ESC"
                        else
                            printf '<tr><td class="%s"><a href="../details/subscriptions/%s.html">%s</a></td></tr>\n' \
                                "$_swcol" "$(slugify "$_swsub")" "$ESC"
                        fi
                    done <<< "$(awk -F'\t' -v D="$_swd" -v W="$_swdirn" '$1==D && $2==W' "$swn" | LC_ALL=C sort -t"$(printf '\t')" -k3,3f)"
                    printf '</table></div>\n</div>\n'
                done
                printf '</div>\n'
                printf '</main>\n</body>\n</html>\n'
            } > "$_swpage"
        done
    fi
    rm -f "$swn"
    # ONLY with TRANSFERS (2026-08-29): dl always carries the Duration TOTAL
    # sentinel, so a bare non-empty test rendered the four titled tables as
    # empty header-only shells on a config-only env (production). The row of
    # five renders only when at least one DAY line carries transfer Files
    # (field 2 — "-" on a server-only day).
    local _hastx=""
    [ -n "$dl" ] && _hastx=$(printf '%s\n' "$dl" | awk -F'\t' '$1!="" && $1!="TOTAL" && $2!="" && $2!="-" { print 1; exit }')
    if [ -n "$_hastx" ]; then
        # THE PER-DAY TABLE (2026-08-31, user request — ONE table again):
        # Files / Duration / Red/Green switch / First seen are column GROUPS
        # of one wide table, a gband banner row over a shared Date column
        # (its cells link the day's combined dashboard). The 2026-08 five-
        # table flex row (a Date spine + four data tables) is gone: one
        # table cannot fall out of row-sync, which the spine did whenever a
        # header's height changed (the csv-hotspot regression). The group
        # dividers are positional CSS on table.dayrows (columns 2/8/12/14 +
        # the gbrow banner cells) — no per-cell class to keep in step.
        #
        # THE 14-DAY CAP (2026-08): the table opens showing only the newest
        # 14 days and NO Total row; the older rows and the Total carry class
        # capx, hidden by CSS while the table carries cap14; the "Show all"
        # button (baked only when there are more than 14 days) removes the
        # cap — setupShowAll uncaps every capped table inside the button's
        # adjacent wrapper, here the one tablewrap. The baked Total keeps
        # the FULL-window figures — report.js recomputeTotals counts inline
        # display only, so the class-hidden rows never leave its sums. The
        # Total row only from 10 days up (2026-08): a short table's sums add
        # nothing a glance does not already give. Still data-nosort: the cap
        # hides the OLDEST rows by class, which a user sort would interleave.
        local dcount capcls="" totcap="" rown=0 trc=""
        dcount=$(printf '%s\n' "$dl" | awk -F'\t' '$1!="" && $1!="TOTAL"' | wc -l | tr -d ' ')
        if [ "$dcount" -gt 14 ]; then capcls=" cap14"; totcap=" capx"; fi
        local d fc fin fout fok frv fer fpc c v fsum=0 finsum=0 foutsum=0 foksum=0 frvsum=0 fersum=0
        local dc50 dv50 dc75 dv75 dc90 dv90 dc95 dv95 dc99 dv99 dtot=""
        local fsp fss fsa fsl fsh fsps=0 fsss=0 fsas=0 fsls=0 fshs=0
        local swr swg swrs=0 swgs=0 dcc=""
        printf '<div class="tablewrap perday"><table class="index fit dayrows%s" data-nosearch="1" data-nosort="1">\n' "$capcls"
        printf '<tr class="gbrow"><th></th><th class="gband" colspan="6">Files</th><th class="gband" colspan="4">Duration</th><th class="gband" colspan="2">Red/Green switch</th><th class="gband" colspan="4">First seen</th></tr>\n'
        printf '<tr><th>Date</th><th class="num">In</th><th class="num">Out</th><th class="num">Ok</th><th class="num">Recovered</th><th class="num">Error</th><th class="num">Error %%</th><th class="num">p50</th><th class="num">p75</th><th class="num">p90</th><th class="num">p95</th><th class="num">Red</th><th class="num">Green</th><th class="num">Logical</th><th class="num">Partners</th><th class="num">Subscriptions</th><th class="num">Accounts</th></tr>\n'
        rown=0
        while IFS=$'\t' read -r d fc fin fout fok frv fer fpc dc50 dv50 dc75 dv75 dc90 dv90 dc95 dv95 dc99 dv99 fsg fsp fss fsa fsl fsh swr swg; do
            [ -n "$d" ] || continue
            # the sentinel LAST line: the overall duration percentiles for
            # the Total row (a percentile cannot be summed)
            if [ "$d" = "TOTAL" ]; then
                dtot=""
                for c in "$dc50:$dv50" "$dc75:$dv75" "$dc90:$dv90" "$dc95:$dv95"; do
                    dtot="$dtot$(_durcell "${c%%:*}" "${c#*:}")"
                done
                continue
            fi
            _daycell "$d"; rown=$((rown + 1)); trc=""
            [ -n "$capcls" ] && [ "$rown" -gt 14 ] && trc=' class="capx"'
            printf '<tr%s><td>%s</td>' "$trc" "$dcc"
            # —— Files (from transfer/topview.html) ——
            # Ok/Error tint like topview's cells, a 0 rendering as an empty
            # cell (the render_rpt.awk convention). A nonzero Error cell
            # links the Entities Subscriptions/ALL view narrowed to that day
            # (?axway_date — report.js sets From=To and persists it like a
            # user selection), sorted by its Error column (axway_sort=5:-1):
            # there the Error column total equals this cell exactly, and the
            # row tints say which of the flows are still red — the ERROR view
            # cannot show that (2026-08: 24 of a day's 25 errors belonged to
            # a flow that recovered the same evening, green and absent there,
            # so the cell said 25 and its target showed 1).
            if [ "$fc" != "-" ] && [ -n "$fc" ]; then
                fsum=$((fsum + fc))   # the Files COUNT column is gone (2026-08: In + Out carries it); fsum stays for Error %
                # the In/Out split (movement direction; In + Out = Count)
                if [ "$fin" = "-" ] || [ "$fin" = 0 ] || [ -z "$fin" ]; then printf '<td class="num"></td>'; else
                    esc "$(dotify "$fin")"; printf '<td class="num">%s</td>' "$ESC"; finsum=$((finsum + fin)); fi
                if [ "$fout" = "-" ] || [ "$fout" = 0 ] || [ -z "$fout" ]; then printf '<td class="num"></td>'; else
                    esc "$(dotify "$fout")"; printf '<td class="num">%s</td>' "$ESC"; foutsum=$((foutsum + fout)); fi
                if [ "$fok" = "-" ] || [ "$fok" = 0 ]; then printf '<td class="num processed z"></td>'; else
                    esc "$(dotify "$fok")"; printf '<td class="num processed">%s</td>' "$ESC"; fi
                # Recovered, amber like topview's cell; a 0/blank cell stays untinted (td.warn:empty)
                if [ "$frv" = "-" ] || [ "$frv" = 0 ] || [ -z "$frv" ]; then printf '<td class="num warn"></td>'; else
                    esc "$(dotify "$frv")"; printf '<td class="num warn">%s</td>' "$ESC"; frvsum=$((frvsum + frv)); fi
                if [ "$fer" = "-" ] || [ "$fer" = 0 ]; then printf '<td class="num failed z"></td>'; else
                    esc "$(dotify "$fer")"
                    if [ -f "docs/$env/transfer/entities/subscription-all.html" ]; then
                        printf '<td class="num failed"><a href="%s/transfer/entities/subscription-all.html?axway_date=%s&amp;axway_sort=5:-1">%s</a></td>' "$env" "$d" "$ESC"
                    else printf '<td class="num failed">%s</td>' "$ESC"; fi; fi
                [ "$fok" != "-" ] && foksum=$((foksum + fok)); [ "$fer" != "-" ] && fersum=$((fersum + fer))
                if [ "$fpc" = "-" ]; then printf '<td class="num"></td>'; else
                    esc "$fpc"; printf '<td class="num">%s</td>' "$ESC"; fi
            else
                printf '<td class="num"></td><td class="num"></td><td class="num processed"></td><td class="num warn"></td><td class="num failed"></td><td class="num"></td>'
            fi
            # —— Duration (from transfer/duration.html): the day's
            # p50/p75/p90/p95, tinted like that page's cells ——
            _durcell "$dc50" "$dv50"; _durcell "$dc75" "$dv75"
            _durcell "$dc90" "$dv90"; _durcell "$dc95" "$dv95"
            # —— Red/Green switch: subscriptions that FLIPPED that day ——
            # Tinted like every other outcome pair on the site — red for the
            # flows that broke, green for the ones that recovered — and a 0
            # renders blank (the render_rpt.awk convention, class z). A
            # nonzero cell links its day's switch page (written above),
            # anchored on the matching section.
            if [ "$swr" = "-" ] || [ "$swr" = 0 ] || [ -z "$swr" ]; then printf '<td class="num failed z"></td>'; else
                esc "$(dotify "$swr")"
                if [ -f "docs/$env/switches/$d.html" ]; then printf '<td class="num failed"><a href="%s/switches/%s.html#red">%s</a></td>' "$env" "$d" "$ESC"
                else printf '<td class="num failed">%s</td>' "$ESC"; fi
                swrs=$((swrs + swr)); fi
            if [ "$swg" = "-" ] || [ "$swg" = 0 ] || [ -z "$swg" ]; then printf '<td class="num processed z"></td>'; else
                esc "$(dotify "$swg")"
                if [ -f "docs/$env/switches/$d.html" ]; then printf '<td class="num processed"><a href="%s/switches/%s.html#green">%s</a></td>' "$env" "$d" "$ESC"
                else printf '<td class="num processed">%s</td>' "$ESC"; fi
                swgs=$((swgs + swg)); fi
            # —— First seen (from analyses/first-seen.html): a count links
            # that day's first-seen list when the page exists (a page exists
            # only for a day with names); 0 renders blank ——
            for c in "logicals:$fsg" "partners:$fsp" "subscriptions:$fss" "accounts:$fsa"; do
                v=${c#*:}
                if [ "$v" = "-" ] || [ "$v" = 0 ] || [ -z "$v" ]; then printf '<td class="num"></td>'; continue; fi
                esc "$(dotify "$v")"
                if [ -f "docs/$env/first-seen/${c%%:*}-$d.html" ]; then
                    printf '<td class="num"><a href="%s/first-seen/%s-%s.html">%s</a></td>' "$env" "${c%%:*}" "$d" "$ESC"
                else printf '<td class="num">%s</td>' "$ESC"; fi
            done
            printf '</tr>\n'
        done <<< "$dl"
        # —— the ONE Total row (from 10 days up) ——
        esc "$(dotify "$fsum")"; local fst=$ESC
        esc "$(dotify "$foksum")"; local fokt=$ESC; esc "$(dotify "$fersum")"; local fert=$ESC
        local fpct=""
        [ "$fsum" -gt 0 ] && fpct=$(awk -v e="$fersum" -v n="$fsum" 'BEGIN{printf "%.1f%%", 100*e/n}')
        local fint="" foutt=""
        if [ "$finsum" -gt 0 ]; then esc "$(dotify "$finsum")"; fint=$ESC; fi
        if [ "$foutsum" -gt 0 ]; then esc "$(dotify "$foutsum")"; foutt=$ESC; fi
        local frvt=""
        if [ "$frvsum" -gt 0 ]; then esc "$(dotify "$frvsum")"; frvt=$ESC; fi
        # the Duration total = the report's own overall percentiles (a
        # percentile cannot be summed); empty cells when the report is absent
        [ -n "$dtot" ] || dtot='<td class="num"></td><td class="num"></td><td class="num"></td><td class="num"></td>'
        # the switch totals: how many flips of each kind in the whole window
        local swrt swgt
        if [ "$swrs" -gt 0 ]; then esc "$(dotify "$swrs")"; swrt="<td class=\"num failed\">$ESC</td>"; else swrt='<td class="num failed z"></td>'; fi
        if [ "$swgs" -gt 0 ]; then esc "$(dotify "$swgs")"; swgt="<td class=\"num processed\">$ESC</td>"; else swgt='<td class="num processed z"></td>'; fi
        # the First-seen totals: the report's SEEN line — the SAME figure as
        # the status tables' Seen column in the Transfer scope (the day cells
        # above plus the report's no-date bucket sum to it); each links its
        # <type>-seen list, whose row count IS that figure
        if [ -f "$HOME_ENV_DATA/analyses/reports/first-seen.rpt" ]; then
            IFS=$'\t' read -r c fsgs fsps fsss fsas fsls fshs \
                <<< "$(awk -F'\t' '$1=="SEEN"{print; exit}' "$HOME_ENV_DATA/analyses/reports/first-seen.rpt")"
        fi
        local fstot=""
        for c in "logicals:$fsgs" "partners:$fsps" "subscriptions:$fsss" "accounts:$fsas"; do
            v=${c#*:}
            if [ -z "$v" ] || [ "$v" = 0 ]; then fstot="$fstot<td class=\"num\"></td>"; continue; fi
            esc "$(dotify "$v")"
            if [ -f "docs/$env/first-seen/${c%%:*}-seen.html" ]; then
                fstot="$fstot<td class=\"num\"><a href=\"$env/first-seen/${c%%:*}-seen.html\">$ESC</a></td>"
            else fstot="$fstot<td class=\"num\">$ESC</td>"; fi
        done
        [ "$dcount" -ge 10 ] && printf '<tr class="total%s"><td>Total</td><td class="num">%s</td><td class="num">%s</td><td class="num processed">%s</td><td class="num warn">%s</td><td class="num failed">%s</td><td class="num">%s</td>%s%s%s%s</tr>\n' \
            "$totcap" "$fint" "$foutt" "$fokt" "$frvt" "$fert" "$fpct" "$dtot" "$swrt" "$swgt" "$fstot"
        printf '</table></div>\n'
        # the "Show all": setupShowAll uncaps the capped table inside the
        # tablewrap above it
        [ -n "$capcls" ] && printf '<button class="showallbtn" type="button">Show all</button>\n'
    fi
    write_failing_now "$env"
    write_log_facts
}

# The active environment's own 404 page (docs/<env>/404.html) — the target
# bin/build/crosslink.sh points an env-switch link at when a page has NO TWIN in
# this environment, so the switch never lands on the webserver's error page.
# Standard top-bar chrome (the page sits at the env root: css href
# "assets/style.css" -> envbase "", base "../").
write_env_404() {
    local out="$DOCS/404.html" envlabel
    case $SITE_ENV in production) envlabel="Production" ;; *) envlabel="Acceptance" ;; esac
    {
        html_head "Page not found — $envlabel" "assets/style.css" "" "" "general"
        printf '<h1>Page not found</h1>\n'
        printf '<p class="subtitle">This page does not exist in the <strong>%s</strong> environment.</p>\n' "$envlabel"
        printf '<p class="range">If the environment switch brought you here, the page you came from has no counterpart in %s &mdash; its entity, report day or data set exists only in the other environment.</p>\n' "$envlabel"
        printf '<p class="range">The environment switch did happen, you are now in <strong>%s</strong>, continue via the report menus above, or go to the <a href="../index.html"><strong>home page</strong></a>.</p>\n' "$envlabel"
        printf '</body>\n</html>\n'
    } > "$out"
}

# ---- The Report finder (docs/<env>/report-finder.html) ----------------------
# One searchable catalog row per report page: TITLE + INTRO lifted from every
# published .rpt (transfer, server, dashboards) plus the hand-rendered
# analyses pages. The client-side search (report.js setupReportFinder, input
# #rfq) ranks TITLE matches ABOVE intro-only matches, both in catalog order.
# Linked from the top-bar magnifier next to the help icon. Env-root page like
# search.html (css depth 0).
finder_row() {   # $1 href  $2 area  $3 title  $4 intro (**bold** markdown, or raw HTML on dashboards)  $5 keywords ("" = none)
    [ -n "$3" ] || return 0
    local text disp tl il et eh ea kw kl kd
    # DISPLAY: tags stripped (the dashboard intros carry raw <a>/<strong>
    # whose page-relative hrefs would break from this page), the **bold**
    # markdown rendered, existing entities (&mdash; …) kept as-is
    text=$(printf '%s' "$4" | sed 's/<[^>]*>//g')
    disp=$(printf '%s' "$text" | sed -E 's/\*\*([^*]+)\*\*/<strong>\1<\/strong>/g')
    # SEARCH attrs: lowercased plain text — no tags, no **, entities blanked
    tl=$(printf '%s' "$3" | tr '[:upper:]' '[:lower:]'); esc "$tl"; tl=$ESC
    il=$(printf '%s' "$text" | sed -e 's/\*\*//g' -e 's/&[a-zA-Z]*;/ /g' | tr '[:upper:]' '[:lower:]'); esc "$il"; il=$ESC
    esc "$3"; et=$ESC
    esc "$1"; eh=$ESC
    esc "$2"; ea=$ESC
    # KEYWORDS: $5 = the SEARCH set (KEYWORDS directive + every table heading
    # and column name, rpt_keywords) -> data-k, ranked with the intro hits by
    # report.js; $6 = the VISIBLE subset (directive + table headings only —
    # a column flood would swamp the muted line) -> the .rfkw second line.
    kw=${5:-}; kd=""
    if [ -n "$kw" ]; then
        kl=$(printf '%s' "$kw" | tr '[:upper:]' '[:lower:]'); esc "$kl"; kl=$ESC
    else
        kl=""
    fi
    if [ -n "${6:-}" ]; then
        # cap the DISPLAYED line (a many-table report — seen-in-server-log has
        # 25 headings — would swamp the row); the search set is never capped
        local kv=$6
        if [ ${#kv} -gt 200 ]; then kv="${kv:0:200}…"; fi
        esc "$kv"; kd=" <span class=\"rfkw\">$ESC</span>"
    fi
    printf '<tr data-t="%s" data-i="%s" data-k="%s"><td><a href="%s">%s</a></td><td>%s</td><td class="desc">%s%s</td></tr>\n' \
        "$tl" "$il" "$kl" "$eh" "$et" "$ea" "$disp" "$kd"
}

# rpt_keywords RPT [vis] — the finder's per-report keywords: any explicit
# KEYWORDS directive values, then every TABLE heading and — in the default
# full/search set only — every HEAD column name (transfer/server shape) or
# KPI label / CARD chart title (dashboards shape), case-insensitively deduped
# in first-seen order, comma-joined. This is what makes content that lives in
# a report's SECONDARY tables (a "By edge node" table, a "Coherence cluster
# warning" row named in KEYWORDS) findable even though the title and intro
# never mention it. The "vis" set (directive + table headings) is what the
# finder DISPLAYS — the column names stay search-only, a many-table report
# would otherwise flood the muted line.
rpt_keywords() {
    [ -f "$1" ] || return 0
    LC_ALL=C awk -F'\t' -v vis="${2:-}" '
        function add(s,   k) { sub(/^ +/, "", s); sub(/ +$/, "", s)
            if (s == "" || s == "-") return
            k = tolower(s); if (k in seen) return
            seen[k] = 1; out = out (out == "" ? "" : ", ") s }
        $1 == "KEYWORDS" { for (i = 2; i <= NF; i++) { n = split($i, a2, /, */); for (j = 1; j <= n; j++) add(a2[j]) } }
        $1 == "TABLE"    { add($2) }
        $1 == "CARD"     { add($2) }     # chart titles: the dashboards twin of a TABLE heading
        vis != "" { next }
        $1 == "HEAD"     { for (i = 2; i <= NF; i++) add($i) }
        $1 == "KPI"      { add($3) }
        END { print out }
    ' "$1"
}
# The finder's Area column for a transfer-area report basename: the reports that
# live in the Analyses menu/sitemap (cross references, partner coverage,
# seen-in-server-log, skipped + its per-value pages, missing-cronjobs,
# not-in-flow-manager, sources-and-targets) are labelled "Analyses" like the
# menu, everything else "Transfer". KEEP IN SYNC with _analyses_groups — every
# member listed there is an Analyses report wherever its page happens to live.
finder_area() {
    case $1 in
        cross-*|entity-coverage|entity-coverage-*|sources-and-targets|seen-in-server-log|skipped|skipped-*|missing-cronjobs|not-in-flow-manager) echo "Analyses" ;;
        *) if is_subs_report "$1" || is_boxes_only "$1"; then echo "Analyses"; else echo "Transfer"; fi ;;
    esac
}
# ---- the finder row builder --------------------------------------------------
# ONE awk pass replaces ~19 forks PER REPORT (field1 twice = grep|cut, two
# rpt_keywords, finder_area, and finder_row's four printf|sed/tr pipelines). At
# 142 reports that was ~2,700 processes and 1.9 s — over a quarter of this
# script's runtime — for work that is pure string munging.
#
# Input: one manifest line per row, TAB-separated.
#   R <TAB> href <TAB> area <TAB> rpt-path          read title/intro/keywords from the .rpt
#   S <TAB> href <TAB> area <TAB> title <TAB> intro <TAB> kw <TAB> kwvis   literal row
# Output: the finished <tr>, in manifest order.
FINDER_AWK='
BEGIN { FS = "\t"; for (_i = 1; _i < 256; _i++) BYTE[sprintf("%c", _i)] = _i }
function esc(s) { gsub(/&/, "\&amp;", s); gsub(/</, "\&lt;", s); gsub(/>/, "\&gt;", s); gsub(/"/, "\&quot;", s); return s }
# --- UTF-8 helpers -----------------------------------------------------------
# awk is BYTE oriented; the bash this replaces was not, and the difference is
# visible in the output. ${#s} counted CHARACTERS, so the 200-cap fell later than
# a byte count would (an em dash is 3 bytes), and `tr [:upper:] [:lower:]` in a
# UTF-8 locale folded non-ASCII letters. Both are reproduced here.
function u_trunc(s, n,   i, c, k, L) {   # first n CHARACTERS of s
    k = 0; L = length(s)
    for (i = 1; i <= L; i++) { c = BYTE[substr(s, i, 1)]
        if (c < 128 || c >= 192) { if (k == n) return substr(s, 1, i - 1); k++ } }
    return s
}
# tolower over ASCII plus the cased ranges that reach this data: Latin-1
# supplement (agrave..thorn, skipping the multiplication sign) and Greek. Only
# Greek capital delta actually occurs today ("delta Files" in the weekly report),
# but a partner name in Latin-1 would fold the same way tr did.
function u_lower(s,   i, L, c, d, o) {
    s = tolower(s); o = ""; L = length(s)
    for (i = 1; i <= L; i++) { c = BYTE[substr(s, i, 1)]
        if (c == 195 && i < L) { d = BYTE[substr(s, i + 1, 1)]
            if (d >= 128 && d <= 158 && d != 151) { o = o sprintf("%c%c", 195, d + 32); i++; continue } }
        else if (c == 206 && i < L) { d = BYTE[substr(s, i + 1, 1)]
            if (d >= 145 && d <= 159) { o = o sprintf("%c%c", 206, d + 32); i++; continue }      # Alpha..Omicron
            if (d >= 160 && d <= 169) { o = o sprintf("%c%c", 207, d - 32); i++; continue } }    # Pi..Omega (lead byte shifts)
        o = o substr(s, i, 1) }
    return o
}
function val(line,   i) { i = index(line, "\t"); return (i ? substr(line, i + 1) : "") }
# TWO independent dedup sets, because this replaced TWO separate rpt_keywords
# runs. Sharing one set silently drops a term from the VISIBLE list when it first
# appeared on a HEAD/KPI line (search-only) earlier in the file — which is
# exactly what the byte-diff caught on the Expired report.
function add(s,   k) { sub(/^ +/, "", s); sub(/ +$/, "", s)
    if (s == "" || s == "-") return
    k = tolower(s)
    if (!(k in kseen)) { kseen[k] = 1; kw = kw (kw == "" ? "" : ", ") s }
    if (visnow && !(k in vseen)) { vseen[k] = 1; kvis = kvis (kvis == "" ? "" : ", ") s } }
# scan one .rpt for TITLE/INTRO and the keyword sets (rpt_keywords, both sets in
# a single pass — it used to be two separate awk invocations per report)
function scan(f,   l, n, a2, j) {
    title = ""; intro = ""; kw = ""; kvis = ""; split("", kseen); split("", vseen)
    while ((getline l < f) > 0) {
        if (title == "" && index(l, "TITLE\t") == 1) { title = val(l); continue }
        if (intro == "" && index(l, "INTRO\t") == 1) { intro = val(l); continue }
        if (index(l, "KEYWORDS\t") == 1) { visnow = 1
            n = split(val(l), a2, "\t")
            for (j = 1; j <= n; j++) { m = split(a2[j], a3, /, */); for (q = 1; q <= m; q++) add(a3[q]) }
            continue }
        if (index(l, "TABLE\t") == 1 || index(l, "CARD\t") == 1) { visnow = 1; split(val(l), a2, "\t"); add(a2[1]); continue }
        if (index(l, "HEAD\t") == 1) { visnow = 0; n = split(val(l), a2, "\t"); for (j = 1; j <= n; j++) add(a2[j]); continue }
        if (index(l, "KPI\t") == 1) { visnow = 0; n = split(val(l), a2, "\t"); add(a2[2]); continue }
    }
    close(f)
}
function row(href, area, title, intro, kw, kvis,   text, disp, tl, il, kl, kd) {
    if (title == "") return
    text = intro; gsub(/<[^>]*>/, "", text)                       # sed s/<[^>]*>//g
    disp = strongify(text)                                        # **bold** -> <strong>
    tl = esc(u_lower(title))
    il = text; gsub(/\*\*/, "", il); gsub(/&[a-zA-Z]*;/, " ", il); il = esc(u_lower(il))
    kl = (kw == "") ? "" : esc(u_lower(kw))
    kd = ""
    if (kvis != "") {
        if (u_trunc(kvis, 201) != kvis) kvis = u_trunc(kvis, 200) "\342\200\246"
        kd = " <span class=\"rfkw\">" esc(kvis) "</span>"
    }
    printf "<tr data-t=\"%s\" data-i=\"%s\" data-k=\"%s\"><td><a href=\"%s\">%s</a></td><td>%s</td><td class=\"desc\">%s%s</td></tr>\n", \
        tl, il, kl, esc(href), esc(title), esc(area), disp, kd
}
# **bold** -> <strong>bold</strong>, left to right (sed -E s/\*\*([^*]+)\*\*/…/g)
function strongify(s,   out, i, j) {
    out = ""
    while ((i = index(s, "**")) > 0) {
        j = index(substr(s, i + 2), "**")
        if (j == 0) break
        if (j == 1) { out = out substr(s, 1, i + 3); s = substr(s, i + 4); continue }   # "****": no [^*]+ match
        out = out substr(s, 1, i - 1) "<strong>" substr(s, i + 2, j - 1) "</strong>"
        s = substr(s, i + j + 3)
    }
    return out s
}
$1 == "R" { scan($4); row($2, $3, title, intro, kw, kvis); next }
$1 == "S" { row($2, $3, $4, $5, $6, $7) }
'

write_report_finder() {
    local out="$DOCS/report-finder.html" name rpt t4 i4 fp a4 rows
    # Emit every finder row first, then derive the per-area counts from what was
    # actually emitted (so the intro line can never drift from the table).
    # Build a MANIFEST (pure bash string work, no forks per row) and turn it into
    # rows with ONE awk. finder_row/rpt_keywords/field1 are gone from this path.
    local mf; mf=$(mktemp "${TMPDIR:-/tmp}/rfind.XXXXXX")
    {
        for name in "${transfer_order[@]}"; do
            case $name in duration-all|duration-minmax|duration-all-minmax) continue ;; esac   # Duration's sibling views — reached via their buttons, not separate finder entries
            rpt="$DATA/transfer/reports/$name.rpt"; [ -f "$rpt" ] || continue
            fp=$(first_page "$name")
            case $name in
                (entity-search) fp="search.html" ;;
                (cross-*)       fp="analyses/xref/$fp" ;;
                (*)             if is_subs_report "$name"; then fp="analyses/$fp"; else fp="transfer/$fp"; fi ;;
            esac
            printf 'R\t%s\t%s\t%s\n' "$fp" "$(finder_area "$name")" "$rpt"
        done
        for rpt in "$DATA"/transfer/reports/skipped-*.rpt; do   # the per-value Skipped reports (dynamic, not in transfer_order)
            [ -f "$rpt" ] || continue
            name=${rpt##*/}; name=${name%.rpt}
            printf 'R\t%s\t%s\t%s\n' "transfer/$name.html" "Analyses" "$rpt"
        done
        for name in "${server_order[@]}"; do
            rpt="$DATA/server/reports/$name.rpt"; [ -f "$rpt" ] || continue
            if is_subs_report "$name"; then fp="analyses/$(first_page "$name")"; a4=Analyses
            elif is_boxes_only "$name"; then fp="server/$(first_page "$name")"; a4=Analyses   # boxes-only: page stays in server/, labeled with its owners
            else fp="server/$(first_page "$name")"; a4=Server; fi
            printf 'R\t%s\t%s\t%s\n' "$fp" "$a4" "$rpt"
        done
        for rpt in "$DATA"/dashboards/reports/*.rpt; do
            [ -f "$rpt" ] || continue
            name=${rpt##*/}; name=${name%.rpt}
            if [ "$name" = transfer ] || [ "$name" = server ]; then continue; fi   # the Transfer/Server dashboards are unlinked from the site
            fp="dashboards/$name.html"; [ "$name" = overview ] && fp="dashboards/index.html"
            printf 'R\t%s\t%s\t%s\n' "$fp" "Dashboard" "$rpt"
        done
        # the hand-rendered analyses pages carry no .rpt — a static list (KEEP IN
        # SYNC with the Analyses menu/sitemap). ONLY pages with no .rpt belong
        # here: a report that HAS one is already emitted by the loops above, so
        # listing it again yields a duplicate finder row — and once such a report
        # moves out of the Subscriptions group its analyses/ page stops existing,
        # making the duplicate a dead link too (expired + missing-cronjobs did
        # exactly that when they became real Transfer reports).
        while IFS='|' read -r sh st si sk sv; do
            [ -n "$sh" ] || continue
            printf 'S\t%s\tAnalyses\t%s\t%s\t%s\t%s\n' "$sh" "$st" "$si" "$sk" "$sv"
        done <<'STATIC'
analyses/use-cases.html|Use cases|The UC flow templates: each use case with its subscriptions and template status.||
analyses/use-case-definitions.html|Use case definitions|Each use case explained — who connects, which way the file travels, and what triggers it.||
analyses/use-case-patterns.html|Use case patterns|The accounts grouped by their subscription mix (e.g. UC2 (1) UC4 (1)).||
analyses/subscriptions.html|Subscriptions (analyses)|Every configured subscription with its FlowID, use case, account, endpoint, BL tag and derived Logical / Partner / Domain / Application groups.|mapping, flowid, tags, BL|mapping, BL tag
analyses/logical-detection.html|Logical detection|How every configured FlowID detected to its Logical flow group — the rule trail per FlowID: separator normalization, variant folds, digit tails, pins and the 3-part reshape.|logical, flowid, derivation, rules, detection|logical, derivation
analyses/accounts.html|Accounts (analyses)|The configured accounts analysed against the FlowManager configuration.||
analyses/cronjobs.html|Cronjobs|The subscriptions polling schedules (cron expressions) in human terms.||
analyses/first-seen.html|First seen|On what day each logical flow, partner, subscription, account, login and remote host was first seen in the transfer logs.||
analyses/first-seen-both.html|First seen (both logs)|On what day each entity was first seen across BOTH the transfer and the server logs.||
analyses/acc-vs-prod-summary.html|Acceptance vs production|The two environments entity name sets compared per type — only in Acceptance, in both, or only in Production — with each side's Files and the set/dormancy Summary.|dormant, promotion, summary|dormant, promotion, summary
analyses/whitelist-audit.html|Whitelist audit|Whitelisted partner IPs vs the addresses actually connecting: used, connect-only, never seen (prunable), plus sources without any whitelist entry.|whitelist, AllowIP, IP, prune, attack surface, unused|whitelist, AllowIP, prune
analyses/accounts-in-boxes.html|Accounts in boxes|Every configured account boxed by what is true of the subscriptions connected to it — an account is in a box when one of its subscriptions is. The account view of Subscriptions in boxes.|boxes, account, box, connected, subscriptions, estate, rollup|boxes, box, account rollup
analyses/config-hygiene.html|Config hygiene|The cleanup backlog: likely-duplicate twins (case / separator folds) and orphaned objects nothing references.|twins, duplicates, orphans, cleanup, legacy|twins, orphans, cleanup
analyses/subscriptions-in-boxes.html|Subscriptions in boxes|Every subscription boxed by what is true of it — OK, or any of twelve problem signals — one column per box, each cell linking into its report or entity view.|boxes, problems, broken, flagged, trouble, one-legged, kaput, only red, regression, ok, not seen, server only|boxes, problems, flagged, ok
analyses/triage.html|Triage|The ranked action list: every subscription that is red, holds staged Files about to expire, or just fell silent — newest flips on the busiest flows first.|triage, action list, worklist, red, expiry, quiet, attention, priority, ranked|triage, action list, priority
analyses/failing-reasons.html|Error reasons|Every possible Reason of the Failed Subscriptions pages — how many currently red subscriptions carry it and the newest occurrence; a nonzero row opens the red subscriptions behind it.|error, reason, cause, failed, failing, red, count, vocabulary|error reasons, cause, red
analyses/data-diff.html|Since yesterday|The data diff against the newest log day: new red flips, newly quiet flows, recoveries, first-seen entities by name and new server-log-only names.|diff, yesterday, new, changed, flips, recovered, first seen|diff, yesterday, changed
analyses/partner-scorecard.html|Partner scorecard|One composite health score per partner relation, worst first — error share, trend, pickup wait, security posture, endpoint redundancy and silence — with the traffic-concentration panel.|partner, scorecard, health, score, gini, concentration, trend|partner, scorecard, health
analyses/blast-radius.html|Blast radius|What stops when a remote host dies: the Files, subscriptions, applications and partners behind every outbound endpoint, sole-endpoint partners flagged.|blast radius, endpoint, host, redundancy, single point of failure, spof|blast radius, endpoint, spof
analyses/app-partners.html|Application dependencies|Which external partners each internal application exchanges Files with — the dependency matrix with traffic weights and dead pairs at 100% Error.|application, dependencies, partner, matrix, lineage, exposure|application, dependencies, lineage
analyses/partner-lifecycle.html|Partner lifecycle|The quiet failure modes of a partner relation: configured but never live, gone quiet after real history, and still transferring on ever fewer flows.|partner, lifecycle, never live, quiet, shrinking, onboarding|partner, lifecycle, quiet
analyses/cleanup-backlog.html|Cleanup backlog|Every cleanup signal merged into one ranked decommission-candidate list, safest first — config orphans, never-seen subscriptions, unused whitelist addresses, cron-less polls and long-quiet entities.|cleanup, backlog, decommission, orphans, unused, prune|cleanup, decommission, prune
file-search-24-hours.html|File search|Find a File by its file name — date, subscription, size and CoreId, OK rows green and Error rows red; six windows (24 hours through a month), each with its own Search button, the query carried between them.|file, search, file name, find, filename, lookup|file search, filename, find
STATIC
    } > "$mf"
    rows=$(LC_ALL=C awk "$FINDER_AWK" "$mf")
    rm -f "$mf"

    # `|| true` on each: grep -c exits 1 on zero matches (it still prints the
    # 0), so an area losing all its finder rows must not kill the publish.
    local rf_tc rf_sc rf_ac
    rf_tc=$(grep -c '<td>Transfer</td>' <<<"$rows" || true)
    rf_sc=$(grep -c '<td>Server</td>' <<<"$rows" || true)
    rf_ac=$(grep -c '<td>Analyses</td>' <<<"$rows" || true)
    {
        html_head "Report finder" "assets/style.css" "" "" "report-finder"
        printf '<h1>Report finder</h1>\n'
        printf '<p class="range">%d Transfer reports, %d Server reports, %d Analyses reports. Find a report by its <strong>title</strong> or <strong>introduction</strong> text &mdash; title matches list first.</p>\n' "$rf_tc" "$rf_sc" "$rf_ac"
        printf '<div class="controls"><label>Search</label><span class="search-wrap"><input type="search" id="rfq" class="search" autocomplete="off" autofocus></span><span class="searchhint">Wildcards: ? = 1 character, * = 0..n characters. Logical operators: or / and / and not</span></div>\n'
        printf '<div class="tablewrap"><table class="index" data-rfinder="1" data-nosearch="1" data-nosort="1">\n<tr><th>Report</th><th>Area</th><th>Introduction</th></tr>\n'
        printf '%s\n' "$rows"
        printf '</table></div>\n'
        printf '</body>\n</html>\n'
    } > "$out"
}

# ---- The Site map (docs/<env>/sitemap.html) ---------------------------------
# The whole environment on one page: per AREA (Transfer / Server / Dashboards /
# Analyses / Data pages & tools) a column of CARDS — one card per report GROUP,
# its group name on top and the member reports tree-listed beneath (the same
# group machinery the menus use); ungrouped reports get a card of their own.
# Env-root page (css depth 0) linked from the top-bar map icon.
sm_href() {   # $1 area  $2 basename -> env-root-relative page
    local fp; fp=$(first_page "$2")
    # the Subscriptions group renders into docs/<env>/analyses/, whichever area
    # its DATA comes from
    if is_subs_report "$2"; then printf 'analyses/%s' "$fp"; return; fi
    if [ "$1" = server ]; then printf 'server/%s' "$fp"; return; fi
    case $2 in
        entity-search) printf 'search.html' ;;
        cross-*)       printf 'analyses/xref/%s' "$fp" ;;
        *)             printf 'transfer/%s' "$fp" ;;
    esac
}
sm_area_cards() {   # $1 area (transfer|server)
    local area=$1 name g members m ml lbl lis n seen=" "
    local order=()
    if [ "$area" = transfer ]; then order=("${transfer_order[@]}"); else order=("${server_order[@]}"); fi
    for name in "${order[@]}"; do
        # NO existence filter (2026-07): the sitemap gives ALL options in every
        # env — a data-less report has an empty-report placeholder page
        # (render_missing_reports), never a 404.
        [ "$name" = entity-search ] && continue     # Search lives in the Tools card
        case $name in duration-all|duration-minmax|duration-all-minmax) continue ;; esac   # Duration's sibling views (reached via their buttons)
        case $name in entity-coverage|entity-coverage-ok|entity-coverage-once|entity-coverage-diff) continue ;; esac   # listed in the Analyses column
        [ "$name" = sources-and-targets ] && continue # listed in the Analyses column
        [ "$name" = skipped ] && continue           # listed in the Analyses column
        [ "$name" = seen-in-server-log ] && continue # listed in the Analyses column
        [ "$name" = missing-cronjobs ] && continue  # listed in the Analyses column (Configuration)
        [ "$name" = not-in-flow-manager ] && continue # listed in the Analyses column (Configuration)
        if is_subs_report "$name"; then continue; fi   # listed in the Analyses column (Subscriptions)
        if is_boxes_only "$name"; then continue; fi    # listed in the Analyses column (the Boxes card)
        case $name in cross-*) continue ;; esac      # Cross References listed in the Analyses column (Configuration)
        g=$(group_of "$area" "$name")
        if [ -n "$g" ]; then
            case $seen in *" $g "*) continue ;; esac
            seen="$seen$g "
            lbl=$(group_label "$g")
            lis=""; n=0; lastm=""
            for m in $(group_members "$g"); do
                ml=$(member_label "$m"); [ -n "$ml" ] || ml=$(member_label "${m#cross-}")
                [ -n "$ml" ] || ml=$m
                esc "$ml"
                lis+=$(printf '<li><a href="%s">%s</a></li>' "$(sm_href "$area" "$m")" "$ESC")$'\n'
                n=$((n + 1)); lastm=$m
            done
            [ "$n" -gt 0 ] || continue
            esc "$lbl"
            if [ "$n" = 1 ]; then   # a single-member group folds into one linked card
                # link the ONE member that has a page (not the whole member
                # list — that produced a spaces-in-href 404 when only one of
                # a group's reports exists, e.g. production srv-security)
                printf '<div class="smcard"><h3><a href="%s">%s</a></h3></div>\n' \
                    "$(sm_href "$area" "$lastm")" "$ESC"
            else
                printf '<div class="smcard"><h3>%s <span class="smcount">%s</span></h3><ul>\n%s</ul></div>\n' "$ESC" "$n" "$lis"
            fi
        else
            lbl=$(entry_label "$area" "$name")
            esc "$lbl"
            printf '<div class="smcard"><h3><a href="%s">%s</a></h3></div>\n' "$(sm_href "$area" "$name")" "$ESC"
        fi
    done
}
write_sitemap() {
    local out="$DOCS/sitemap.html" rpt name t4 n1 n2 sub base cnt lbl
    {
        html_head "Site Map" "assets/style.css" "" "" "sitemap"
        printf '<h1>Site Map</h1>\n'
        printf '<p class="range">Everything in this environment on one page: each card is a report <strong>group</strong> — the group name on top, its reports beneath. The same order as the menus, left to right by area.</p>\n'
        printf '<div class="smgrid">\n'
        printf '<section class="smarea sm-transfer"><h2>Transfer reports</h2>\n'
        printf '<div class="smcard"><h3><a href="transfer/index.html">Start page</a></h3></div>\n'
        sm_area_cards transfer
        printf '</section>\n<section class="smarea sm-server"><h2>Server reports</h2>\n'
        printf '<div class="smcard"><h3><a href="server/index.html">Start page</a></h3></div>\n'
        sm_area_cards server
        # one card per GROUP — the same five groups as ANALYSES_MENU and the
        # pages' analyses_group_tabs rows. Analyses BEFORE Dashboards to match
        # the top-bar pulldown order (Transfer · Server · Analyses · Dashboards).
        printf '</section>\n<section class="smarea sm-ana"><h2>Analyses</h2>\n'
        printf '<div class="smcard"><h3><a href="analyses/index.html">Start page</a></h3></div>\n'
        # A report family sharing one prefix lists ONCE, linked to its first
        # page (First seen, Use Case, Skipped — the per-value Skipped pages and
        # the sibling views are reached from there). Deliberately NOT a generic
        # prefix rule: the No/By/Per-style labels (No remote files / No remote
        # dir, ...) are distinct reports and stay separate entries.
        printf '<div class="smcard"><h3>Coverage &amp; seen <span class="smcount">5</span></h3><ul>\n'
        printf '<li><a href="transfer/entity-coverage-accounts.html">Entity coverage</a></li>\n'
        printf '<li><a href="analyses/first-seen.html">First seen</a></li>\n'
        printf '<li><a href="analyses/data-diff.html">Since yesterday</a></li>\n'
        printf '<li><a href="file-search-24-hours.html">File search</a></li>\n'
        printf '<li><a href="transfer/seen-in-server-log.html">Seen in server log</a></li>\n'
        printf '</ul></div>\n'
        printf '<div class="smcard"><h3>Configuration <span class="smcount">15</span></h3><ul>\n'
        printf '<li><a href="analyses/use-cases.html">Use Case</a></li>\n'
        printf '<li><a href="analyses/uc2-visits.html">UC2 pickup visits</a></li>\n'
        printf '<li><a href="analyses/subscriptions.html">Subscriptions</a></li>\n'
        printf '<li><a href="analyses/logical-detection.html">Logical detection</a></li>\n'
        printf '<li><a href="analyses/accounts.html">Accounts</a></li>\n'
        printf '<li><a href="analyses/account-sharing.html">Account sharing</a></li>\n'
        printf '<li><a href="analyses/twins.html">Twins</a></li>\n'
        printf '<li><a href="analyses/cronjobs.html">Cronjobs</a></li>\n'
        printf '<li><a href="analyses/config-hygiene.html">Config hygiene</a></li>\n'
        printf '<li><a href="analyses/whitelist-audit.html">Whitelist audit</a></li>\n'
        printf '<li><a href="analyses/cleanup-backlog.html">Cleanup backlog</a></li>\n'
        printf '<li><a href="transfer/sources-and-targets.html">Sources and Targets</a></li>\n'
        printf '<li><a href="transfer/skipped.html">Skipped</a></li>\n'
        printf '<li><a href="transfer/not-in-flow-manager.html">Not in Flow Manager</a></li>\n'
        printf '<li><a href="analyses/%s">Cross References</a></li>\n' "$(group_home cross)"
        printf '</ul></div>\n'
        # The Boxes card — the two hand-written boxes pages (under analyses/)
        # plus the BOXES_ONLY_REPORTS, whose pages stay at their area URLs and
        # are linked only from here and the boxes texts. KEEP IN SYNC with
        # _analyses_groups' "Boxes" line, ANALYSES_MENU and the analyses index.
        # (The four SUBS_GROUP_REPORTS members live in the Configuration card
        # above, not here.)
        printf '<div class="smcard"><h3>Partners <span class="smcount">4</span></h3><ul>\n'
        printf '<li><a href="analyses/partner-scorecard.html">Partner scorecard</a></li>\n'
        printf '<li><a href="analyses/blast-radius.html">Blast radius</a></li>\n'
        printf '<li><a href="analyses/app-partners.html">Application dependencies</a></li>\n'
        printf '<li><a href="analyses/partner-lifecycle.html">Partner lifecycle</a></li>\n'
        printf '</ul></div>\n'
        printf '<div class="smcard"><h3>Boxes <span class="smcount">15</span></h3><ul>\n'
        local sub5
        for sub5 in 'analyses/accounts-in-boxes.html|Accounts in boxes' \
                    'analyses/subscriptions-in-boxes.html|Subscriptions in boxes' \
                    'analyses/triage.html|Triage' \
                    'transfer/missing-cronjobs.html|Missing cronjobs' \
                    'transfer/pirates-details.html|One-legged transfers' \
                    'transfer/from-green-to-red.html|From green to red' \
                    'transfer/only-red.html|Only red' \
                    'transfer/waiting.html|Waiting files' \
                    'transfer/expired.html|Expired files' \
                    'transfer/went-quiet-subscriptions.html|Went quiet' \
                    'server/went-kaput.html|Trouble after success' \
                    'server/site-failures.html|Connection failures' \
                    'server/deploy-errors.html|Deploy errors' \
                    'server/no-remote-dir.html|No remote dir' \
                    'server/no-remote-files.html|No remote files'; do
            printf '<li><a href="%s">%s</a></li>\n' "${sub5%%|*}" "${sub5#*|}"
        done
        printf '</ul></div>\n'
        printf '<div class="smcard"><h3>Errors <span class="smcount">2</span></h3><ul>\n'
        printf '<li><a href="analyses/failed.html">Failed Subscriptions</a></li>\n'
        printf '<li><a href="analyses/failing-reasons.html">Error reasons</a></li>\n'
        printf '</ul></div>\n'
        printf '<div class="smcard"><h3>Acceptance vs production <span class="smcount">12</span></h3><ul>\n'
        local avp
        for avp in accounts:Accounts subscriptions:Subscriptions logicals:Logical logins:Logins hosts:Hosts \
                   partners:Partners domains:Domains applications:Applications bl:BL whitelist:Whitelist; do
            printf '<li><a href="analyses/acc-vs-prod-%s-both.html">%s</a></li>\n' "${avp%%:*}" "${avp#*:}"
        done
        printf '<li><a href="analyses/acc-vs-prod-subs-partners.html">Subscriptions vs partners</a></li>\n'
        printf '<li><a href="analyses/acc-vs-prod-summary.html">Summary</a></li>\n'
        printf '</ul></div>\n'
        printf '</section>\n<section class="smarea sm-dash"><h2>Dashboards</h2>\n'
        # ONE dashboard (2026-07): the per-topic pages folded into the overview
        printf '<div class="smcard"><h3><a href="dashboards/index.html">Dashboard</a></h3></div>\n'
        # the Monitor dashboard exists only in an env with monitor data (the
        # rpt is the flag); this sitemap line is also what keeps the page
        # REACHABLE for linkcheck — the top-bar Monitor link is runtime-only
        [ -f "$DATA/dashboards/reports/monitor.rpt" ] && \
            printf '<div class="smcard"><h3><a href="dashboards/monitor.html">Monitor</a></h3></div>\n'
        printf '</section>\n<section class="smarea sm-tools"><h2>Data pages &amp; tools</h2>\n'
        # per-day pages: the COMBINED day dashboard, one per calendar day
        # (date-named; the per-area transfer-/server- day pages were removed
        # 2026-07) — reached from the Top view Date cells and the home
        # log-files table.
        # `|| true`: zero day pages (config-only estate) makes ls fail, and
        # pipefail would kill the publish over a legitimate 0
        n1=$({ ls "$DOCS"/day/[0-9]*.html 2>/dev/null || true; } | wc -l | tr -d ' ')
        printf '<div class="smcard"><h3>Per-day pages <span class="smcount">%s</span></h3><ul>\n' "$n1"
        printf '<li><a href="../index.html">Day dashboards (%s) — one per calendar day, via the home log-files table</a></li>\n' "$n1"
        printf '</ul></div>\n'
        # the per-entity detail pages: one page per configured-or-logged entity
        printf '<div class="smcard"><h3>Entity detail pages</h3><ul>\n'
        for sub in accounts:account subscriptions:subscription logins:login hosts:remote-host logicals:logical \
                   partners:partner applications:application domains:domain bl:bl; do
            base=${sub#*:}; sub=${sub%%:*}
            # an entity type can have ZERO names (production 2026-08: no
            # DNS-named hosts at all) — a missing slugmap is a valid state,
            # and `wc < missing` would kill the publish under set -e
            cnt=0
            [ -f "$DATA/transfer/reports/details/$sub/_slugmap.tsv" ] && \
                cnt=$(wc -l < "$DATA/transfer/reports/details/$sub/_slugmap.tsv" | tr -d ' ')
            lbl=$(member_label "$base")
            esc "$lbl"
            printf '<li><a href="transfer/entities/%s-all.html">%s (%s)</a></li>\n' "$base" "$ESC" "${cnt:-0}"
        done
        printf '</ul></div>\n'
        printf '<div class="smcard"><h3>Tools</h3><ul>\n'
        printf '<li><a href="../index.html">Home</a> — the shared landing page</li>\n'
        printf '<li><a href="search.html">Search</a> — find any entity by name</li>\n'
        printf '<li><a href="report-finder.html">Report finder</a> — find a report by title or intro</li>\n'
        printf '<li><a href="whats-new.html">What is new</a> — new and changed reports</li>\n'
        printf '<li><a href="../help/index.html">Help</a> — how to read the report catalogs (per-report help sits behind each page'\''s <b>?</b> button)</li>\n'
        # (the Build report link is GONE 2026-08-29: the report is no longer
        # published into docs/ at all — it lives only in the local build/
        # directory, and nothing on the site references a build any more)
        printf '</ul></div>\n'
        printf '</section>\n</div>\n</body>\n</html>\n'
    } > "$out"
}

# ---- What is new (docs/<env>/whats-new.html) --------------------------------
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
        first-seen)      printf 'First seen\tAnalyses\tanalyses/first-seen.html\tOn what day each logical flow, partner, subscription, account, login and remote host was first seen in the transfer logs.\n'; return 0 ;;
        cross-reference) printf 'Cross References\tAnalyses\tanalyses/xref/cross-account-subscriptions.html\tEvery pair of the eight entities cross-tabulated both ways — which appear together on a transfer, which are configured but never seen.\n'; return 0 ;;
        # the analyses PUBLISH writers render several pages each — one row per
        # page that exists (the insight pages have no .rpt to read a title from)
        publish-insights)
            local pg key rest ttl dsc
            for pg in                      "whitelist-audit:Whitelist audit:Whitelisted partner IPs vs the addresses actually connecting — used, connect-only or prunable." \
                      "accounts-in-boxes:Accounts in boxes:Every configured account boxed by what is true of the subscriptions connected to it." \
                      "config-hygiene:Config hygiene:The cleanup backlog — likely-duplicate twins and orphaned objects nothing references." \
                      "expired:Expired:Staged UC2 files the retention sweep deleted before any pickup — time to expiry, per-account pickup behavior, never-delivered volume."; do
                key=${pg%%:*}; rest=${pg#*:}; ttl=${rest%%:*}; dsc=${rest#*:}
                [ -f "$DOCS/analyses/$key.html" ] && printf '%s\tAnalyses\tanalyses/%s.html\t%s\n' "$ttl" "$key" "$dsc"
            done
            return 0 ;;
        publish-accvsprod)
            printf 'Acceptance vs production\tAnalyses\tanalyses/acc-vs-prod-summary.html\tThe two environments’ entities compared per type, with each side’s activity and the promotion gaps.\n'; return 0 ;;
    esac
    case $1 in bin/server/*|server/bin/*) area=server ;; esac   # (the pre-2026-07 path too — see write_whats_new)
    # the Subscriptions group scripts all live in bin/analyses/reports/, so the
    # path says nothing about which area holds their .rpt — ask the group table
    local sa; if sa=$(subs_report_area "$2"); then area=$sa; fi
    # A component of a 2026-07 merged report has no page of its own — but a
    # CHANGE to it is a change to its MERGED report's page, so map it to the
    # parent and recurse (2026-08-15: was a plain skip, which hid every
    # extended component — e.g. the seven-table server batch — from the
    # Changed table). Retired components (no parent page) still return 0.
    if is_merged_component "$2"; then
        local wn_parent=""
        case $2 in
            day|weekly|hourly|weekday)                              wn_parent=activity ;;
            retry|attempts|resubmissions)                           wn_parent=retries ;;
            patterns|legs-count|protocol-journey|arrived-left)      wn_parent=file-journey ;;
            errors-day|error-timing|error-reasons|top-messages)     wn_parent=errors ;;
            unknown-sites|unknown-accounts|unknown-hosts|unknown-whitelisting|unknown-logins) wn_parent=missing-entities ;;
            inbound-connections|connection-diagnostics)             wn_parent=connections ;;
            logon|auth-activity|ssh-key-auth)                       wn_parent=logons ;;
            cluster-health|stuck-events|scheduler-overruns)          wn_parent=platform-health ;;
            pesit|file-cleanup)                                     wn_parent=capacity ;;
            ssh-crypto|ssh-sessions)                                wn_parent=ssh-security ;;
            uc1-status|uc2-status|uc3-status|uc4-status)            wn_parent=uc-status ;;
            volume-src|trend)                                       wn_parent=volume ;;
            size-dist|file-type|duplicate-files)                    wn_parent=files ;;
            *) return 0 ;;   # retired (ranking, double, stale-accounts, ...) — no page
        esac
        wn_meta "bin/$area/reports/$wn_parent.sh" "$wn_parent"
        return $?
    fi
    rpt="$DATA/$area/reports/$2.rpt"
    [ -f "$rpt" ] || return 0
    { read -r t; read -r i2; } <<<"$(field2 "$rpt" TITLE INTRO)"   # one awk, both directives
    [ -n "$t" ] || t=$2
    wn_short "$i2"; i=$WN_SHORT
    if is_subs_report "$2"; then printf '%s\tAnalyses\t%s\t%s\n' "$t" "$(sm_href "$area" "$2")" "$i"
    elif [ "$area" = server ]; then printf '%s\tServer\t%s\t%s\n' "$t" "$(sm_href server "$2")" "$i"
    else printf '%s\tTransfer\t%s\t%s\n' "$t" "$(sm_href transfer "$2")" "$i"
    fi
}
write_whats_new() {
    local out="$DOCS/whats-new.html"
    # The generator dirs, CURRENT and pre-2026-07 (the tool sets moved from
    # <area>/bin/ to bin/<area>/): git log's path limiting does not follow a
    # rename, so without the legacy paths every report's history would start at
    # the move commit — the catalog went empty the first time this ran after it.
    local dirs=(bin/transfer/reports bin/server/reports bin/analyses/reports \
                bin/analyses/publish-insights.sh bin/analyses/publish-accvsprod.sh \
                transfer/bin/reports server/bin/reports analyses/bin/reports \
                analyses/bin/publish-insights.sh analyses/bin/publish-accvsprod.sh)
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
    local hist
    hist=$(git log --format='@@@%x09%as%x09%s' --name-status -M -- "${dirs[@]}" 2>/dev/null | awk -F'\t' -v CMAX=100 '
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
        END { flush(); for (k in add) print "N\t" add[k] "\t0\t" pth[k] "\t" }' || true)
    local kind date seq path subj nm meta t a href desc rows_new="" rows_chg="" et ea eh ed
    while IFS=$'\t' read -r kind date seq path subj; do
        [ -n "$path" ] || continue
        nm=${path##*/}; nm=${nm%.sh}
        meta=$(wn_meta "$path" "$nm") || continue
        [ -n "$meta" ] || continue
        # a multi-page writer (publish-insights.sh renders eight insight pages)
        # emits several meta lines, so a CHANGE to it names no single report —
        # unless the commit SUBJECT does. Keep the page whose slug or title the
        # subject mentions; drop the commit when that is not exactly one page
        # (a subscriptions-in-boxes commit would otherwise stamp its message
        # onto all eight).
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
            esc "$t"; et=$ESC; esc "$a"; ea=$ESC; esc "$href"; eh=$ESC
            if [ "$kind" = N ]; then
                esc "$desc"; ed=$ESC
                rows_new+="$date\t$seq\t$eh\t<tr><td><a href=\"$eh\">$et</a></td><td>$ea</td><td class=\"desc\">$ed</td></tr>\n"
            else
                esc "$subj"; ed=$ESC
                rows_chg+="$date\t$seq\t$eh\t<tr><td><a href=\"$eh\">$et</a></td><td>$ea</td><td class=\"desc\">$ed</td></tr>\n"
            fi
        done <<< "$meta"
    done <<< "$hist"
    # New: the 25 newest adds. Changed: the 25 newest qualifying commits, ONE
    # row per report (its latest) and never a report the New table already
    # lists — "new" and "changed on the day it was added" are the same news.
    local ntop="" ctop="" keyf
    if [ -n "$rows_new" ]; then
        ntop=$(printf "%b" "$rows_new" | LC_ALL=C sort -t$'\t' -k1,1r -k2,2n | awk -F'\t' '!seen[$3]++ && n++ < 25')
    fi
    if [ -n "$rows_chg" ]; then
        keyf=$(mktemp "${TMPDIR:-/tmp}/wn.XXXXXX")
        printf '%s\n' "$ntop" | cut -f3 > "$keyf"
        ctop=$(printf "%b" "$rows_chg" | LC_ALL=C sort -t$'\t' -k1,1r -k2,2n | awk -F'\t' -v kf="$keyf" '
            BEGIN { while ((getline l < kf) > 0) if (l != "") nw[l] = 1 }
            ($3 in nw) { next }
            seen[$3]++ { next }
            n++ < 25')
        rm -f "$keyf"
    fi
    {
        html_head "What is new" "assets/style.css" "" "" ""
        printf '<h1>What is new</h1>\n'
        printf '<p class="range">The report catalog’s history, from the generators’ git log: the <strong>25 most recently added</strong> reports and the <strong>25 most recently changed</strong> ones. A change is listed only when its commit was about <strong>a few reports</strong> (up to eight — a sweep across more is about the site, not about any one of them), and a report the New table already names is not repeated below it. Newest first; the Description gives a new report’s introduction, or a changed report’s latest change.</p>\n'
        printf '<h2>New reports</h2>\n'
        printf '<div class="tablewrap"><table class="index fit">\n<tr><th>Report</th><th>Area</th><th>Description</th></tr>\n'
        if [ -n "$ntop" ]; then printf '%s\n' "$ntop" | cut -f4-
        else printf '<tr><td>(none)</td><td></td><td></td></tr>\n'; fi
        printf '</table></div>\n'
        printf '<h2>Changed reports</h2>\n'
        printf '<div class="tablewrap"><table class="index fit">\n<tr><th>Report</th><th>Area</th><th>Description</th></tr>\n'
        if [ -n "$ctop" ]; then printf '%s\n' "$ctop" | cut -f4-
        else printf '<tr><td>(none)</td><td></td><td></td></tr>\n'; fi
        printf '</table></div>\n'
        printf '</body>\n</html>\n'
    } > "$out"
}

# The SHARED root 404 page (docs/404.html) — what GitHub Pages (and any
# webserver configured for it) serves for a URL that matches nothing at all,
# instead of the stock error page. Same chrome as the shared home
# (SITE_ENV-less: acceptance-rooted menus).
# SELF-CONTAINED on purpose: Pages serves this page AT THE REQUESTED URL
# (any depth), so relative hrefs — stylesheet included — would resolve
# against the missing page's directory and 404 too. Inline style only, and
# the home link is derived at runtime (the path before the env segment;
# else the missing URL's own directory) — base-path-free, so the same page
# works at /develop/, /runtime/, a Pages project base or a server root.
write_root_404() {
    local out="docs/404.html"
    {
        printf '<!DOCTYPE html>\n<html lang="en">\n<head>\n<meta charset="utf-8">\n'
        printf '<meta name="viewport" content="width=device-width, initial-scale=1">\n'
        printf '<title>Page not found — Cloud Reports</title>\n'
        printf '<style>body{font-family:Arial,Helvetica,sans-serif;background:#f7f7f9;color:#222;text-align:center;padding:5rem 2rem}h1{color:#20344a}a{color:#1a5dab}</style>\n'
        printf '</head>\n<body>\n'
        printf '<h1>Page not found</h1>\n'
        printf '<p>There is no page at this address.</p>\n'
        printf '<p>The site moved to per-environment trees in 2026-07 (<code>acceptance/&hellip;</code> and <code>production/&hellip;</code>), so older bookmarks may need updating.</p>\n'
        printf '<p><a id="homelink" href="/"><strong>Go to the home page</strong></a></p>\n'
        printf '<script>(function(){var p=location.pathname,m=p.match(/^(.*?)(?:acceptance|production)\\//);var r=m?m[1]:p.replace(/[^/]*$/,"");document.getElementById("homelink").href=r+"index.html";})();</script>\n'
        printf '</body>\n</html>\n'
    } > "$out"
}

# The root landing page — the ONE SHARED page serving BOTH environments:
# everything centered (body class "home", style.css), one .envblock per env
# with that env's status snapshot + log-files table. CSS shows the ACTIVE
# env's block only (default acceptance); the top-bar env label toggles it
# client-side (report.js setupEnvSwitch, sessionStorage "axway-env") and
# rewrites the topbar's env-scoped links. Always written to the DOCS ROOT and
# always reads BOTH envs from disk, so the per-env build passes are idempotent
# (each rewrites the same page; an env without data simply contributes no
# block). Navigation is the top-bar dropdowns.
write_root_index() {
    local out="docs/index.html"
    {
        # the home is the shared page: SITE_ENV empty makes html_head emit
        # root-depth shared links + acceptance-rooted menus (a local shadows
        # the sourced global for this call only)
        local SITE_ENV=""
        html_head "Cloud Reports" "assets/style.css" "" "" "index" "" "" "home"
        printf '<h1>Cloud Reports</h1>\n'
        local env
        for env in acceptance production; do
            HOME_ENV_DATA="data/$env"
            [ -d "$HOME_ENV_DATA" ] || continue
            printf '<div class="envblock env-%s">\n' "$env"
            write_env_block "$env"
            printf '</div>\n'
        done
        printf '</body>\n</html>\n'
    } > "$out"
}

# The Entities coverage table (configured vs seen vs last-transaction result,
# per entity group) on its own root-level page — linked from the Analyses
# top-bar dropdown. Lives at the docs root so the coverage/… and per-area

# The home status tables' figures are CALCULATED (base caches + analyses
# rpts) while their cells link a LIST page — the Transfer > Entities view for
# the Flow manager entities table, a coverage cell page for the PDA table and
# the two toggle-OFF variants — two INDEPENDENT derivations that must agree.
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
            echo "CONSISTENCY WARNING: home shows $num for $href but the page's Total footer says $foot — an untinted (unconfigured) row leaked into the view" >&2
            mism=$((mism+1))
        fi
    done < <(perl -ne 'while (m{<a href="((?:acceptance|production)/transfer/entities/[a-z0-9-]+)\.html">([\d.]+)</a>}g) { print "$1\t$2\n" }' docs/index.html 2>/dev/null)
    if [ "$mism" -gt 0 ]; then
        echo "CONSISTENCY WARNING: $mism home status figure(s) disagree with their linked pages — investigate, do not mask." >&2
    else
        echo "Home status figures verified against their linked pages." >&2
    fi
}

# transfer_menu_order (the top-bar Transfer menu set) excludes the Analyses-menu
# members (cross-*, seen-in-server-log, entity-coverage, skipped) and Search, so
# the grouped index matches the menu — those live in the Analyses index instead.
write_area_index transfer "Transfer Reports" "${transfer_menu_order[@]}"
[ ${#server_order[@]} -gt 0 ] && write_area_index server "Server Reports" "${server_order[@]}"
write_env_404
write_report_finder
write_whats_new
write_sitemap
write_root_index
write_root_404
check_status_consistency

# Every area's report pages are rendered by now (this runs LAST per env), so tag
# each report <h1> with its "Group &larr; Section" breadcrumb. Analyses first (it
# claims its members that live in transfer/), then transfer, then server.
tag_analyses_group_h1s
tag_transfer_group_h1s
tag_server_group_h1s

# The shared help pages' chrome (acceptance pass only — the default env's menus).
[ "${SITE_ENV:-}" = acceptance ] && apply_help_chrome

echo "Wrote index pages (root + transfer${SERVER_MENU:+ + server})." >&2

publish_stamp "$STAMP"
