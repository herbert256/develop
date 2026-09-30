#!/usr/bin/env bash
#
# no-remote-files.sh — "No remote files": UC3 subscriptions that poll the
# partner perfectly well and NEVER find a thing. From the TM message
#
#   Applying the search pattern '<PAT>' for transfer site '<SITE>': 0 file(s)
#   were found of which 0 matched the pattern.
#
# Technically these flows are healthy — the connection, the credentials and the
# remote directory are all fine, the listing succeeds — there is simply never a
# file on the other side. Every scheduled slot, connection and listing is spent
# for nothing, and because an empty poll starts no transfer, none of it appears
# in the transfer logs.
#
# Scope, deliberately narrow (the report answers "which flows have NEVER had
# anything to fetch"):
#   * UC3 only        — the pull use case; a poll is its whole reason to exist
#   * NO transfer data — result orange (never transferred; a cleanly-polling
#                       UC3 stays orange since 2026-09-28 — until then
#                       result.sh's clean-poll rule flipped it green). A green
#                       or red subscription HAS moved files (or, red, cannot
#                       connect), so it is not this problem. (An Expired-last
#                       UC3 is orange too, but it found files, so the
#                       every-poll-empty rule below drops it.)
#   * every poll empty — 0 file(s) FOUND on every single one. A subscription
#                       that found files it could not match (found > 0,
#                       matched = 0) has a pattern problem, not an empty remote
#                       directory, and is left out.
#
# Neighbours: the UC status / UC3 tab (Polls by subscription) ranks the empty-poll rate of EVERY subscription
# (including the ones that do work); No remote dir is the flows whose listing
# fails outright.
#
# Reads the parse cache (data/_parse.tsv: 1=date, 2=time, 3=level, 5=message)
# and base/_subscriptions.tsv. Writes data/no-remote-files.rpt.
#
# Usage:
#   ./no-remote-files.sh   # reads input/*.csv (via the cache), writes data/no-remote-files.rpt
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# A server-DATA report (it reads the server parse cache and writes
# data/server/reports/); its rows are a table on the UC status / UC3 tab.
source "$SCRIPT_DIR/../lib.sh"
mkdir -p "$REPORTS_DIR"
OUT="$REPORTS_DIR/no-remote-files.rpt"

SUBB="$CONFIG_BASE/_subscriptions.tsv"    # name <TAB> direction <TAB> result
TSITE="$TRANSFER_REPORTS/subscription.rpt"
# The no-transfer UC3 roster: "KB<TAB>name" lines, fed in ahead of the cache —
# the ORANGE ones (2026-09-29 audit: green was still admitted, a leftover of
# the clean-poll greens of 2026-08..09-27; a green UC3 has transferred).
# UC3-named OR derived-UC3 (xref/_subscriptions-ucderived.tsv): the production
# hybrid flows carry no UC prefix (2026-08-31 audit)
UCDF="$CONFIG_XREF/_subscriptions-ucderived.tsv"; [ -f "$UCDF" ] || UCDF=/dev/null
notx_uc3() {
    [ -f "$SUBB" ] || return 0
    awk -F'\t' -v ucdf="$UCDF" '
        BEGIN { while ((getline l < ucdf) > 0) { n = split(l, a, "\t"); if (n >= 2 && a[2] == "UC3") ucd[toupper(a[1])] = 1 } close(ucdf) }
        ($1 ~ /^UC3/ || (toupper($1) in ucd)) && $3 == "orange" && $1 != "" { print "KB\t" toupper($1) }' "$SUBB"
}
# sitelink(): the logged name resolves to its detail page — exact, else the
# unique known subscription it prefixes, else the raw name (alink resolves
# through the comprehensive slugmap at render time, so a miss renders
# unlinked). A listed subscription has no transfer data, so it is usually absent
# from the roster and takes the raw path.
known_names() {   # $1 marker  $2 transfer .rpt — emits "marker<TAB>name" lines
    [ -f "$2" ] || return 0
    awk -F'\t' -v M="$1" '$1=="TABLE"{t++; if(t>1)exit} t==1&&$1=="ROW"{print M "\t" $2}' "$2"
}
LINK_AWK='
    # RENAMES (2026-08): a server line keeps the name that was current when it
    # was written, so fold it to the CURRENT one before matching the roster —
    # which carries current names, the transfer parse having folded them — and
    # DISPLAY the folded name, so the page names the flow as the configuration
    # does. rn_canon_pfx also covers the truncated old spelling the server
    # writes, folding only when every completion agrees.
    function sitecanon(t,   k, hits, full, c) {
        c = rn_canon_pfx(t)
        if (c in ksite) return c
        hits = 0
        for (k in ksite) if (index(k, c) == 1) { hits++; full = k; if (hits > 1) { hits = 0; break } }
        return hits == 1 ? full : c
    }
    function sitelink(t,   k, hits, full) {
        t = sitecanon(t)
        if (t in ksite) return "@{alink=subscriptions/" t "}"
        hits = 0
        for (k in ksite) if (index(k, t) == 1) { hits++; full = k; if (hits > 1) { hits = 0; break } }
        return hits == 1 ? "@{alink=subscriptions/" full "}" : "@{alink=subscriptions/" t "}"
    }
