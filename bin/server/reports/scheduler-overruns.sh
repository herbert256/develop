#!/usr/bin/env bash
#
# scheduler-overruns.sh — subscription tasks that run longer than their schedule
# interval, from the TM warning "The task \"…\" of account with name: \"ACCOUNT\"
# with subscription folder: \"/…/FOLDER\" is still in progress. Skipping the next
# scheduled occurrence of this task." Each such line is one polling occurrence
# dropped because the previous run had not finished — a backlog/latency signal
# that never appears in the transfer logs (no transfer happens on a skip).
#
# Reads the parse cache (data/_parse.tsv: 1=date, 2=time, 3=level, 5=message).
# Two views: per account (rollup) and per subscription (account + folder leaf).
# Account/subscription names are shown as logged (mono); a name that resolves
# against the transfer-side known lists (account: exact or @endpoint-stripped;
# subscription: exact or unique prefix of one known subscription) is linked to
# its detail page — the rest stay plain text.
#
# Usage:
#   ./scheduler-overruns.sh    # reads input/*.csv (via the cache), writes data/scheduler-overruns.rpt
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib.sh"
mkdir -p "$REPORTS_DIR"
OUT="$REPORTS_DIR/scheduler-overruns.rpt"

# Entity cross-links: known account/subscription names from the transfer-side
# reports (ROW field 2 of each report's FIRST table). A resolved name gets an
# @{link=…} prefix on its cell (rendered by bin/publish_lib.sh render_cell as
# a link to its detail page); unresolved names stay plain text. Linking is
# skipped for a list whose transfer report is absent.
TDATA="$TRANSFER_REPORTS"
TACCT="$TDATA/account.rpt"
TSITE="$TDATA/subscription.rpt"
known_names() {   # $1 marker  $2 transfer .rpt — emits "marker<TAB>name" lines
    [ -f "$2" ] || return 0
    awk -F'\t' -v M="$1" '$1=="TABLE"{t++; if(t>1)exit} t==1&&$1=="ROW"{print M "\t" $2}' "$2"
}
# LINK_AWK — slug() matches bin/publish_lib.sh's slugify (the same function as
# entity-search.sh's SLUG_AWK). sitelink(): exact match or unique prefix of one
# known subscription (the server truncates long names; same rule as
# site-failures.sh); acctlink(): exact match, also @endpoint-stripped.
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
        for (k in ksite) if (index(k, t) == 1) { hits++; full = k; if (hits > 1) return "" }
        return hits == 1 ? "@{alink=subscriptions/" full "}" : ""
    }
    function acctlink(t,   s) {
        if (t in kacct) return "@{alink=accounts/" t "}"
        s = t; sub(/@.*$/, "", s)
        if (s in kacct) return "@{alink=accounts/" s "}"
        return ""
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
ensure_parsed
skip_if_fresh "$OUT" "${BASH_SOURCE[0]}" "$TACCT" "$TSITE"
echo "Found ${#files[@]} file(s) in '$INPUT_DIR', processing..." >&2

# One pass over the "still in progress. Skipping" warnings: extract the account
# and the subscription folder leaf, count per account and per (account, folder),
# with per-day buckets, first/last, and the drill lines. Emits TAB-separated:
#   ACC <TAB> count <TAB> account <TAB> nsubs <TAB> buckets <TAB> first <TAB> last <TAB> loglines
#   SUB <TAB> count <TAB> account <TAB> subscription <TAB> buckets <TAB> first <TAB> last <TAB> loglines
#   TOT <TAB> total <TAB> naccounts <TAB> nsubs
agg=$(awk -F'\t' -v RNF="$RENAMES_FILE" "$LOGLINES_AWK$RENAMES_AWK$LINK_AWK"'
    BEGIN { rn_load(RNF) }
    $1 == "KA" { kacct[$2] = 1; next }                       # known-account list       (first input)
    $1 == "KS" { ksite[$2] = 1; next }                       # known-subscription list  (first input)
    $5 !~ /is still in progress\. Skipping/ { next }
    {
        d = substr($1, 1, 10); if (d !~ /^[0-9][0-9][0-9][0-9]-/) d = ""
        m = $5
        if (!match(m, /account with name: "[^"]*"/)) next
        acct = substr(m, RSTART + 20, RLENGTH - 21)
        if (acct == "") next
        sub_ = ""
        if (match(m, /subscription folder: "[^"]*"/)) {
            fp = substr(m, RSTART + 22, RLENGTH - 23)
            n = split(fp, parts, "/"); sub_ = parts[n]
            if (sub_ == "") sub_ = fp
        }
        if (sub_ == "") sub_ = "(none)"
        sk = acct SUBSEP sub_
        ac[acct]++; sc[sk]++; tot++
        if (!(sk in subseen)) { subseen[sk] = 1; nsub[acct]++ }
        addline("A" SUBSEP acct, $1 " " $2, lvlname($3) " " compname($4) "  " substr(m, 1, 200))
        addline("S" SUBSEP sk,   $1 " " $2, lvlname($3) " " compname($4) "  " substr(m, 1, 200))
        if (d != "") {
            acd[acct SUBSEP d]++
            if (!(acct in afst) || d < afst[acct]) afst[acct] = d
            if (!(acct in alst) || d > alst[acct]) alst[acct] = d
            scd[sk SUBSEP d]++
            if (!(sk in sfst) || d < sfst[sk]) sfst[sk] = d
            if (!(sk in slst) || d > slst[sk]) slst[sk] = d
        }
    }
    END {
        for (x in acd) { split(x, a, SUBSEP); abk[a[1]] = abk[a[1]] (abk[a[1]] ? "," : "") a[2] ":" acd[x] }
        for (x in scd) { split(x, a, SUBSEP); kk = a[1] SUBSEP a[2]; sbk[kk] = sbk[kk] (sbk[kk] ? "," : "") a[3] ":" scd[x] }
        nacc = 0; nsubtot = 0
        for (nm in ac)  { nacc++;    printf "ACC\t%d\t%s%s\t%d\t%s\t%s\t%s\t%s\n", ac[nm], acctlink(nm), nm, nsub[nm]+0, abk[nm], afst[nm], alst[nm], lastlines("A" SUBSEP nm) }
        for (k in sc)  { nsubtot++; split(k, a, SUBSEP)
            printf "SUB\t%d\t%s%s\t%s%s\t%s\t%s\t%s\t%s\n", sc[k], acctlink(a[1]), a[1], sitelink(a[2]), sitecanon(a[2]), sbk[k], sfst[k], slst[k], lastlines("S" SUBSEP k) }
        printf "TOT\t%d\t%d\t%d\n", tot+0, nacc+0, nsubtot+0
    }
' <(known_names KA "$TACCT"; known_names KS "$TSITE") "$PARSED")

IFS=$'\t' read -r _ tot_skips n_acc n_sub <<< "$(printf '%s\n' "$agg" | grep $'^TOT\t')"
if [ "${tot_skips:-0}" -eq 0 ]; then
    echo "No scheduler-overrun ('still in progress. Skipping') warnings found." >&2
    rm -f "$OUT"   # no data for this ENV — page not published (an env-split legitimate state)
    exit 0
fi

# Both row writers print STRAIGHT to stdout inside the page block below — a
# `rows+=$(printf …)` per row forks a subshell per row for nothing.
acc_rows() {
    while IFS=$'\t' read -r _ count acct nsubs bk fst lst lines; do
        [ -z "$acct" ] && continue
        printf 'ROW\t%s\t%s\t%s\t%s\t%s\t@data:buckets=%s\t@data:loglines=%s\n' "$acct" "$count" "$nsubs" "$fst" "$lst" "$bk" "$lines"
    done <<< "$(printf '%s\n' "$agg" | grep $'^ACC\t' | sort -t"$(printf '\t')" -k2,2nr)"
}

sub_rows() {
    while IFS=$'\t' read -r _ count acct sub_ bk fst lst lines; do
        [ -z "$sub_" ] && continue
        printf 'ROW\t%s\t%s\t%s\t%s\t%s\t@data:buckets=%s\t@data:loglines=%s\n' "$acct" "$sub_" "$count" "$fst" "$lst" "$bk" "$lines"
    done <<< "$(printf '%s\n' "$agg" | grep $'^SUB\t' | sort -t"$(printf '\t')" -k2,2nr)"
}

{
    printf 'TITLE\tScheduler Overruns\n'
    printf 'DESC\tScheduled subscription tasks skipped because the previous run was still in progress — a backlog/latency signal.\n'
    printf 'INTRO\t**%s** scheduled occurrence(s) were **skipped** because the previous run of the same task had not finished, across **%s** account(s) and **%s** subscription(s). Each skip means the poll interval is shorter than the run time — a chronic overrun builds latency and, if the source keeps producing, backlog. None of this shows in the transfer logs (a skipped poll starts no transfer).\n' \
        "$tot_skips" "$n_acc" "$n_sub"

    printf 'TABLE\tBy account\n'
    printf 'HEAD\tAccount\tSkipped runs\tSubscriptions\tFirst\tLast\n'
    printf 'KIND\tmono\tnumwarn\tnum\ttext\ttext\n'
    printf 'RECALC\t-\ts0\t-\t-\t-\n'
    acc_rows
    printf 'TOTAL\tTotal (%s account(s))\t@{class=num warn}%s\t@{class=num}%s\t\t\n' "$n_acc" "$tot_skips" "$n_sub"

    printf 'TABLE\tBy subscription\twide\n'
    printf 'HEAD\tAccount\tSubscription\tSkipped runs\tFirst\tLast\n'
    printf 'KIND\tmono\tmono\tnumwarn\ttext\ttext\n'
    printf 'RECALC\t-\t-\ts0\t-\t-\n'
    sub_rows
    printf 'TOTAL\t@{colspan=2}Total (%s subscription(s))\t@{class=num warn}%s\t\t\n' "$n_sub" "$tot_skips"

    printf 'NOTE\tSource: TM warnings "The task … is still in progress. Skipping the next scheduled occurrence of this task." The subscription is the last segment of the logged subscription folder. Names are shown as logged; a name matching a known account or subscription from the transfer logs links to its detail page. Skipped-run counts are additive, so a date-filtered range re-totals them. Click a row to expand its 10 most recent skip lines.\n'
    printf 'SUMMARY\tSkipped runs: %s  |  Accounts: %s  |  Subscriptions: %s\n' "$tot_skips" "$n_acc" "$n_sub"
    printf 'FOOT\tGenerated on %s from %s file(s)\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${#files[@]}"
} > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"

echo "Data written to $OUT ($tot_skips skip(s), $n_acc account(s), $n_sub subscription(s))." >&2
