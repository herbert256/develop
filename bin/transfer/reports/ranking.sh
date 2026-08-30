#!/usr/bin/env bash
#
# ranking.sh — "Ranking": where every entity stands against the others of its
# OWN type, on the five metrics the detail pages rank it by:
#
#   Files · Volume · Errors · Duration · Throughput
#
# One table per entity TYPE (the seven of them are the report's tab row), each
# metric contributing TWO columns — the position (#1 = the top of that metric)
# and the value behind it — with a column-group divider between the pairs, so
# five rankings read side by side without running together.
#
# The positions are NOT recomputed here. bin/transfer/details_writer.awk writes
# one line per entity into data/<env>/transfer/reports/ranking/<TYPE>.tsv while
# it renders that entity's own Ranking table, so this page and the detail pages
# are the same numbers by construction (the retired 2026-07 report recomputed
# them, and the two could drift). Sidecar columns:
#
#   name  ntype  files  frank  volume  vrank  err%  erank  avgdur  drank  thr  trank
#   buckets
#
# The 13th column is the per-day re-aggregation payload
# (date:files:errors:bytes:timed:ms:timedbytes per active day), which is what
# lets THIS page carry a From/To filter the detail pages do not have: the five
# values recompute over the range and the five positions renumber with them
# (report.js, the r tokens).
#
# The ranked population is what the detail pages rank: entities SEEN with
# totals, blue (server-log-only) ones excluded — they have no metric to stand
# on. Ranks follow details_lib.sh: Files/Volume/Errors by size DESC (#1 = most
# Files, most bytes, worst error rate — a flawless entity sorts last), average
# duration ASC (#1 = fastest) and throughput DESC (#1 = fastest).
#
# PHASE 2: it reads details.sh's sidecars, so it must run after them.
#
# Usage:
#   ./ranking.sh    # -> data/<env>/transfer/reports/ranking.rpt
#
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib.sh"
mkdir -p "$REPORTS_DIR"
OUT="$REPORTS_DIR/ranking.rpt"
RANKDIR="$REPORTS_DIR/ranking"

if [ ! -d "$RANKDIR" ]; then
    echo "ranking: no $RANKDIR (details.sh has not run) — page not published." >&2
    rm -f "$OUT"
    exit 0
fi
# $CONFIG_BASE: the rows carry the entity RESULT COLOUR from its third column,
# so a recolour must rebuild this report (cmp-guarded, so no-change runs do
# not re-trigger it) — same reason as failed.sh (2026-08).
skip_if_fresh "$OUT" "${BASH_SOURCE[0]}" "$RANKDIR" "$CONFIG_BASE"
echo "Building the Ranking report from the detail-page sidecars..." >&2

# TYPE -> table heading, entity KIND, noun, base result cache. The ORDER is the
# tab order and must match report_tabs "ranking" in bin/publish_lib.sh. The base
# cache gives each row the ENTITY's own result colour (bin/build/result.sh's
# third column), the same tint its detail page and the Entities views carry.
SPECS="SITE:Subscriptions:site:subscription:_subscriptions
ACC:Accounts:acct:account:_accounts
LOGIN:Logins:login:login:_logins
HOST:Remote hosts:host:remote host:_hosts
PTN:Partners:ptn:partner:_partners
APP:Applications:app:application:_apps
DOM:Domains:dom:domain:_domains"

