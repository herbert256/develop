#!/usr/bin/env bash
#
# entity-coverage.sh — "Entity coverage" (an ANALYSES report published with
# the transfer pages, like cross-reference.sh): per ENTITY, is each configured
# direction actually WORKING?
#
# TWO selectors, so 5 x 4 = 20 pages:
#   entity  Accounts (default) · Logical · Partners · Domains · Applications  (report_tabs)
#   rule    Current (default) · Once · OK transfers ·
#           Difference between Current & Once                       (a report NAV)
# The RULE rides on the basename like duration/duration-all: entity-coverage,
# entity-coverage-ok, entity-coverage-once and entity-coverage-diff, each
# tabbed into the four entities. Its NAV line is emitted INSIDE each table block — that is what makes
# it per-entity, so switching rule keeps the entity you are on — and render_report
# hoists a table-block NAV onto the entity row to its RIGHT (@sep), so the two
# selectors share ONE line: group row, intro, "entity | gap | rule", STAT boxes.
#
# The two structural rules never change (a side with no configured
# subscriptions is trivially covered, and an entity needs every side it
# configures). What varies is the EVIDENCE:
#   Current          COMMUNICATION, latest: the most recent File that way was
#     (default)      delivered OK - or a successful logon / poll, which is a
#                    successful connection by definition
#   Once             COMMUNICATION, ever: a File moved that way at all, or a
#                    successful SSH logon / UC3 poll
#   OK transfers     the TRANSFER: the most recent File that way was delivered
#                    OK. The logon and poll proofs do NOT count here - this view
#                    is about files arriving, not about the link being up.
#   Difference       the REGRESSIONS: only the entities covered under Once but
#                    not under Current - it worked at some point, and the most
#                    recent attempt did not. All rows are red by construction,
#                    and the row count equals Once's green count minus Current's
#                    green count (Current is a subset of Once) - the invariant
#                    to re-assert after any change here.
# Monotonic in strictness: OK transfers is a subset of Current, which is
# a subset of Once.
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
#                  subscription by server/remote-poll.rpt.
#
# One row per configured entity: the configured subscription counts per side,
# the File counts per side, the proof counts (Logons / Polls) and a per-side
# verdict. TWO colours only — green = every configured side covered, red =
# not; a side with no configured connections is trivially covered and a "both"
# entity needs BOTH sides. That verdict OVERRULES the usual status colours.
# No date filter — a status report.
#
# On the ACCOUNTS view the account rollup is the IDENTITY (an account is its
# own account), so the Logons proof is that account's own logon count.
#
# Reads: base/_{accounts,partners,domains,apps}.tsv, base/_subscriptions.tsv,
#        the xref pairs in both directions, $FILES,
#        $SERVER_REPORTS/{auth-activity,remote-poll}.rpt (may be absent —
#        that proof source then counts 0).
# Writes: data/<env>/transfer/reports/entity-coverage.rpt
#
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../transfer/lib.sh"
mkdir -p "$REPORTS_DIR"
OUT="$REPORTS_DIR/entity-coverage.rpt"

