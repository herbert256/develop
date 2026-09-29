#!/usr/bin/env bash
#
# routing-errors.sh — "Advanced Routing errors": one row per Advanced Routing
# server-log line of the three families a route gives up on, NEWEST FIRST,
# in ONE table (2026-09-28, user request: fewer server reports — until then
# three pages on one shared body, bin/server/arlist.sh: could-not-send,
# publish-failed and post-client-action):
#   Could not send file        AR0074    "AR0074: [SECURETRANSPORT] [<subscription>]  Could not send
#                                        file: {<path>} using transfer site: {<site>} after attempting
#                                        {<n>} times."  — the subscription + the path's last element
#   Publish to account failed  ARPA0001  "ARPA0001: [SECURETRANSPORT] [<subscription>]  An error
#                                        occurred while publishing the file {<file>} to an account. …"
#   Post client action error   ARRC0009  "ARRC0009: [<account>@<login>] []  Error deleting the file
#                                        after a post client action." (any AR line whose text names a
#                                        post client action) — the ACCOUNT, the first bracket before @
#   Route stopped              ARSP0001  "ARSP0001: [SECURETRANSPORT] [<subscription>]  An error
#                                        occurred while sending the file {<file>} to a partner site.
#                                        Step configuration suggests to stop further route execution."
#                                        (2026-09-29: the most frequent routing code, and the lines behind
#                                        the Boxes Deploy column — its own page went)
# An Advanced Routing line reads  AR<code>: [<first>] [<second>]  <body> —
# ar_parse() splits it into B1, B2 and BODY. Capped (user rule, 2026-09-12)
# at MAXROWS rows and MAXPER rows per error family AND entity — the newest
# ones on both counts; the INTRO and the TOTAL always say how many lines the
# log really holds. The entity column is "Account or subscription" — the
# header render_rpt.awk's row tint reads against both caches (deploy-errors'
# convention) — linked to its detail page.
#
# Reads the parse cache + the transfer subscription roster (a logged,
# possibly truncated or renamed subscription resolves to its current name).
#
# Usage:
#   ./routing-errors.sh    # reads the cache, writes data/server/reports/routing-errors.rpt
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib.sh"
mkdir -p "$REPORTS_DIR"
OUT="$REPORTS_DIR/routing-errors.rpt"
MAXROWS=1000 MAXPER=10
ROSTER="$TRANSFER_REPORTS/subscription.rpt"   # the subscriptions with a detail page

shopt -s nullglob
files=("$INPUT_DIR"/*.csv)
shopt -u nullglob
if [ ${#files[@]} -eq 0 ]; then
    echo "No files matching '*.csv' found in '$INPUT_DIR'" >&2
    rm -f "$OUT"   # no data for this ENV — page not published (an env-split legitimate state)
    exit 0
fi
echo "Found ${#files[@]} file(s) in '$INPUT_DIR', processing..." >&2

# the known-subscription roster ("KS<TAB>name", fed in ahead of the cache): a
# logged name resolves to its detail page — exact, else the unique known name
# it prefixes, else the raw name (alink resolves through the comprehensive
# slugmap at render time, so a miss renders unlinked)
known_names() {
    [ -f "$ROSTER" ] || return 0
    awk -F'\t' '$1=="TABLE"{t++; if(t>1)exit} t==1&&$1=="ROW"{print "KS\t" $2}' "$ROSTER"
}
# One pass over the matching lines. Every matched line comes out as a
# finished ROW behind a sort prefix (the shell only sorts, caps and cuts — a
# bash read over TAB fields would collapse empty ones):
#   LIN <TAB> sortkey <TAB> family|entity <TAB> ROW …
#   FAM <TAB> family <TAB> lines        TOT <TAB> lines <TAB> entities <TAB> days
agg=$(awk -F'\t' -v RNF="$RENAMES_FILE" "$RENAMES_AWK"'
    # RENAMES: a server line keeps the name that was current when it was
    # written, so fold it to the CURRENT one before matching the roster
    # (which carries current names) and DISPLAY the folded name
    function subcanon(t,   k, hits, full, c) {
        sub(/_(SS?|C)CP_.*$|_[A-Za-z0-9]+_(SERVER|CLIENT)_.*$/, "", t)   # the extended transfer-site spellings
        c = rn_canon_pfx(t)
        if (c in ksite) return c
        hits = 0
        for (k in ksite) if (index(k, c) == 1) { hits++; full = k; if (hits > 1) { hits = 0; break } }
        return hits == 1 ? full : c
    }
    function ar_parse(m,   p, q, r) {   # AR<code>: [B1] [B2]  BODY -> 1 when the line has the shape
        if (m !~ /^AR[A-Z]*[0-9]*: \[/) return 0
        p = index(m, "["); r = substr(m, p + 1); q = index(r, "]"); if (q == 0) return 0
        B1 = substr(r, 1, q - 1); r = substr(r, q + 1); sub(/^ */, "", r)
        if (substr(r, 1, 1) != "[") return 0
        r = substr(r, 2); q = index(r, "]"); if (q == 0) return 0
        B2 = substr(r, 1, q - 1); BODY = substr(r, q + 1); sub(/^ */, "", BODY)
        return 1 }
    function ar_brace(s) { if (!match(s, /\{[^}]*\}/)) return ""; return substr(s, RSTART + 1, RLENGTH - 2) }
    # lit(): a raw name starting with @ would read as renderer metadata; the empty block @{} keeps it literal (audit 2026-09-29 F07)
    function lit(s) { return (substr(s, 1, 1) == "@") ? "@{}" s : s }
    function basename(p,   n, P) { n = split(p, P, "/"); return (P[n] != "" ? P[n] : p) }
    BEGIN { rn_load(RNF) }
    $1 == "KS" { ksite[$2] = 1; next }                       # the known-subscription list (first input)
    $5 !~ /Could not send file|while publishing the file|post client action|stop further route execution/ { next }
    {
        m = $5
        if (!ar_parse(m)) next
        fam = ""; ent = ""; fn = ""; kind = ""
        if ((b = index(BODY, "Could not send file:")) > 0) {
            fam = "Could not send file"; kind = "subscriptions"; ent = B2
            fn = basename(ar_brace(substr(BODY, b + 20))); if (fn == "") ent = ""
        } else if ((b = index(BODY, "while publishing the file")) > 0) {
            fam = "Publish to account failed"; kind = "subscriptions"; ent = B2
            fn = basename(ar_brace(substr(BODY, b)))
        } else if (BODY ~ /post client action/) {
            fam = "Post client action error"; kind = "accounts"; ent = B1; sub(/@.*$/, "", ent)
        } else if (index(BODY, "stop further route execution") > 0) {
            fam = "Route stopped"; kind = "subscriptions"; ent = B2
            fn = basename(ar_brace(BODY))
        }
        if (ent == "") next
        d = substr($1, 1, 10); if (d !~ /^[0-9][0-9][0-9][0-9]-/) next
        if (kind == "subscriptions") ent = subcanon(ent)
        code = m; sub(/:.*$/, "", code)
        nl++; fl[fam]++
        if (!((kind SUBSEP ent) in seen)) { seen[kind SUBSEP ent] = 1; ne++ }
        if (!(d in dseen)) { dseen[d] = 1; nd++ }
        printf "LIN\t%s %s\t%s|%s\tROW\t%s %s\t%s\t%s\t@{alink=%s/%s}%s\t%s\n", d, $2, fam, ent, d, substr($2, 1, 8), fam, code, kind, ent, ent, lit(fn)
    }
    END {
        for (f in fl) printf "FAM\t%s\t%d\n", f, fl[f]
        printf "TOT\t%d\t%d\t%d\n", nl+0, ne+0, nd+0
    }
