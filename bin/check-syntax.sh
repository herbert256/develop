#!/usr/bin/env bash
#
# check-syntax.sh — `bash -n` over every bin/**/*.sh of this checkout
# (2026-09-27). WHY: macOS /bin/bash 3.2 exits 0 when a script that set an
# EXIT trap (the common `trap 'rm -rf "$TMPD"' EXIT`) hits a SYNTAX error —
# $? inside the trap is 0 too — so the report silently goes missing and the
# build passes green. The usual cause is an apostrophe in a comment inside a
# single-quoted awk program, which ends the quoted string.
#
# Callers: bin/build.sh, first thing (before it clears docs/ or runs a
# step), and bin/runtime-lib.sh on DEVELOP's tree before it syncs the code
# into a runtime checkout — whose bin/fresh.sh wipes data/ and docs/ before
# bin/build.sh would get to this check.
#
# Prints each failing file's error; exit 1 when any fails. ~0.5 s for ~200
# scripts. Usage: bin/check-syntax.sh
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
bad=0
while IFS= read -r -d '' f; do
    out=$(bash -n "$f" 2>&1) || { bad=$((bad + 1)); printf '%s\n' "$out" >&2; }
done < <(find "$ROOT/bin" -name '*.sh' -type f -print0)
if [ "$bad" -gt 0 ]; then
    echo "check-syntax: $bad script(s) under $ROOT/bin have a bash syntax error — nothing was run." >&2
    exit 1
fi
exit 0
