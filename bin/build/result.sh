#!/usr/bin/env bash
#
# result.sh — the RESULT build step (runs right after the transfer parse):
# fill the third `result` field of every data/flow-manager/base/_*.tsv
# (schema "name<TAB>direction<TAB>result"; bin/flow-manager.sh initializes it
# to "unknown").
#
# Stage 1 — subscriptions, from the transfer logs (data/transfer/cache/
# _files.tsv: one row per logical transfer, col 12 = dest site, col 6 =
# sortkey, col 2 = outcome). Per configured subscription (matched against the
# logged site names case-insensitively — the parser already stores the clean
# pre-_SCP_ subscription name):
#     not seen                              -> orange
#     seen, last transfer OK (Processed or
#     Waiting — the outcome policy)         -> green
#     seen, last transfer Failed            -> red
#     seen, last transfer Expired           -> orange (a pickup problem, not a
#                                              failed delivery — 2026-08; red
#                                              only by the server-log rule below)
#     seen, last transfer OK but the server log holds an Error/Warn line
#     NEWER than its END (col 24; the newest
#     OK File END — a File that finished OK
#     after the error ended OK after it,
#     2026-09-12 user rule)                 -> red   (2026-08: a flow with
#     "ERRORS IN SERVER LOG AFTER LAST TRANSFER" on its detail page cannot
#     be green; the evidence is the subscription's own _err_warn ring plus
#     every connected host/account/login ring LINE the attribution below
#     pins on this flow — never a connected ring wholesale; and never a
#     line on a TRANSFER-ENDED session, 2026-09-12 user rule: a session
#     that also logged the platform's own "Transfer end logged." bookend
#     is not a server-log error — bin/server/parse.sh keeps such lines out
#     of every _err_warn ring, data/server/cache/_sessions-ended.tsv)
#     … EXCEPT a UC3 flow whose newest evidence is a "Connection failure
#     while <flow> tried to connect …" line — its own, or a sibling's on
#     the shared host/account ring: that reds it only after THREE FAILED
#     POLLS IN A ROW of its own (2026-09-05, user rule — one or two failed
#     polls are a blip); below three the connection failures are discounted
#     and the newest other evidence decides (the flows it keeps green are
#     HELD; their sidecar _connhold.tsv went 2026-09-29 — no reader)
#     never transferred, but a UC3 whose own polls FAIL with a "Connection
#     failure while <flow> tried to connect …" line on THREE POLLS IN A ROW
#     (newer than its newest successful poll, or none at all)
#                                           -> red   (2026-09-10, user rule:
#     a flow that polls and cannot connect is broken, not idle — orange
#     would hide it; the newest failure is its _redflip evidence stamp and
#     the oldest failure of the streak its SINCE, so Failed Subscriptions
#     and its error page show it as a server-log failure)
#
# Stage 2 — every OTHER base file, rolled up from its connected subscriptions
# via the data/flow-manager/xref/_<item>-subscriptions.tsv pair caches:
#     all connected subscriptions green     -> green
#     one or more red                       -> red
#     everything else (incl. no connected
#     subscriptions at all)                 -> orange
# A subscription the CONFIG does not know (discovered in the transfer log;
# never "Unknown", the no-subscription value — no subscription, no colour, no
# pairs: 2026-09-29, the UCx_<account> fallback it replaced was one) has no
# configured pairs, so for it the
# rollup reads the OBSERVED pairs instead: _files.tsv col 3 (account) and
# col 14 (login) -> col 12, and the leg hosts of its OUT-connection Files
# (_hostlegs.tsv) — 2026-09-29 audit; the rule for configured pairs is
# unchanged.
#
# EXCEPTION — whitelisted IPs (_white.tsv) do NOT roll up: a partner's healthy
# flow says nothing about which of its whitelisted addresses actually connect,
# so an IP is green/red by the LAST real transfer whose remote host is that
# address (stage 1's rule, keyed on _files.tsv col 15), orange when none.
#
# Usage:
#   ./result.sh    # rewrites the result column of data/flow-manager/base/_*.tsv
#
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$ROOT/bin/fastawk.sh"   # route unqualified `awk` to mawk when installed

BASE="$ROOT/data/flow-manager/base"
XREF="$ROOT/data/flow-manager/xref"
FILES="$ROOT/data/transfer/cache/_files.tsv"

[ -f "$BASE/_subscriptions.tsv" ] || { echo "result.sh: no $BASE/_subscriptions.tsv (run bin/flow-manager.sh first) — nothing to do." >&2; exit 0; }
# the configured-name snapshot bin/flow-manager.sh writes with the base lists
# (the prune and the observed pairs read it) — present whenever they are
[ -f "$BASE/.configured.tsv" ] || { echo "result.sh: no $BASE/.configured.tsv (run bin/flow-manager.sh first)." >&2; exit 1; }

commit_tmp() { mv "$1.tmp" "$1"; }   # $1 = final path; expects $1.tmp
[ -f "$FILES" ] || { echo "result.sh: no $FILES (run bin/transfer/parse.sh first) — nothing to do." >&2; exit 0; }
# THE MODE: an explicit argument (never a freshness check).
#   (none)          the whole step: discovery + every colour
#   discover-hosts  stage 0 for the HOSTS only, and stop (2026-09-29, build
#                   speed): bin/build.sh runs it right after the transfer
#                   parse, so the server MENTION SCAN — which starts the moment
#                   the server parse is done — already matches the discovered
#                   hosts. Until then every production build paid the
#                   appended-names RESCAN (~13 s: its one discovered host is
#                   in the server log) plus a second result.sh run (~4 s) on
#                   the critical path. Safe that early because nothing before
#                   result.sh reads base/_hosts.tsv (the transfer parse and
#                   its session-sites re-derive read the xref pairs) — and the
#                   re-derive CAN still move a leg, so `discover` re-checks.
#                   Drops no rescan marker (the scan has not started yet).
#   discover        stage 0 after session-sites (the transfer caches final for
#                   it — expire-files / bookend-ok rewrite outcome and stamps
#                   only): the HOST RE-CHECK — the discovery recomputed
#                   against the pristine roster; when the re-derive changed
#                   it, base/_hosts.tsv is rewritten to what the full run
#                   would append and the rescan marker drops — and the
#                   SUBSCRIPTIONS (appended here, never before session-sites:
#                   the re-derive reads base/_subscriptions.tsv); an append
#                   drops the marker, the mention scan being under way.
#                   The full run then finds nothing left to append, and the
#                   rescan + re-colour steps of bin/build.sh fire only when
#                   a marker dropped here.
RS_MODE=${1:-all}
case $RS_MODE in
    all|discover-hosts|discover) ;;
    *) echo "usage: bin/build/result.sh [discover-hosts|discover]" >&2; exit 2 ;;
esac

