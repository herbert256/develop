#!/usr/bin/env bash
#
# could-not-send.sh — "Could not send file" (2026-09-12, user request): the
# Advanced Routing AR0074 lines, one row per line, newest first. From the TM
# message
#
#   AR0074: [SECURETRANSPORT] [UC1_CD_IDM_ROTAFORM]  Could not send file:
#   {/.stfs/objects/…/krpdashboard-productie-20260910135425809.xml} using
#   transfer site: {UC1_CD_IDM_ROTAFORM_SFTP_SERVER_ROTAFORM} after
#   attempting {11} times.
#
# The ROUTE — the subscription — is the SECOND bracket group (the same
# reading as uc1-status.sh and flip-reason.awk, where this line is the
# "Duplicate file" reason); the File is the basename of the first
# {…} after "Could not send file:". The row is
#
#   Date & time (to the second) · Subscription · File
#
# CAPPED (user rule): at most 1000 rows on the report, at most 10 rows per
# subscription — the newest ones on both counts. The INTRO and the TOTAL
# say how many lines the log really holds.
#
# Reads the parse cache (data/server/cache/_parse.tsv: 1=date, 2=time,
# 3=level, 4=component, 5=message, 6=session) and the transfer roster
# (subscription.rpt) for the detail-page links. Writes
# data/server/reports/could-not-send.rpt — the srv-errors group's fourth
# member (bin/publish_lib.sh).
#
# Usage:
#   ./could-not-send.sh   # reads input/*.csv (via the cache), writes data/could-not-send.rpt
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib.sh"
mkdir -p "$REPORTS_DIR"
OUT="$REPORTS_DIR/could-not-send.rpt"

TSITE="$TRANSFER_REPORTS/subscription.rpt"
MAXROWS=1000
MAXPERSUB=10

# The known-subscription roster ("KS<TAB>name", fed in ahead of the cache):
# a logged route name resolves to its detail page — exact, else the unique
# known subscription it prefixes, else the raw name (alink resolves through
# the comprehensive slugmap at render time, so a miss renders unlinked).
known_names() {   # $1 marker  $2 transfer .rpt — emits "marker<TAB>name" lines
    [ -f "$2" ] || return 0
    awk -F'\t' -v M="$1" '$1=="TABLE"{t++; if(t>1)exit} t==1&&$1=="ROW"{print M "\t" $2}' "$2"
}
LINK_AWK='
    # RENAMES: a server line keeps the name that was current when it was
    # written, so fold it to the CURRENT one before matching the roster (which
    # carries current names) and DISPLAY the folded name (no-remote-files.sh
    # has the same pair).
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
ensure_parsed
skip_if_fresh "$OUT" "${BASH_SOURCE[0]}" "$TSITE"
echo "Found ${#files[@]} file(s) in '$INPUT_DIR', processing..." >&2

