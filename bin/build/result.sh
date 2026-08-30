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
#     seen, last transfer Processed         -> green
#     seen, last transfer not Processed     -> red
#     seen, last transfer OK but the server log holds an Error/Warn line
#     NEWER than it                         -> red   (2026-08: a flow with
#     "ERRORS IN SERVER LOG AFTER LAST TRANSFER" on its detail page cannot
#     be green; the evidence is the subscription's own _err_warn ring plus
#     every connected host/account/login ring LINE the attribution below
#     pins on this flow — never a connected ring wholesale)
#
# Stage 2 — every OTHER base file, rolled up from its connected subscriptions
# via the data/flow-manager/xref/_<item>-subscriptions.tsv pair caches:
#     all connected subscriptions green     -> green
#     one or more red                       -> red
#     everything else (incl. no connected
#     subscriptions at all)                 -> orange
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
source "$ROOT/bin/env.sh"       # resolve $AXWAY_ENV (acceptance|production, default acceptance)

BASE="$ROOT/data/$AXWAY_ENV/flow-manager/base"
XREF="$ROOT/data/$AXWAY_ENV/flow-manager/xref"
FILES="$ROOT/data/$AXWAY_ENV/transfer/cache/_files.tsv"
UNK="$ROOT/data/$AXWAY_ENV/unknown"
# SSH-logon-seen names (bin/build/seen-in-server-log.sh Step F0): a login/account/IP still
# ORANGE after the rollup below, named in the server SSH-logon lines, AND with no
# real transfer data (no green/red connected subscription) is server-log-only ->
# blue. A MIXED entity that DID transfer on some subscription stays orange, so a
# blue entity never carries a Last transfer.
LOGON_A="$UNK/logon-accounts.tsv"; LOGON_L="$UNK/logon-logins.tsv"; LOGON_I="$UNK/logon-ips.tsv"

[ -f "$BASE/_subscriptions.tsv" ] || { echo "result.sh: no $BASE/_subscriptions.tsv (run bin/flow-manager.sh first) — nothing to do." >&2; exit 0; }

# cmp-guarded commit (the seen-in-server-log.sh pattern): a no-change run must keep
# the base caches' mtimes, or every downstream skip_if_fresh/ensure_parsed
# that watches them re-runs on every build (details rpts, the server
# per-entity mention rescan, cross-reference, the unknown-* reports, ...).
commit_tmp() {   # $1 = final path; expects $1.tmp
    if cmp -s "$1.tmp" "$1" 2>/dev/null; then rm -f "$1.tmp"; else mv "$1.tmp" "$1"; fi
}
[ -f "$FILES" ] || { echo "result.sh: no $FILES (run bin/transfer/parse.sh first) — nothing to do." >&2; exit 0; }

# ---- the UC3 clean-poll rule (2026-08) --------------------------------------
# A UC3 subscription the server log shows POLLING SUCCESSFULLY — "Applying the
# search pattern … for transfer site '…': N file(s) …" — with no NEWER E-level
# mention is WORKING from our point of view, even when there was never a file
# to fetch. It has no transfer rows, so stage 1 would leave it blue: flip it
# GREEN instead. data/<env>/blue/_greenpoll.tsv records the names stage 1
# actually FLIPPED (candidates with real transfers stay untouched and out of
# it) — the evidence block below keeps those detail pages' server-log card.
# Source: the per-name server mention caches (last 25 rows + last 10
# Error/Warn per subscription, bin/server/parse.sh) — present once the server
# parse ran; a missing dir just leaves the list empty.
SUBMENT="$ROOT/data/$AXWAY_ENV/server/cache/subscriptions"
BLUEDIR="$ROOT/data/$AXWAY_ENV/blue"
POLLOK="$BLUEDIR/_greenpoll.tsv"
POLLCAND="$BLUEDIR/_greenpoll.cand"   # candidates; stage 1 writes the final list
# The red-flip sidecar (2026-08): every subscription the after-last-transfer
# rule below flips green -> red, with the ring evidence stamp that did it
# (name <TAB> "YYYY-MM-DD HH:MM:SS…"). The UC status per-hour walkers
# (uc{1,3,4}-status.sh) read it so their sidecars apply the same flip at the
# evidence hour — the last sidecar row must equal the report's STAT figures.
REDFLIP="$BLUEDIR/_redflip.tsv"
mkdir -p "$BLUEDIR"
{
    if [ -d "$SUBMENT" ]; then
        for _pf in "$SUBMENT"/UC3*.tsv; do
            [ -f "$_pf" ] || continue
            case $_pf in *_err_warn.tsv) continue ;; esac   # the per-name Error/Warn RING file, not a subscription's mention cache
            awk -F'\t' -v n="$(basename "$_pf" .tsv)" '
                $5 ~ /Applying the search pattern/ && $5 ~ /for transfer site/ && $5 ~ /file\(s\)/ { t = $1 " " $2; if (t > p) p = t }
                $3 == "E" { t = $1 " " $2; if (t > e) e = t }
                # name <TAB> newest successful poll <TAB> 1 when no E-level
                # mention is newer. The FLAG drives the blue rule (a UC3 that
                # never transferred); the STAMP drives the green-keep below,
                # where the comparison is against the red-flip evidence rather
                # than against E-level mentions.
                END { if (p != "") printf "%s\t%s\t%d\n", n, p, (p >= e ? 1 : 0) }
            ' "$_pf"
        done
    fi
} > "$POLLCAND"