'

shopt -s nullglob
files=("$INPUT_DIR"/*.csv)
shopt -u nullglob
if [ ${#files[@]} -eq 0 ]; then
    echo "No files matching '*.csv' found in '$INPUT_DIR'" >&2
    rm -f "$OUT"   # no data for this ENV — page not published (an env-split legitimate state)
    exit 0
fi
echo "Found ${#files[@]} file(s) in '$INPUT_DIR', processing..." >&2

# One pass over the poll lines. A site is kept only when it is a roster UC3
# subscription AND every poll of it found ZERO files. Emits TAB-separated:
#   SUB <TAB> polls <TAB> last <TAB> subscription <TAB> days <TAB> first <TAB> buckets <TAB> loglines
#   DAY <TAB> date <TAB> polls <TAB> nsubs
#   TOT <TAB> polls <TAB> nsubs <TAB> ndays <TAB> skipped(found files)
agg=$(awk -F'\t' -v RNF="$RENAMES_FILE" "$LOGLINES_AWK$RENAMES_AWK$LINK_AWK"'
    BEGIN { rn_load(RNF) }
    $1 == "KB" { ros[$2] = 1; next }                         # no-transfer UC3 roster  (first input)
    $1 == "KS" { ksite[$2] = 1; next }                       # known-subscription list (first input)
    $5 !~ /Applying the search pattern .* for transfer site / { next }
    {
        m = $5
        if (!match(m, /for transfer site '\''[^'\'']*'\''/)) next
        site = substr(m, RSTART + 19, RLENGTH - 20); sub(/_(SS?|C)CP_.*$|_[A-Za-z0-9]+_(SERVER|CLIENT)_.*$/, "", site)
        if (site == "") next
        tail = substr(m, RSTART + RLENGTH)                    # ": N file(s) …"
        # the CANONICAL name, as remote-poll.sh keys it (2026-09-29 fix: the
        # server logs the site as <subscription>_<profile>, which only the
        # rename fold maps back — the raw spelling matched no roster name, so
        # the report stayed empty while Polling showed every-poll-empty flows)
        site = sitecanon(site)
        u = toupper(site)
        if (!(u in ros)) next                                 # no-transfer UC3 subscriptions only
        d = substr($1, 1, 10); if (d !~ /^[0-9][0-9][0-9][0-9]-/) next
        # the file count, from BOTH message shapes — "N file(s) were found of
        # which M matched the pattern." and "N file(s), matching the pattern,
        # were found and will be downloaded." (the second is 28% of the polls;
        # it carries no "of which" clause, so only the leading count is common)
        if (!match(tail, /[0-9]+ file\(s\)/)) next
        found = substr(tail, RSTART, RLENGTH - 8) + 0         # " file(s)" = 8 chars
        poll[site]++
        if (found > 0) hadfiles[site] = 1                     # not an empty remote directory
        pd[site SUBSEP d]++
        if (!((site SUBSEP d) in dseen)) { dseen[site, d] = 1; days[site]++ }
        if (!(site in fst) || d < fst[site]) fst[site] = d
        if (!(site in lst) || d > lst[site]) lst[site] = d
        addline("P" SUBSEP site, $1 " " $2, lvlname($3) " " compname($4) "  " substr(m, 1, 200))
    }
    END {
        for (s in poll) {
            if (s in hadfiles) { nskip++; continue }           # it DID see files at least once
            keep[s] = 1; tot += poll[s]
            nsub++
        }
        for (x in pd) { split(x, a, SUBSEP)
            if (!(a[1] in keep)) continue
            bk[a[1]] = bk[a[1]] (bk[a[1]] ? "," : "") a[2] ":" pd[x]
            dc[a[2]] += pd[x]
            if (!((a[2] SUBSEP a[1]) in dsn2)) { dsn2[a[2], a[1]] = 1; dsn[a[2]]++ } }
        for (s in keep)
            printf "SUB\t%d\t%s\t%s%s\t%d\t%s\t%s\t%s\n", poll[s], lst[s], sitelink(s), sitecanon(s), days[s], fst[s], bk[s], lastlines("P" SUBSEP s)
        nday = 0
        for (d in dc) { nday++; printf "DAY\t%s\t%d\t%d\n", d, dc[d], dsn[d] }
        printf "TOT\t%d\t%d\t%d\t%d\n", tot+0, nsub+0, nday+0, nskip+0
    }
' <(notx_uc3; known_names KS "$TSITE") "$(srv_subset poll)")   # the poll subset (2026-09-30): it reads the Applying the search pattern lines only

IFS=$'\t' read -r _ tot_polls n_sub n_day n_skip <<< "$(printf '%s\n' "$agg" | grep $'^TOT\t')"
if [ "${tot_polls:-0}" -eq 0 ]; then
    echo "No transfer-less UC3 subscription polls an always-empty directory." >&2
    rm -f "$OUT"   # no data for this ENV — page not published (an env-split legitimate state)
    exit 0
fi

# Both row writers print STRAIGHT to stdout inside the page block below — a
# `rows+=$(printf …)` per row forks a subshell per row for nothing.
sub_rows() {
    while IFS=$'\t' read -r _ polls last site days first bk lines; do
        [ -z "$site" ] && continue
        printf 'ROW\t%s\t%s\t%s\t%s\t%s\t@data:buckets=%s\t@data:loglines=%s\n' \
            "$last" "$site" "$polls" "$days" "$first" "$bk" "$lines"
    done <<< "$(printf '%s\n' "$agg" | grep $'^SUB\t' | sort -t"$(printf '\t')" -k3,3r -k2,2nr)"
}

day_rows() {
    while IFS=$'\t' read -r _ date polls nsubs; do
        [ -z "$date" ] && continue
        printf 'ROW\t%s\t%s\t%s\n' "$date" "$polls" "$nsubs"
    done <<< "$(printf '%s\n' "$agg" | grep $'^DAY\t' | sort -t"$(printf '\t')" -k2,2)"
}

{
    printf 'TITLE\tNo remote files\n'

    # tab=uc3 (2026-09-29): both tables ride the UC3 tab of UC status
    printf 'TABLE\tUC3 subscriptions that never find a file\twide\ttab=uc3\n'
    printf 'HEAD\tLast\tSubscription\tPolls\tDays\tFirst\n'
    printf 'KIND\ttext\tmono\tnumwarn\tnum\ttext\n'
    printf 'RECALC\t-\t-\ts0\t-\t-\n'
    sub_rows
    printf 'TOTAL\t@{colspan=2}Total (%s subscription(s))\t@{class=num warn}%s\t\t\n' "$n_sub" "$tot_polls"

    printf 'TABLE\tNever find a file — polls per day\ttab=uc3\n'   # its own heading on the shared UC3 tab (2026-09-29: two tables read "Per day"; "Polls that found no file, per day" until 2026-09-30 — it counts only the never-find-a-file flows, not every empty poll)
    printf 'HEAD\tDate\tPolls\tSubscriptions\n'
    printf 'KIND\ttext\tnumwarn\tnum\n'
    day_rows
    printf 'TOTAL\tTotal (%s day(s))\t@{class=num warn}%s\t\n' "$n_day" "$tot_polls"

    printf 'FOOT\n'
} > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"

echo "Data written to $OUT ($n_sub subscription(s), $tot_polls empty poll(s))." >&2
