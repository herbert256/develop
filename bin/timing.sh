# bin/timing.sh — SOURCED (never run): the build's per-script timing lines
# (2026-09-27, user request: analyse and speed up the production build).
#
# timed CMD [ARG...] — run CMD, then print ONE line to stderr:
#
#     TIME   123s  <basename of CMD>
#
# and return CMD's exit status. The report runners wrap every pooled report
# in it, so a stage that runs dozens of scripts in parallel says which of
# them is the long pole. A timing line carries a script name and a duration
# only — never data — so it is safe to read from ANY checkout's console, the
# runtime builds included (bin/build.sh replays a background step's TIME
# lines onto the console when the step finishes).
timed() {
    local t0 st=0
    t0=$(date +%s)
    "$@" || st=$?
    printf 'TIME %5ds  %s\n' "$(( $(date +%s) - t0 ))" "${1##*/}" >&2
    return "$st"
}