nall=0
{
    printf 'TITLE\tRanking\n'
    printf 'DESC\tWhere each entity stands against the others of its own type — its position on Files, Volume, Errors, Duration and Throughput, with the value behind every position.\n'
    printf 'INTRO\tThe five rankings the detail pages carry, for every entity at once. Each metric is **two columns**: the **position** — **#1** is the most Files, the most bytes, the worst error rate, the fastest average duration and the highest throughput — and the **value** it stands on. An entity is ranked among the others of its OWN type only, and only when it has been seen with real transfers: server-log-only (blue) entities have no metric to stand on and are left out, as they are on their own pages. Pick a type with the tabs above. Positions come from the detail pages themselves, so the two can never disagree. **From/To re-ranks the page**: narrow the range and every value AND every position is recomputed over those days alone, so a partner that only matters in the last week rises to where it belongs — at the full range the numbers are the detail pages again.\n'
    printf 'KEYWORDS\tranking,rank,position,league,top,best,worst,files,volume,errors,duration,throughput,fastest,slowest\n'

    while IFS=: read -r ty head kind noun basef; do
        [ -n "$ty" ] || continue
        f="$RANKDIR/$ty.tsv"
        printf 'TABLE\t%s\twide\trestint\tgsep=1,3,5,7,9\tsort=1:1\tpager=50\n' "$head"
        # the GHEAD banner names the metric ONCE over its (position, value)
        # pair; gsep draws the divider that starts each pair
        printf 'GHEAD\t\t@{colspan=2}Files\t@{colspan=2}Volume\t@{colspan=2}Errors\t@{colspan=2}Duration\t@{colspan=2}Throughput\n'
        printf 'HEAD\t%s\t#\tFiles\t#\tVolume\t#\tError %%\t#\tAverage\t#\tPer second\n' "$head"
        printf 'KIND\t%s\tnum\tnum\tnum\tnum\tnum\tnum\tnum\tnum\tnum\tnum\n' "$kind"
        # From/To re-aggregation. Each row carries its active days as
        # date:files:errors:bytes:timed:ms:timedbytes — the last three being the
        # TIMED population Duration and Throughput average over. The five VALUE
        # columns recompute from those; the five POSITION columns (r) renumber
        # over the recomputed values, so a narrowed range never shows a filtered
        # value beside a full-period rank. The full range restores the baked
        # numbers exactly.
        printf 'RECALC\t-\tr2\ts0\tr4\th2\tr6.z\tp1.0\tr8.a\tq4.3\tr10\tt5.4\n'
        rows=""
        if [ -s "$f" ]; then
            # by Files position, name breaking ties so the order never depends
            # on the sidecar's write order
            rows=$(LC_ALL=C sort -t"$(printf '\t')" -k4,4n -k1,1f "$f" | awk -F'\t' -v BASE="$CONFIG_BASE/$basef.tsv" '
                function pos(p) { return (p == "" || p + 0 == 0) ? "-" : "#" p }
                # the entity RESULT colour: @data:res paints the whole row
                # (restint). A name the base cache does not know (logged but
                # unconfigured) simply stays untinted, as elsewhere on the site.
                BEGIN { while ((getline l9 < BASE) > 0) { n9 = split(l9, z9, "\t")
                            if (n9 >= 3 && z9[1] != "") RES[toupper(z9[1])] = z9[3] }
                        close(BASE) }
                function tint(nm,   r) { r = RES[toupper(nm)]
                    return (r == "green" || r == "orange" || r == "red" || r == "blue") ? "\t@data:res=" r : "" }
                { printf "ROW\t%s\t%s\t%s\t%s\t%s\t%s\t%s%s\t%s\t%s\t%s\t%s%s%s\n", \
                    $1, pos($4), $3, pos($6), $5, pos($8), $7, ($7 ~ /%$/ ? "" : "%"), \
                    pos($10), $9, pos($12), $11, tint($1), \
                    ($13 != "" ? "\t@data:buckets=" $13 : "") }')
        fi
        n=$(printf '%s' "$rows" | grep -c '^ROW' || true)
        if [ -n "$rows" ]; then printf '%s\n' "$rows"
        else printf 'ROW\t@{colspan=11}No ranked %ss in this environment.\n' "$noun"; fi
        printf 'TOTAL\tTotal (%s %s(s))\t\t\t\t\t\t\t\t\t\t\n' "$n" "$noun"
        nall=$((nall + n))
    done <<EOF
$SPECS
EOF

    printf 'NOTE\tPositions are per entity TYPE: a subscription is ranked among subscriptions, never against an account. **#1** means the most Files, the most bytes, the highest error percentage, the fastest average duration and the highest throughput — so a **high** position on Errors is bad news while a high position on Throughput is good. An entity with no measurable duration (nothing timed) shows **-** for Duration and Throughput. Sorted on the Files position by default; every column sorts.\n'
    printf 'NOTE\tThe same five positions appear on each entity'"'"'s own detail page, in its **Ranking** box — this page is that box for every entity at once, which is what makes the outliers visible: the flow that is #1 by volume but #40 by throughput, or the account whose error position is far worse than its file position. Every row of that box links back here: it opens this page at the entity type it belongs to, sorted on the metric that was clicked and scrolled to that entity'"'"'s own outlined row, so the position it names is read with the neighbours around it.\n'
    printf 'SUMMARY\tRanked entities: %s across 7 types\n' "$nall"
    printf 'FOOT\tGenerated on %s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
} > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"

echo "Data written to $OUT ($nall ranked entity row(s))." >&2