# ---- the UC3 poll evidence ---------------------------------------------------
# The newest SUCCESSFUL poll per UC3 subscription — "Applying the search
# pattern … for transfer site '…': N file(s) …" — from the per-name server
# mention caches (last 25 rows + last 10 Error/Warn per subscription,
# bin/server/parse.sh; a missing dir just leaves the list empty). It feeds the
# green-KEEP below (a UC3 that transferred and has polled cleanly since an
# error stays green) and the connection-failure streak.
# NO CLEAN-POLL GREEN (2026-09-28, user rule: "A UC3 subscription that has no
# transfers must be orange and not green"): a UC3 that polls fine but never
# moved a file stays ORANGE — until then (2026-08..09-27) it flipped green,
# listed in data/colour/_greenpoll.tsv, which is gone with the rule.
SUBMENT="$ROOT/data/server/cache/subscriptions"
# data/colour/ — this step's working files and sidecars (the red-flip, poll,
# ring-attribution evidence); data/blue/ until 2026-09-27, when the BLUE status
# (server-log-only entities) was removed. (No cleanup of the retired files:
# every build wipes data/ first — fresh-only builds, 2026-09-28.)
COLDIR="$ROOT/data/colour"
POLLCAND="$COLDIR/_uc3polls.cand"       # name <TAB> newest successful poll, per UC3 (a working file)
# The UC3 CONNECTION-FAILURE STREAK (2026-09-05, user rule): a "Connection
# failure while <UC3 flow> tried to connect to remote host …" line reds the
# flow only when it happened on THREE POLLS IN A ROW — each such line is one
# failed poll attempt, and one or two in a row are a blip the next poll
# clears. CONNCAND carries, per UC3 flow (EVERY one since 2026-09-28 — before,
# only a flow with an own E-level line got a row, so a UC3 whose shared host
# logged a sibling's connection failure went red on that ONE line, its own
# streak never counted): name
# <TAB> newest own E stamp <TAB> newest own NON-connection-failure E stamp
# <TAB> newest successful poll <TAB> the "|"-joined stamps of its connection
# failures (mention cache AND Error/Warn ring, one entry per stamp). Stage 1
# recognises connection-failure evidence by those stamps — the flow's own
# line, or the same failure kind arriving through a shared host/account
# ring — counts the failures newer than the newest successful poll and the
# last transfer as the streak, and below three DISCOUNTS the connection
# failures: the newest of the remaining evidence decides.
CONNCAND="$COLDIR/_connfail.cand"
# The red-flip sidecar (2026-08): every subscription the after-last-transfer
# rule (or the cannot-connect rule) below turns red on server-log evidence:
#   name <TAB> EVIDENCE <TAB> SINCE          (both "YYYY-MM-DD HH:MM:SS…")
# EVIDENCE = the NEWEST line that did it (the error page, the Last column);
# SINCE (2026-09-29 audit) = when it WENT red — the oldest evidence line after
# the cut (the last transfer's end) that is still in force, or for a
# cannot-connect flow the oldest failure of its qualifying streak. Every "red
# since" / "new red flip" reader (failed.sh, the UC status
# per-hour walkers) dates by SINCE; the evidence stamp alone made a flow
# failing for two months read as a new flip on its newest failure.
REDFLIP="$COLDIR/_redflip.tsv"
# the cannot-connect SINCE, from the WHOLE server cache (the mention caches
# hold the newest 25 lines only): name <TAB> the oldest "Connection failure
# while <flow> …" Error after the flow's newest successful poll (the
# _build_ringattr parallel pass writes it; CCAND = the candidates it tracks)
CCSINCE="$COLDIR/_ccsince.tsv"
CCAND="$COLDIR/_ccand.tsv"
mkdir -p "$COLDIR"
if [ "$RS_MODE" = all ]; then   # (the poll / connection evidence reads the mention caches — not built yet in the discover modes)
: > "$CONNCAND"
{
    # every UC3 flow: UC3-NAMED or DERIVED (xref/_subscriptions-ucderived.tsv;
    # the production hybrid flows carry no UC prefix — 2026-08-31 audit: a
    # UC3*.tsv glob built no candidate for them, so a cleanly polling hybrid
    # pull flow could neither be kept green nor flip orange -> green)
    if [ -d "$SUBMENT" ]; then
        { awk -F'\t' '$1 ~ /^UC3/ { print $1 }' "$BASE/_subscriptions.tsv"
          [ -f "$XREF/_subscriptions-ucderived.tsv" ] && awk -F'\t' '$2 == "UC3" { print $1 }' "$XREF/_subscriptions-ucderived.tsv"
          :; } 2>/dev/null | LC_ALL=C sort -u | while IFS= read -r _n; do
            _pf="$SUBMENT/$_n.tsv"
            # no server-log mention at all: a candidate with an empty streak
            # (its own polls decide — it has none)
            [ -f "$_pf" ] || { printf '%s\t\t\t\t\n' "$_n" >> "$CONNCAND"; continue; }
            _rf="$SUBMENT/${_n}_err_warn.tsv"; [ -f "$_rf" ] || _rf=/dev/null
            awk -F'\t' -v n="$_n" -v cf="$CONNCAND" '
                FILENAME == ARGV[1] && $5 ~ /Applying the search pattern/ && $5 ~ /for transfer site/ && $5 ~ /file\(s\)/ { t = $1 " " $2; if (t > p) p = t }
                $3 == "E" { t = $1 " " $2
                            iscf = ($5 ~ /^Connection failure while /) ? 1 : 0
                            if (t > e) e = t
                            if (iscf) cfs[t] = 1; else if (t > encf) encf = t }
                # name <TAB> newest successful poll: the STAMP the green-keep
                # below compares against the red-flip evidence
                END { if (p != "") printf "%s\t%s\n", n, p
                      # the connection-failure streak candidate (see CONNCAND) —
                      # for every UC3 flow, an own E line or not
                      z = ""; for (t in cfs) z = z (z == "" ? "" : "|") t
                      printf "%s\t%s\t%s\t%s\t%s\n", n, e, encf, p, z >> cf }
            ' "$_pf" "$_rf"
        done
    fi
} > "$POLLCAND"
# the cannot-connect CANDIDATES (see CCSINCE): the UC3 flows whose own
# connection failures newer than their newest successful poll already make the
# streak of three (stage 1 adds "never transferred"). Upper-cased names.
awk -F'\t' '{ n = 0; m = split($5, Z, "|")
              for (i = 1; i <= m; i++) if (Z[i] != "" && ($4 == "" || Z[i] > $4)) n++
              if ($1 != "" && n >= 3) print toupper($1) }' "$CONNCAND" | LC_ALL=C sort -u > "$CCAND"
: > "$CCSINCE"
fi   # RS_MODE = all

# ---- stage 0: entities DISCOVERED in the transfer log ----------------------
# A subscription (or remote host) can carry real transfers and still be absent
# from the FlowManager export — a flow configured after the export was taken.
# The entity reports list it (they read the parse cache), so the Entities view
# shows a row for it, but the base cache has no entry: the home figure counts
# the base cache and the view footer counts the rows, and the two disagree.
# bin/build/publish.sh's check_status_consistency catches exactly that.
#
# So the transfer log DISCOVERS entities: they are appended
# with an EMPTY result and coloured below like any other row: a subscription by
# stage 1, a host by the own-transfer rule after the rollups.
#
# The two rosters MIRROR the reports that list them, which is what keeps the
# figures equal:
#   subscriptions  every dest_site (col 12) in _files.tsv
#   hosts          every LEG host (_transfers.tsv col 16) of an OUT-connection
#                  File (_files.tsv col 16) — the rows remote-host.sh and the
#                  Entities writer list, so the raw INCOMING addresses of an
#                  in-connection File are not invented as entities here either.
#                  2026-09-28 fix (the production run): the File's FIRST host
#                  (_files col 15) alone missed an outbound leg to an unmapped
#                  raw address, which the Entities view then listed untinted
#                  (home 105 against a page footer of 106).
# HOSTLEGS = that population once, one line per (host, File): host <TAB> File
# sortkey <TAB> outcome <TAB> subscription (col 12) <TAB> File END (col 24, else
# its start) — read by the discovery, the prune, the own-colour rule of an
# unpaired host, the observed host pairs and the hosts orphan_red below.
HOSTLEGS="$COLDIR/_hostlegs.tsv"
# the OBSERVED pairs (see the header, stage 2): entity <TAB> subscription for
# every subscription the CONFIG does not know (base/.configured.tsv — the
# discovered ones; "Unknown" is no subscription and pairs with nothing), from _files.tsv
# col 3 (account) / col 14 (login) -> col 12, and the leg hosts of its
# OUT-connection Files (HOSTLEGS col 1 -> col 4)
OBS_ACC="$COLDIR/_observed-accounts.tsv"; OBS_LGN="$COLDIR/_observed-logins.tsv"; OBS_HST="$COLDIR/_observed-hosts.tsv"
if [ "$RS_MODE" != all ]; then
    # THE DISCOVER MODES need the host NAMES only (2026-09-29, build speed —
    # they run on the critical path): the distinct leg hosts of the
    # OUT-connection Files in _transfers.tsv order — the first spelling of
    # each first, exactly the order HOSTLEGS lists them in — instead of the
    # full per-(host, File) HOSTLEGS and the observed pairs, which the full
    # run builds anyway
    HOSTLEGS="$COLDIR/_hostset.tsv"
    if [ -f "$ROOT/data/transfer/cache/_transfers.tsv" ]; then
        awk -F'\t' 'FILENAME == ARGV[1] { if ($16 == "out") o[$1] = 1; next }
            ($1 in o) && $16 != "" && !($16 in seen) { seen[$16] = 1; print $16 }
        ' "$FILES" "$ROOT/data/transfer/cache/_transfers.tsv" > "$HOSTLEGS"
    else
        : > "$HOSTLEGS"
    fi
