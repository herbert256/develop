#!/usr/bin/env bash
#
# bin/skiplist.sh — the ONE reader for input/<env>/skip.txt, the site-local SKIP LIST.
#
# SOURCED, not run. Mirrors bin/blacklist.sh (same layout, same injection idiom)
# but a different OPERATION: the blacklist BLANKS one field of a row it keeps,
# the skip list DROPS the whole record and sets it aside in _skipped.tsv for the
# "Skipped" analyses report.
#
# Defines:
#   SKIPLIST_FILE  the path (input/<env>/skip.txt — per environment since 2026-08-31)
#   SKIPLIST_AWK   awk functions to inject with string concatenation:
#
#                      awk -F'\t' -v SLF="$SKIPLIST_FILE" "$SKIPLIST_AWK"'
#                          BEGIN { sl_load(SLF) }
#                          { if (sl_hit("account", $4)) ... }'
#
# sl_load(f)        read the file into SL_FIELD/SL_RULE/SL_VAL/SL_RAW[1..SL_N].
#                   A missing path is fine: SL_N stays 0, i.e. skip nothing.
# sl_match(fld,v)   the INDEX of the first rule that matches value v for field
#                   fld, or 0. A rule matches when its field is fld or "any"
#                   and its value test passes. The index lets the Skipped
#                   report name WHICH rule caught a row (SL_RAW[i]).
# sl_hit(fld,v)     1 when sl_match is non-zero.
#
# FIELDS: account | login | site | message | any.
#   The transfer parse tests account, login and site (a row is dropped when any
#   of them hits); the server parse has only the message text, so it tests
#   "message" — an "any" rule therefore still scrubs server lines mentioning
#   the token, exactly as the flat token list did.
# RULES: contains (case-insensitive substring, the default) | exact
#   (case-insensitive equality) | regex (an ERE, matched as written).
#
# A line with NO TAB is the LEGACY form and means "any contains <line>", so a
# flat token list keeps working unchanged.
#
SCRIPT_DIR_SL="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# PER ENVIRONMENT since 2026-08-31 (user request): input/<env>/skip.txt.
# $AXWAY_ENV comes from bin/env.sh (sourced here when the caller has not).
[ -n "${AXWAY_ENV:-}" ] || source "$SCRIPT_DIR_SL/env.sh"
SKIPLIST_FILE="${SKIPLIST_FILE:-$(cd "$SCRIPT_DIR_SL/.." && pwd)/input/$AXWAY_ENV/skip.txt}"
export SKIPLIST_FILE

# NOTE: no single quotes inside this program — it rides in a single-quoted
# shell string.
SKIPLIST_AWK='
function sl_load(f,   ln, a, n) {
    SL_N = 0
    while ((getline ln < f) > 0) {
        sub(/\r$/, "", ln)
        if (ln ~ /^[ \t]*#/ || ln ~ /^[ \t]*$/) continue
        n = split(ln, a, "\t")
        if (n < 3) {                      # LEGACY: a bare token
            gsub(/^[ \t]+|[ \t]+$/, "", ln)
            if (ln == "") continue
            SL_N++; SL_FIELD[SL_N] = "any"; SL_RULE[SL_N] = "contains"
            SL_VAL[SL_N] = ln; SL_RAW[SL_N] = ln
            continue
        }
        gsub(/^[ \t]+|[ \t]+$/, "", a[1]); gsub(/^[ \t]+|[ \t]+$/, "", a[2])
        if (a[1] == "" || a[3] == "") continue
        SL_N++
        SL_FIELD[SL_N] = a[1]; SL_RULE[SL_N] = (a[2] == "") ? "contains" : a[2]
        SL_VAL[SL_N] = a[3]
        SL_RAW[SL_N] = a[3]
    }
    close(f)
}
function sl_match(fld, v,   i) {
    if (v == "") return 0
    for (i = 1; i <= SL_N; i++) {
        if (SL_FIELD[i] != fld && SL_FIELD[i] != "any") continue
        if (SL_RULE[i] == "exact")    { if (toupper(v) == toupper(SL_VAL[i])) return i }
        else if (SL_RULE[i] == "regex") { if (v ~ SL_VAL[i]) return i }
        else                          { if (index(toupper(v), toupper(SL_VAL[i]))) return i }
    }
    return 0
}
function sl_hit(fld, v) { return sl_match(fld, v) > 0 }
'

# skip_values FIELD — the VALUES of every rule applying to FIELD (its own rules
# plus the "any" ones), one per line, for the consumers that cannot run awk
# against a row: bin/flow-manager.sh (jq, filtering configured names) and
# publish_lib.sh's skipped_tokens (the display list). Legacy bare tokens count
# as "any". Values only — a regex rule's value comes out as written.
skip_values() {
    local want=${1:-any}
    [ -f "$SKIPLIST_FILE" ] || return 0
    awk -F'\t' -v want="$want" '
        /^[ \t]*#/ || /^[ \t]*$/ { next }
        {
            sub(/\r$/, "")
            if (NF < 3) { gsub(/^[ \t]+|[ \t]+$/, ""); if ($0 != "") print; next }
            f = $1; gsub(/^[ \t]+|[ \t]+$/, "", f)
            if (f == want || f == "any") print $3
        }' "$SKIPLIST_FILE"
}
