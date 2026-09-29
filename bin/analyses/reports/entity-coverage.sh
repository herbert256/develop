#!/usr/bin/env bash
#
# entity-coverage.sh — "Entity coverage" (an ANALYSES report published with
# the transfer pages, like cross-reference.sh): per ENTITY, is each configured
# direction actually WORKING?
#
# ONE selector, one page per entity (6 pages):
#   entity  Accounts (default) · Logical · Partners · Domains · Applications · BL  (report_tabs)
# The RULE is a set of verdict COLUMNS since 2026-09-29 (it was a second
# selector until then — entity-coverage, -once, -ok and -diff, 24 pages
# holding the same rows under four verdicts):
#
# The two structural rules never change (a side with no configured
# subscriptions is trivially covered, and an entity needs every side it
# configures). What varies is the EVIDENCE, one column each:
#   Current          COMMUNICATION, latest: the most recent File that way was
#     (row colour)   delivered OK - or a successful logon / poll, which is a
#                    successful connection by definition
#   Once             COMMUNICATION, ever: a File moved that way at all, or a
#                    successful SSH logon / UC3 poll
#   OK transfers     the TRANSFER: the most recent File that way was delivered
#                    OK. The logon and poll proofs do NOT count here - this
#                    column is about files arriving, not about the link being up.
#   Regressed        covered Once but not Current - it worked at some point,
#                    and the most recent attempt did not (the former
#                    "Difference between Current & Once" view; search
#                    "regressed" for that list).
# Monotonic in strictness: OK transfers is a subset of Current, which is
# a subset of Once — the invariant to re-assert after any change here.
# It was Partner-only until 2026-07; the coverage question is the same for any
# entity that owns subscriptions, so the whole computation is now driven by a
# per-entity SPEC (base list, the two xref directions, the account rollup and
# the direct attribution column of _files.tsv) and runs five times. The
# Logical view resolves its direct column (13, the profile/FlowID) through
# the xref/_profiles-logicals.tsv map — an unmapped value abstains.
#
#   IN  covered  = at least one real incoming File (a file moved), OR a
#                  successful SSH logon by one of the entity's accounts —
#                  the server-log "User with login name "FE…", associated
#                  with account "…", successfully authenticated" lines,
#                  already aggregated per account by server/auth-activity.rpt.
#   OUT covered  = at least one real outgoing File, OR a successful UC3
#                  remote poll — the server-log "Applying the search pattern
#                  '…' for transfer site '…': N file(s) …" lines (the message
#                  only appears when the remote listing SUCCEEDED; 0 files
#                  found still proves the connection), already aggregated per
#                  subscription by server/remote-poll.rpt (an unpublished
#                  intermediate since 2026-09-05 — its tables surface on the
#                  UC status / UC3 tab, bin/analyses/reports/uc3-polling.sh).
#
# One row per configured entity: the configured subscription counts per side,
# the File counts per side, the proof counts (Logons / Polls) and the four
# verdict columns. TWO row colours only, by the CURRENT verdict — green =
# every configured side covered, red = not; a side with no configured
# connections is trivially covered and a "both" entity needs BOTH sides. That
# verdict OVERRULES the usual status colours.
# No date filter — a status report.
#
# On the ACCOUNTS view the account rollup is the IDENTITY (an account is its
# own account), so the Logons proof is that account's own logon count.
#
# Reads: base/_{accounts,partners,domains,apps}.tsv, base/_subscriptions.tsv,
#        the xref pairs in both directions, $FILES,
#        $SERVER_REPORTS/{auth-activity,remote-poll}.rpt (may be absent —
#        that proof source then counts 0).
# Writes: data/transfer/reports/entity-coverage.rpt
#
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../transfer/lib.sh"
source "$ROOT/bin/pda-union.sh"   # SP_AWK: the File attribution UNION (sp_union / ap_union / lg_union / bl_union / uni_join)
mkdir -p "$REPORTS_DIR"
OUT="$REPORTS_DIR/entity-coverage.rpt"

