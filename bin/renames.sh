#!/usr/bin/env bash
#
# bin/renames.sh — the ONE reader/writer for input/<env>/renames/, the record of
# subscriptions that FlowManager RENAMED.
#
# Why this exists (2026-08). A FlowManager export renamed 545 of 570
# acceptance subscriptions in one go: the old names carried a doubled tail and
# mixed separators, the new ones keep only the first half with "-" folded to
# "_":
#
#     UC4_ODV-TDRS-OBVION_ODV-TDRS-OBVION          -> UC4_ODV_TDRS_OBVION
#     UC1_AB_DIRIGENT_PMM_QUION_AB_DIRIGENT_PROMMISE -> UC1_AB_DIRIGENT_PMM_QUION
#
# The LOGS keep the name that was current when each line was written, so an
# export like that splits every flow in two: the configured half joins nothing
# and goes orange "never seen", while the logged half arrives as an unknown
# entity. Folding the logged name to the CURRENT one is the only thing that
# keeps a flow's history in one piece across a rename.
#
# The map cannot be derived from the names. Deriving the 2026-08 rename by rule
# reproduced 366 of 545 correctly, got 37 WRONG and could not touch 142 — the
# dropped tail is not always a copy of the head. It is derived instead from the
# EXPORTS, which carry a stable flowId per subscription: same flowId + a
# different name = a rename, no guessing. fm_snapshot_renames() below does that
# on every config run, so a future rename records itself.
#
# WHY UNDER input/. The snapshot of the previous export is irreplaceable: once
# the export is overwritten, the old name is gone for good and no rebuild can
# recover it. Same argument as input/<env>/ip/ (a DNS answer cannot be
# regenerated) — "rm -rf data/" must stay safe. Both files are therefore
# per-env data under input/, never under data/.
#
#   input/<env>/renames/subscriptions.tsv   <old name> <TAB> <current name>
#   input/<env>/renames/profiles.tsv        the same, for the transfer PROFILE
#                                           (customAttribute_FlowIdentifier)
#   input/<env>/renames/flowid-names.tsv    <flowId> <TAB> <subscription>
#                                           <TAB> <profile> — the snapshot the
#                                           next run compares against
#
# THE PROFILE MATTERS AS MUCH AS THE NAME. The 2026-08 export renamed 218
# profiles alongside the subscriptions (same "-" -> "_" normalisation), and the
# profile is what the REVERSE config fallback attributes a leg by: with the
# logged profile no longer matching the config, 7,743 CoreIds lost their
# subscription entirely and were dropped by the no-subscription skip — 7,717
# Files, ~4.6% of the estate, silently gone. That is the failure mode CLAUDE.md
# warns about under "transfer-profile is PARSE-INTERNAL ONLY".
#
# SOURCED, not run. Defines:
#   RENAMES_DIR / RENAMES_FILE / RENAMES_SNAP   the paths
#   RENAMES_AWK   awk functions to inject with string concatenation, the
#                 BLACKLIST_AWK idiom:
#
#                     awk -F'\t' -v RNF="$RENAMES_FILE" "$RENAMES_AWK"'
#                         BEGIN { rn_load(RNF) }
#                         { $6 = rn_canon($6) }'
#
#   rn_load(f[,pf])  read the subscription map into RN_S[] and, when a second
#                 path is given, the profile map into RN_P[]. A missing path
#                 leaves that map empty, which means "no renames known" —
#                 never an error.
#   rn_canon(v)   the CURRENT subscription name for v, or v itself when it is
#                 not an old name.
#   rnp_canon(v)  the same for a transfer PROFILE.
#   rn_canon_pfx(v)  rn_canon for a TRUNCATED name (the server log cuts names
#                 off): folds only when every completion agrees, else returns v. Case-insensitive on lookup (the logs and the exports
#                 agree on case today, but a name is matched on identity
#                 site-wide, so folding case here costs nothing and survives an
#                 export that changes it); the value returned is always the
#                 export's own spelling.
#
# THE MAP IS APPEND-ONLY AND MUST STAY A FUNCTION. Three rules keep the fold
# safe, all asserted by fm_snapshot_renames():
#   - no two old names may map to one current name (that would MERGE flows);
#   - a current name may never be some other flow's old name (that would send
#     one flow's history to another);
#   - an OLD name may never be a name the export STILL CONFIGURES (2026-08-31
#     audit): a rename is a name that went away. This rule also PRUNES the
#     map on every config run — a line whose old name is configured today is
#     dropped with a note — because the diff once wrote such pairs: a flowId
#     is NOT unique per subscription (one flow, several subscribers — 8 of
#     them on the production STMT_EXPORT_GLOBEX flow), and join(1) over a
#     shared key emits the cartesian product, whose off-diagonal rows all
#     read as "renames" (_01 -> _02, _03 -> _01, …) and rotated every File of
#     the account onto the neighbouring flow. The diff now also only looks at
#     keys unique on BOTH sides.
# A pair breaking any rule is refused with a warning rather than written,
# because a wrong fold is unrecoverable once the logs have been parsed under it.
#
# Consumers: bin/transfer/parse.sh (col 6, right where the _SCP_ tail is
# stripped — the one canonicalisation point) and bin/server/parse.sh (the
# per-entity subscription caches). Everything else reads those caches and so
# sees current names only.
#
SCRIPT_DIR_RN="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_RN="$(cd "$SCRIPT_DIR_RN/.." && pwd)"
[ -n "${AXWAY_ENV:-}" ] || source "$SCRIPT_DIR_RN/env.sh"   # the env default lives in ONE place (production since 2026-08-31)
RENAMES_DIR="$ROOT_RN/input/$AXWAY_ENV/renames"
RENAMES_FILE="$RENAMES_DIR/subscriptions.tsv"
RENAMES_PROF="$RENAMES_DIR/profiles.tsv"
RENAMES_SNAP="$RENAMES_DIR/flowid-names.tsv"
export RENAMES_DIR RENAMES_FILE RENAMES_PROF RENAMES_SNAP