' <(known_names) "$PARSED")

IFS=$'\t' read -r _ n_lines n_ents n_days <<< "$(printf '%s\n' "$agg" | grep $'^TOT\t' || printf 'TOT\t0\t0\t0\n')"
n_lines=${n_lines:-0}; n_ents=${n_ents:-0}; n_days=${n_days:-0}
fam_n() { printf '%s\n' "$agg" | awk -F'\t' -v F="$1" '$1 == "FAM" && $2 == F { n = $3 } END { print n + 0 }'; }
n_cns=$(fam_n "Could not send file"); n_pub=$(fam_n "Publish to account failed"); n_pca=$(fam_n "Post client action error"); n_rst=$(fam_n "Route stopped")

# newest first (the sortkey = date + full time), then the two caps in that
# order: the first MAXPER rows met per family + entity are its newest, the
# first MAXROWS overall the newest of all
TAB=$(printf '\t')
lin_rows() {
    printf '%s\n' "$agg" | grep $'^LIN\t' | sort -t"$TAB" -k2,2r -k3,3 \
        | awk -F'\t' -v PS="$MAXPER" -v MX="$MAXROWS" '{ if (++n[$3] > PS) next; if (++t > MX) exit; print }' | cut -f4-
}
n_shown=0
if [ "$n_lines" -gt 0 ]; then n_shown=$(lin_rows | grep -c $'^ROW\t' || true); fi

{
    printf 'TITLE\tRouting errors\n'   # = its Reports menu label (2026-09-29)
    printf 'DESC\tThe Advanced Routing errors a route gives up on — Could not send file (AR0074), Publish to account failed (ARPA0001), Post client action error (ARRC0009), Route stopped (ARSP0001) — one row per line, newest first, with the subscription or account and the file.\n'

    printf 'TABLE\tAdvanced Routing errors\twide\tpager=100\n'
    printf 'HEAD\tDate & time\tError\tCode\tAccount or subscription\tFile\n'
    printf 'KIND\ttext\ttext\ttext\tmono\tfile\n'
    if [ "$n_lines" -gt 0 ]; then lin_rows
    else printf 'ROW\t@{colspan=5}No Advanced Routing error line in this data window.\n'; fi
    printf 'TOTAL\t@{colspan=5}%s row(s) shown — %s line(s) in the log (%s Could not send file, %s Publish to account failed, %s Post client action error, %s Route stopped), %s entities, %s day(s)\n' \
        "$n_shown" "$n_lines" "$n_cns" "$n_pub" "$n_pca" "$n_rst" "$n_ents" "$n_days"
    printf 'SUMMARY\tLines: %s  |  Could not send file: %s  |  Publish to account failed: %s  |  Post client action error: %s  |  Route stopped: %s  |  Shown: %s\n' "$n_lines" "$n_cns" "$n_pub" "$n_pca" "$n_rst" "$n_shown"
    printf 'FOOT\n'
} > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"

echo "Data written to $OUT ($n_lines line(s), $n_ents entit(ies), $n_shown shown)." >&2
