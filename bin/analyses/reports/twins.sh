#!/usr/bin/env bash
#
# twins.sh — "Twins": every twin pair the detail pages' Twin rows know, on one
# page. Two tables:
#
#   Subscription twins   the same flow configured the opposite way, detected by
#                        the union of three rules (bin/transfer/reports/details.sh):
#                          A  the connected accounts are separator-spelling twins
#                          B  same name body, opposite side (UC1/UC2 vs UC3/UC4)
#                          C  the same account: its UC2+UC4 mailbox pair, or its
#                             exact one-UC1 + one-UC3 outbound pair
#                        A pair detected ONLY by rule C is a NAMING SLIP: the
#                        flows belong together (same account) but their names
#                        disagree — listed first.
#   Account twins        the same account name spelled with the other separator
#                        (`-` vs `_`) — two configured objects for one relation.
#
# Thin formatter over the pair maps details.sh persists
# (data/<env>/transfer/reports/details/_twins-{subscriptions,accounts}.tsv),
# so this page and the detail pages' Twin rows can never disagree. A
# transfer-DATA report housed with the ANALYSES scripts; bin/analyses/reports.sh
# runs it (wave 1); the PAGE renders into docs/<env>/analyses/ via
# SUBS_GROUP_REPORTS.
#
# Usage:
#   ./twins.sh   # -> data/<env>/transfer/reports/twins.rpt
#
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../transfer/lib.sh"
mkdir -p "$REPORTS_DIR"
OUT="$REPORTS_DIR/twins.rpt"
TWS="$REPORTS_DIR/details/_twins-subscriptions.tsv"
TWA="$REPORTS_DIR/details/_twins-accounts.tsv"

if [ ! -f "$TWS" ] && [ ! -f "$TWA" ]; then
    echo "twins: no twin maps (run bin/transfer/reports/details.sh first) — page not published." >&2
    rm -f "$OUT"
    exit 0
fi
[ -f "$TWS" ] || TWS=/dev/null
[ -f "$TWA" ] || TWA=/dev/null
# The LOGIN column (2026-08): the FE… service login each side connects with,
# from the config pair caches. A dep, so a login change re-renders the page.
SLF="$CONFIG_XREF/_subscriptions-logins.tsv"; [ -f "$SLF" ] || SLF=/dev/null
ALF="$CONFIG_XREF/_accounts-logins.tsv";      [ -f "$ALF" ] || ALF=/dev/null
# the DERIVED use case map: a production hybrid flow carries no UC prefix, and
# read from the name alone every hybrid pair rendered empty Direction cells
# and lumped into a "? / ?" use-case box (2026-08-31 audit)
UCDF="$CONFIG_XREF/_subscriptions-ucderived.tsv"; [ -f "$UCDF" ] || UCDF=/dev/null
skip_if_fresh "$OUT" "${BASH_SOURCE[0]}" "$TWS" "$TWA" "$SLF" "$ALF"

read -r n_sub n_name n_slip n_same n_twin <<< "$(awk -F'\t' '
    { n++
      if (index($3, "B")) b++
      if ($3 == "C")      c++
      if (index($3, "C")) s++
      if (index($3, "A")) t++ }
    END { print n+0, b+0, c+0, s+0, t+0 }' "$TWS")"
n_acc=$(awk -F'\t' '$1 != "" && $2 != "" { c++ } END { print c + 0 }' "$TWA")