else
    source "$ROOT/bin/ranges.sh"    # grp_par: the leg-host pass below (and the session vote further down)
    # (the observed account / login pairs — one _files.tsv pass — run in the
    # BACKGROUND beside the leg-host pass: 2026-09-29, speed round 3; result.sh
    # ran at ~40 % CPU on production)
    (
    awk -F'\t' -v C="$BASE/.configured.tsv" -v OA="$OBS_ACC.tmp" -v OL="$OBS_LGN.tmp" '
        BEGIN { while ((getline l < C) > 0) { split(l, a, "\t"); if (a[1] == "_subscriptions" && a[2] != "") K[toupper(a[2])] = 1 }
                close(C); printf "" > OA; printf "" > OL }
        $12 != "" && $12 != "Unknown" && !(toupper($12) in K) {
            if ($3 != ""  && !(("A" SUBSEP $3 SUBSEP $12) in d)) { d["A" SUBSEP $3 SUBSEP $12] = 1; print $3 "\t" $12 > OA }
            if ($14 != "" && !(("L" SUBSEP $14 SUBSEP $12) in d)) { d["L" SUBSEP $14 SUBSEP $12] = 1; print $14 "\t" $12 > OL } }
    ' "$FILES"
    LC_ALL=C sort -o "$OBS_ACC.tmp" "$OBS_ACC.tmp"; commit_tmp "$OBS_ACC"
    LC_ALL=C sort -o "$OBS_LGN.tmp" "$OBS_LGN.tmp"; commit_tmp "$OBS_LGN"
    ) & OBS_AL_PID=$!
    # THE LEG-HOST PASS in key-aligned slices of _transfers.tsv (grp_par — the
    # cache is CoreId-sorted, so a slice never splits a File's legs and the
    # per-(host, File) dedup stays exact; outputs joined in slice order = the
    # serial order). The OUT Files' facts ride a small map instead of every
    # slice reading _files.tsv itself. (2026-09-29, speed round 3: one serial
    # pass over the leg cache was a third of result.sh.)
    if [ -f "$ROOT/data/transfer/cache/_transfers.tsv" ]; then
        awk -F'\t' '$16 == "out" { print $1 "\t" $6 "\t" $2 "\t" $12 "\t" (($24 != "") ? $24 : $4 " " $5) }' "$FILES" > "$COLDIR/_outfiles.tmp"
        _rnj=$( (command -v nproc >/dev/null 2>&1 && nproc) || sysctl -n hw.ncpu 2>/dev/null || echo 2 )
        grp_par "$ROOT/data/transfer/cache/_transfers.tsv" "$HOSTLEGS.tmp" "$_rnj" awk -F'\t' -v OM="$COLDIR/_outfiles.tmp" '
            BEGIN { while ((getline l < OM) > 0) { split(l, a, "\t"); SK[a[1]] = a[2]; OC[a[1]] = a[3]; SB[a[1]] = a[4]; EN[a[1]] = a[5] } close(OM) }
            ($1 in SK) && $16 != "" { k = $16 SUBSEP $1; if (!(k in seen)) { seen[k] = 1; print $16 "\t" SK[$1] "\t" OC[$1] "\t" SB[$1] "\t" EN[$1] } }'
        rm -f "$COLDIR/_outfiles.tmp"
        commit_tmp "$HOSTLEGS"
    else
        : > "$HOSTLEGS"
    fi
    wait "$OBS_AL_PID" || { echo "result.sh: the observed account / login pairs failed" >&2; exit 1; }
    awk -F'\t' -v C="$BASE/.configured.tsv" '
        BEGIN { while ((getline l < C) > 0) { split(l, a, "\t"); if (a[1] == "_subscriptions" && a[2] != "") K[toupper(a[2])] = 1 } close(C) }
        $4 != "" && $4 != "Unknown" && !(toupper($4) in K) && !(($1 SUBSEP $4) in d) { d[$1 SUBSEP $4] = 1; print $1 "\t" $4 }
    ' "$HOSTLEGS" | LC_ALL=C sort > "$OBS_HST.tmp"
    commit_tmp "$OBS_HST"
fi
# the rows discovery appends for roster file $1 ($2 = sub | host), sorted
disc_block() {
    local src="$FILES"; [ "$2" = host ] && src="$HOSTLEGS"
    awk -F'\t' -v COND="$2" -v BF="$1" '
        BEGIN { while ((getline l < BF) > 0) { split(l, a, "\t"); if (a[1] != "") B[toupper(a[1])] = 1 }
                close(BF) }
        { v = (COND == "sub") ? $12 : $1 }
        COND == "sub" && v == "Unknown" { next }   # the no-subscription value (2026-09-29): never an entity
        v != "" && !(toupper(v) in B) && !(toupper(v) in seen) { seen[toupper(v)] = 1; ord[++n] = v }
        END { for (i = 1; i <= n; i++) print ord[i] "\t\t" }
    ' "$src" | LC_ALL=C sort
}
discover_logged() {   # $1 = base name  $2 = the awk condition picking its column
    local basef="$BASE/_$1.tsv" n
    [ -f "$basef" ] || return 0
    local pris="$COLDIR/_pristine_$1.tsv" blk="$COLDIR/_discovered_$1.txt"
    # THE HOST RE-CHECK (discover mode, after an early discover-hosts): the
    # block against the PRISTINE roster the early run saved; unchanged -> the
    # roster stands; changed -> rewritten as the full run would append it
    if [ "$RS_MODE" = discover ] && [ "$1" = hosts ] && [ -f "$pris" ] && [ -f "$blk" ]; then
        n=$(disc_block "$pris" "$2")
        [ "$n" = "$(cat "$blk")" ] && return 0
        { cat "$pris"; [ -z "$n" ] || printf '%s\n' "$n"; } > "$basef.tmp"
        commit_tmp "$basef"
        printf '%s' "$n" > "$blk"
        : > "$ROOT/data/server/cache/.rescan-mentions" 2>/dev/null || true
        echo "result.sh: the session join changed the discovered hosts — base/_hosts.tsv rewritten, the mention rescan will run." >&2
        return 0
    fi
    [ "$RS_MODE" = discover-hosts ] && { cp "$basef" "$pris"; : > "$blk"; }
    n=$(disc_block "$basef" "$2")
    [ -n "$n" ] || return 0
    { cat "$basef"; printf '%s\n' "$n"; } > "$basef.tmp"
    commit_tmp "$basef"
    [ "$RS_MODE" = discover-hosts ] && printf '%s' "$n" > "$blk"
    printf 'result.sh: %s discovered in the transfer log, appended to %s.\n' \
        "$(printf '%s\n' "$n" | wc -l | tr -d ' ')" "base/_$1.tsv" >&2
    # the per-entity server MENTION caches did not match the new names —
    # their detail pages would lose the server-log table: the rescan marker
    # (bin/build.sh rescans once, after this step). Not for the early hosts
    # (discover-hosts): the mention scan starts after them and reads them.
    [ "$RS_MODE" = discover-hosts ] || : > "$ROOT/data/server/cache/.rescan-mentions" 2>/dev/null || true
}
case $RS_MODE in
    discover-hosts) discover_logged hosts host; exit 0 ;;
    discover)       discover_logged hosts host; discover_logged subscriptions sub; exit 0 ;;
esac
discover_logged subscriptions sub
discover_logged hosts host

# ---- stage 1: the subscriptions' own result --------------------------------
# One pass over _files.tsv keyed on the UPPERCASED site name: keep the outcome
# of the LAST (max sortkey) transfer per site, then stamp each configured
# subscription green/red/orange. A would-be-green subscription flips RED when
# the server log holds an E-LEVEL line NEWER than that last transfer (errors
# only since 2026-08: a Warning never flips a flow red). The evidence is
# the subscription's own _err_warn ring plus every connected-ring
# LINE the attribution below pins on this flow, plus (2026-08-22) the LOOSE
# connected-ring newest E of the went-kaput join — _build_kaputflip below,
# deploy-classified flows excluded — so a trouble-after-success flow reads
# RED (Failed Subscriptions, the Entities Error view) rather than green.
IPH_P="$ROOT/input/ip/ip-hosts.tsv"; [ -f "$IPH_P" ] || IPH_P=/dev/null
TRANSFERS="$ROOT/data/transfer/cache/_transfers.tsv"
SRVC="$ROOT/data/server/cache"
source "$ROOT/bin/renames.sh"   # rn_canon_pfx: the log names a flow as it was called THEN
source "$ROOT/bin/ranges.sh"    # rng_feed / rng_off: the parallel session-vote pass (2026-09-27)

