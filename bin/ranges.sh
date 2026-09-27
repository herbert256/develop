# bin/ranges.sh — SOURCED (never run): the byte-range split the parallel scans
# of one big line file share (2026-09-27: the 3 GB server cache, read by the
# mention rescan, session-sites, bookend-ok, expire-files, failed.sh and the
# day pages).
#
# N jobs split the file; job I owns the lines that START in its byte range
# [lo, hi) — rng_lo / rng_hi, the last range closing past the end. rng_feed
# streams the file from the 64 KiB block holding byte lo-1 on: dd SEEKS
# there, so no job reads what precedes its range (the jobs used to read the
# file from its start, over five times its size between them). The awk side
# is one rule, placed before the rule that reads the file, with the file
# operand /dev/stdin and -v RANGEF=/dev/stdin RLO=lo RHI=hi ROFF=$(rng_off lo):
#
#   RANGEF != "" && FILENAME == RANGEF { if (!_rs) { _rs = 1; _off = ROFF + 0 }
#       _lo = _off; _off += length($0) + 1; if (_lo < RLO + 0) next; if (_lo >= RHI + 0) exit }
#
# The stream starts at a true file offset (ROFF), so every line start is
# counted exactly; the partial line the block cut, and whole lines before
# lo, start below lo and are skipped. Every job counts the same offsets, so
# the jobs partition the lines, in file order.
RNG_BS=65536
rng_lo()  { echo $(( ($3 - 1) * $1 / $2 )); }                                        # SIZE N I
rng_hi()  { if [ "$3" -eq "$2" ]; then echo $(( $1 + 1 )); else echo $(( $3 * $1 / $2 )); fi; }   # SIZE N I
rng_off() { if [ "$1" -gt 0 ]; then echo $(( ($1 - 1) / RNG_BS * RNG_BS )); else echo 0; fi; }    # LO -> where rng_feed starts
# FILE LO — dd is cut off by SIGPIPE once the awk has passed hi: not an error
rng_feed() { dd if="$1" bs="$RNG_BS" skip=$(( $(rng_off "$2") / RNG_BS )) 2>/dev/null || true; }