shopt -s nullglob
files=("$INPUT_DIR"/*.csv)
shopt -u nullglob
if [ ${#files[@]} -eq 0 ]; then
    echo "No *.csv in $INPUT_DIR — building from the EMPTY caches (config-only estate)" >&2
fi

SB="$CONFIG_BASE/_subscriptions.tsv"
AUTH="$SERVER_REPORTS/auth-activity.rpt"
POLL="$SERVER_REPORTS/remote-poll.rpt"
# the per-(account, login) logon sidecar (auth-activity.sh, 2026-08-31): on a
# MULTI-FE account (several configured logins) the In-side logon proof is
# composed per LOGIN — login -> its in-side subscriptions -> entities — since
# a logon by login A proves nothing for login B's flows. Missing sidecar
# (older data) = fall back to the account-wide composition.
AUTHL="$SERVER_REPORTS/auth-logins.tsv"; AUTHLOK=1
[ -f "$AUTHL" ] || { AUTHL=/dev/null; AUTHLOK=0; }
LSF2="$CONFIG_XREF/_logins-subscriptions.tsv"; [ -f "$LSF2" ] || LSF2=/dev/null
ALF2="$CONFIG_XREF/_accounts-logins.tsv";      [ -f "$ALF2" ] || ALF2=/dev/null
[ -f "$CONFIG_BASE/_accounts.tsv" ] || { echo "No base caches — skipping." >&2; rm -f "$OUT"; exit 0; }
for f in SB AUTH POLL; do eval "[ -f \"\$$f\" ] || $f=/dev/null"; done
echo "Found ${#files[@]} file(s) in '$INPUT_DIR', building entity coverage..." >&2

# view:label:base:entity->subs:subs->entity:account->entity:$FILES col:KIND
# The account->entity map is "-" on the Accounts view (identity) and the
# $FILES column is that view's DIRECT attribution (col 3/13/18/19/20; the
# Logical view resolves col 13 through the FlowID map, the BL view col 12
# through the subscription->BL tag map).
SPECS=(
    "accounts:Accounts:_accounts:_accounts-subscriptions:_subscriptions-accounts:-:3:acct"
    "logical:Logical:_logicals:_logicals-subscriptions:_subscriptions-logicals:_accounts-logicals:13:lgc"
    "partners:Partners:_partners:_partners-subscriptions:_subscriptions-partners:_accounts-partners:20:ptn"
    "domains:Domains:_domains:_domains-subscriptions:_subscriptions-domains:_accounts-domains:19:dom"
    "applications:Applications:_apps:_apps-subscriptions:_subscriptions-apps:_accounts-apps:18:app"
    "bl:BL:_bl:_bl-subscriptions:_subscriptions-bl:_accounts-bl:12:bl"
)

ASF="$CONFIG_XREF/_accounts-subscriptions.tsv"; [ -f "$ASF" ] || ASF=/dev/null   # the logon-proof composition (see the awk)
TMPD=$(mktemp -d "${TMPDIR:-/tmp}/axecov.XXXXXX")
trap 'rm -rf "$TMPD"' EXIT

# cov_view SPEC -> $TMPD/<key>.part, the entity's table block. THE SIX
# ENTITIES IN PARALLEL (the four rules ran as parallel jobs until 2026-09-29;
# one job per entity now, each one awk pass over _files.tsv), concatenated in
# SPECS order afterwards.
cov_view() {
    local spec=$1
    IFS=: read -r _key label base es se ae fcol kind <<< "$spec"
    EB="$CONFIG_BASE/$base.tsv"
    ES="$CONFIG_XREF/$es.tsv"; SE="$CONFIG_XREF/$se.tsv"; AE="$CONFIG_XREF/$ae.tsv"
    [ -f "$EB" ] || return 0
    [ -f "$ES" ] || ES=/dev/null
    [ -f "$SE" ] || SE=/dev/null
    ident=0
    if [ "$ae" = "-" ]; then ident=1; AE=/dev/null; elif [ ! -f "$AE" ]; then AE=/dev/null; fi
    awk -F'\t' -v EB="$EB" -v SB="$SB" -v ES="$ES" -v SE="$SE" -v AE="$AE" -v KEY="$_key" -v ASF="$ASF" \
        -v AUTH="$AUTH" -v POLL="$POLL" -v AUTHL="$AUTHL" -v AUTHLOK="$AUTHLOK" -v LSF2="$LSF2" -v ALF2="$ALF2" \
        -v FCOL="$fcol" -v IDENT="$ident" "${SP_AWK_V[@]}" "$SP_AWK"'
        function stripattr(v) { sub(/^@\{[^}]*\}/, "", v); return v }
        function yn(b) { return b ? "@{class=processed}yes" : "@{class=failed}no" }
        BEGIN {
            FS = "\t"
            while ((getline l < EB) > 0) { n = split(l, a, "\t"); if (n >= 2 && a[1] != "") { P[toupper(a[1])] = a[2]; DISP[toupper(a[1])] = a[1] } }
            close(EB)
            while ((getline l < SB) > 0) { n = split(l, a, "\t"); if (n >= 2 && a[1] != "") { SD[toupper(a[1])] = a[2]; SN[++ns] = toupper(a[1]) } }
            close(SB)
            while ((getline l < ES) > 0) {
                n = split(l, a, "\t"); if (n < 2 || a[1] == "") continue
                p = toupper(a[1]); d = SD[toupper(a[2])]
                if (d == "in"  || d == "both") insub[p]++
                if (d == "out" || d == "both") outsub[p]++
            }
            close(ES)
            while ((getline l < SE) > 0) { n = split(l, a, "\t"); if (n >= 2 && a[1] != "") SUBP[toupper(a[1])] = SUBP[toupper(a[1])] SUBSEP toupper(a[2]) }
            close(SE)
            # account -> its subscriptions: the SSH-logon proof is composed
            # account -> IN-side subscription -> entity (2026-08-31 audit). On
            # the Accounts view the account is its own entity (IDENT), so the
            # proof is that account own count. It used to roll up account ->
            # entity over every entity of the account: a hybrid production
            # account with one live inbound flow and four dead ones marked the
            # In side of all five entities covered.
            if (!IDENT) { while ((getline l < ASF) > 0) { n = split(l, a, "\t"); if (n >= 2 && a[1] != "" && a[2] != "") ASUB[toupper(a[1])] = ASUB[toupper(a[1])] SUBSEP toupper(a[2]) }
                          close(ASF)
                          # the multi-FE maps (see the AUTHL comment up top)
                          while ((getline l < LSF2) > 0) { n = split(l, a, "\t"); if (n >= 2 && a[1] != "" && a[2] != "") LSUB[toupper(a[1])] = LSUB[toupper(a[1])] SUBSEP toupper(a[2]) }
                          close(LSF2)
                          while ((getline l < ALF2) > 0) { n = split(l, a, "\t"); if (n >= 2 && a[1] != "") aln[toupper(a[1])]++ }
                          close(ALF2) }
            # the Accounts / Domains views: the same File union over their own
            # subscription pair cache (SE) — the other four have theirs in SP_AWK
            if (KEY == "accounts" || KEY == "domains") uni_load(SE, SEX)
            t = 0
            while ((getline l < AUTH) > 0) {
                n = split(l, a, "\t")
                if (a[1] == "TABLE") { t++; if (t > 1) break }
                if (a[1] != "ROW" || t != 1) continue
                acct = toupper(stripattr(a[2])); c = a[3] + 0
                if (IDENT) { logons[acct] += c; continue }
                # a MULTI-FE account takes the per-login path below instead
                if (AUTHLOK + 0 == 1 && aln[acct] + 0 >= 2) continue
                m = split(substr(ASUB[acct], 2), PL, SUBSEP)
                for (i = 1; i <= m; i++) { s9 = PL[i]; d9 = SD[s9]
                    if (d9 != "in" && d9 != "both") continue          # a logon proves the In side only
                    m2 = split(substr(SUBP[s9], 2), PL2, SUBSEP)
                    for (j = 1; j <= m2; j++) logons[PL2[j]] += c }
            }
            close(AUTH)
            # the multi-FE accounts: the logon proof per LOGIN, from the
            # auth-logins.tsv sidecar — login -> its in-side subscriptions ->
            # entities (single-login accounts took the account path above)
            if (!IDENT && AUTHLOK + 0 == 1) {
                while ((getline l < AUTHL) > 0) {
                    n = split(l, a, "\t"); if (n < 3 || a[1] == "" || a[2] == "") continue
                    acct = toupper(a[1]); if (aln[acct] + 0 < 2) continue
                    m = split(substr(LSUB[toupper(a[2])], 2), PL, SUBSEP)
                    for (i = 1; i <= m; i++) { s9 = PL[i]; d9 = SD[s9]
                        if (d9 != "in" && d9 != "both") continue
                        m2 = split(substr(SUBP[s9], 2), PL2, SUBSEP)
                        for (j = 1; j <= m2; j++) logons[PL2[j]] += a[3] + 0 }
                }
                close(AUTHL)
            }
            t = 0
            while ((getline l < POLL) > 0) {
                n = split(l, a, "\t")
                if (a[1] == "TABLE") { t++; if (t > 1) break }
                if (a[1] != "ROW" || t != 1) continue
                site = toupper(stripattr(a[2])); c = a[3] + 0
                # exact, else the ONE configured name the logged value
                # prefixes/extends (the server truncates names) — an ambiguous
                # token attributes to nothing (2026-08-31 audit: first-match
                # handed one flow the poll proof of a sibling sharing its prefix)
                cfg = ""
                if (site in SD) cfg = site
                else { c9 = 0; for (i = 1; i <= ns; i++) if (index(site, SN[i]) == 1 || index(SN[i], site) == 1) { c9++; hit9 = SN[i] }
                       if (c9 == 1) cfg = hit9 }
                if (cfg == "") continue
                m = split(substr(SUBP[cfg], 2), PL, SUBSEP)
                for (i = 1; i <= m; i++) polls[PL[i]] += c
            }
            close(POLL)
        }
        # $FILES: the entity of a File is the UNION of its DIRECT attribution
        # column and the subscription configured entities (col 12) — the
        # shared sets of bin/pda-union.sh (the Logical view resolves its
        # direct column, the FlowID, through the FlowID map; BL has no direct
        # column) — a both-partner file carries an EMPTY col 20 because the
        # parse abstains on a two-group account, so counting the direct column
        # alone left such entities uncovered despite real traffic. The set is
        # keyed UPPERCASED, like every lookup here.
        {
            split("", FP)
            if (KEY == "partners") u9 = sp_union($20, $12)
            else if (KEY == "applications") u9 = ap_union($18, $12)
            else if (KEY == "logical") u9 = lg_union($13, $12)
            else if (KEY == "bl") u9 = bl_union($12)
            else u9 = uni_join($FCOL, $12, SEX)
            m = split(u9, PL, "\037"); for (i = 1; i <= m; i++) FP[toupper(PL[i])] = 1
            # OK vs Error follows the site-wide outcome policy: Error is
            # Failed or Expired, everything else (incl. Waiting) is OK.
            ok = ($2 != "Failed" && $2 != "Expired")
            for (p in FP) {
                if ($16 == "in") {
                    infile[p]++; if (ok) infileok[p]++
                    if ($6 > lastin[p]) { lastin[p] = $6; lastinok[p] = ok }
                } else if ($16 == "out") {
                    outfile[p]++; if (ok) outfileok[p]++
                    if ($6 > lastout[p]) { lastout[p] = $6; lastoutok[p] = ok }
                }
            }
        }
        END {
            for (p in P) {
                dir = P[p]
                # Current and Once ask about the COMMUNICATION, so a
                # successful SSH logon or UC3 poll proves the side on its own.
                # OK transfers asks about the TRANSFER, so neither counts there
                # — the most recent File itself has to have been delivered OK.
                ni = (insub[p]  + 0 == 0); no = (outsub[p] + 0 == 0)
                li = (lastin[p]  != "" && lastinok[p]); lo = (lastout[p] != "" && lastoutok[p])
                pi = (logons[p] > 0); po = (polls[p] > 0)
                cur  = (ni || li || pi) && (no || lo || po)
                once = (ni || infile[p] > 0 || pi) && (no || outfile[p] > 0 || po)
                okt  = (ni || li) && (no || lo)
                reg  = once && !cur
                res = cur ? "green" : "red"
                rank = cur ? 0 : 1
                dl = (dir == "in") ? "in" : (dir == "out") ? "out" : (dir == "both") ? "both" : "?"
                printf "%d\t%s\tROW\t%s\t%s\t%d\t%d\t%d\t%d\t%d\t%d\t%s\t%s\t%s\t%s\t@data:res=%s\n", \
                    rank, p, DISP[p], dl, insub[p]+0, infile[p]+0, logons[p]+0, \
                    outsub[p]+0, outfile[p]+0, polls[p]+0, yn(cur), yn(once), yn(okt), \
                    (reg ? "@{class=failed}regressed" : ""), res
                tot++; if (cur) tg++; else tr++
                if (once) to++; if (okt) tk++; if (reg) tx++
            }
            printf "9\t~\tEND\t%d\t%d\t%d\t%d\t%d\t%d\n", tot+0, tg+0, tr+0, to+0, tk+0, tx+0
        }
    ' "$FILES" \
    | LC_ALL=C sort -t$'\t' -k1,1n -k2,2 \
    | awk -F'\t' -v LABEL="$label" -v KIND="$kind" '
        # The STAT boxes sit AFTER the TABLE line on purpose: segment_rpt puts
        # every directive following a TABLE into THAT table block, so each
        # tabbed page gets its own boxes instead of one shared set.
        $3 == "END" { tot = $4; tg = $5; tr = $6; to = $7; tk = $8; tx = $9
            printf "TABLE\t%s\twide\tgsep=2,5,8\n", LABEL
            printf "STAT\twhite\t%d\tTotal %s\n", tot+0, tolower(LABEL)
            printf "STAT\tgreen\t%d (%.0f%%)\tCovered (Current)\n", tg+0, (tot > 0 ? 100 * tg / tot : 0)
            printf "STAT\tred\t%d (%.0f%%)\tNot covered\n", tr+0, (tot > 0 ? 100 * tr / tot : 0)
            printf "STAT\twhite\t%d\tCovered once\n", to+0
            printf "STAT\twhite\t%d\tOK transfers\n", tk+0
            printf "STAT\tred\t%d\tRegressed\n", tx+0
            printf "GHEAD\t@{colspan=2}\t@{colspan=3,class=gband gsep}In\t@{colspan=3,class=gband gsep}Out\t@{colspan=4,class=gband gsep}Covered\n"
            printf "HEAD\t%s\tDirection\tSubs\tFiles\tLogons\tSubs\tFiles\tPolls\tCurrent\tOnce\tOK transfers\tRegressed\n", (LABEL == "Logical" || LABEL == "BL" ? LABEL : substr(LABEL, 1, length(LABEL) - 1))
            printf "KIND\t%s\ttext\tnum\tnum\tnum\tnum\tnum\tnum\ttext\ttext\ttext\ttext\n", KIND
            for (i = 1; i <= nbuf; i++) print BUF[i]
            printf "TOTAL\tTotal (%d %s)\t\t@{class=num}%d\t@{class=num}%d\t@{class=num}%d\t@{class=num}%d\t@{class=num}%d\t@{class=num}%d\t\t\t\t\n", \
                tot+0, tolower(LABEL), s3+0, s4+0, s5+0, s6+0, s7+0, s8+0
            next
        }
        $3 == "ROW" {
            line = "ROW"
            for (i = 4; i <= NF; i++) line = line "\t" $i
            BUF[++nbuf] = line
            s3 += $6; s4 += $7; s5 += $8; s6 += $9; s7 += $10; s8 += $11
            next
        }
    ' > "$TMPD/$_key.part"
}
_cpids=()
for spec in "${SPECS[@]}"; do cov_view "$spec" & _cpids+=("$!"); done
_crc=0
for _cp in "${_cpids[@]}"; do wait "$_cp" || _crc=$?; done
[ "$_crc" -eq 0 ] || { echo "entity-coverage: a view failed (exit $_crc)." >&2; exit "$_crc"; }

{
printf 'TITLE\tEntity coverage\n'
printf 'DESC\tPer account, logical flow, partner, domain, application or BL: covered (green) or not (red) — each side proven by real transferred Files, successful SSH logons (In) or successful UC3 remote polls (Out); the Current, Once and OK-transfers verdicts side by side, the regressions marked.\n'
for spec in "${SPECS[@]}"; do
    _key=${spec%%:*}
    [ -f "$TMPD/$_key.part" ] && cat "$TMPD/$_key.part"
done
printf 'FOOT\n'
} > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"
echo "Data written to $OUT ($(command grep -c '^TABLE' "$OUT") view(s))." >&2
