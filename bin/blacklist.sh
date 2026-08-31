#!/usr/bin/env bash
#
# bin/blacklist.sh — the ONE reader for input/<env>/blacklist.txt, the platform-internal
# pseudo-entities (see that file's header for the format and the why).
#
# SOURCED, not run. Defines:
#   BLACKLIST_FILE  the path (input/<env>/blacklist.txt — per environment since
#                   2026-08-31, user request; platform policy differs per estate)
#   BLACKLIST_AWK   awk functions to inject into a program with string
#                   concatenation, the COREIDS_AWK / LOGLINES_AWK idiom:
#
#                       awk -F'\t' -v BLF="$BLACKLIST_FILE" "$BLACKLIST_AWK"'
#                           BEGIN { bl_load(BLF) }
#                           { if (bl_blank("login", $5)) $5 = "" ... }'
#
#                   (An .awk file loaded with -f cannot be combined with an
#                   inline program: POSIX awk takes either -f progfile or a
#                   program string, never both, and neither mawk nor BSD awk
#                   has gawk's -e. Hence the shell-variable form.)
#
# bl_load(f)          read the file into BL_DROP[] / BL_KEEP[]. Safe to call
#                     with a missing path: the lists come out empty, which
#                     means "blacklist nothing" — callers that care should
#                     check the file exists and say so.
# bl_blank(field,v)   1 when value v of that field must be BLANKED:
#                       - an exact "drop" match, or
#                       - a "keep" regex the value fails.
#
# Consumers: bin/transfer/parse.sh (the authoritative blanking) and
# bin/server/reports/unknown-entities.sh (so the server side agrees about what
# is internal). Those two are ALL of them: report.js has no client-side
# blacklist net and must not gain one (CLAUDE.md) — filtering happens entirely
# at parse time.
#
SCRIPT_DIR_BL="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# PER ENVIRONMENT since 2026-08-31 (user request): input/<env>/blacklist.txt —
# the two estates are different platforms with different internal values.
# $AXWAY_ENV comes from bin/env.sh (sourced here when the caller has not).
[ -n "${AXWAY_ENV:-}" ] || source "$SCRIPT_DIR_BL/env.sh"
BLACKLIST_FILE="${BLACKLIST_FILE:-$(cd "$SCRIPT_DIR_BL/.." && pwd)/input/$AXWAY_ENV/blacklist.txt}"
export BLACKLIST_FILE

# NOTE: no single quotes inside this program — it is carried in a
# single-quoted shell string.
BLACKLIST_AWK='
function bl_load(f,   ln, a, n) {
    while ((getline ln < f) > 0) {
        sub(/\r$/, "", ln)
        if (ln ~ /^[ \t]*#/ || ln ~ /^[ \t]*$/) continue
        n = split(ln, a, "\t")
        if (n < 3 || a[1] == "" || a[3] == "") continue
        if (a[2] == "drop")      BL_DROP[a[1] SUBSEP a[3]] = 1
        else if (a[2] == "keep") BL_KEEP[a[1]] = a[3]
    }
    close(f)
}
function bl_blank(field, v) {
    if ((field SUBSEP v) in BL_DROP) return 1
    if ((field in BL_KEEP) && v !~ BL_KEEP[field]) return 1
    return 0
}
function bl_keep_re(field) { return (field in BL_KEEP) ? BL_KEEP[field] : "" }
'
