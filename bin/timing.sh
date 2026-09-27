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
#
# ...plus, since round 2 of the 2026-09-27 speed work, the CPU the command
# used — "[cpu Ns]", user + system of the reaped children, from bash's own
# `times` (read in THIS shell: a subshell would count only its own children).
# Wall time under a busy pool mostly measures the contention; the CPU figure
# is what a script costs.
timed() {
    local t0 st=0 f c0 c1
    f=$(mktemp "${TMPDIR:-/tmp}/timed.XXXXXX")
    times > "$f"; c0=$(sed -n 2p "$f")
    t0=$(date +%s)
    "$@" || st=$?
    times > "$f"; c1=$(sed -n 2p "$f"); rm -f "$f"
    printf 'TIME %5ds  %s  [cpu %s]\n' "$(( $(date +%s) - t0 ))" "${1##*/}" \
        "$(awk -v a="$c0" -v b="$c1" 'function t(v,   m) { m = v; sub(/m.*/, "", m); sub(/^[0-9]+m/, "", v); sub(/s$/, "", v); return m * 60 + v }
            function s(x,   p) { split(x, p, " "); return t(p[1]) + t(p[2]) }
            BEGIN { printf "%.0fs", s(b) - s(a) }')" >&2
    return "$st"
}
