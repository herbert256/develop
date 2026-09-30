# bin/awklib.sh — SOURCED. The shared awk function libraries as ONE string,
# $AWKLIB, injected in front of a program's text: awk … "$AWKLIB"'program'
# (or "$OTHER_AWK$AWKLIB"'…'). bin/date.awk (jdn, fromjdn, minof) and
# bin/fmt.awk (hbytes2 / hbytes0 / hbytes1, hdurms, hdsecs, lit, html_esc, slugof, qsortn) — 2026-09-30,
# the lean round. A program that injects it must not define those names.
_AWKLIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AWKLIB="$(cat "$_AWKLIB_DIR/date.awk" "$_AWKLIB_DIR/fmt.awk")
"
# $CADENCE_AWK — bin/cadence.awk (patron, regspread, label: the pickup-pattern
# vocabulary), NOT in $AWKLIB ("label" is a common local name): the two
# pattern programs (uc2-status.sh, logons.sh) inject it beside $AWKLIB.
CADENCE_AWK="$(cat "$_AWKLIB_DIR/cadence.awk")
"