shopt -s nullglob
files=("$INPUT_DIR"/*.csv)
shopt -u nullglob
if [ ${#files[@]} -eq 0 ]; then
    echo "No *.csv in $INPUT_DIR — building from the EMPTY caches (config-only estate)" >&2
fi
ensure_parsed

SB="$CONFIG_BASE/_subscriptions.tsv"
AUTH="$SERVER_REPORTS/auth-activity.rpt"
POLL="$SERVER_REPORTS/remote-poll.rpt"
[ -f "$CONFIG_BASE/_accounts.tsv" ] || { echo "No base caches — skipping." >&2; rm -f "$OUT"; exit 0; }
for f in SB AUTH POLL; do eval "[ -f \"\$$f\" ] || $f=/dev/null"; done

# skip_if_fresh guards ONE output, but this writes four (one per rule) — a
# missing sibling forces the rebuild, the same guard the pesit/uc-status
# sidecars carry.
for _rb in entity-coverage-ok entity-coverage-once entity-coverage-diff; do
    [ -f "$REPORTS_DIR/$_rb.rpt" ] || rm -f "$OUT"
done
skip_if_fresh "$OUT" "${BASH_SOURCE[0]}" "$CONFIG_BASE" "$CONFIG_XREF" "$AUTH" "$POLL"
echo "Found ${#files[@]} file(s) in '$INPUT_DIR', building entity coverage..." >&2

# view:label:base:entity->subs:subs->entity:account->entity:$FILES col:KIND
# The account->entity map is "-" on the Accounts view (identity) and the
# $FILES column is that view's DIRECT attribution (col 3/13/18/19/20; the
# Logical view resolves col 13 through the FlowID map).
SPECS=(
    "accounts:Accounts:_accounts:_accounts-subscriptions:_subscriptions-accounts:-:3:acct"
    "logical:Logical:_logicals:_logicals-subscriptions:_subscriptions-logicals:_accounts-logicals:13:lgc"
    "partners:Partners:_partners:_partners-subscriptions:_subscriptions-partners:_accounts-partners:20:ptn"
    "domains:Domains:_domains:_domains-subscriptions:_subscriptions-domains:_accounts-domains:19:dom"
    "applications:Applications:_apps:_apps-subscriptions:_subscriptions-apps:_accounts-apps:18:app"
)

now=$(date '+%Y-%m-%d %H:%M:%S')

# rule key : label : output basename
# Button order leads with Current — "is this working NOW" is what these pages
# are opened for — then Once (has it EVER worked) and OK transfers (strictest:
# the latest FILE itself was delivered OK, no logon/poll fallback). So the
# buttons are NO LONGER in increasing-strictness order; the subset relation
# still holds and is the thing to assert after a change: OK <= Current <= Once.
# CURRENT IS THE DEFAULT, and a rule is made default by owning the UNSUFFIXED
# basename — first_page, the Analyses menu, the analyses index and the sitemap
# all land on entity-coverage-accounts.html, which IS this rule's Accounts
# page. Moving the default therefore means moving which rule holds
# "entity-coverage"; there is no default flag anywhere to set.
RULES=(
    "current:Current:entity-coverage"
    "once:Once:entity-coverage-once"
    "ok:OK transfers:entity-coverage-ok"
    "diff:Difference between Current & Once:entity-coverage-diff"
)

# rulenav VIEWKEY ACTIVERULE -> the NAV line switching rule while staying on
# this entity. Emitted inside the table block, so it is the third button row.
rulenav() {
    local vk=$1 active=$2 out="NAV" r rk rl rb
    for r in "${RULES[@]}"; do
        IFS=: read -r rk rl rb <<< "$r"
        out+=$'\t'"$([ "$rk" = "$active" ] && echo 1 || echo 0)|$rl|$rb-$vk.html"
    done
    printf '%s\n' "$out"
}

for rule in "${RULES[@]}"; do
IFS=: read -r RKEY RLABEL RBASE <<< "$rule"
OUT="$REPORTS_DIR/$RBASE.rpt"
{
printf 'TITLE\tEntity coverage\n'
printf 'DESC\tPer account, logical flow, partner, domain or application: covered (green) or not (red) — each side proven by real transferred Files, successful SSH logons (In) or successful UC3 remote polls (Out); a side with no configured connections is trivially covered.\n'
printf 'INTRO\tIs the connection for each entity WORKING? A side is **covered** when at least one real File moved that way, or when the server log proves the connection: **In** — one of the entity'"'"'s accounts **successfully authenticated over SSH**; **Out** — a **UC3 remote poll succeeded** (the "Applying the search pattern" message appears only when the remote listing worked — 0 files found still proves the connection). A side with **no configured connections** is covered by definition, and a **both** entity needs In AND Out working. Two colors only — **green** = covered (listed first), **red** = not covered; this verdict overrules the usual status colors here. The buttons below pick the **entity**; the ones to their right pick the **rule**. *Current* and *Once* are about the **communication**, so a successful SSH logon or UC3 poll proves a side on its own — most-recently, and ever. *OK transfers* is about the **transfer**: neither proof counts there, the most recent File itself must have been delivered OK. *Difference between Current & Once* lists only the regressions — entities covered under *Once* but not under *Current*: the connection worked at some point, and the most recent attempt did not.\n'
printf 'KEYWORDS\tcoverage,covered,working,proof,logon,poll,account,logical,partner,domain,application\n'

for spec in "${SPECS[@]}"; do
    IFS=: read -r _key label base es se ae fcol kind <<< "$spec"
    EB="$CONFIG_BASE/$base.tsv"
    ES="$CONFIG_XREF/$es.tsv"; SE="$CONFIG_XREF/$se.tsv"; AE="$CONFIG_XREF/$ae.tsv"
    [ -f "$EB" ] || continue
    [ -f "$ES" ] || ES=/dev/null
    [ -f "$SE" ] || SE=/dev/null
    ident=0
    if [ "$ae" = "-" ]; then ident=1; AE=/dev/null; elif [ ! -f "$AE" ]; then AE=/dev/null; fi
    # the Logical view's direct column holds the FlowID — resolve through the map
    VMAP=""
    [ "$_key" = logical ] && [ -f "$CONFIG_XREF/_profiles-logicals.tsv" ] && VMAP="$CONFIG_XREF/_profiles-logicals.tsv"

    awk -F'\t' -v EB="$EB" -v SB="$SB" -v ES="$ES" -v SE="$SE" -v AE="$AE" -v VMAP="$VMAP" \
        -v AUTH="$AUTH" -v POLL="$POLL" -v FCOL="$fcol" -v IDENT="$ident" -v RULE="$RKEY" '
        function stripattr(v) { sub(/^@\{[^}]*\}/, "", v); return v }
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
            # account -> entity. On the Accounts view this is the IDENTITY (an
            # account is its own account), so the logon proof is that account
            # own count rather than a rollup.
            if (!IDENT) { while ((getline l < AE) > 0) { n = split(l, a, "\t"); if (n >= 2 && a[1] != "") ACCP[toupper(a[1])] = ACCP[toupper(a[1])] SUBSEP toupper(a[2]) }
                          close(AE) }
            if (VMAP != "") { while ((getline l < VMAP) > 0) { n = split(l, a, "\t"); if (n >= 2 && a[1] != "" && a[2] != "") VM[toupper(a[1])] = a[2] }
                              close(VMAP) }
            t = 0
            while ((getline l < AUTH) > 0) {
                n = split(l, a, "\t")
                if (a[1] == "TABLE") { t++; if (t > 1) break }
                if (a[1] != "ROW" || t != 1) continue
                acct = toupper(stripattr(a[2])); c = a[3] + 0
                if (IDENT) { logons[acct] += c; continue }
                m = split(substr(ACCP[acct], 2), PL, SUBSEP)
                for (i = 1; i <= m; i++) logons[PL[i]] += c
            }
            close(AUTH)
            t = 0
            while ((getline l < POLL) > 0) {
                n = split(l, a, "\t")
                if (a[1] == "TABLE") { t++; if (t > 1) break }
                if (a[1] != "ROW" || t != 1) continue
                site = toupper(stripattr(a[2])); c = a[3] + 0
                cfg = ""
                if (site in SD) cfg = site
                else for (i = 1; i <= ns; i++) if (index(site, SN[i]) == 1) { cfg = SN[i]; break }
                if (cfg == "") continue
                m = split(substr(SUBP[cfg], 2), PL, SUBSEP)
                for (i = 1; i <= m; i++) polls[PL[i]] += c
            }
            close(POLL)
        }
        # $FILES: the entity of a File is the UNION of its DIRECT attribution
        # column and the subscription configured entities (col 12 via SUBP) —
        # a both-partner file carries an EMPTY col 20 because the parse abstains
        # on a two-group account, so counting the direct column alone left such
        # entities uncovered despite real traffic (cf. pda-entities.sh).
        {
            split("", FP)
            if ($FCOL != "") { v9 = $FCOL
                if (VMAP != "") v9 = ((toupper(v9) in VM) ? VM[toupper(v9)] : "")
                if (v9 != "") FP[toupper(v9)] = 1 }
            if ($12 != "") { m = split(substr(SUBP[toupper($12)], 2), PL, SUBSEP); for (i = 1; i <= m; i++) FP[PL[i]] = 1 }
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
                if (RULE == "once") { fi = infile[p] > 0; fo = outfile[p] > 0 }
                else                { fi = (lastin[p]  != "" && lastinok[p])
                                      fo = (lastout[p] != "" && lastoutok[p]) }
                pi = (RULE == "ok") ? 0 : (logons[p] > 0)
                po = (RULE == "ok") ? 0 : (polls[p]  > 0)
                iok = (insub[p]  + 0 == 0) || fi || pi
                ook = (outsub[p] + 0 == 0) || fo || po
                if (RULE == "diff") {
                    # iok/ook came out of the else-branch above, so they ARE the
                    # Current verdict; the Once verdict is recomputed here. Keep
                    # only the regressions: covered Once, not covered Current.
                    # END fields become total / Once-covered / rows shown.
                    conce = ((insub[p]  + 0 == 0) || infile[p]  > 0 || pi) && \
                            ((outsub[p] + 0 == 0) || outfile[p] > 0 || po)
                    tot++; if (conce) tg++
                    if (!conce || (iok && ook)) continue
                    tr++
                    printf "1\t%s\tROW\t%s\t%s\t%d\t%d\t%d\t%d\t%d\t%d\t@data:res=red\n", \
                        p, DISP[p], (dir == "in") ? "in" : (dir == "out") ? "out" : (dir == "both") ? "both" : "?", \
                        insub[p]+0, infile[p]+0, logons[p]+0, outsub[p]+0, outfile[p]+0, polls[p]+0
                    continue
                }
                res = (iok && ook) ? "green" : "red"
                rank = (res == "green") ? 0 : 1
                dl = (dir == "in") ? "in" : (dir == "out") ? "out" : (dir == "both") ? "both" : "?"
                printf "%d\t%s\tROW\t%s\t%s\t%d\t%d\t%d\t%d\t%d\t%d\t@data:res=%s\n", \
                    rank, p, DISP[p], dl, insub[p]+0, infile[p]+0, logons[p]+0, \
                    outsub[p]+0, outfile[p]+0, polls[p]+0, res
                tot++; if (res == "green") tg++; else tr++
            }
            printf "9\t~\tEND\t%d\t%d\t%d\n", tot+0, tg+0, tr+0
        }
    ' "$FILES" \
    | LC_ALL=C sort -t$'\t' -k1,1n -k2,2 \
    | awk -F'\t' -v LABEL="$label" -v KIND="$kind" -v RULE="$RKEY" -v RULENAV="$(rulenav "$_key" "$RKEY")" '
        # The STAT boxes sit AFTER the TABLE line on purpose: segment_rpt puts
        # every directive following a TABLE into THAT table block, so each
        # tabbed page gets its own three boxes instead of one shared set.
        $3 == "END" { tot = $4; tg = $5; tr = $6
            printf "TABLE\t%s\twide\tgsep=2,5\n", LABEL
            # In the block so it is per-entity; render_report lifts it out and
            # merges it onto the entity row to the RIGHT (@sep), above the boxes
            print RULENAV
            printf "STAT\twhite\t%d\tTotal %s\n", tot+0, tolower(LABEL)
            if (RULE == "diff") {
                # tg/tr carry Once-covered / rows shown here (see the END emit)
                printf "STAT\tgreen\t%d (%.0f%%)\tCovered once\n", tg+0, (tot > 0 ? 100 * tg / tot : 0)
                printf "STAT\tred\t%d\tOnce but not Current\n", tr+0
            } else {
                printf "STAT\tgreen\t%d (%.0f%%)\tCovered\n", tg+0, (tot > 0 ? 100 * tg / tot : 0)
                printf "STAT\tred\t%d (%.0f%%)\tNot covered\n", tr+0, (tot > 0 ? 100 * tr / tot : 0)
            }
            printf "GHEAD\t@{colspan=2}\t@{colspan=3,class=gband gsep}In\t@{colspan=3,class=gband gsep}Out\n"
            printf "HEAD\t%s\tDirection\tSubs\tFiles\tLogons\tSubs\tFiles\tPolls\n", (LABEL == "Logical" ? LABEL : substr(LABEL, 1, length(LABEL) - 1))
            printf "KIND\t%s\ttext\tnum\tnum\tnum\tnum\tnum\tnum\n", KIND
            for (i = 1; i <= nbuf; i++) print BUF[i]
            printf "TOTAL\tTotal (%d %s)\t\t@{class=num}%d\t@{class=num}%d\t@{class=num}%d\t@{class=num}%d\t@{class=num}%d\t@{class=num}%d\n", \
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
    '
done

printf 'NOTE\tIn proof: the server-log SSH logon lines ("User with login name … associated with account … successfully authenticated"), counted per account by the Auth activity report and rolled up to the account'"'"'s entity — on the Accounts view that rollup is the identity. Out proof: the UC3 poll lines ("Applying the search pattern … for transfer site …"), counted per subscription by the Remote Polls report and rolled up to the subscription'"'"'s entity. Files are real logical transfers, split by the connection side.\n'
printf 'NOTE\tThe Logons and Polls columns show on every view, but they only COUNT towards the verdict on *Current* and *Once* — on *OK transfers* the verdict rests on the most recent File alone.\n'
printf 'NOTE\tSubs = the configured subscriptions per side (a both-ways subscription counts on both sides); a side with 0 Subs has nothing to prove and counts as covered.\n'
printf 'FOOT\tGenerated on %s from %s file(s)\n' "$now" "${#files[@]}"
} > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"
echo "Data written to $OUT ($(command grep -c '^TABLE' "$OUT") view(s), rule '$RLABEL')." >&2
done