# NOTE: no single quotes inside this program — it is carried in a
# single-quoted shell string.
RENAMES_AWK='
function rn_read(f, arr,   ln, a, n) {
    while ((getline ln < f) > 0) {
        sub(/\r$/, "", ln)
        if (ln ~ /^[ \t]*#/ || ln ~ /^[ \t]*$/) continue
        n = split(ln, a, "\t")
        if (n < 2 || a[1] == "" || a[2] == "") continue
        arr[toupper(a[1])] = a[2]
    }
    close(f)
}
# The arrays are RN_S / RN_P, never RNF / RNP: the caller passes the PATHS in
# -v variables of those names, and awk refuses one identifier being both a
# scalar and an array.
function rn_load(f, pf) {
    if (f != "")  rn_read(f, RN_S)
    if (pf != "") rn_read(pf, RN_P)
}
function rn_canon(v) {
    if (v == "") return v
    return (toupper(v) in RN_S) ? RN_S[toupper(v)] : v
}
function rnp_canon(v) {
    if (v == "") return v
    return (toupper(v) in RN_P) ? RN_P[toupper(v)] : v
}
# rn_canon_pfx — rn_canon for a TRUNCATED name. The server log cuts a
# subscription name off at varying lengths, so a renamed flow arrives as a
# PREFIX of its old name and the exact lookup misses. Fold it only when every
# old name it could complete to agrees on one current name; a token whose
# completions disagree is left alone, because a wrong fold sends one flow s
# history to another and the map exists precisely so nothing is guessed.
# Memoised: the callers run over millions of log rows, and the scan is O(map).
function rn_canon_pfx(v,   u, k, t, c, bt, bc, bsame, nx) {
    if (v == "") return v
    u = toupper(v)
    if (u in RN_S) return RN_S[u]
    if (u in RN_PFX) return RN_PFX[u]
    t = ""; c = 0; bt = ""; bc = 0; bsame = 1
    for (k in RN_S) {
        if (index(k, u) != 1) continue
        c++
        if (t == "") t = RN_S[k]
        else if (t != RN_S[k]) t = "\001"          # the full candidate set disagrees
        # A candidate the token stops at a NAME-PART BOUNDARY of — the "_"
        # between the old doubled name s two halves, or its whole length — is
        # stronger evidence than one the token stops mid-part. UC4_ODV-ARE-YARDI
        # is exactly UC4_ + the first half of UC4_ODV-ARE-YARDI_ODV-ARE-YARDI,
        # while UC4_ODV-ARE-YARDI-DWH_... continues with "-DWH": same prefix,
        # but only the first is a complete part. Still a boundary rule, not a
        # guess about content, and it only decides when the boundary candidates
        # AGREE — otherwise the token is left alone as before.
        nx = substr(k, length(u) + 1, 1)
        if (nx == "_" || nx == "") { bc++
            if (bt == "") bt = RN_S[k]
            else if (bt != RN_S[k]) bsame = 0 }
    }
    if (c > 0 && t != "" && t != "\001")      RN_PFX[u] = t
    else if (bc > 0 && bsame && bt != "")      RN_PFX[u] = bt
    else                                       RN_PFX[u] = v
    return RN_PFX[u]
}
'

# ---------------------------------------------------------------------------
# fm_snapshot_renames — called by bin/flow-manager.sh once per config run.
#   $1 = the subscriptions export (JSON)
# Compares its flowId->name pairs with the previous run's snapshot; every
# flowId whose name changed appends one old<TAB>new pair to the map (UNION,
# never a rewrite — an old name recorded once must stay recorded, since logs
# older than the map still carry it). Then refreshes the snapshot.
# Needs jq, like the rest of the config step; without it, it does nothing.
# ---------------------------------------------------------------------------
fm_snapshot_renames() {   # $1 = subscriptions.json
    local subs=$1 tmp
    [ -f "$subs" ] || return 0
    command -v jq >/dev/null 2>&1 || return 0
    mkdir -p "$RENAMES_DIR"
    tmp=$(mktemp "${TMPDIR:-/tmp}/axrn.XXXXXX") || return 0
    # flowId is the stable per-subscription key; businessId stands in where an
    # export carries no flowId (the production EXAMPLE export). Both were
    # verified stable across the 2026-08 rename: 567 of 570 shared, either way.
    # Columns: key, subscription name, profile (customAttribute_FlowIdentifier).
    jq -r '.[] | (.flowId // .businessId // "") as $k
           | select($k != "" and (.name // "") != "")
           | [$k, .name, (.parameters.customAttribute_FlowIdentifier // "")] | @tsv' \
        "$subs" 2>/dev/null | LC_ALL=C sort > "$tmp.now" || { rm -f "$tmp"*; return 0; }
    if [ ! -s "$tmp.now" ]; then rm -f "$tmp"*; return 0; fi

    # rule 3 as a PRUNE: a recorded pair whose old name the export still
    # configures is wrong by definition (see the header) — drop it, and say so
    _rn_prune 2 "$RENAMES_FILE" subscription "$tmp"
    _rn_prune 3 "$RENAMES_PROF" profile      "$tmp"
    if [ -s "$RENAMES_SNAP" ]; then
        _rn_record 2 "$RENAMES_FILE" subscription "$tmp"
        _rn_record 3 "$RENAMES_PROF" profile      "$tmp"
    fi
    # the snapshot always tracks the export we just read
    if ! cmp -s "$tmp.now" "$RENAMES_SNAP" 2>/dev/null; then mv "$tmp.now" "$RENAMES_SNAP"; fi
    rm -f "$tmp"*
    return 0
}

# _rn_record — one column of the snapshot against the same column of the new
# export: every key whose value moved becomes an old<TAB>new pair, filtered by
# the two safety rules and APPENDED (union). $1 = column, $2 = map file,
# $3 = noun for the message, $4 = the temp prefix ($4.now holds the export).
_rn_record() {   # $1 col  $2 mapfile  $3 noun  $4 tmp prefix
    local col=$1 map=$2 noun=$3 tmp=$4 pairs added
    [ -f "$map" ] || : > "$map"
    # join on the key — restricted to keys that are UNIQUE ON BOTH SIDES: a
    # flowId shared by several subscriptions (one flow, many subscribers)
    # would otherwise join as a cartesian product whose every off-diagonal
    # row reads as a rename (the 2026-08-31 audit finding; see the header).
    # Then compare that column old vs new. NOTE the join output layout: key,
    # then the snapshot fields, then the export fields — so column N of the
    # snapshot is $N and of the export is $(N + width - 1).
    awk -F'\t' 'NR == FNR { c[$1]++; next } c[$1] == 1' "$RENAMES_SNAP" "$RENAMES_SNAP" > "$tmp.snap1"
    awk -F'\t' 'NR == FNR { c[$1]++; next } c[$1] == 1' "$tmp.now" "$tmp.now" > "$tmp.now1"
    pairs=$(LC_ALL=C join -t"$(printf '\t')" "$tmp.snap1" "$tmp.now1" 2>/dev/null \
        | awk -F'\t' -v c="$col" '{ o = $c; n = $(c + 2)
              if (o != "" && n != "" && o != n) print o "\t" n }')
    [ -n "$pairs" ] || return 0
    printf '%s\n' "$pairs" | LC_ALL=C sort -u > "$tmp.cand"
    # NEW[] indexes every name that is already the TARGET of a recorded pair,
    # so the safety rules see the map AND this run at once; CUR[] is every
    # name the export configures TODAY (rule 3)
    awk -F'\t' -v MAP="$map" -v NOUN="$noun" -v NOW="$tmp.now" -v c="$col" '
        BEGIN { while ((getline l < MAP) > 0) { n = split(l, a, "\t")
                    if (n >= 2 && a[1] != "") { OLD[toupper(a[1])] = a[2]; NEW[toupper(a[2])] = a[1] } }
                close(MAP)
                while ((getline l < NOW) > 0) { n = split(l, a, "\t"); if (n >= c && a[c] != "") CUR[toupper(a[c])] = 1 }
                close(NOW) }
        (toupper($1) in OLD) && OLD[toupper($1)] == $2 { next }   # already recorded
        {
            if ((toupper($1) in OLD) && OLD[toupper($1)] != $2) {
                printf "renames: REFUSED %s %s -> %s (already maps to %s)\n", NOUN, $1, $2, OLD[toupper($1)] > "/dev/stderr"; next }
            if (toupper($2) in NEW) {
                printf "renames: REFUSED %s %s -> %s (that name is already the current name of %s)\n", NOUN, $1, $2, NEW[toupper($2)] > "/dev/stderr"; next }
            if (toupper($1) in NEW) {
                printf "renames: REFUSED %s %s -> %s (%s is the CURRENT name of %s)\n", NOUN, $1, $2, $1, NEW[toupper($1)] > "/dev/stderr"; next }
            if (toupper($2) in OLD) {
                printf "renames: REFUSED %s %s -> %s (%s is itself an OLD name, mapping to %s)\n", NOUN, $1, $2, $2, OLD[toupper($2)] > "/dev/stderr"; next }
            if (toupper($1) in CUR) {
                printf "renames: REFUSED %s %s -> %s (%s is a name the export still configures)\n", NOUN, $1, $2, $1 > "/dev/stderr"; next }
            OLD[toupper($1)] = $2; NEW[toupper($2)] = $1
            print
        }' "$tmp.cand" > "$tmp.acc"
    added=$(wc -l < "$tmp.acc" | tr -d " ")
    if [ "${added:-0}" -gt 0 ]; then
        cat "$tmp.acc" >> "$map"
        printf 'renames: %s %s rename(s) recorded in %s.\n' "$added" "$noun" "${map#*/input/}" >&2
    fi
    return 0
}

# _rn_prune — rule 3 applied to what is ALREADY in the map: drop every pair
# whose old name the export configures today (a current name cannot be an old
# one), naming each on stderr. The map keeps its order and every other line;
# it is rewritten only when something goes, so a clean map keeps its mtime.
# parser_sig cksums the maps, so a prune re-tokenizes the logs under the
# corrected fold. $1 = column of $4.now, $2 = map file, $3 = noun, $4 = tmp prefix.
_rn_prune() {   # $1 col  $2 mapfile  $3 noun  $4 tmp prefix
    local col=$1 map=$2 noun=$3 tmp=$4 dropped
    [ -s "$map" ] || return 0
    : > "$tmp.keep"   # (a map losing EVERY line must still leave a file to move)
    dropped=$(awk -F'\t' -v c="$col" -v OUT="$tmp.keep" -v NOUN="$noun" '
        NR == FNR { if (NF >= c && $c != "") cur[toupper($c)] = 1; next }
        {
            n = split($0, a, "\t")
            if (n >= 2 && a[1] != "" && (toupper(a[1]) in cur)) {
                printf "renames: DROPPED %s %s -> %s from the map: %s is a name the export still configures, so it cannot be an old name (the shared-flowId join artefact)\n", NOUN, a[1], a[2], a[1] > "/dev/stderr"
                d++; next }
            print > OUT
        }
        END { close(OUT); printf "%d\n", d + 0 }' "$tmp.now" "$map")
    if [ "${dropped:-0}" -gt 0 ]; then
        mv "$tmp.keep" "$map"
        printf 'renames: %s wrong %s pair(s) pruned from %s.\n' "$dropped" "$noun" "${map#*/input/}" >&2
    else
        rm -f "$tmp.keep"
    fi
    return 0
}