# ---- connected-ring Error/Warn lines, ATTRIBUTED to one subscription --------
# A remote host — and just as much an account or a login — serves many flows,
# so taking the newest line of its ring reddened EVERY subscription configured
# for it: one bad endpoint, a dozen false reds, all carrying the same evidence
# stamp. A line belongs to ONE flow, and the log says which: the message names
# it, another line of the SAME SESSION does (the connection id, _parse.tsv
# col 6), or the transfer legs of that session do (_transfers.tsv col 24 is
# the SAME id and col 6 the site the attribution chain gave the leg — the
# session join, 2026-08).
#
# Three passes over the host + account + login rings, each only for what the
# one before leaves unresolved:
#   1. every ring line whose message names a UC token -> that subscription
#   2. the remaining lines by session, voted from the parse cache's own lines
#   3. still-unresolved sessions joined against _transfers.tsv col 24 -> the
#      leg's site (col 6, already rename-canonical; two sites -> neither)
# A line that attributes to NOTHING cannot redden a flow we cannot identify —
# its E-level residue goes to the ring's own entity instead (orphan_red).
RINGATTR="$COLDIR/_ringattr.tsv"    # subscription <TAB> newest attributed E-level stamp <TAB> every attributed E stamp, "|"-joined (the SINCE of a flip)
RINGORPH="$COLDIR/_ringorphan.tsv"  # ring kind <TAB> name <TAB> newest E-level line attributable to NO flow
# the SESSION VOTE itself, kept for the two wholesale joins (2026-09-12, user
# rule: "for server errors with a host, read all server log lines with the
# same session-id to find the right subscription"): session <TAB> the ONE
# subscription the session's other lines name (pass 2), or the one site its
# transfer legs carried (pass 3), or \001 when they name two. A connected-ring
# line whose session votes one flow is THAT flow's evidence — carried to it
# here — and must not be taken wholesale for every sibling on the shared
# host/account/login (_build_kaputflip, went-kaput.sh). A production host
# shared by two flows reddened the wrong one on an authentication failure
# whose session named the other flow's transfer site.
SESSVOTE="$COLDIR/_sessvote.tsv"
_build_ringattr() {
    local rings=() f tmp
    for f in "$SRVC"/hosts/*_err_warn.tsv "$SRVC"/accounts/*_err_warn.tsv "$SRVC"/logins/*_err_warn.tsv; do
        [ -e "$f" ] && rings+=("$f")
    done
    if [ ${#rings[@]} -eq 0 ]; then
        : > "$RINGATTR.tmp"; commit_tmp "$RINGATTR"
        : > "$RINGORPH.tmp"; commit_tmp "$RINGORPH"
        : > "$SESSVOTE.tmp"; commit_tmp "$SESSVOTE"
        return 0
    fi
    tmp=$(mktemp "${TMPDIR:-/tmp}/axrattr.XXXXXX")
    # subname(msg): the configured subscription a server-log line NAMES —
    # every name-shaped token tried, tail-stripped and rename-folded, against
    # the roster (base/_subscriptions.tsv, case-folded) — else the first
    # UC-shaped token (the pre-2026-08-31 rule, kept so a line naming a
    # decommissioned flow still attributes to that name instead of becoming
    # an orphan of its ring), else "". The former UC[0-9]+ regex could not
    # attribute a line to a production hybrid flow at all (no UC prefix), so
    # on that estate the precise channel abstained and the wholesale
    # went-kaput join decided the colour.
    local SUBNAME_AWK; SUBNAME_AWK=$(cat "$ROOT/bin/subname.awk")   # shared with went-kaput.sh (2026-09-05)
    # pass 1: the message names it. Emits N (named), S (session to resolve) or
    # X (neither — SSHD/PESITD records carry no session at all): tag, stamp,
    # subscription-or-session, level, ring kind, ring name. A forward-address
    # ring belongs to its ENDPOINT (ip-hosts.tsv), so its residue lands there.
    awk -F'\t' -v RNF="$RENAMES_FILE" -v IPH="$IPH_P" -v SUBB="$BASE/_subscriptions.tsv" "$RENAMES_AWK$SUBNAME_AWK"'
        BEGIN { rn_load(RNF); ros_load(SUBB)
                while ((getline l < IPH) > 0) { n = split(l, a, "\t"); if (n >= 2 && a[1] != "") ipm[a[1]] = tolower(a[2]) }
                close(IPH) }
        FNR == 1 { nm = FILENAME; sub(/_err_warn\.tsv$/, "", nm)
                   kind = nm; sub(/\/[^\/]*$/, "", kind); sub(/.*\//, "", kind)
                   sub(/.*\//, "", nm)
                   if (kind == "hosts" && (nm in ipm)) nm = ipm[nm] }
        { st = $1 " " $2
          sn = subname($5)
          if (sn != "") { print "N\t" st "\t" sn "\t" $3 "\t" kind "\t" nm; next }
          if ($6 != "") { print "S\t" st "\t" $6 "\t" $3 "\t" kind "\t" nm; next }
          print "X\t" st "\t-\t" $3 "\t" kind "\t" nm }
    ' "${rings[@]}" > "$tmp.raw"
    : > "$tmp.map"
    # pass 2 also runs for the cannot-connect candidates alone (CCAND — see
    # CCSINCE): with no session to vote on, $tmp.sess is simply empty
    if command grep -q "^S" "$tmp.raw" 2>/dev/null || [ -s "$CCAND" ]; then
        awk -F'\t' '$1 == "S" { print $3 }' "$tmp.raw" | LC_ALL=C sort -u > "$tmp.sess"
        # pass 2: ONE pass over the parse cache for those sessions only
        # IN PARALLEL (2026-09-27, speed round 11): byte ranges of the 3 GB
        # cache (bin/ranges.sh), one job per core — this single-threaded pass
        # sat on the build's critical path. Each part lists its DISTINCT
        # (session, flow) pairs in first-seen order; the merge reads the parts
        # in range (= cache) order, so a session's first flow is the one the
        # single pass printed, and a second distinct flow anywhere marks it
        # "\001" (a session naming two flows resolves to neither) — the same
        # lines, then the same sort -u.
        # The SAME pass tracks the cannot-connect candidates (CCAND): per part
        # and flow, whether a successful poll ("Applying the search pattern …
        # for transfer site … file(s)") occurred and the first "Connection
        # failure while <flow> …" Error after the part's last such poll —
        # the cache is chronological and the parts are in cache order, so the
        # merge below walks them into the oldest failure of the CURRENT streak.
        if [ -f "$SRVC/_parse.tsv" ]; then
            _rsz=$(wc -c < "$SRVC/_parse.tsv" | tr -d ' ')
            _rnj=$( (command -v nproc >/dev/null 2>&1 && nproc) || sysctl -n hw.ncpu 2>/dev/null || echo 2 )
            case $_rnj in ""|*[!0-9]*) _rnj=2 ;; esac
            _rparts=(); _rpids=(); _rcc=()
            for ((_ri = 1; _ri <= _rnj; _ri++)); do
                _rlo=$(rng_lo "$_rsz" "$_rnj" "$_ri"); _rhi=$(rng_hi "$_rsz" "$_rnj" "$_ri")
                rng_feed "$SRVC/_parse.tsv" "$_rlo" | awk -F'\t' -v SF="$tmp.sess" -v RNF="$RENAMES_FILE" -v SUBB="$BASE/_subscriptions.tsv" \
                    -v CCF="$CCAND" -v CCO="$tmp.cc.$_ri" \
                    -v RANGEF=/dev/stdin -v RLO="$_rlo" -v RHI="$_rhi" -v ROFF="$(rng_off "$_rlo")" "$RENAMES_AWK$SUBNAME_AWK"'
                    BEGIN { while ((getline l < SF) > 0) S[l] = 1; close(SF); rn_load(RNF); ros_load(SUBB)
                            while ((getline l < CCF) > 0) if (l != "") { CC[l] = 1; hascc = 1 }
                            close(CCF); printf "" > CCO }
                    FILENAME == RANGEF { if (!_rs) { _rs = 1; _off = ROFF + 0 } _lo = _off; _off += length($0) + 1; if (_lo < RLO + 0) next; if (_lo >= RHI + 0) exit }
                    hascc && $3 == "E" && index($5, "Connection failure while ") == 1 {
                        c = toupper(subname($5)); if (c in CC) { CT[c] = 1; if (!(c in CF)) CF[c] = $1 " " $2 } }
                    hascc && index($5, "Applying the search pattern") && index($5, "for transfer site") && index($5, "file(s)") {
                        c = toupper(subname($5)); if (c in CC) { CT[c] = 1; CP[c] = 1; delete CF[c] } }
                    ($6 in S) {
                        t = subname($5); if (t == "") next
                        k = $6 SUBSEP t
                        if (!(k in seen)) { seen[k] = 1; print $6 "\t" t } }
                    END { for (c in CT) print c "\t" ((c in CP) ? 1 : 0) "\t" ((c in CF) ? CF[c] : "") > CCO }
                ' /dev/stdin > "$tmp.rv.$_ri" &
                _rpids+=("$!"); _rparts+=("$tmp.rv.$_ri"); _rcc+=("$tmp.cc.$_ri")
            done
            for _rp in "${_rpids[@]}"; do wait "$_rp"; done
            # ONE line per session: an ambiguous one (it named two flows) is
            # "\001" alone — every reader keeps the LAST line of a session, and
            # a sorted "\001" line landed before its flow line, so the session
            # voted for one of its two flows (2026-09-28 fix)
            awk -F'\t' '{ if (!($1 in f)) { f[$1] = $2; o[++n] = $1 } else if ($2 != f[$1]) a[$1] = 1 }
                END { for (i = 1; i <= n; i++) print o[i] "\t" ((o[i] in a) ? "\001" : f[o[i]]) }' "${_rparts[@]}" \
                | LC_ALL=C sort -u > "$tmp.map"
            rm -f "${_rparts[@]}"
            # the cannot-connect SINCE: the parts in cache order — a part that
            # polled successfully restarts the streak at its first failure
            # after that poll ("" = none yet), one that did not only fills an
            # empty start
            awk -F'\t' '{ if ($2 == 1) st[$1] = $3; else if (st[$1] == "") st[$1] = $3 }
                END { for (c in st) if (st[c] != "") print c "\t" st[c] }' "${_rcc[@]}" | LC_ALL=C sort > "$CCSINCE"
            rm -f "${_rcc[@]}"
        fi
        # pass 3: the SESSION JOIN — a session the parse cache could not vote
        # on may still be the connection of logged transfer LEGS: _transfers.tsv
        # col 24 carries the same id, col 6 the site the attribution chain gave
        # that leg (canonical since parse time — no fold needed). Legs naming
        # two sites resolve to neither, the pass-2 rule.
        awk -F'\t' '{ print $1 }' "$tmp.map" | LC_ALL=C sort -u | LC_ALL=C comm -13 - "$tmp.sess" > "$tmp.sess2"
        if [ -s "$tmp.sess2" ] && [ -f "$TRANSFERS" ]; then
            awk -F'\t' -v SF="$tmp.sess2" '
                BEGIN { while ((getline l < SF) > 0) S[l] = 1; close(SF) }
                ($24 in S) && $6 != "" {
                    if (sites[$24] == "") sites[$24] = $6
                    else if (sites[$24] != $6) sites[$24] = "\001" }
                END { for (k in sites) if (sites[k] != "\001") print k "\t" sites[k] }
            ' "$TRANSFERS" >> "$tmp.map"
        fi
    fi
    # the vote, persisted for _build_kaputflip and went-kaput.sh (see SESSVOTE)
    LC_ALL=C sort -u "$tmp.map" > "$SESSVOTE.tmp"; commit_tmp "$SESSVOTE"
    awk -F'\t' -v MAP="$tmp.map" -v ORPH="$RINGORPH.tmp" '
        BEGIN { while ((getline l < MAP) > 0) { n = split(l, a, "\t")
                    if (n >= 2 && a[2] != "\001") M[a[1]] = a[2]; else if (n >= 2) M[a[1]] = "" }
                close(MAP) }
        $1 == "N" { sub_ = $3 }
        $1 == "S" { sub_ = ($3 in M) ? M[$3] : "" }
        $1 == "X" { sub_ = "" }
        # ERRORS ONLY, like ringmax below: the map feeds the red flip, and a
        # Warning must not flip a flow red ($4 carries the ring line level)
        sub_ != "" && $4 == "E" { k = toupper(sub_); if ($2 > mx[k]) { mx[k] = $2; nm[k] = sub_ }; al[k] = al[k] "|" $2; next }
        sub_ != "" { next }   # attributed Warning: neither flip evidence nor an orphan
        # UNATTRIBUTABLE and E-level: the ring owner keeps it (see orphan_red).
        # Warnings are left out — "Error" is the E level site-wide, and the
        # W-level orphans are all the benign "Transfer site ID is not present
        # in environment" shape.
        $4 == "E" { o = $5 "\t" $6; if ($2 > omx[o]) omx[o] = $2 }
        END { for (k in mx) printf "%s\t%s\t%s\n", nm[k], mx[k], substr(al[k], 2)
              for (o in omx) printf "%s\t%s\n", o, omx[o] > ORPH }
    ' "$tmp.raw" | LC_ALL=C sort > "$RINGATTR.tmp"
    rm -f "$tmp"*
    commit_tmp "$RINGATTR"
    [ -f "$RINGORPH.tmp" ] || : > "$RINGORPH.tmp"
    LC_ALL=C sort -o "$RINGORPH.tmp" "$RINGORPH.tmp"
    commit_tmp "$RINGORPH"
}
_build_ringattr
[ -f "$RINGATTR" ] || : > "$RINGATTR"

# ---- the TROUBLE-AFTER-SUCCESS flip evidence (2026-08-22) -------------------
# The went-kaput join, promoted to the COLOUR: a flow whose CONNECTED
# account/login/host rings carry an E-level line — joined 1-to-1 and
# WHOLESALE, the way the went-kaput page and the detail-page banner read
# them, attribution or not — is failing, and must read red (the user's call,
# 2026-08-22: an early warning IS a failing flow). Two exceptions, the same
# two the retired home early-warning table applied: the flow whose NEWEST
# connected E line classifies as a DEPLOY
# defect (Route stopped / Receive File As not set — a config mistake, its
# report is Deploy errors) contributes NOTHING here and stays green; and the
# UC3 poll green-keep still applies in the flip below, so a flow that has
# transferred and polled cleanly since stays green. The subscription's OWN ring is already in
# bdt via ringmax; this file carries only the connected-ring side. Host rings
# join only for a single-host flow (two hosts = unattributable, as
# everywhere), the endpoint's forward addresses included.
KAPUTFLIP="$COLDIR/_kaputflip.tsv"   # subscription <TAB> newest connected-ring E stamp <TAB> 1 = a connection failure (deploy-classified flows absent)
_build_kaputflip() {
    local rings=() f tmp
    for f in "$SRVC"/accounts/*_err_warn.tsv "$SRVC"/logins/*_err_warn.tsv "$SRVC"/hosts/*_err_warn.tsv; do
        [ -e "$f" ] && rings+=("$f")
    done
    if [ ${#rings[@]} -eq 0 ]; then
        : > "$KAPUTFLIP.tmp"; commit_tmp "$KAPUTFLIP"
        return 0
    fi
    local _kfsa="$XREF/_subscriptions-accounts.tsv"; [ -f "$_kfsa" ] || _kfsa=/dev/null
    local _kfsl="$XREF/_subscriptions-logins.tsv";   [ -f "$_kfsl" ] || _kfsl=/dev/null
    local _kfsh="$XREF/_subscriptions-hosts.tsv";    [ -f "$_kfsh" ] || _kfsh=/dev/null
    tmp=$(mktemp "${TMPDIR:-/tmp}/axkflip.XXXXXX")
    local SUBNAME_AWK; SUBNAME_AWK=$(cat "$ROOT/bin/subname.awk")
    # pass 1: each ring's newest E line THAT NAMES NO FLOW -> "kind <TAB> name
    # <TAB> stamp <TAB> message" (a host ring name is folded lowercase like the
    # pair-cache side it joins). A line naming a flow — "Connection failure
    # while UC3_X tried to connect …" on the account/host UC3_X shares with
    # its siblings — is THAT flow's evidence and reaches it through
    # _build_ringattr; taken wholesale here it reddened every sibling on the
    # shared owner, an inbound UC1 flow included (2026-09-05, user report).
    # … and the same for a line whose SESSION names a flow (2026-09-12, user
    # rule — SESSVOTE, the vote _build_ringattr just took): the newest E line
    # of a host shared by two flows is an "Authentication failure connecting
    # to remote host …" that names no flow, but the poll lines of its session
    # name one flow's transfer site — that flow's evidence alone, never the
    # sibling's. A session naming two flows (\001) or none votes nothing and
    # the wholesale rule below still applies.
    awk -F'\t' -v RNF="$RENAMES_FILE" -v SUBB="$BASE/_subscriptions.tsv" -v SV="$SESSVOTE" "$RENAMES_AWK$SUBNAME_AWK"'
        BEGIN { rn_load(RNF); ros_load(SUBB)
                while ((getline l < SV) > 0) { n = split(l, a, "\t"); if (n >= 2 && a[1] != "") V[a[1]] = a[2] } close(SV) }
        function sessnamed(s) { return (s != "" && (s in V) && V[s] != "" && V[s] != "\001") }
        FNR == 1 { fdone = 0
            nm = FILENAME; sub(/_err_warn\.tsv$/, "", nm)
            kind = (nm ~ /\/accounts\//) ? "A" : (nm ~ /\/logins\//) ? "L" : "H"
            sub(/^.*\//, "", nm); if (kind == "H") nm = tolower(nm) }
        !fdone && $3 == "E" && NF >= 5 && subname($5) == "" && !sessnamed($6) { printf "%s\t%s\t%s\t%s\n", kind, nm, $1 " " $2, substr($5, 1, 200); fdone = 1 }
    ' "${rings[@]}" > "$tmp"
    # pass 2: join per subscription (newest across its connected rings),
    # classify that ONE newest message, drop the deploy verdicts.
    # A RING OWNER SERVING SEVERAL FLOWS (2026-08-31 audit) speaks for all of
    # them only when its newest line is about the CONNECTION itself — a
    # connection failure, a rejected server key, an outbound authentication
    # failure: the credential / endpoint every one of those flows uses is
    # broken. A flow-level line (a route step, a missing directory, a PeSIT
    # refusal …) on a shared account, login or host concerns ONE of its flows
    # and reaches the colour only through _build_ringattr, which names it.
    # Before, eight production flows on one hybrid account all went red on
    # one sibling's route error, with one shared evidence stamp — the exact
    # failure _build_ringattr was written to kill, reintroduced by this join.
    # The 1:1 owners (most of acceptance) are unchanged. went-kaput.sh applies
    # the same rule to its page and evidence sidecar.
    awk -F'\t' -v RINGS="$tmp" "$(cat "$ROOT/bin/flip-reason.awk")"'
        function connlevel(r) { return (r == "Connection failures" || r == "Wrong server fingerprint" || r == "Login errors (out)") }
        # the USER an outbound authentication failure names ("... as user U:"),
        # upper-cased, "" when the line is no such failure
        function authuser(m,   u) {
            if (m !~ /^Authentication failure connecting to remote host / || !match(m, / as user [^:]+:/)) return ""
            u = toupper(substr(m, RSTART + 9, RLENGTH - 10)); return u }
        # does subscription s log in as u (a configured login or account)?
        function usesuser(s, u,   n, z, i, v) {
            n = split(substr(SL[s], 2) SUBSEP substr(SA[s], 2), z, SUBSEP)
            for (i = 1; i <= n; i++) { v = toupper(z[i]); if (v != "" && (v == u || v == substr(u, 1, index(u "@", "@") - 1))) return 1 }
            return 0 }
        # the candidate ring k (owner serving own flows): its newest E line, if it may speak for s
        function take(k, own, s,   r9, u9) {
            if (!(k in re) || re[k] <= best) return
            if (own > 1) { r9 = flip_reason(rm[k]); if (!connlevel(r9)) return }
            # a HOST line of an outbound authentication failure names the user
            # that failed: it concerns the flows logging in as that user only,
            # never every flow of the host (2026-09-28 fix)
            if (substr(k, 1, 1) == "H") { u9 = authuser(rm[k]); if (u9 != "" && !usesuser(s, u9)) return }
            best = re[k]; msg = rm[k]
        }
        FILENAME == RINGS { re[$1 SUBSEP $2] = $3; rm[$1 SUBSEP $2] = $4; next }
        FILENAME ~ /_subscriptions-accounts\.tsv$/ { if ($1 != "" && $2 != "") { SA[$1] = SA[$1] SUBSEP $2; AN[$2]++ }; next }
        FILENAME ~ /_subscriptions-logins\.tsv$/   { if ($1 != "" && $2 != "") { SL[$1] = SL[$1] SUBSEP $2; LN[$2]++ }; next }
        FILENAME ~ /_subscriptions-hosts\.tsv$/    { if ($1 != "" && $2 != "") { nh[$1]++; vh[$1] = tolower($2); HN[tolower($2)]++ }; next }
        FILENAME ~ /ip-hosts\.tsv$/ { if ($1 != "" && $2 != "") fw[tolower($2)] = fw[tolower($2)] SUBSEP $1; next }
        # base/_subscriptions.tsv: the roster
        {
            s = $1; if (s == "") next
            best = ""; msg = ""
            n = split(substr(SA[s], 2), Z, SUBSEP)
            for (i = 1; i <= n; i++) take("A" SUBSEP Z[i], AN[Z[i]] + 0, s)
            n = split(substr(SL[s], 2), Z, SUBSEP)
            for (i = 1; i <= n; i++) take("L" SUBSEP Z[i], LN[Z[i]] + 0, s)
            if (nh[s] + 0 == 1) {
                h = vh[s]
                take("H" SUBSEP h, HN[h] + 0, s)
                n = split(substr(fw[h], 2), Z, SUBSEP)
                for (i = 1; i <= n; i++) take("H" SUBSEP tolower(Z[i]), HN[h] + 0, s)   # a forward address carries its endpoint fan-out
            }
            if (best == "") next
            r = flip_reason(msg)
            if (r == "Route stopped" || r == "Receive File As not set") next
            printf "%s\t%s\t%d\n", s, best, (r == "Connection failures" ? 1 : 0)   # col 3: the UC3 streak rule discounts a connection failure (stage 1)
        }
    ' "$tmp" "$_kfsa" "$_kfsl" "$_kfsh" "$IPH_P" "$BASE/_subscriptions.tsv" \
    | LC_ALL=C sort > "$KAPUTFLIP.tmp"
    rm -f "$tmp"
    commit_tmp "$KAPUTFLIP"
}
_build_kaputflip
[ -f "$KAPUTFLIP" ] || : > "$KAPUTFLIP"
[ -f "$RINGORPH" ] || : > "$RINGORPH"

awk -F'\t' -v rf="$REDFLIP.tmp" -v srvc="$SRVC" '
    # raise bdt to ring file f'\''s newest E-LEVEL line "date time" when newer
    # (a missing file reads nothing), and collect EVERY E stamp of the ring in
    # EVL ("|"-joined) — the candidates of the flip SINCE. ERRORS ONLY
    # (2026-08): a Warning must not flip a flow red — the warnings-only shape
    # was the benign "Transfer site ID is not present in environment", which
    # has its own report, and went-kaput applies the same errors-only rule.
    function ringmax(f,   l2, b2, n2, t2) {
        while ((getline l2 < f) > 0) {
            n2 = split(l2, b2, "\t")
            if (n2 >= 3 && b2[3] == "E") {
                t2 = b2[1] " " b2[2]
                if (t2 > bdt) bdt = t2
                EVL = EVL "|" t2
            }
        }
        close(f)
    }
    FILENAME == ARGV[1] {
        s = toupper($12)
        if (s != "" && $6 != "" && $6 >= sk[s]) { sk[s] = $6; oc[s] = $2; lt[s] = $4 " " $5 }
        # the newest OK END per flow (col 24, 2026-09-12 user rule: "there are
        # CoreIds from this subscription that ended ok after it — in those
        # cases do not mark it as a Server Error"): a File that started before
        # the Error but FINISHED OK after it — a retry burst whose late leg
        # delivered — is a transfer that ended OK after the error, so the
        # error is not "after the last transfer". Outcome-policy OK (Waiting
        # counts); the start when the parse wrote no end.
        if (s != "" && $2 != "Failed" && $2 != "Expired" && $6 != "") { e9 = ($24 != "") ? $24 : $4 " " $5; if (!(s in le) || e9 > le[s]) le[s] = e9 }
        next
    }
    FILENAME == ARGV[2] { if ($1 != "" && $2 != "") pt[toupper($1)] = $2   # newest successful poll, for the green-keep
                          next }   # the UC3 poll evidence (see above)
    FILENAME == ARGV[3] { if ($1 != "" && $2 != "") { RA[toupper($1)] = $2; RAL[toupper($1)] = ($3 != "") ? $3 : $2 }; next }   # subscription -> newest connected-ring Error attributed to it (+ every attributed stamp)
    FILENAME == ARGV[4] { if ($1 != "" && $2 != "") { KF[toupper($1)] = $2; KFC[toupper($1)] = $3 + 0 }; next }   # subscription -> newest LOOSE connected-ring Error (the went-kaput join; deploy-classified flows absent) + its connection-failure flag
    FILENAME == ARGV[5] { if ($1 != "") { u = toupper($1); UC3[u] = 1; ENCF[u] = $3; CFP[u] = $4
                                                      m5 = split($5, Z5, "|"); for (i5 = 1; i5 <= m5; i5++) if (Z5[i5] != "") { cfset[u SUBSEP Z5[i5]] = 1; CFL[u] = CFL[u] SUBSEP Z5[i5] } }
                          next }   # UC3 connection-failure streak candidates (see CONNCAND)
    FILENAME == ARGV[6] { if ($1 != "" && $2 != "") CCS[toupper($1)] = $2; next }   # cannot-connect: the oldest failure of the streak, whole cache (CCSINCE)
    {
        k = toupper($1)
        r = "orange"; expd = 0   # expd, not exp: exp() is an awk BUILT-IN
        # EXPIRED-LAST IS ORANGE, NOT RED (2026-08). A staged UC2 copy the
        # partner never collected and the retention sweep deleted is a PICKUP
        # problem, not a delivery failure: nothing errored, the file aged out.
        # It still counts as an Error everywhere the OUTCOME POLICY applies
        # (CLAUDE.md: Error = Failed || Expired) — this is the entity COLOUR
        # only, so the flow is not red (Failed Subscriptions, the Entities
        # Error view) while the Expired report
        # and the Expired box still carry it. `exp` keeps it a candidate for
        # the after-last-transfer rule below: expired AND a newer server-log
        # Error/Warn is red on that evidence, so "only red because it expired"
        # is the exact condition for orange.
        if (k in oc) {
            if (oc[k] == "Failed")       r = "red"
            else if (oc[k] == "Expired") { r = "orange"; expd = 1 }
            else                         r = "green"   # Waiting-last = green (interim policy)
        }
        # the after-last-transfer rule (2026-08): an ERROR logged AFTER the
        # last (OK) transfer -> red, matching the detail-page ALERT banner
        if ((r == "green" || expd) && (k in lt)) {
            bdt = ""; EVL = ""; disc = 0
            # the cut the evidence must be NEWER than: the last transfer
            # START, raised to the newest OK File END (le, col 24) — never
            # lower than before, so this only ever spares a flip
            ct = lt[k]; if ((k in le) && le[k] > ct) ct = le[k]
            ringmax(srvc "/subscriptions/" $1 "_err_warn.tsv")
            # the connected host/account/login rings contribute only the lines
            # ATTRIBUTED to THIS subscription (see _build_ringattr): each of
            # those entities serves other flows too, and one of its errors must
            # redden the flow it actually concerns — never the whole set.
            if ((k in RA) && RA[k] > bdt) bdt = RA[k]
            if (k in RA) EVL = EVL "|" RAL[k]
            # ... plus the LOOSE connected-ring evidence (2026-08-22): the
            # went-kaput join promoted to the colour — see _build_kaputflip.
            # Deploy-classified flows are absent from that file by design.
            if ((k in KF) && KF[k] > bdt) bdt = KF[k]
            if (k in KF) EVL = EVL "|" KF[k]
            # A UC3 that has POLLED CLEANLY SINCE that Error/Warn is working:
            # "0 file(s) were found of which 0 matched the pattern" is a
            # successful poll with nothing to fetch, and it is the newest
            # thing the log says about the flow: the flip is skipped and the
            # subscription stays green (2026-08). Only a flow that HAS
            # transferred — a UC3 that never moved a file is not green on
            # its polls (2026-09-28, user rule), it stays orange.
            # THE UC3 CONNECTION-FAILURE STREAK (2026-09-05, user rule): when
            # the newest evidence IS this flow'\''s own newest "Connection
            # failure while <flow> tried to connect …" line, it reds the flow
            # only after THREE failed polls in a row — its connection failures
            # newer than the newest successful poll (CONNCAND) and newer than
            # the last transfer. Fewer = HELD: the flow stays green (the
            # went-kaput evidence still lists it as trouble after success).
            # Evidence of any other kind, or a newer line, flips as before.
            due = (bdt != "" && bdt > ct && !((k in pt) && pt[k] > bdt))
            held = 0
            if (due && (k in UC3)) {
                # is the newest evidence a connection failure? The flow'\''s own
                # line (its stamp is in the CONNCAND set — the attributed ring
                # lines name the flow, so theirs are the same stamps), or the
                # loose connected-ring line classified as one (a sibling flow
                # failing on the shared host: the same endpoint, but THIS
                # flow'\''s own polls decide its streak).
                iscf = ((k SUBSEP bdt) in cfset) || ((k in KF) && KF[k] == bdt && KFC[k] == 1)
                if (iscf) {
                    n3 = 0; m3 = split(substr(CFL[k], 2), Z3, SUBSEP)
                    for (i3 = 1; i3 <= m3; i3++) if (Z3[i3] > ct && Z3[i3] > CFP[k]) n3++
                    if (n3 < 3) {
                        # DISCOUNT the connection failures: the newest of the
                        # remaining evidence decides, by the same test
                        b2 = ENCF[k]
                        if ((k in RA) && !((k SUBSEP RA[k]) in cfset) && RA[k] > b2) b2 = RA[k]
                        if ((k in KF) && KFC[k] != 1 && KF[k] > b2) b2 = KF[k]
                        if (b2 != "" && b2 > ct && !((k in pt) && pt[k] > b2)) { bdt = b2; disc = 1 }
                        else held = 1
                    }
                }
            }
            if (due && !held) {
                r = "red"
                # SINCE: the OLDEST evidence line still in force — newer than
                # the cut, not superseded by a newer successful poll (the
                # green-keep), and no connection failure the streak rule
                # discounted (disc: the evidence decided without them)
                sn = bdt; m6 = split(substr(EVL, 2), Z6, "|")
                for (i6 = 1; i6 <= m6; i6++) { t6 = Z6[i6]
                    if (t6 == "" || t6 <= ct || t6 >= sn) continue
                    if ((k in pt) && pt[k] > t6) continue
                    if (disc && (((k SUBSEP t6) in cfset) || ((k in KF) && KFC[k] == 1 && KF[k] == t6))) continue
                    sn = t6 }
                print $1 "\t" bdt "\t" sn > rf   # the _redflip sidecar: name, newest evidence, SINCE
            }
        }
        # A UC3 THAT NEVER TRANSFERRED AND CANNOT CONNECT (2026-09-10, user
        # rule): no File at all, but its own polls fail — "Connection failure
        # while <flow> tried to connect …" — on THREE POLLS IN A ROW: three
        # connection failures newer than its newest successful poll, or with
        # no successful poll at all. Orange would read "never seen", but
        # a flow that polls and cannot connect is BROKEN, not idle: RED, with
        # the newest failure as the evidence stamp (the _redflip sidecar), so
        # Failed Subscriptions lists it under the server-log failures and its
        # error page shows the failures; its SINCE is the OLDEST failure of the
        # streak — from the whole server cache (CCSINCE), else the oldest the
        # mention caches still hold. The same three-in-a-row threshold as
        # the streak rule above — one or two failed polls are a blip.
        if (!(k in oc) && (k in UC3) && (k in CFL)) {
            n4 = 0; b4 = ""; o4 = ""; m4 = split(substr(CFL[k], 2), Z4, SUBSEP)
            for (i4 = 1; i4 <= m4; i4++) if (Z4[i4] != "" && (CFP[k] == "" || Z4[i4] > CFP[k])) { n4++; if (Z4[i4] > b4) b4 = Z4[i4]; if (o4 == "" || Z4[i4] < o4) o4 = Z4[i4] }
            if (n4 >= 3) { r = "red"; if ((k in CCS) && CCS[k] <= b4) o4 = CCS[k]; print $1 "\t" b4 "\t" o4 > rf }
        }
        # (no UC3 clean-poll GREEN since 2026-09-28, user rule: a UC3 with no
        # transfers is orange — or red by the cannot-connect rule above)
        print $1 "\t" $2 "\t" r
    }
' "$FILES" "$POLLCAND" "$RINGATTR" "$KAPUTFLIP" "$CONNCAND" "$CCSINCE" "$BASE/_subscriptions.tsv" > "$BASE/_subscriptions.tsv.tmp"
commit_tmp "$BASE/_subscriptions.tsv"
[ -f "$REDFLIP.tmp" ] || : > "$REDFLIP.tmp"   # no flips: an empty (not absent) sidecar
commit_tmp "$REDFLIP"
rm -f "$POLLCAND" "$CONNCAND" "$CCAND" "$CCSINCE"

# ---- stage 2: everything else, rolled up from its subscriptions ------------
# For each other base file, join its _<item>-subscriptions.tsv pair cache
# (col 1 = the entity, col 2 = a connected subscription) against the results
# just computed: all green -> green, any red -> red, else orange (an entity
# with no connected subscriptions stays orange). $3 (optional) = the OBSERVED
# pairs of the subscriptions the config does not know (see the header): they
# join the configured pairs — a discovered subscription has none of its own,
# so its account / login / host would otherwise ignore it (2026-09-29 audit:
# an account whose 127 Files all failed on its UCx_<account> flow was orange;
# since UCx went the same day those Files read subscription "Unknown", which
# colours nothing — the Unknown transfers report lists them).
rollup() {   # $1 = base name (accounts|logins|...)  $2 = its <item>-subscriptions pair cache  $3 = observed pairs (optional)
    local basef="$BASE/_$1.tsv" pair="$XREF/_$2.tsv" obs="${3:-/dev/null}"
    [ -f "$basef" ] || return 0
    [ -f "$obs" ] || obs=/dev/null
    [ -f "$pair" ] || pair=/dev/null
    awk -F'\t' '
        FILENAME == ARGV[1] { sres[toupper($1)] = $3; next }            # subscription -> its result
        FILENAME == ARGV[2] || FILENAME == ARGV[3] {                   # entity -> connected subscriptions (configured, then observed)
            k = toupper($1); u = toupper($2)
            if (!(u in sres) || sres[u] == "" || ((k SUBSEP u) in dup)) next   # unknown subscription: ignore; a pair once
            dup[k SUBSEP u] = 1; s = sres[u]
            n[k]++
            if (s == "green") g[k]++
            else if (s == "red") rd[k]++                               # only REAL transfer data colours the rollup
            next
        }
        {
            k = toupper($1)
            r = "orange"
            if ((k in rd) && rd[k] > 0) r = "red"
            else if ((k in n) && n[k] > 0 && g[k] == n[k]) r = "green"
            print $1 "\t" $2 "\t" r
        }
    ' "$BASE/_subscriptions.tsv" "$pair" "$obs" "$basef" > "$basef.tmp"
    commit_tmp "$basef"
}
# The same own-transfer rule for a host with NO connected subscriptions — in
# practice only one discovered by stage 0, since every configured host is in the
# pair cache. Without it the rollup calls a host that has moved files "never
# seen". Reads the last OUT-connection File per host from HOSTLEGS (every leg
# host of such a File, since 2026-09-28), the population the remote-host
# report counts.
host_own_unpaired() {
    local basef="$BASE/_hosts.tsv" pair="$XREF/_hosts-subscriptions.tsv"
    [ -f "$basef" ] || return 0
    [ -f "$pair" ] || pair=/dev/null
    awk -F'\t' '
        FILENAME == ARGV[1] { if ($1 != "") P[toupper($1)] = 1; next }         # entity -> has connected subscription(s)
        FILENAME == ARGV[2] { if ($2 != "") {                                   # the last OUT-connection File per host
                                  k = toupper($1)
                                  if ($2 >= sk[k]) { sk[k] = $2; oc[k] = $3 } }
                              next }
        { k = toupper($1)
          # Expired-last = ORANGE, like the subscription rule (2026-09-28 fix:
          # this and white_own still said red, from before 2026-08)
          if (!(k in P) && (k in oc)) $3 = (oc[k] == "Failed") ? "red" : (oc[k] == "Expired") ? "orange" : "green"
          print $1 "\t" $2 "\t" $3 }
    ' "$pair" "$HOSTLEGS" "$basef" > "$basef.tmp"
    commit_tmp "$basef"
}
# the whitelist exception: an IP is colored by ITS OWN transfers (the last
# real transfer with that remote host), never by its partner's flows
white_own() {
    local basef="$BASE/_white.tsv"
    [ -f "$basef" ] || return 0
    awk -F'\t' '
        FILENAME == ARGV[1] {
            h = $15
            if (h != "" && $6 != "" && $6 >= sk[h]) { sk[h] = $6; oc[h] = $2 }
            next
        }
        {
            r = "orange"
            if ($1 in oc) r = (oc[$1] == "Failed") ? "red" : (oc[$1] == "Expired") ? "orange" : "green"   # Waiting-last = green; Expired-last = orange (like the subscription rule)
            print $1 "\t" $2 "\t" r
        }
    ' "$FILES" "$basef" > "$basef.tmp"
    commit_tmp "$basef"
}

rollup accounts accounts-subscriptions "$OBS_ACC"
rollup logins   logins-subscriptions   "$OBS_LGN"
rollup hosts    hosts-subscriptions    "$OBS_HST"
# A host DISCOVERED in the transfer log (stage 0) has no configured
# subscriptions, so the rollup above leaves it ORANGE — "never seen", which is
# false: it is here precisely because files went through it. Colour those by
# their OWN transfers instead, the rule white_own() already applies to a
# whitelisted address. Scoped to hosts absent from the pair cache, so no
# configured host can change colour (all 78 acceptance hosts are in it).
host_own_unpaired
white_own
# PRUNE the estate of withdrawn discoveries (2026-08). Stage 0 above APPENDS
# the entities the transfer log revealed, and nothing ever removed one whose
# evidence went away: the row settled as ORANGE, a phantom "configured but
# never seen" flow that is not configured at all, inflating every estate
# figure. A row survives when it is CONFIGURED (the export snapshot
# flow-manager takes before stage 0 appends) or backed by real transfer data.
# Nothing else is an entity. (Until 2026-09-27 the server-log BLUE step
# appended too; the first run after its removal prunes what it left behind.)
prune_withdrawn() {   # $1 = base name  $2 = the _files.tsv column (0 = no own data)
    local basef="$BASE/_$1.tsv" conf="$BASE/.configured.tsv" legs=/dev/null
    [ -f "$basef" ] || return 0
    # a HOST is also backed by a leg of an OUT-connection File (HOSTLEGS, the
    # discovery population — 2026-09-28), not only by a File's first host
    [ "$1" = hosts ] && legs="$HOSTLEGS"
    awk -F'\t' -v L="_$1" -v C="$2" '
        FILENAME == ARGV[1] { if ($1 == L && $2 != "") CONF[toupper($2)] = 1; next }
        FILENAME == ARGV[2] { if (C + 0 > 0 && $C != "") HAS[toupper($C)] = 1; next }
        FILENAME == ARGV[3] { if ($1 != "") HAS[toupper($1)] = 1; next }
        { k = toupper($1)
          if ((k in CONF) || (k in HAS)) { print; next }
          n++ }
        END { if (n) printf "result.sh: pruned %d withdrawn discover(y/ies) from base/_%s.tsv.\n", n, "'"$1"'" > "/dev/stderr" }
    ' "$conf" "$FILES" "$legs" "$basef" > "$basef.tmp"
    commit_tmp "$basef"
}
prune_withdrawn subscriptions 12
prune_withdrawn hosts         15
prune_withdrawn accounts       3
prune_withdrawn logins        14

# The ring owner keeps the Error lines nothing can pin on a flow (2026-08).
# Attribution gives a connected-ring error to the ONE subscription it concerns;
# what is left over — an authentication failure naming only a credential, a
# PeSIT transfer-profile complaint naming only the account, a connection the
# far end refused — is a real problem at that ENDPOINT / account / login, and
# with no flow to carry it the entity itself must. RED unless it has moved a
# file OK since: a later OK transfer says the problem is over, exactly the
# "recovered since" test the unresolved server reports apply. E-level only
# (colour/_ringorphan.tsv holds no warnings) and it never touches a row that is
# already red.
orphan_red() {   # $1 = base/ring name (hosts|accounts|logins)  $2 = its _files.tsv column, or "legs" = HOSTLEGS (the hosts rule)
    local basef="$BASE/_$1.tsv" src="$FILES"
    [ -f "$basef" ] || return 0
    [ -s "$RINGORPH" ] || return 0
    # a HOST recovers through ANY leg host of an OUT-connection File — the
    # population the host rows are (HOSTLEGS: col 1 host, col 3 outcome,
    # col 5 the File END), not only the File first host (col 15) — 2026-09-29
    [ "$2" = legs ] && src="$HOSTLEGS"
    awk -F'\t' -v K="$1" -v C="$2" '
        FILENAME == ARGV[1] { if ($1 == K && $2 != "") ORPH[toupper($2)] = $3; next }   # name -> newest orphan Error
        FILENAME == ARGV[2] {                                                          # the last OK file per entity
            if (C == "legs") { e = toupper($1); oc = $3; t = $5 }
            else { e = ($C != "") ? toupper($C) : ""; oc = $2; t = ($24 != "") ? $24 : $4 " " $5 }   # the File END (col 24, 2026-09-12): finished OK after the error = recovered
            if (e != "" && oc != "Failed" && oc != "Expired" && t > ok[e]) ok[e] = t
            next }
        { e = toupper($1)
          if ((e in ORPH) && $3 != "red" && !((e in ok) && ok[e] > ORPH[e])) { $3 = "red"; n++ }
          print $1 "\t" $2 "\t" $3 }
        END { if (n) printf "result.sh: %d %s row(s) reddened by server Errors no flow could claim.\n", n, K > "/dev/stderr" }
    ' "$RINGORPH" "$src" "$basef" > "$basef.tmp"
    commit_tmp "$basef"
}

orphan_red hosts    legs
orphan_red accounts  3
orphan_red logins   14
rollup logicals logicals-subscriptions
rollup partners partners-subscriptions
rollup apps     apps-subscriptions
rollup domains  domains-subscriptions
rollup bl       bl-subscriptions

# ---- report ------------------------------------------------------------------
for f in subscriptions accounts logins hosts white logicals partners apps domains bl; do
    [ -f "$BASE/_$f.tsv" ] || continue
    awk -F'\t' -v n="$f" '{ c[$3]++ } END { printf "  _%s.tsv: %d green, %d red, %d orange, %d unknown\n", n, c["green"]+0, c["red"]+0, c["orange"]+0, c["unknown"]+0 }' "$BASE/_$f.tsv" >&2
done
echo "result.sh: result column filled for the 10 base caches." >&2
