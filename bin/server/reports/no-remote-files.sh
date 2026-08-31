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
#   * NO transfer data — result blue, or GREEN via result.sh's clean-poll rule
#                       (2026-08: a cleanly-polling UC3 flips blue -> green but
#                       still never moved a file). A red subscription HAS moved
#                       files, so an empty stretch is a lull, not this problem;
#                       a REAL green is dropped by the every-poll-empty rule
#                       below (some poll of it found files).
#   * every poll empty — 0 file(s) FOUND on every single one. A subscription
#                       that found files it could not match (found > 0,
#                       matched = 0) has a pattern problem, not an empty remote
#                       directory, and is left out.
#
# Neighbours: Remote Polls ranks the empty-poll rate of EVERY subscription
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
# SERVER lib, not the analyses one: this is a server-DATA report (it reads the
# server parse cache and writes data/<env>/server/reports/). It lives HERE
# because its page sits in the ANALYSES menu, in the Subscriptions group — the
# same arrangement as cross-reference.sh. bin/server/reports.sh still runs it.
source "$SCRIPT_DIR/../lib.sh"
mkdir -p "$REPORTS_DIR"
OUT="$REPORTS_DIR/no-remote-files.rpt"

SUBB="$CONFIG_BASE/_subscriptions.tsv"    # name <TAB> direction <TAB> result (blue = server-log only)
TSITE="$TRANSFER_REPORTS/subscription.rpt"
# The no-transfer UC3 roster: "KB<TAB>name" lines, fed in ahead of the cache.
# Blue OR green: a cleanly-polling UC3 subscription is flipped GREEN by
# result.sh's clean-poll rule (2026-08) but still has no transfer data — it
# belongs here all the same. The every-poll-empty rule below keeps a REAL
# green (one that transferred: some poll found files) out of the list.
# UC3-named OR derived-UC3 (xref/_subscriptions-ucderived.tsv): the production
# hybrid flows carry no UC prefix (2026-08-31 audit)
UCDF="$CONFIG_XREF/_subscriptions-ucderived.tsv"; [ -f "$UCDF" ] || UCDF=/dev/null
blue_uc3() {
    [ -f "$SUBB" ] || return 0
    awk -F'\t' -v ucdf="$UCDF" '
        BEGIN { while ((getline l < ucdf) > 0) { n = split(l, a, "\t"); if (n >= 2 && a[2] == "UC3") ucd[toupper(a[1])] = 1 } close(ucdf) }
        ($1 ~ /^UC3/ || (toupper($1) in ucd)) && ($3 == "blue" || $3 == "green") && $1 != "" { print "KB\t" toupper($1) }' "$SUBB"
}
# sitelink(): the logged name resolves to its detail page — exact, else the
# unique known subscription it prefixes, else the raw name (alink resolves
# through the comprehensive slugmap at render time, so a miss renders
# unlinked). A blue subscription has no transfer data, so it is usually absent
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
ensure_config
ensure_parsed
skip_if_fresh "$OUT" "${BASH_SOURCE[0]}" "$TSITE" "$SUBB"
echo "Found ${#files[@]} file(s) in '$INPUT_DIR', processing..." >&2

# One pass over the poll lines. A site is kept only when it is a blue UC3
# subscription AND every poll of it found ZERO files. Emits TAB-separated:
#   SUB <TAB> polls <TAB> last <TAB> subscription <TAB> days <TAB> first <TAB> buckets <TAB> loglines
#   DAY <TAB> date <TAB> polls <TAB> nsubs
#   TOT <TAB> polls <TAB> nsubs <TAB> ndays <TAB> skipped(found files)
agg=$(awk -F'\t' -v RNF="$RENAMES_FILE" "$LOGLINES_AWK$RENAMES_AWK$LINK_AWK"'
    BEGIN { rn_load(RNF) }
    $1 == "KB" { blue[$2] = 1; next }                        # blue UC3 roster         (first input)
    $1 == "KS" { ksite[$2] = 1; next }                       # known-subscription list (first input)
    $5 !~ /Applying the search pattern .* for transfer site / { next }
    {
        m = $5
        if (!match(m, /for transfer site '\''[^'\'']*'\''/)) next
        site = substr(m, RSTART + 19, RLENGTH - 20); sub(/_(SS?|C)CP_.*$/, "", site)
        if (site == "") next
        tail = substr(m, RSTART + RLENGTH)                    # ": N file(s) …"
        u = toupper(site)
        if (!(u in blue)) next                                # blue UC3 subscriptions only
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
' <(blue_uc3; known_names KS "$TSITE") "$PARSED")

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
    printf 'DESC\tUC3 subscriptions that poll the partner successfully but have NEVER found a file — every listing came back empty.\n'
    printf 'KEYWORDS\tempty poll,no files,nothing to fetch,idle schedule,blue,server-log only,uc3,pull\n'
    printf 'INTRO\tThese UC3 flows work — the connection, the credentials and the remote directory are all fine and the listing succeeds — but the directory is **always empty**. **%s** subscription(s) polled **%s** time(s) over **%s** day(s) and found **nothing, ever**. None of them has ever produced a transfer row — seen in the server log only; the result shows **green** when the latest poll is clean (the clean-poll rule: the flow verifiably works, there is simply nothing to fetch), else **blue**. Every slot spent here is a connection and a listing for no data, and none of it is visible in the transfer reports — an empty poll starts no transfer.\n' \
        "$n_sub" "$tot_polls" "$n_day"

    printf 'TABLE\tUC3 subscriptions that never find a file\twide\n'
    printf 'HEAD\tLast\tSubscription\tPolls\tDays\tFirst\n'
    printf 'KIND\ttext\tmono\tnumwarn\tnum\ttext\n'
    printf 'RECALC\t-\t-\ts0\t-\t-\n'
    sub_rows
    printf 'TOTAL\t@{colspan=2}Total (%s subscription(s))\t@{class=num warn}%s\t\t\n' "$n_sub" "$tot_polls"

    printf 'TABLE\tPer day\n'
    printf 'HEAD\tDate\tPolls\tSubscriptions\n'
    printf 'KIND\ttext\tnumwarn\tnum\n'
    day_rows
    printf 'TOTAL\tTotal (%s day(s))\t@{class=num warn}%s\t\n' "$n_day" "$tot_polls"

    printf 'NOTE\tSource: the TM message "Applying the search pattern … for transfer site …: **0 file(s) were found** of which 0 matched the pattern." Listed are the **UC3** subscriptions with no transfer data at all (result **green** via the clean-poll rule, or **blue**) whose EVERY poll found zero files; a subscription that did see files it could not match has a pattern problem, not an empty directory, and is left out%s. **Remote Polls** ranks the empty-poll rate of every subscription, working ones included, and **No remote dir** covers the flows whose listing fails outright. Poll counts are additive, so a date-filtered range re-totals them. Click a row to expand its 10 most recent poll lines.\n' \
        "$([ "${n_skip:-0}" -gt 0 ] && printf ' (%s here)' "$n_skip" || true)"
    printf 'SUMMARY\tSubscriptions: %s  |  Empty polls: %s  |  Days: %s\n' "$n_sub" "$tot_polls" "$n_day"
    printf 'FOOT\tGenerated on %s from %s file(s)\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${#files[@]}"
} > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"

echo "Data written to $OUT ($n_sub subscription(s), $tot_polls empty poll(s))." >&2
