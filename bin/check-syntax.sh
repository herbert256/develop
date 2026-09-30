#!/usr/bin/env bash
#
# check-syntax.sh — `bash -n` over every bin/**/*.sh of this checkout (and a
# mawk compile of every bin/**/*.awk, 2026-09-29; a node --check of every
# assets/*.js, 2026-09-30)
# (2026-09-27). WHY: macOS /bin/bash 3.2 exits 0 when a script that set an
# EXIT trap (the common `trap 'rm -rf "$TMPD"' EXIT`) hits a SYNTAX error —
# $? inside the trap is 0 too — so the report silently goes missing and the
# build passes green. The usual cause is an apostrophe in a comment inside a
# single-quoted awk program, which ends the quoted string.
#
# Callers: bin/build.sh, first thing (before it wipes build/, data/ and
# docs/ or runs a step), and bin/runtime-lib.sh on DEVELOP's tree before it
# syncs the code into a runtime checkout.
#
# Prints each failing file's error; exit 1 when any fails. ~0.5 s for ~200
# scripts. Usage: bin/check-syntax.sh
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
bad=0
while IFS= read -r -d '' f; do
    out=$(bash -n "$f" 2>&1) || { bad=$((bad + 1)); printf '%s\n' "$out" >&2; }
done < <(find "$ROOT/bin" -name '*.sh' -type f -print0)
# the stand-alone .awk programs COMPILE (2026-09-29 audit — bash -n never saw
# them): mawk -W dump parses without running; the sample generators are
# compiled behind their prelude, subname.awk behind the renames helpers it is
# always run with, details_writer.awk and render_rpt.awk behind bin/fmt.awk. Skipped when mawk is not installed.
if command -v mawk >/dev/null 2>&1; then
    rn_awk=$( . "$ROOT/bin/renames.sh" >/dev/null 2>&1; printf '%s' "${RENAMES_AWK:-}" )
    awktmp=$(mktemp "${TMPDIR:-/tmp}/axcs.XXXXXX")
    while IFS= read -r -d '' f; do
        case $f in
            */sample/prelude.awk) : > "$awktmp" ;;
            */sample/*.awk)       cat "$ROOT/bin/sample/prelude.awk" > "$awktmp" ;;
            */subname.awk)        printf '%s\n' "$rn_awk" > "$awktmp" ;;
            */details_writer.awk) cat "$ROOT/bin/fmt.awk" > "$awktmp" ;;   # run as -f fmt.awk -f details_writer.awk
            */render_rpt.awk)     cat "$ROOT/bin/fmt.awk" > "$awktmp" ;;   # run as -f fmt.awk -f render_rpt.awk (2026-09-30)
            *)                    : > "$awktmp" ;;
        esac
        cat "$f" >> "$awktmp"
        out=$(mawk -W dump -f "$awktmp" 2>&1 >/dev/null) || { bad=$((bad + 1)); printf '%s: %s\n' "$f" "$out" >&2; }
    done < <(find "$ROOT/bin" -name '*.awk' -type f -print0)
    rm -f "$awktmp"
fi
# the front-end scripts PARSE (2026-09-30 audit A6-07): a syntax error in an
# assets/*.js would ship green and leave every page without its top bar and
# table features. `node --check` parses without running; skipped when node is
# not installed.
if command -v node >/dev/null 2>&1; then
    for f in "$ROOT"/assets/*.js; do
        [ -f "$f" ] || continue
        out=$(node --check "$f" 2>&1) || { bad=$((bad + 1)); printf '%s: %s\n' "$f" "$out" >&2; }
    done
fi
if [ "$bad" -gt 0 ]; then
    echo "check-syntax: $bad script(s) under $ROOT/bin or $ROOT/assets have a bash, awk or JavaScript syntax error — nothing was run." >&2
    exit 1
fi
exit 0