# ---- stage 0: entities DISCOVERED in the transfer log ----------------------
# A subscription (or remote host) can carry real transfers and still be absent
# from the FlowManager export — a flow configured after the export was taken.
# The entity reports list it (they read the parse cache), so the Entities view
# shows a row for it, but the base cache has no entry: the home figure counts
# the base cache and the view footer counts the rows, and the two disagree.
# bin/build/publish.sh's check_status_consistency catches exactly that.
#
# So the transfer log DISCOVERS entities as well, the way the server log
# already does (bin/build/seen-in-server-log.sh appends its unknown names as
# blue). These are not blue — they have transferred — so they are appended
# with an EMPTY result and coloured below like any other row: a subscription by
# stage 1, a host by the own-transfer rule after the rollups.
#
# The two rosters MIRROR the reports that list them, which is what keeps the
# figures equal:
#   subscriptions  every dest_site (col 12) in _files.tsv
#   hosts          the host (col 15) of an OUT-side file (col 16) — the same
#                  restriction bin/transfer/reports/remote-host.sh applies, so
#                  the raw INCOMING addresses that never reach that report are
#                  not invented as entities here either.
discover_logged() {   # $1 = base name  $2 = the awk condition picking its column
    local basef="$BASE/_$1.tsv" n
    [ -f "$basef" ] || return 0
    n=$(awk -F'\t' -v COND="$2" -v BF="$basef" '
        BEGIN { while ((getline l < BF) > 0) { split(l, a, "\t"); if (a[1] != "") B[toupper(a[1])] = 1 }
                close(BF) }
        { v = (COND == "sub") ? $12 : (($16 == "out") ? $15 : "") }
        v != "" && !(toupper(v) in B) && !(toupper(v) in seen) { seen[toupper(v)] = 1; ord[++n] = v }
        END { for (i = 1; i <= n; i++) print ord[i] "\t\t" }
    ' "$FILES" | LC_ALL=C sort)
    [ -n "$n" ] || return 0
    # append and re-sort nothing: the base caches are name-ordered as written by
    # flow-manager.sh, and the colour passes below rewrite them line by line, so
    # the new rows simply join at the end (cmp-guarded like every other write)
    { cat "$basef"; printf '%s\n' "$n"; } > "$basef.tmp" && commit_tmp "$basef"
    printf 'result.sh: %s discovered in the transfer log, appended to %s.\n' \
        "$(printf '%s\n' "$n" | wc -l | tr -d ' ')" "base/_$1.tsv" >&2
    # the per-entity server MENTION caches were built before this step and do
    # not know the new names — their detail pages would lose the server-log
    # table. The same marker seen-in-server-log.sh drops for an appended name;
    # bin/build.sh rescans once, right after this step.
    : > "$ROOT/data/$AXWAY_ENV/server/cache/.rescan-mentions" 2>/dev/null || true
}
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
# RED on the home worklist rather than green beside it.
IPH_P="$ROOT/input/$AXWAY_ENV/ip/ip-hosts.tsv"; [ -f "$IPH_P" ] || IPH_P=/dev/null
TRANSFERS="$ROOT/data/$AXWAY_ENV/transfer/cache/_transfers.tsv"
SRVC="$ROOT/data/$AXWAY_ENV/server/cache"
source "$ROOT/bin/renames.sh"   # rn_canon_pfx: the log names a flow as it was called THEN

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
RINGATTR="$BLUEDIR/_ringattr.tsv"    # subscription <TAB> newest attributed E-level stamp
RINGORPH="$BLUEDIR/_ringorphan.tsv"  # ring kind <TAB> name <TAB> newest E-level line attributable to NO flow
_build_ringattr() {
    local rings=() f tmp
    for f in "$SRVC"/hosts/*_err_warn.tsv "$SRVC"/accounts/*_err_warn.tsv "$SRVC"/logins/*_err_warn.tsv; do
        [ -e "$f" ] && rings+=("$f")
    done
    if [ ${#rings[@]} -eq 0 ]; then
        : > "$RINGATTR.tmp"; commit_tmp "$RINGATTR"
        : > "$RINGORPH.tmp"; commit_tmp "$RINGORPH"
        return 0
    fi
    tmp=$(mktemp "${TMPDIR:-/tmp}/axrattr.XXXXXX")
    # pass 1: the message names it. Emits N (named), S (session to resolve) or
    # X (neither — SSHD/PESITD records carry no session at all): tag, stamp,
    # subscription-or-session, level, ring kind, ring name. A forward-address
    # ring belongs to its ENDPOINT (ip-hosts.tsv), so its residue lands there.
    awk -F'\t' -v RNF="$RENAMES_FILE" -v IPH="$IPH_P" "$RENAMES_AWK"'
        BEGIN { rn_load(RNF)
                while ((getline l < IPH) > 0) { n = split(l, a, "\t"); if (n >= 2 && a[1] != "") ipm[a[1]] = tolower(a[2]) }
                close(IPH) }
        FNR == 1 { nm = FILENAME; sub(/_err_warn\.tsv$/, "", nm)
                   kind = nm; sub(/\/[^\/]*$/, "", kind); sub(/.*\//, "", kind)
                   sub(/.*\//, "", nm)
                   if (kind == "hosts" && (nm in ipm)) nm = ipm[nm] }
        { st = $1 " " $2
          if (match($5, /UC[0-9]+[_-][A-Za-z0-9_-]+/)) {
              t = substr($5, RSTART, RLENGTH); sub(/_(SS?|C)CP_.*$/, "", t)
              print "N\t" st "\t" rn_canon_pfx(t) "\t" $3 "\t" kind "\t" nm; next }
          if ($6 != "") { print "S\t" st "\t" $6 "\t" $3 "\t" kind "\t" nm; next }
          print "X\t" st "\t-\t" $3 "\t" kind "\t" nm }
    ' "${rings[@]}" > "$tmp.raw"
    : > "$tmp.map"
    if command grep -q "^S" "$tmp.raw" 2>/dev/null; then
        awk -F'\t' '$1 == "S" { print $3 }' "$tmp.raw" | LC_ALL=C sort -u > "$tmp.sess"
        # pass 2: ONE pass over the parse cache for those sessions only
        if [ -f "$SRVC/_parse.tsv" ]; then
            awk -F'\t' -v SF="$tmp.sess" -v RNF="$RENAMES_FILE" "$RENAMES_AWK"'
                BEGIN { while ((getline l < SF) > 0) S[l] = 1; close(SF); rn_load(RNF) }
                ($6 in S) && match($5, /UC[0-9]+[_-][A-Za-z0-9_-]+/) {
                    t = substr($5, RSTART, RLENGTH); sub(/_(SS?|C)CP_.*$/, "", t); t = rn_canon_pfx(t)
                    if (!(($6) in got)) { got[$6] = t; print $6 "\t" t }
                    else if (got[$6] != t) got[$6] = "\001" }   # a session naming two flows resolves to neither
                END { for (k in got) if (got[k] == "\001") print k "\t\001" }
            ' "$SRVC/_parse.tsv" | LC_ALL=C sort -u > "$tmp.map"
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
    awk -F'\t' -v MAP="$tmp.map" -v ORPH="$RINGORPH.tmp" '
        BEGIN { while ((getline l < MAP) > 0) { n = split(l, a, "\t")
                    if (n >= 2 && a[2] != "\001") M[a[1]] = a[2]; else if (n >= 2) M[a[1]] = "" }
                close(MAP) }
        $1 == "N" { sub_ = $3 }
        $1 == "S" { sub_ = ($3 in M) ? M[$3] : "" }
        $1 == "X" { sub_ = "" }
        # ERRORS ONLY, like ringmax below: the map feeds the red flip, and a
        # Warning must not flip a flow red ($4 carries the ring line level)
        sub_ != "" && $4 == "E" { k = toupper(sub_); if ($2 > mx[k]) { mx[k] = $2; nm[k] = sub_ }; next }
        sub_ != "" { next }   # attributed Warning: neither flip evidence nor an orphan
        # UNATTRIBUTABLE and E-level: the ring owner keeps it (see orphan_red).
        # Warnings are left out — "Error" is the E level site-wide, and the
        # W-level orphans are all the benign "Transfer site ID is not present
        # in environment" shape.
        $4 == "E" { o = $5 "\t" $6; if ($2 > omx[o]) omx[o] = $2 }
        END { for (k in mx) printf "%s\t%s\n", nm[k], mx[k]
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
# them, attribution or not — is failing, and the home page must show it red
# (the user's call, 2026-08-22: an early warning on the failing worklist IS a
# failing flow). Two exceptions, the same two the home early-warning table
# applied: the flow whose NEWEST connected E line classifies as a DEPLOY
# defect (Route stopped / Receive File As not set — a config mistake, its
# report is Deploy errors) contributes NOTHING here and stays green; and the
# UC3 clean-poll keep still applies in the flip below, so a flow that has
# polled cleanly since stays green. The subscription's OWN ring is already in
# bdt via ringmax; this file carries only the connected-ring side. Host rings
# join only for a single-host flow (two hosts = unattributable, as
# everywhere), the endpoint's forward addresses included.
KAPUTFLIP="$BLUEDIR/_kaputflip.tsv"   # subscription <TAB> newest connected-ring E stamp (deploy-classified flows absent)
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
    # pass 1: each ring's newest E line -> "kind <TAB> name <TAB> stamp <TAB> message"
    awk -F'\t' '
        FNR == 1 { fdone = 0
            nm = FILENAME; sub(/_err_warn\.tsv$/, "", nm)
            kind = (nm ~ /\/accounts\//) ? "A" : (nm ~ /\/logins\//) ? "L" : "H"
            sub(/^.*\//, "", nm) }
        !fdone && $3 == "E" && NF >= 5 { printf "%s\t%s\t%s\t%s\n", kind, nm, $1 " " $2, substr($5, 1, 200); fdone = 1 }
    ' "${rings[@]}" > "$tmp"
    # pass 2: join per subscription (newest across its connected rings),
    # classify that ONE newest message, drop the deploy verdicts
    awk -F'\t' -v RINGS="$tmp" "$(cat "$ROOT/bin/flip-reason.awk")"'
        FILENAME == RINGS { re[$1 SUBSEP $2] = $3; rm[$1 SUBSEP $2] = $4; next }
        FILENAME ~ /_subscriptions-accounts\.tsv$/ { if ($1 != "" && $2 != "") SA[$1] = SA[$1] SUBSEP $2; next }
        FILENAME ~ /_subscriptions-logins\.tsv$/   { if ($1 != "" && $2 != "") SL[$1] = SL[$1] SUBSEP $2; next }
        FILENAME ~ /_subscriptions-hosts\.tsv$/    { if ($1 != "" && $2 != "") { nh[$1]++; vh[$1] = tolower($2) }; next }
        FILENAME ~ /ip-hosts\.tsv$/ { if ($1 != "" && $2 != "") fw[tolower($2)] = fw[tolower($2)] SUBSEP $1; next }
        # base/_subscriptions.tsv: the roster
        {
            s = $1; if (s == "") next
            best = ""; msg = ""
            n = split(substr(SA[s], 2), Z, SUBSEP)
            for (i = 1; i <= n; i++) { k = "A" SUBSEP Z[i]; if ((k in re) && re[k] > best) { best = re[k]; msg = rm[k] } }
            n = split(substr(SL[s], 2), Z, SUBSEP)
            for (i = 1; i <= n; i++) { k = "L" SUBSEP Z[i]; if ((k in re) && re[k] > best) { best = re[k]; msg = rm[k] } }
            if (nh[s] + 0 == 1) {
                h = vh[s]
                k = "H" SUBSEP h; if ((k in re) && re[k] > best) { best = re[k]; msg = rm[k] }
                n = split(substr(fw[h], 2), Z, SUBSEP)
                for (i = 1; i <= n; i++) { k = "H" SUBSEP tolower(Z[i]); if ((k in re) && re[k] > best) { best = re[k]; msg = rm[k] } }
            }
            if (best == "") next
            r = flip_reason(msg)
            if (r == "Route stopped" || r == "Receive File As not set") next
            printf "%s\t%s\n", s, best
        }
    ' "$tmp" "$_kfsa" "$_kfsl" "$_kfsh" "$IPH_P" "$BASE/_subscriptions.tsv" \
    | LC_ALL=C sort > "$KAPUTFLIP.tmp"
    rm -f "$tmp"
    commit_tmp "$KAPUTFLIP"
}
_build_kaputflip
[ -f "$KAPUTFLIP" ] || : > "$KAPUTFLIP"
[ -f "$RINGORPH" ] || : > "$RINGORPH"

awk -F'\t' -v gp="$POLLOK.tmp" -v rf="$REDFLIP.tmp" -v srvc="$SRVC" '
    # raise bdt to ring file f'\''s newest E-LEVEL line "date time" when newer
    # (the per-name rings are newest-first, so the first E met is the newest;
    # a missing file reads nothing). ERRORS ONLY (2026-08): a Warning must not
    # flip a flow red — the warnings-only shape was the benign "Transfer site
    # ID is not present in environment", which has its own report, and
    # went-kaput applies the same errors-only rule to its page.
    function ringmax(f,   l2, b2, n2) {
        while ((getline l2 < f) > 0) {
            n2 = split(l2, b2, "\t")
            if (n2 >= 3 && b2[3] == "E") {
                if (b2[1] " " b2[2] > bdt) bdt = b2[1] " " b2[2]
                break
            }
        }
        close(f)
    }
    FILENAME == ARGV[1] {
        s = toupper($12)
        if (s != "" && $6 != "" && $6 >= sk[s]) { sk[s] = $6; oc[s] = $2; lt[s] = $4 " " $5 }
        next
    }
    FILENAME == ARGV[2] { if ($1 != "") { if ($3 + 0 == 1) po[toupper($1)] = 1   # blue -> green (never transferred)
                                          if ($2 != "") pt[toupper($1)] = $2 }   # newest successful poll, for the green-keep
                          next }   # UC3 clean-poll candidates (see above)
    FILENAME == ARGV[3] { if ($1 != "" && $2 != "") RA[toupper($1)] = $2; next }   # subscription -> newest connected-ring Error attributed to it
    FILENAME == ARGV[4] { if ($1 != "" && $2 != "") KF[toupper($1)] = $2; next }   # subscription -> newest LOOSE connected-ring Error (the went-kaput join; deploy-classified flows absent)
    {
        k = toupper($1)
        r = "orange"; expd = 0   # expd, not exp: exp() is an awk BUILT-IN
        # EXPIRED-LAST IS ORANGE, NOT RED (2026-08). A staged UC2 copy the
        # partner never collected and the retention sweep deleted is a PICKUP
        # problem, not a delivery failure: nothing errored, the file aged out.
        # It still counts as an Error everywhere the OUTCOME POLICY applies
        # (CLAUDE.md: Error = Failed || Expired) — this is the entity COLOUR
        # only, so the flow leaves the red worklist while the Expired report
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
            bdt = ""
            ringmax(srvc "/subscriptions/" $1 "_err_warn.tsv")
            # the connected host/account/login rings contribute only the lines
            # ATTRIBUTED to THIS subscription (see _build_ringattr): each of
            # those entities serves other flows too, and one of its errors must
            # redden the flow it actually concerns — never the whole set.
            if ((k in RA) && RA[k] > bdt) bdt = RA[k]
            # ... plus the LOOSE connected-ring evidence (2026-08-22): the
            # went-kaput join promoted to the colour — see _build_kaputflip.
            # Deploy-classified flows are absent from that file by design.
            if ((k in KF) && KF[k] > bdt) bdt = KF[k]
            # A UC3 that has POLLED CLEANLY SINCE that Error/Warn is working:
            # "0 file(s) were found of which 0 matched the pattern" is a
            # successful poll with nothing to fetch, and it is the newest
            # thing the log says about the flow. The same evidence the blue
            # rule above trusts for a UC3 that never transferred, applied to
            # one that has: the flip is skipped and the subscription stays
            # green (2026-08).
            if (bdt != "" && bdt > lt[k] && !((k in pt) && pt[k] > bdt)) { r = "red"; print $1 "\t" bdt > rf }   # record the flip + its evidence stamp (the _redflip sidecar)
        }
        if ($3 == "blue" && r == "orange") r = "blue"   # preserve the server-log-only marking ONLY over orange — an entity whose own data says green/red is already seen (bin/build/seen-in-server-log.sh runs first)
        # The UC3 clean-poll rule: polling verified working, simply nothing
        # to fetch. It fires on ORANGE as well as BLUE (2026-08): the blue
        # marking is no longer a precondition, because seen-in-server-log.sh
        # now leaves these rows alone to stop the two steps rewriting the
        # base caches on every build. The evidence is unchanged — `po` is
        # recomputed from the mention caches each run.
        if ((r == "blue" || r == "orange") && (k in po)) { r = "green"; print $1 > gp }
        print $1 "\t" $2 "\t" r
    }
' "$FILES" "$POLLCAND" "$RINGATTR" "$KAPUTFLIP" "$BASE/_subscriptions.tsv" > "$BASE/_subscriptions.tsv.tmp" \
    && commit_tmp "$BASE/_subscriptions.tsv"
[ -f "$POLLOK.tmp" ] || : > "$POLLOK.tmp"   # no flips: an empty (not absent) sidecar
commit_tmp "$POLLOK"
[ -f "$REDFLIP.tmp" ] || : > "$REDFLIP.tmp"   # same rule for the red-flip sidecar
commit_tmp "$REDFLIP"
rm -f "$POLLCAND"

# ---- stage 2: everything else, rolled up from its subscriptions ------------
# For each other base file, join its _<item>-subscriptions.tsv pair cache
# (col 1 = the entity, col 2 = a connected subscription) against the results
# just computed: all green -> green, any red -> red, else orange (an entity
# with no connected subscriptions stays orange).
rollup() {   # $1 = base name (accounts|logins|...)  $2 = its <item>-subscriptions pair cache  $3 = optional SSH-logon-seen list (orange -> blue)
    local basef="$BASE/_$1.tsv" pair="$XREF/_$2.tsv" logon="${3:-/dev/null}"
    [ -f "$basef" ] || return 0
    [ -f "$logon" ] || logon=/dev/null
    if [ ! -f "$pair" ]; then
        awk -F'\t' '
            FILENAME == ARGV[1] { if ($1 != "#") lg[toupper($1)] = 1; next }
            { r = ($3=="blue" ? "blue" : "orange"); if ((toupper($1) in lg) && r=="orange") r="blue"; print $1 "\t" $2 "\t" r }
        ' "$logon" "$basef" > "$basef.tmp" && commit_tmp "$basef"
        return 0
    fi
    awk -F'\t' '
        FILENAME == ARGV[1] { if ($1 != "") gp[toupper($1)] = 1; next }   # the UC3 clean-poll greens (blue/_greenpoll.tsv)
        FILENAME == ARGV[2] { sres[toupper($1)] = $3; next }            # subscription -> its result
        FILENAME == ARGV[3] {                                          # entity -> connected subscriptions
            k = toupper($1); u = toupper($2); s = sres[u]
            # A CLEAN-POLL green counts like ORANGE here (2026-08): it is green
            # because the server log shows it POLLING, having moved no file at
            # all — the same reason a blue subscription counts like orange, and
            # the same doctrine (server-log discovery never sets a health
            # verdict). Letting it through made the rollup call an entity SEEN
            # that has never transferred, which seen-in-server-log.sh re-marked
            # blue on the next run: the two steps then rewrote the base caches
            # every build and every report reading them rebuilt for nothing.
            if (s == "green" && (u in gp)) s = "orange"
            if (s == "") next                                          # unknown subscription: ignore
            n[k]++
            if (s == "green") g[k]++
            else if (s == "red") rd[k]++                               # a BLUE (server-log-only) subscription counts like orange here: the blue discovery must never change a red/green health verdict — only REAL transfer data colors the rollup
            if (s == "green" || s == "red") hd[k] = 1                  # REAL transfer data behind this entity (blue/orange subs carry none)
            next
        }
        FILENAME == ARGV[4] { if ($1 != "#") lg[toupper($1)] = 1; next }   # SSH-logon-seen names (bin/build/seen-in-server-log.sh Step F0)
        {
            k = toupper($1)
            r = "orange"
            if ((k in rd) && rd[k] > 0) r = "red"
            else if ((k in n) && n[k] > 0 && g[k] == n[k]) r = "green"
            # preserve the own server-log-only marking ONLY when no connected
            # subscription has REAL data — an entity whose subs logged actual
            # files (green or real red) is already seen, so its rollup wins.
            if ($3 == "blue" && !(k in hd)) r = "blue"
            # SSH-logon evidence: a still-ORANGE login/account named in the
            # server SSH-logon lines is server-log-seen -> blue — but ONLY when it
            # has NO real transfer data (no green/red connected subscription).
            # A MIXED entity (orange only because SOME subscription is unseen, yet
            # it DID transfer on another) stays orange, so blue always means
            # "never transferred" — no blue row can carry a Last transfer.
            if ((k in lg) && r == "orange" && !(k in hd)) r = "blue"
            print $1 "\t" $2 "\t" r
        }
    ' "$POLLOK" "$BASE/_subscriptions.tsv" "$pair" "$logon" "$basef" > "$basef.tmp" && commit_tmp "$basef"
}
# An entity marked BLUE that nevertheless has files of its own: re-colour it by
# its own newest file (green/red), because blue asserts the opposite. $1 = base
# name, $2 = the _files.tsv column holding that entity (3 account, 12 dest_site,
# 14 login, 15 host). Touches ONLY blue rows, so nothing else can move.
blue_with_own_transfers() {   # $1 base name  $2 _files column
    local basef="$BASE/_$1.tsv"
    [ -f "$basef" ] || return 0
    awk -F'\t' -v C="$2" '
        FILENAME == ARGV[1] { if ($C != "" && $6 != "") { k = toupper($C)
                                  if ($6 >= sk[k]) { sk[k] = $6; oc[k] = $2 } }
                              next }
        { k = toupper($1)
          if ($3 == "blue" && (k in oc)) $3 = (oc[k] == "Failed" || oc[k] == "Expired") ? "red" : "green"
          print $1 "\t" $2 "\t" $3 }
    ' "$FILES" "$basef" > "$basef.tmp" && commit_tmp "$basef"
}
# The same own-transfer rule for a host with NO connected subscriptions — in
# practice only one discovered by stage 0, since every configured host is in the
# pair cache. Without it the rollup calls a host that has moved files "never
# seen". Reads the last OUT-side file per host (cols 15/16/6/2 of _files.tsv),
# the same population the remote-host report counts.
host_own_unpaired() {
    local basef="$BASE/_hosts.tsv" pair="$XREF/_hosts-subscriptions.tsv"
    [ -f "$basef" ] || return 0
    [ -f "$pair" ] || pair=/dev/null
    awk -F'\t' '
        FILENAME == ARGV[1] { if ($1 != "") P[toupper($1)] = 1; next }         # entity -> has connected subscription(s)
        FILENAME == ARGV[2] { if ($16 == "out" && $15 != "" && $6 != "") {     # the last OUT-side file per host
                                  k = toupper($15)
                                  if ($6 >= sk[k]) { sk[k] = $6; oc[k] = $2 } }
                              next }
        { k = toupper($1)
          if (!(k in P) && (k in oc)) $3 = (oc[k] == "Failed" || oc[k] == "Expired") ? "red" : "green"
          print $1 "\t" $2 "\t" $3 }
    ' "$pair" "$FILES" "$basef" > "$basef.tmp" && commit_tmp "$basef"
}
# the whitelist exception: an IP is colored by ITS OWN transfers (the last
# real transfer with that remote host), never by its partner's flows
white_own() {   # $1 = optional SSH-logon-seen source-IP list (orange -> blue)
    local basef="$BASE/_white.tsv" logon="${1:-/dev/null}"
    [ -f "$basef" ] || return 0
    [ -f "$logon" ] || logon=/dev/null
    awk -F'\t' '
        FILENAME == ARGV[1] {
            h = $15
            if (h != "" && $6 != "" && $6 >= sk[h]) { sk[h] = $6; oc[h] = $2 }
            next
        }
        FILENAME == ARGV[2] { if ($1 != "#") lg[$1] = 1; next }   # SSH-logon-seen source IPs (bin/build/seen-in-server-log.sh Step F0)
        {
            r = "orange"
            if ($1 in oc) r = (oc[$1] == "Failed" || oc[$1] == "Expired") ? "red" : "green"   # Waiting-last = green; Expired-last = red (like the subscription rule)
            if ($3 == "blue" && r == "orange") r = "blue"   # own data wins over the server-log marking
            if (($1 in lg) && r == "orange") r = "blue"     # SSH-logon-seen IP that never carried a real transfer -> blue
            print $1 "\t" $2 "\t" r
        }
    ' "$FILES" "$logon" "$basef" > "$basef.tmp" && commit_tmp "$basef"
}

rollup accounts accounts-subscriptions "$LOGON_A"
rollup logins   logins-subscriptions   "$LOGON_L"
rollup hosts    hosts-subscriptions
# A host DISCOVERED in the transfer log (stage 0) has no configured
# subscriptions, so the rollup above leaves it ORANGE — "never seen", which is
# false: it is here precisely because files went through it. Colour those by
# their OWN transfers instead, the rule white_own() already applies to a
# whitelisted address. Scoped to hosts absent from the pair cache, so no
# configured host can change colour (all 78 acceptance hosts are in it).
host_own_unpaired
white_own "$LOGON_I"
# BLUE MEANS "NEVER TRANSFERRED" (CLAUDE.md), so an entity with transfer rows of
# its own can never be blue — whatever the rollup made of its connected
# subscriptions. The rollup only sees a connected subscription's data (hd[]), so
# an entity whose own legs are logged but whose flows carry none kept a blue it
# had contradicted: one acceptance login (FE000509, 26 rows) sat blue in the
# Entities view AND in its Summary, which is what made the view list it twice.
# Colour those by their own last file, the white_own rule, per entity type.
# 2026-08: found when the profile rename fold restored ~64k attributions and the
# entity turned up seen; it is a latent contradiction, not a rename artefact.
# PRUNE the estate of withdrawn discoveries (2026-08). Both colour steps APPEND
# entities the logs revealed — seen-in-server-log.sh its blues, stage 0 above its
# transfer discoveries — and nothing ever removed one whose evidence went away:
# the row simply lost its blue and settled as ORANGE, a phantom "configured but
# never seen" flow that is not configured at all, inflating every estate figure.
# (One truncated server token folded correctly by a later rename rule left
# exactly that behind.) A row survives when it is CONFIGURED (the export
# snapshot flow-manager takes before either step appends), or still marked
# blue this run, or backed by real transfer data. Nothing else is an entity.
prune_withdrawn() {   # $1 = base name  $2 = the _files.tsv column (0 = no own data)
    local basef="$BASE/_$1.tsv" conf="$BASE/.configured.tsv"
    [ -f "$basef" ] || return 0
    [ -f "$conf" ] || return 0            # no snapshot yet: never prune blindly
    awk -F'\t' -v L="_$1" -v C="$2" '
        FILENAME == ARGV[1] { if ($1 == L && $2 != "") CONF[toupper($2)] = 1; next }
        FILENAME == ARGV[2] { if (C + 0 > 0 && $C != "") HAS[toupper($C)] = 1; next }
        { k = toupper($1)
          if ((k in CONF) || $3 == "blue" || (k in HAS)) { print; next }
          n++ }
        END { if (n) printf "result.sh: pruned %d withdrawn discover(y/ies) from base/_%s.tsv.\n", n, "'"$1"'" > "/dev/stderr" }
    ' "$conf" "$FILES" "$basef" > "$basef.tmp" && commit_tmp "$basef"
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
# (blue/_ringorphan.tsv holds no warnings) and it never touches a row that is
# already red.
orphan_red() {   # $1 = base/ring name (hosts|accounts|logins)  $2 = its _files.tsv column  $3 = "out" = the recovery test counts OUT-side files only (the hosts rule)
    local basef="$BASE/_$1.tsv"
    [ -f "$basef" ] || return 0
    [ -s "$RINGORPH" ] || return 0
    awk -F'\t' -v K="$1" -v C="$2" -v OO="${3:-}" '
        FILENAME == ARGV[1] { if ($1 == K && $2 != "") ORPH[toupper($2)] = $3; next }   # name -> newest orphan Error
        FILENAME == ARGV[2] {                                                          # the last OK file per entity
            if ($C != "" && $2 != "Failed" && $2 != "Expired" && (OO == "" || $16 == "out")) {
                e = toupper($C); t = $4 " " $5
                if (t > ok[e]) ok[e] = t }
            next }
        { e = toupper($1)
          if ((e in ORPH) && $3 != "red" && !((e in ok) && ok[e] > ORPH[e])) { $3 = "red"; n++ }
          print $1 "\t" $2 "\t" $3 }
        END { if (n) printf "result.sh: %d %s row(s) reddened by server Errors no flow could claim.\n", n, K > "/dev/stderr" }
    ' "$RINGORPH" "$FILES" "$basef" > "$basef.tmp" && commit_tmp "$basef"
}

blue_with_own_transfers accounts      3
blue_with_own_transfers logins       14
blue_with_own_transfers hosts        15
blue_with_own_transfers subscriptions 12
orphan_red hosts    15 out
orphan_red accounts  3
orphan_red logins   14
rollup logicals logicals-subscriptions
rollup partners partners-subscriptions
rollup apps     apps-subscriptions
rollup domains  domains-subscriptions
rollup bl       bl-subscriptions

# ---- blue-evidence files -----------------------------------------------------
# For every entity the rollups left BLUE (server-log-seen, never in the transfer
# log), record the evidencing server-log line — "date time <TAB> message" — into
# data/<env>/blue/<type>/<name>.txt, read by the detail-page "seen in the server
# log" box. The evidence map (latest line per type+value) is produced by
# bin/build/seen-in-server-log.sh, which ran just before. Rewritten from scratch each run, so a
# name that stopped being blue leaves no stale file behind.
BLUEDIR="$ROOT/data/$AXWAY_ENV/blue"
EVID="$BLUEDIR/_evidence.tsv"
# (no whitelisted-ip entry: IPs have no detail pages, so nothing ever read
# blue/whitelisted-ip/*.txt — dropped 2026-07)
for _bt in account:accounts subscription:subscriptions login:logins host:hosts application:apps domain:domains logical:logicals partner:partners bl:bl; do
    _ty=${_bt%%:*}; _bf="$BASE/_${_bt#*:}.tsv"; _dir="$BLUEDIR/$_ty"
    rm -rf "$_dir"
    { [ -f "$_bf" ] && [ -f "$EVID" ] && awk -F'\t' '$3=="blue"{f=1} END{exit !f}' "$_bf"; } || continue
    mkdir -p "$_dir"
    awk -F'\t' -v ty="$_ty" -v dir="$_dir" '
        FILENAME==ARGV[1] { if ($1==ty && !($2 in ev)) ev[$2]=$3 "\t" $4; next }   # evidence: already latest-first per (type,value)
        FILENAME==ARGV[2] && $3=="blue" {
            k=toupper($1); if (ty=="host") k=tolower($1); if (ty=="whitelisted-ip") k=$1
            if (k in ev) { f=dir "/" $1 ".txt"; print ev[k] > f; close(f) }
        }
    ' "$EVID" "$_bf"
done
# The UC3 clean-poll subscriptions flipped GREEN above are still server-log-only
# entities: keep their evidence card too (the loop covers only FINAL blue rows).
if [ -s "$POLLOK" ] && [ -f "$EVID" ]; then
    mkdir -p "$BLUEDIR/subscription"
    awk -F'\t' -v dir="$BLUEDIR/subscription" '
        FILENAME == ARGV[1] { if ($1 == "subscription" && !($2 in ev)) ev[$2] = $3 "\t" $4; next }
        $1 != "" { k = toupper($1); if (k in ev) { f = dir "/" $1 ".txt"; print ev[k] > f; close(f) } }
    ' "$EVID" "$POLLOK"
fi

# ---- report ------------------------------------------------------------------
for f in subscriptions accounts logins hosts white logicals partners apps domains bl; do
    [ -f "$BASE/_$f.tsv" ] || continue
    awk -F'\t' -v n="$f" '{ c[$3]++ } END { printf "  _%s.tsv: %d green, %d red, %d orange, %d blue, %d unknown\n", n, c["green"]+0, c["red"]+0, c["orange"]+0, c["blue"]+0, c["unknown"]+0 }' "$BASE/_$f.tsv" >&2
done
echo "result.sh: result column filled for the 10 base caches." >&2