# The SECOND STAT row: the subscription twins grouped by their use-case PAIR.
# Every twin joins two flows of opposite use cases, so each box names BOTH (each
# with its connection/movement pattern) and the box counts sum to the total
# number of subscription twins. Direction is definitional: connection is "out"
# when WE initiate (UC1/UC3), "in" when the partner does (UC2/UC4); movement is
# the flow direction (UC1/UC2 out, UC3/UC4 in) — UC1 out/out, UC2 in/out,
# UC3 out/in, UC4 in/in. The label's two lines are \x1f-separated (render_rpt
# stacks them like a `lines` cell). Sorted by count, then pair name.
combos=$(awk -F'\t' -v UCDF="$UCDF" '
    function uc(n)  { return match(n, /^UC[0-9]+/) ? substr(n, 1, RLENGTH) : ((toupper(n) in UCD) ? UCD[toupper(n)] : "?") }
    function pat(u) { return (u=="UC1")?"out/out":(u=="UC2")?"in/out":(u=="UC3")?"out/in":(u=="UC4")?"in/in":"" }
    function lab(u) { return (pat(u)=="") ? u : u" ("pat(u)")" }
    function pf(u1,u2) { return "pair-" tolower(u1) tolower(u2) }
    function prio(u) { return (u=="UC4")?1:(u=="UC2")?2:(u=="UC1")?3:(u=="UC3")?4:9 }
    BEGIN { US = sprintf("%c", 31)
            while ((getline l9 < UCDF) > 0) { split(l9, a9, "\t"); if (a9[1] != "" && a9[2] != "") UCD[toupper(a9[1])] = a9[2] } close(UCDF) }
    { a = uc($1); b = uc($2); if (a > b) { t = a; a = b; b = t }
      key = a US b
      if (!(key in A)) { A[key] = a; B[key] = b }
      cnt[key]++ }
    # display order UC4, UC2, UC1, UC3 (incoming side first — delivery then
    # collect — then the outgoing side — push then pull); the pf key stays
    # canonical (A,B ascending) so it still matches the rows
    END { for (k in cnt) {
            lo = (prio(A[k]) <= prio(B[k])) ? A[k] : B[k]
            hi = (prio(A[k]) <= prio(B[k])) ? B[k] : A[k]
            print cnt[k] "\t" lab(lo) US lab(hi) "\t" pf(A[k], B[k]) } }
' "$TWS" | LC_ALL=C sort -t$'\t' -k1,1nr -k2,2f)

{
    printf 'TITLE\tTwins\n'
    printf 'DESC\tEvery twin pair on one page: subscriptions that are the same flow configured the opposite way (by name, by shared login, or by spelling-twin accounts — with the naming slips listed first), and the accounts spelled with both separators.\n'
    printf 'INTRO\tThe **Twin** rows of the detail pages, collated. A **subscription twin** is the same flow configured the opposite way — the UC2+UC4 mailbox pair or the UC1+UC3 outbound pair — detected by **name** (same body, opposite side), by **login** (the UC2+UC4 pair sharing one FE login — the partner&#8217;s actual credential; the login-less UC1+UC3 mirror pairs on its account instead), or via **spelling-twin accounts**; a pair the login or account proves but the names do NOT match is a **naming slip**. An **account twin** is one partner relation configured twice, under both separator spellings.\n'
    # the first STAT row doubles as the table's filters: the total box carries an
    # empty pf key (shows all rows), the detection boxes narrow to their rule.
    # Name-matched / Shared login-account / Twin account count rows CARRYING
    # that evidence (the rules union, so the boxes overlap and need not sum to
    # the total). The naming slips have no box of their own — they are the
    # shared login/account rows without a name match, labelled in the Detected
    # by column and sorted first.
    printf 'STAT\twhite\t%s\tSubscription twin pairs\t\n' "$n_sub"
    printf 'STAT\twhite\t%s\tName-matched\tdet-name\n' "$n_name"
    printf 'STAT\twhite\t%s\tShared login/account\tdet-sameacct\n' "$n_same"
    printf 'STAT\twhite\t%s\tTwin account\tdet-twinacct\n' "$n_twin"
    # second STAT row: the twins grouped by use-case pair (each box's two lines
    # name both use cases); the SUBTITLE forces the break after the first row
    # (the .stat boxes are inline-block, so a block element starts a new line)
    if [ -n "$combos" ]; then
        printf 'SUBTITLE\tSubscription twins by use-case pair\n'
        while IFS=$'\t' read -r _cnt _lab _pf; do
            [ -n "$_cnt" ] && printf 'STAT\twhite\t%s\t%s\t%s\n' "$_cnt" "$_lab" "$_pf" || true
        done <<< "$combos"
    fi
    # sortable since 2026-08 (no `nosort`): the emitted order — naming slips
    # first — is the initial order, and every column sorts. The Login column is
    # the pair'"'"'s FE… service login(s): one value when both sides share it (the
    # usual mailbox shape, linked), the union when they differ.
    printf 'TABLE\tSubscription twins\twide\tnofilter\tpfnoun=pair\n'
    printf 'HEAD\tSubscription\tTwin\tDirection\tDirection\tLogin\tDetected by\n'
    printf 'KIND\tmono\tmono\ttext\ttext\tlogin\ttext\n'
    # naming slips first (C only), then spelling-only (A…), then the name-matched
    # bulk; name order within each — the sort key is emitted, then stripped
    awk -F'\t' -v SLF="$SLF" -v UCDF="$UCDF" '
        function lbl(r) {
            # C = the shared FE login (UC2+UC4) or the exact-pair account
            # (the login-less UC1+UC3 mirror) — 2026-08-30
            if (r == "C")        return "Shared login/account only — naming slip"
            if (index(r, "B")) {
                if (index(r, "C") && index(r, "A")) return "Name + shared login/account + spelling twins"
                if (index(r, "C")) return "Name + shared login/account"
                if (index(r, "A")) return "Name + spelling-twin accounts"
                return "Name match"
            }
            if (r == "A")        return "Spelling-twin accounts"
            if (r == "AC")       return "Shared login/account + spelling twins"
            return r
        }
        function rank(r) { if (r == "C") return 0; if (!index(r, "B")) return 1; return 2 }
        function uc(n)     { return match(n, /^UC[0-9]+/) ? substr(n, 1, RLENGTH) : ((toupper(n) in UCD) ? UCD[toupper(n)] : "?") }
        function pat(u)    { return (u=="UC1")?"out/out":(u=="UC2")?"in/out":(u=="UC3")?"out/in":(u=="UC4")?"in/in":"" }
        function prio(u)   { return (u=="UC4")?1:(u=="UC2")?2:(u=="UC1")?3:(u=="UC3")?4:9 }
        # one token per detection box the row belongs under — the rules union,
        # so a row can carry several (data-pf is a space-separated token list)
        function detkeys(r,   k) {
            k = ""
            if (index(r, "B")) k = "det-name"
            if (index(r, "C")) k = k (k == "" ? "" : " ") "det-sameacct"
            if (index(r, "A")) k = k (k == "" ? "" : " ") "det-twinacct"
            return k
        }
        # each row lists its detection-box keys and its use-case-pair key, so a
        # click on ANY box (report.js setupStatFilter) narrows to it
        function pfrow(s1, s2, r,   a, b, t, p) {
            a = uc(s1); b = uc(s2); if (a > b) { t = a; a = b; b = t }
            p = "pair-" tolower(a) tolower(b)
            return (detkeys(r) == "") ? p : detkeys(r) " " p
        }
        # display order UC4, UC2, UC1, UC3 in both subscription columns and their
        # Direction columns; the pf key (pfrow, canonical) is unchanged so the
        # box filters still match
        # the pair\047s login cell: the union of both sides\047 configured
        # logins — one shared value is the usual mailbox shape (linked); a
        # differing pair is listed plain, and no login at all is "-" (out-only
        # flows carry the remote credential in the comm profile instead)
        function logcell(s1, s2,   l1, l2) {
            l1 = LOG[toupper(s1)]; l2 = LOG[toupper(s2)]
            if (l1 == "" && l2 == "") return "-"
            if (l1 == l2 || l2 == "") return "@{alink=logins/" l1 "}" l1
            if (l1 == "")             return "@{alink=logins/" l2 "}" l2
            return l1 ", " l2
        }
        BEGIN { while ((getline lg < SLF) > 0) { nl = split(lg, az, "\t")
                    if (nl >= 2 && az[1] != "" && az[2] != "") {
                        k = toupper(az[1])
                        if (LOG[k] == "") LOG[k] = az[2]
                        else if (index(", " LOG[k] ", ", ", " az[2] ", ") == 0) LOG[k] = LOG[k] ", " az[2] } }
                close(SLF)
                while ((getline lg < UCDF) > 0) { nl = split(lg, az, "\t"); if (nl >= 2 && az[1] != "" && az[2] != "") UCD[toupper(az[1])] = az[2] } close(UCDF) }
        { u1 = uc($1); u2 = uc($2)
          if (prio(u1) <= prio(u2)) { s1 = $1; s2 = $2 } else { s1 = $2; s2 = $1 }
          printf "%d\t%s\tROW\t@data:pf=%s\t@{alink=subscriptions/%s}%s\t@{alink=subscriptions/%s}%s\t%s\t%s\t%s\t%s\n", rank($3), s1, pfrow($1, $2, $3), s1, s1, s2, s2, pat(uc(s1)), pat(uc(s2)), logcell(s1, s2), lbl($3) }
    ' "$TWS" | LC_ALL=C sort -t$'\t' -k1,1n -k2,2f | cut -f3-
    printf 'TOTAL\tTotal (%s pair(s))\t\t\t\t\t\n' "$n_sub"
    printf 'TABLE\tAccount twins (separator spellings)\tnofilter\n'
    printf 'HEAD\tAccount\tTwin\tLogin\n'
    printf 'KIND\tmono\tmono\tlogin\n'
    awk -F'\t' -v ALF="$ALF" '
        function logcell(a1, a2,   l1, l2) {
            l1 = LOG[toupper(a1)]; l2 = LOG[toupper(a2)]
            if (l1 == "" && l2 == "") return "-"
            if (l1 == l2 || l2 == "") return "@{alink=logins/" l1 "}" l1
            if (l1 == "")             return "@{alink=logins/" l2 "}" l2
            return l1 ", " l2
        }
        BEGIN { while ((getline lg < ALF) > 0) { nl = split(lg, az, "\t")
                    if (nl >= 2 && az[1] != "" && az[2] != "") {
                        k = toupper(az[1])
                        if (LOG[k] == "") LOG[k] = az[2]
                        else if (index(", " LOG[k] ", ", ", " az[2] ", ") == 0) LOG[k] = LOG[k] ", " az[2] } }
                close(ALF) }
        $1 != "" && $2 != "" { printf "ROW\t@{alink=accounts/%s}%s\t@{alink=accounts/%s}%s\t%s\n", $1, $1, $2, $2, logcell($1, $2) }' "$TWA"
    printf 'TOTAL\tTotal (%s pair(s))\t\t\n' "$n_acc"
    printf 'NOTE\tEach pair is listed ONCE (the relation is symmetric; the detail pages carry it on both sides). The subscription rules are unioned, so one pair can be proven several ways; a pair proven ONLY by the shared login (or, for the login-less UC1+UC3 mirror, the shared account) means the two flows belong together while their names disagree — the rename backlog. The account twins are the `-`/`_` double configurations the Separator collision analysis and Config hygiene also track; renaming one side merges the pair.\n'
    printf 'KEYWORDS\ttwin,twins,pair,mailbox,uc2,uc4,uc1,uc3,separator,spelling,naming slip,rename\n'
    printf 'FOOT\tGenerated on %s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
} > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"

echo "Data written to $OUT ($n_sub subscription pair(s): $n_name name-matched, $n_slip naming slip(s), $n_same same-account, $n_twin twin-account; $n_acc account spelling pair(s))." >&2