# One pass over the AR0074 lines. Every matched line comes out as a finished
# ROW behind a sort prefix (the shell only sorts, caps and cuts — a bash read
# over TAB fields would collapse empty ones):
#   LIN <TAB> sortkey <TAB> subscription <TAB> ROW …
#   TOT <TAB> lines <TAB> subscriptions <TAB> days
agg=$(awk -F'\t' -v RNF="$RENAMES_FILE" "$RENAMES_AWK$LINK_AWK"'
    BEGIN { rn_load(RNF) }
    $1 == "KS" { ksite[$2] = 1; next }                       # known-subscription list (first input)
    $5 !~ /Could not send file/ { next }
    {
        m = $5
        if (m !~ /^AR[A-Z]*[0-9]*: \[/) next                  # an Advanced Routing line
        p = index(m, "] ["); if (p == 0) next
        rest = substr(m, p + 3); q = index(rest, "]"); if (q == 0) next
        route = substr(rest, 1, q - 1)                         # the ROUTE = the subscription (second bracket)
        sub(/_(SS?|C)CP_.*$|_[A-Za-z0-9]+_(SERVER|CLIENT)_.*$/, "", route)
        if (route == "") next
        body = substr(rest, q + 1)
        b = index(body, "Could not send file:"); if (b == 0) next
        body = substr(body, b + 20)
        if (!match(body, /\{[^}]*\}/)) next                    # the first {…} = the file path
        path = substr(body, RSTART + 1, RLENGTH - 2)
        n = split(path, P, "/"); fn = P[n]; if (fn == "") fn = path
        d = substr($1, 1, 10); if (d !~ /^[0-9][0-9][0-9][0-9]-/) next
        s = sitecanon(route)
        nl++; if (!(s in seen)) { seen[s] = 1; ns++ }
        if (!(d in dseen)) { dseen[d] = 1; nd++ }
        printf "LIN\t%s %s\t%s\tROW\t%s %s\t%s%s\t%s\n", d, $2, s, d, substr($2, 1, 8), sitelink(route), s, fn
    }
    END { printf "TOT\t%d\t%d\t%d\n", nl+0, ns+0, nd+0 }
' <(known_names KS "$TSITE") "$PARSED")

IFS=$'\t' read -r _ n_lines n_subs n_days <<< "$(printf '%s\n' "$agg" | grep $'^TOT\t' || printf 'TOT\t0\t0\t0\n')"
n_lines=${n_lines:-0}; n_subs=${n_subs:-0}; n_days=${n_days:-0}

# newest first (the sortkey = date + full time), then the two caps in that
# order: the first MAXPERSUB rows met per subscription are its newest, the
# first MAXROWS overall the newest of all
TAB=$(printf '\t')
lin_rows() {
    printf '%s\n' "$agg" | grep $'^LIN\t' | sort -t"$TAB" -k2,2r \
        | awk -F'\t' -v PS="$MAXPERSUB" -v MX="$MAXROWS" '{ if (++n[$3] > PS) next; if (++t > MX) exit; print }' | cut -f4-
}
n_shown=0
if [ "$n_lines" -gt 0 ]; then n_shown=$(lin_rows | grep -c $'^ROW\t' || true); fi

{
    printf 'TITLE\tCould not send file\n'
    printf 'DESC\tThe Advanced Routing "Could not send file" errors (AR0074): the route gave up delivering a file to its transfer site — per line, newest first, with the subscription and the file.\n'
    printf 'KEYWORDS\tcould not send file,AR0074,send failed,transfer site,after attempting,advanced routing,delivery,cft,push,uc1,route\n'
    if [ "$n_lines" -eq 0 ]; then
        printf 'INTRO\tNo **Could not send file** line in this data window — no Advanced Routing route gave up delivering a file to its transfer site.\n'
    else
        printf 'INTRO\t**%s** "Could not send file" line(s) for **%s** subscription(s) on **%s** day(s) — an Advanced Routing route that gave up delivering a file to its transfer site after its retries (the AR0074 error, the "Duplicate file" reason of the failure pages). Newest first; the report shows at most **%s** rows and at most **%s** per subscription (**%s** shown here); the subscription opens its detail page.\n' \
            "$n_lines" "$n_subs" "$n_days" "$MAXROWS" "$MAXPERSUB" "$n_shown"
    fi

    printf 'TABLE\tCould not send file\twide\tpager=100\n'
    printf 'HEAD\tDate & time\tSubscription\tFile\n'
    printf 'KIND\ttext\tmono\tfile\n'
    if [ "$n_lines" -gt 0 ]; then lin_rows
    else printf 'ROW\t@{colspan=3}No "Could not send file" line in this data window.\n'; fi
    printf 'TOTAL\t@{colspan=3}%s row(s) shown — %s line(s) in the log, %s subscription(s), %s day(s)\n' "$n_shown" "$n_lines" "$n_subs" "$n_days"

    printf 'NOTE\tSource: the TM error "AR0074: [SECURETRANSPORT] [<subscription>]  Could not send file: {<path>} using transfer site: {<site>} after attempting {<n>} times." — the route is the second bracket, the File the last path element. At most %s rows and %s per subscription, the newest ones; the totals name what the log holds.\n' "$MAXROWS" "$MAXPERSUB"
    printf 'SUMMARY\tLines: %s  |  Subscriptions: %s  |  Days: %s  |  Shown: %s\n' "$n_lines" "$n_subs" "$n_days" "$n_shown"
    printf 'FOOT\tGenerated on %s from %s file(s)\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${#files[@]}"
} > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"

echo "Data written to $OUT ($n_lines line(s), $n_subs subscription(s), $n_shown shown)." >&2
