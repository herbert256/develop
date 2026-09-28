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

# ---- KEY-ALIGNED SLICES (2026-09-28, speed round 16) -----------------------
# grp_cuts FILE N — "lo hi" byte ranges splitting a file SORTED on its first
# TAB field into at most N slices that never split a run of equal keys (a
# run of BLANK keys included — a pass may group them, like the no-subscription
# skip). Every byte lands in exactly one slice.
# From each target k*size/N: to the next line start, then past the key run
# that line belongs to — the cut is the first line with another key.
grp_cuts() {
    perl -e '
        my ($f, $n) = @ARGV; my $size = -s $f; my @c = (0);
        if ($size && $n > 1) {
            open(my $h, "<", $f) or die "$f: $!";
            for my $i (1 .. $n - 1) {
                my $t = int($i * $size / $n); next if $t <= $c[-1];
                seek($h, $t - 1, 0); my $rest = <$h>;
                my $l = <$h>; last unless defined $l;
                chomp $l; my ($k) = split /\t/, $l, 2; $k = "" unless defined $k;
                my $cut;
                while (1) { my $p = tell($h); my $nl = <$h>; last unless defined $nl;
                    chomp $nl; my ($k2) = split /\t/, $nl, 2; $k2 = "" unless defined $k2;
                    if ($k2 ne $k) { $cut = $p; last } }
                push @c, $cut if defined $cut && $cut > $c[-1] && $cut < $size;
            }
        }
        push @c, $size;
        for my $i (0 .. $#c - 1) { print "$c[$i] $c[$i+1]\n" if $c[$i+1] > $c[$i] }' "$1" "$2"
}
# byte_feed FILE LO HI — exactly the bytes [LO, HI) (dd seeks by block only)
byte_feed() {
    perl -e 'my ($f, $lo, $hi) = @ARGV; open(my $h, "<", $f) or die "$f: $!"; binmode $h; binmode STDOUT;
        seek($h, $lo, 0); my $left = $hi - $lo;
        while ($left > 0) { my $n = read($h, my $b, $left < 4194304 ? $left : 4194304); last unless $n; print $b; $left -= $n }' "$1" "$2" "$3"
}
# grp_par FILE OUT N CMD... — CMD once per key-aligned slice of FILE, in
# parallel, the slice on its stdin and GRP_PART=<i> in its environment; OUT =
# the outputs concatenated in slice order. So a per-key-group filter (no state
# across groups) over the whole file equals its run on each slice, in order.
# A failed slice fails the call. GRP_N = the slice count afterwards (per-slice
# side files, named by GRP_PART, join in order 1..GRP_N).
# The slice output goes to its part file through cat(1): mawk writes a regular
# file in 4 KB chunks, and ten slices doing that at once spend ~6x the time in
# the kernel (370 MB: 0.84 s direct, 0.14 s through cat — 2026-09-28).
grp_par() {
    local f=$1 out=$2 nj=$3 lo hi i=0 rc=0 p; shift 3
    local pids=() parts=()
    while read -r lo hi; do
        i=$((i + 1))
        ( set -o pipefail; byte_feed "$f" "$lo" "$hi" | GRP_PART=$i "$@" | cat > "$out.grp$i" ) &
        pids+=("$!"); parts+=("$out.grp$i")
    done < <(grp_cuts "$f" "$nj")
    for p in ${pids[@]+"${pids[@]}"}; do wait "$p" || rc=$?; done
    GRP_N=$i
    if [ "$rc" -ne 0 ]; then rm -f ${parts[@]+"${parts[@]}"}; return "$rc"; fi
    if [ "${#parts[@]}" -gt 0 ]; then cat "${parts[@]}" > "$out"; else : > "$out"; fi
    rm -f ${parts[@]+"${parts[@]}"}
}
