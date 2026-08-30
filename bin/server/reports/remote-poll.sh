#!/usr/bin/env bash
#
# remote-poll.sh — remote-poll effectiveness per subscription, from the TM message
# "Applying the search pattern '<pat>' for transfer site '<SITE>': N file(s) were
# found of which M matched the pattern." Each such line is one scheduled poll: it
# names the subscription and says how many files it actually picked up (M). The
# striking finding is that the overwhelming majority of polls pick up NOTHING —
# chronic empty polling that burns schedule cycles and never appears in the
# transfer logs (an empty poll starts no transfer).
#
# The context-free "No files were found for download." lines are NOT used — they
# carry no site, so they can't be attributed; the "Applying the search pattern …"
# line carries both the site and the counts.
#
# The logged site keeps its "_SCP_…" suffix; we truncate at _SCP_ to the clean
# subscription name (as the transfer parser does), shown as logged (mono; a
# name that matches a known subscription from the transfer logs is linked to
# its detail page — a chronic empty poller may never appear there at all).
#
# Reads the parse cache (data/_parse.tsv). Writes data/remote-poll.rpt.
#
# Usage:
#   ./remote-poll.sh    # reads input/*.csv (via the cache), writes data/remote-poll.rpt
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib.sh"
mkdir -p "$REPORTS_DIR"
OUT="$REPORTS_DIR/remote-poll.rpt"
# poll-times.tsv — the per-subscription poll TIMING sidecar (written from the
# PT lines below): the schedule's own footprint in the server log, read by the
# analyses Cronjobs page (the former Schedule vs reality, merged 2026-08). A poll that downloads nothing leaves no
# transfer record at all, so this is the only evidence that a schedule fires.
PT_OUT="$REPORTS_DIR/poll-times.tsv"
# poll-failures.tsv — the poll FAILURE evidence sidecar (2026-08), for the
# Cronjobs page's "never completes" table: why a schedule that fires (its
# "Remote files pattern … evaluated" setup lines appear on time) never reaches
# the completed-listing line that counts as a poll. TAB rows:
#   S <TAB> site <TAB> count            poll STARTS (pattern-evaluated lines)
#   C <TAB> site <TAB> count <TAB> why  connection failures (line names the site)
#   A <TAB> host <TAB> count <TAB> why  auth-style failures — the line names
#                                       only host+user, so keyed by HOST
#   L <TAB> site <TAB> count <TAB> why  remote-listing errors
# Site names are cleaned like the polls (the _SCP_ suffix stripped; the server
# may truncate — consumers join by prefix). One row per distinct reason.
PF_OUT="$REPORTS_DIR/poll-failures.tsv"

# Entity cross-links: known subscription names from the transfer Subscription
# report (ROW field 2 of its FIRST table). A subscription name that matches a
# known one — exactly, or as the unique prefix of one (the server truncates
# long names; same rule as site-failures.sh) — gets an @{link=…} prefix on its
# cell (rendered by bin/publish_lib.sh render_cell as a link to its detail
# page). Linking is skipped when the transfer report is absent.
TDATA="$TRANSFER_REPORTS"
TSITE="$TDATA/subscription.rpt"
known_names() {   # $1 marker  $2 transfer .rpt — emits "marker<TAB>name" lines
    [ -f "$2" ] || return 0
    awk -F'\t' -v M="$1" '$1=="TABLE"{t++; if(t>1)exit} t==1&&$1=="ROW"{print M "\t" $2}' "$2"
}
# LINK_AWK — slug() matches bin/publish_lib.sh's slugify (the same function as
# entity-search.sh's SLUG_AWK); sitelink() returns the @{link=…} cell prefix
# for a resolved subscription name, or "" when it stays unresolved.
LINK_AWK='
    function slug(x){ x=tolower(x); gsub(/[^a-z0-9]+/,"-",x); sub(/^-+/,"",x); sub(/-+$/,"",x); return x }
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
        # unknown/ambiguous: still try the RAW name — alink resolves through
        # the comprehensive slugmap at render time (a miss renders unlinked),
        # so config-named polls link their page without a roster hit
        return hits == 1 ? "@{alink=subscriptions/" full "}" : "@{alink=subscriptions/" t "}"
    }
'

shopt -s nullglob
files=("$INPUT_DIR"/*.csv)
shopt -u nullglob
if [ ${#files[@]} -eq 0 ]; then
    echo "No files matching '*.csv' found in '$INPUT_DIR'" >&2
    rm -f "$PT_OUT" "$PF_OUT"
    rm -f "$OUT"   # no data for this ENV — page not published (an env-split legitimate state)
    exit 0
fi
ensure_parsed
[ -f "$PT_OUT" ] && [ -f "$PF_OUT" ] || rm -f "$OUT"   # a missing sidecar must force a rebuild (skip_if_fresh checks $OUT only)
skip_if_fresh "$OUT" "${BASH_SOURCE[0]}" "$TSITE"
echo "Found ${#files[@]} file(s) in '$INPUT_DIR', processing..." >&2

# One pass over the "Applying the search pattern … for transfer site '…'" polls.
# The Empty % is computed HERE (pctof) — polls and empties are already in the
# arrays, so the row loop below needs no awk fork per subscription.
# Emits TAB-separated:
#   SUB <TAB> subscription <TAB> polls <TAB> empty <TAB> matched <TAB> empty% <TAB> buckets(date:polls:empty:matched) <TAB> first <TAB> last <TAB> loglines
#   PT  <TAB> the poll-times.tsv sidecar row (see below)
#   LST <TAB> subscription <TAB> listing errors <TAB> buckets(date:count) <TAB> first <TAB> last <TAB> loglines
#   TOT <TAB> polls <TAB> empty <TAB> nonempty <TAB> matched <TAB> nsubs
agg=$(awk -F'\t' -v RNF="$RENAMES_FILE" "$LOGLINES_AWK$RENAMES_AWK$LINK_AWK"'
    BEGIN { rn_load(RNF) }
    function pctof(e, p) { return sprintf("%.1f", p ? e * 100 / p : 0) }
    $1 == "KS" { ksite[$2] = 1; next }                       # known-subscription list (first input)
    {
        m = $5
        d = substr($1, 1, 10); if (d !~ /^[0-9][0-9][0-9][0-9]-/) d = ""
        if (m ~ /Applying the search pattern .* for transfer site /) {
            if (!match(m, /for transfer site '\''[^'\'']*'\''/)) next
            site = substr(m, RSTART + 19, RLENGTH - 20)              # strip "for transfer site '" and trailing "'"
            sub(/_(SS?|C)CP_.*$/, "", site)                           # -> clean subscription name (drop _SCP_ / _SSCP_ / _CCP_)
            if (site == "") next
            matched = 0
            if (match(m, /of which [0-9]+ matched/)) matched = substr(m, RSTART + 9, RLENGTH - 17) + 0
            poll[site]++; tpoll++
            if (matched > 0) { ne[site]++; tne++; fz[site] += matched; tmatch += matched } else { em[site]++; te++ }
            if (d != "") {
                pd[site SUBSEP d]++
                if (matched == 0) ed[site SUBSEP d]++
                fd[site SUBSEP d] += matched
                dk = site SUBSEP d
                # the day FIRST poll minute — punctuality.sh models an arrival
                # exactly this way, so the two observed slots are comparable
                mn = substr($2, 1, 2) * 60 + substr($2, 4, 2)
                if (!(dk in fpm) || mn < fpm[dk]) fpm[dk] = mn
                if (!(dk in dseen)) { dseen[dk]=1; dlist[site] = dlist[site] (dlist[site]?",":"") d }
                if (!(site in fst) || d < fst[site]) fst[site] = d
                if (!(site in lst) || d > lst[site]) lst[site] = d
            }
            addline("P" SUBSEP site, $1 " " $2, lvlname($3) " " compname($4) "  " substr(m, 1, 200))
        } else if (m ~ /listing files from partner /) {
            # the site may CONTAIN spaces ("Clone - UC3_..."): capture up to
            # " defined in account ", falling back to the first space
            rest2 = substr(m, index(m, "listing files from partner ") + 27)
            p2 = index(rest2, " defined in account "); if (p2 <= 1) p2 = index(rest2, " ")
            if (p2 <= 1) next
            lsite = substr(rest2, 1, p2 - 1); sub(/_(SS?|C)CP_.*$/, "", lsite)   # clean subscription name
            if (lsite == "") next
            # the reason for the failure sidecar: the tail after "account X. "
            r3 = substr(rest2, p2 + 20); p3 = index(r3, ". ")
            if (p3 > 0) lr[lsite SUBSEP substr(r3, p3 + 2, 120)]++
            lc[lsite]++; tlist++
            if (d != "") {
                ld[lsite SUBSEP d]++
                lk = lsite SUBSEP d
                if (!(lk in ldseen)) { ldseen[lk]=1; ldlist[lsite] = ldlist[lsite] (ldlist[lsite]?",":"") d }
                if (!(lsite in lfst) || d < lfst[lsite]) lfst[lsite] = d
                if (!(lsite in llst) || d > llst[lsite]) llst[lsite] = d
            }
            addline("L" SUBSEP lsite, $1 " " $2, lvlname($3) " " compname($4) "  " substr(m, 1, 200))
        } else if (m ~ /^Remote files pattern of transfer site/) {
            # the poll STARTED (setup line) — with the completed-listing count
            # above, the gap says a schedule fires but never finishes a poll
            if (!match(m, /'\''[^'\'']*'\''/)) next
            ssite = substr(m, RSTART + 1, RLENGTH - 2)
            sub(/_(SS?|C)CP_.*$/, "", ssite)
            if (ssite != "") pfs[ssite]++
        } else if (m ~ /Connection failure while .* tried to connect to remote host /) {
            csite = substr(m, index(m, "Connection failure while ") + 25)
            p2 = index(csite, " tried to connect to remote host "); if (p2 <= 1) next
            why = substr(csite, p2 + 33, 120)
            csite = substr(csite, 1, p2 - 1); sub(/_(SS?|C)CP_.*$/, "", csite)
            if (csite != "") pfc[csite SUBSEP why]++
        } else if (m ~ /failure connecting to remote host /) {
            # auth-style failures name only host+user — keyed by HOST (the
            # consumer joins via the subscription'\''s configured host)
            why = substr(m, index(m, "connecting to remote host ") + 26, 120)
            fhost = why; sub(/[: ].*$/, "", fhost)
            if (fhost != "") pfa[tolower(fhost) SUBSEP why]++
        }
    }
    END {
        nsubs = 0
        for (s in poll) {
            nsubs++
            no = split(dlist[s], dz, ","); bk = ""
            for (i=1;i<=no;i++) { dd=dz[i]; k=s SUBSEP dd; bk = bk (bk?",":"") dd ":" pd[k] ":" (ed[k]+0) ":" (fd[k]+0) }
            printf "SUB\t%s%s\t%d\t%d\t%d\t%s\t%s\t%s\t%s\t%s\n", sitelink(s), sitecanon(s), poll[s], em[s]+0, fz[s]+0, pctof(em[s]+0, poll[s]), bk, fst[s], lst[s], lastlines("P" SUBSEP s)
            # PT — the timing sidecar row: median of the per-day FIRST poll
            # minute (the typical slot), its standard deviation (the window)
            # and the same class thresholds punctuality.sh uses, plus the
            # polls-per-day so
            # a continuous poller is not shown as a one-a-day slot.
            n = 0
            for (i = 1; i <= no; i++) { n++; PM[n] = fpm[s SUBSEP dz[i]] + 0 }
            for (i = 2; i <= n; i++) { v = PM[i]; j2 = i - 1; while (j2 >= 1 && PM[j2] > v) { PM[j2+1] = PM[j2]; j2-- } PM[j2+1] = v }
            med = (n % 2) ? PM[(n + 1) / 2] : int((PM[n / 2] + PM[n / 2 + 1]) / 2)
            sum = 0; ss = 0
            for (i = 1; i <= n; i++) { sum += PM[i]; ss += PM[i] * PM[i] }
            mean = sum / n; var2 = ss / n - mean * mean; if (var2 < 0) var2 = 0
            spread = int(sqrt(var2) + 0.5)
            if      (spread <= 15)  cls = "Clockwork"
            else if (spread <= 60)  cls = "Regular"
            else if (spread <= 180) cls = "Loose"
            else                    cls = "Irregular"
            printf "PT\t%s\t%d\t%d\t%02d:%02d\t%d\t%s\t%d\t%s\t%s\n", \
                s, poll[s], n, int(med/60), med%60, spread, cls, int(poll[s]/n + 0.5), fst[s], lst[s]
        }
        nlist = 0
        for (s in lc) { nlist++
            no = split(ldlist[s], dz, ","); bk = ""
            for (i=1;i<=no;i++) { dd=dz[i]; bk = bk (bk?",":"") dd ":" ld[s SUBSEP dd] }
            printf "LST\t%s%s\t%d\t%s\t%s\t%s\t%s\n", sitelink(s), sitecanon(s), lc[s], bk, lfst[s], llst[s], lastlines("L" SUBSEP s)
        }
        # the poll-failure sidecar lines (hash order — the shell sorts the file)
        for (k in pfs) printf "PF\tS\t%s\t%d\n", k, pfs[k]
        for (k in pfc) { split(k, K2, SUBSEP); printf "PF\tC\t%s\t%d\t%s\n", K2[1], pfc[k], K2[2] }
        for (k in pfa) { split(k, K2, SUBSEP); printf "PF\tA\t%s\t%d\t%s\n", K2[1], pfa[k], K2[2] }
        for (k in lr)  { split(k, K2, SUBSEP); printf "PF\tL\t%s\t%d\t%s\n", K2[1], lr[k], K2[2] }
        printf "TOT\t%d\t%d\t%d\t%d\t%d\t%d\t%d\n", tpoll+0, te+0, tne+0, tmatch+0, nsubs+0, tlist+0, nlist+0
    }
' <(known_names KS "$TSITE") "$PARSED")

IFS=$'\t' read -r _ t_polls t_empty t_nonempty t_matched n_subs t_list n_listsubs <<< "$(printf '%s\n' "$agg" | grep $'^TOT\t')"
# the failure sidecar is written even for a zero-poll env — failing schedules
# are exactly the case where no poll ever completes
printf '%s\n' "$agg" | { grep $'^PF\t' || true; } | cut -f2- | LC_ALL=C sort > "$PF_OUT"
if [ "${t_polls:-0}" -eq 0 ]; then
    echo "No remote-poll ('Applying the search pattern') messages found." >&2
    rm -f "$PT_OUT"
    rm -f "$OUT"   # no data for this ENV — page not published (an env-split legitimate state)
    exit 0
fi
empty_pct=$(awk -v e="$t_empty" -v p="$t_polls" 'BEGIN{printf "%.1f", p? e*100/p : 0}')

# the timing sidecar: subscription, polls, days, typical, spread(min), class,
# polls/day, first, last — one row per polled subscription, name-sorted
printf '%s\n' "$agg" | grep $'^PT\t' | cut -f2- | LC_ALL=C sort > "$PT_OUT" || : > "$PT_OUT"

# Both loops only assemble what the awk already rendered — no fork per row (a
# `$(printf …)` per row is a subshell, and the poll table is one row per
# subscription).
list_rows=""
while IFS=$'\t' read -r _ sub count bk fst lst lines; do
    [ -z "$sub" ] && continue
    list_rows+="ROW"$'\t'"$sub"$'\t'"$count"$'\t'"$fst"$'\t'"$lst"$'\t'"@data:buckets=$bk"$'\t'"@data:loglines=$lines"$'\n'
done <<< "$(printf '%s\n' "$agg" | grep $'^LST\t' | sort -t$'\t' -k3,3nr)"

sub_rows=""
while IFS=$'\t' read -r _ sub polls empty matched pct bk fst lst lines; do
    [ -z "$sub" ] && continue
    sub_rows+="ROW"$'\t'"$sub"$'\t'"$polls"$'\t'"$empty"$'\t'"$matched"$'\t'"${pct}%"$'\t'"$fst"$'\t'"$lst"$'\t'"@data:buckets=$bk"$'\t'"@data:loglines=$lines"$'\n'
done <<< "$(printf '%s\n' "$agg" | grep $'^SUB\t' | sort -t$'\t' -k4,4nr -k3,3nr)"

{
    printf 'TITLE\tRemote Polls\n'
    printf 'DESC\tScheduled remote-poll effectiveness per subscription — how many polls pick up files versus how many find nothing (chronic empty polling that never reaches the transfer logs).\n'
    printf 'INTRO\t**%s** scheduled polls across **%s** subscription(s): **%s** (**%s%%**) picked up **nothing**, only **%s** returned files (**%s** files matched in total). Chronic empty polling burns schedule cycles without ever starting a transfer — none of it shows in the transfer logs. A separate table lists **%s** remote-directory **listing failure(s)** (the poll could not list the folder at all — a wrong-path problem). Sorted worst-first. Click a subscription for its 10 most recent lines.\n' \
        "$t_polls" "$n_subs" "$t_empty" "$empty_pct" "$t_nonempty" "$t_matched" "$t_list"

    printf 'TABLE\tPolls by subscription\twide\n'
    printf 'HEAD\tSubscription\tPolls\tEmpty polls\tFiles matched\tEmpty %%\tFirst\tLast\n'
    printf 'KIND\tmono\tnum\tnumwarn\tnumprocessed\tnum\ttext\ttext\n'
    printf 'RECALC\t-\ts0\ts1\ts2\tp1.0\t-\t-\n'
    printf '%s' "$sub_rows"
    printf 'TOTAL\tTotal (%s subscription(s))\t@{class=num}%s\t@{class=num warn}%s\t@{class=num processed}%s\t@{class=num}%s%%\t\t\n' \
        "$n_subs" "$t_polls" "$t_empty" "$t_matched" "$empty_pct"

    printf 'NOTE\tSource: TM "Applying the search pattern … for transfer site '\''SITE'\'': N file(s) were found of which M matched the pattern." A poll is **empty** when M = 0. Subscription names are truncated at _SCP_ to the clean name and shown as logged; a name matching a known subscription from the transfer logs links to its detail page (a chronic empty poller may never appear there). Polls/empty/matched are additive and re-total under the date filter.\n'

    if [ "${t_list:-0}" -gt 0 ]; then
        printf 'TABLE\tRemote directory listing failures\twide\n'
        printf 'HEAD\tSubscription\tListing errors\tFirst\tLast\n'
        printf 'KIND\tmono\tnumfailed\ttext\ttext\n'
        printf 'RECALC\t-\ts0\t-\t-\n'
        printf '%s' "$list_rows"
        printf 'TOTAL\tTotal (%s subscription(s))\t@{class=num failed}%s\t\t\n' "$n_listsubs" "$t_list"
        printf 'NOTE\tSource: TM "Error occurred while listing files from partner SITE." The poll could not even list the remote folder — usually a wrong remote path or permissions, distinct from an empty poll (right folder, no files). Almost all are concentrated on a few subscriptions. Additive; re-totals under the date filter. Click a subscription for its 10 most recent listing errors.\n'
    fi

    printf 'SUMMARY\tPolls: %s  |  Empty: %s (%s%%)  |  With files: %s  |  Listing failures: %s  |  Subscriptions: %s\n' \
        "$t_polls" "$t_empty" "$empty_pct" "$t_nonempty" "$t_list" "$n_subs"
    printf 'FOOT\tGenerated on %s from %s file(s)\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${#files[@]}"
} > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"

echo "Data written to $OUT ($t_polls poll(s), $t_empty empty, $n_subs subscription(s))." >&2
