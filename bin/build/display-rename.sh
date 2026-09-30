#!/usr/bin/env bash
#
# display-rename.sh — the DISPLAY RENAME sweep (2026-08-30, user request):
# the LAST page-touching build step. input/rename.txt holds this checkout's
# PRESENTATION renames (one repo = one environment since 2026-09-11); the
# rules rewrite the whole docs/ tree:
#
#     <entity> <old_value> <new_value>      (whitespace-separated, # comments)
#     e.g.  subscription UC8_..._SRC_..._DEST UC8_HR_PLURALSIGHT_SAPSF
#
# The rename is PUBLISH-TIME ONLY: the parse caches, the .rpt files and every
# join keep the real value; this sweep rewrites the RENDERED pages (and the
# client-side data payloads — search-data.js, the all-files day shards) so
# the new value is SHOWN instead of the real one.
#
# Matching is BOUNDARY-AWARE on the entity-name alphabet [A-Za-z0-9_.-]
# (the dot included, so a host rename never matches a prefix of a longer
# domain): an old value never matches inside a longer name (renaming UC2_X
# leaves UC2_X2 and the _SCP_-tailed internal spellings alone). Links keep working
# untouched: page hrefs use lowercased SLUGS of the real name, which the
# case-sensitive replacement never matches — while a ?axway_search=<name>
# query IS renamed, deliberately: the client search runs over the DISPLAYED
# text, so the carried query must show the new value too.
#
# The entity column (subscription account login host logical partner
# application domain bl profile any) is documentation and validation; the value match is
# what rewrites. A missing or empty rename.txt renames nothing (the MILLISECOND
# sweep below runs regardless, 2026-09-30). MANUAL-REPUBLISH
# GOTCHA: this runs only in bin/build.sh — a manual per-area publish shows
# real values until the next build.
#
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/../.."

[ -d docs ] || { echo "display-rename: no docs/ tree." >&2; exit 0; }

# load_rules FILE — the rules of one env file, validated: 3 columns, a known
# entity, values on the name alphabet. Prints "old<TAB>new" lines.
load_rules() {
    [ -s "$1" ] || return 0
    awk -v F="$1" '
    /^[ \t]*#/ || /^[ \t]*$/ { next }
    {
        if (NF != 3) { printf "display-rename: %s line %d: %d column(s), need 3 — skipped\n", F, NR, NF > "/dev/stderr"; next }
        if ($1 !~ /^(subscription|account|login|host|logical|partner|application|domain|bl|profile|any)$/) {
            printf "display-rename: %s line %d: unknown entity \"%s\" — skipped\n", F, NR, $1 > "/dev/stderr"; next }
        if ($2 !~ /^[A-Za-z0-9_.-]+$/ || $3 !~ /^[A-Za-z0-9_.-]+$/) {
            printf "display-rename: %s line %d: value outside the name alphabet — skipped\n", F, NR > "/dev/stderr"; next }
        if ($2 == $3) next
        print $2 "\t" $3
    }' "$1"
}

# apply_rules RULES DIR [FIND-ARGS...] — rewrite the pages under DIR that
# carry an old value. Only the files that CONTAIN one are rewritten (mtime
# churn and write I/O stay proportional to the rules, not the site).
# perl (a stated requirement — crosslink uses it too): boundary-guarded
# replacement, rules loaded once. NOTE s{}{} delimiters, never s|…| (the
# repo's perl trap: an escaped | inside s|…| is alternation).
apply_rules() {
    local rules=$1 dir=$2; shift 2
    local pats lst n np
    [ -n "$rules" ] && [ -d "$dir" ] || return 0
    pats=$(mktemp "${TMPDIR:-/tmp}/axdr.XXXXXX")
    lst=$(mktemp "${TMPDIR:-/tmp}/axdl.XXXXXX")
    printf '%s\n' "$rules" | cut -f1 | LC_ALL=C sort -u > "$pats"
    # the matching pages NUL-separated (2026-09-29 audit: an unquoted list
    # broke on spaces and could exceed ARG_MAX on a sweeping rename)
    find "$dir" "$@" -type f \( -name '*.html' -o -name '*-data.js' -o -name 'search-data.js' -o -path '*/search/all/*.js' \) -print0 \
        | xargs -0 grep -lF --null -f "$pats" > "$lst" 2>/dev/null || true
    rm -f "$pats"
    n=$(printf '%s\n' "$rules" | wc -l | tr -d ' ')
    np=$(tr -cd '\000' < "$lst" | wc -c | tr -d ' ')
    if [ "$np" -eq 0 ]; then
        rm -f "$lst"
        echo "display-rename: $dir: $n rule(s), 0 pages carry an old value." >&2
        return 0
    fi
    # ONE pass per line over ONE alternation, longest name first (2026-09-29
    # audit: the rules ran one after the other, so a chain A->B, B->C turned
    # an A into C)
    RULES="$rules" xargs -0 perl -pi -e '
        BEGIN {
            my %seen; my @alt;
            for my $l (split /\n/, $ENV{RULES}) {
                my ($old, $new) = split /\t/, $l;
                next if !defined $new || $seen{$old}++;
                $MAP{$old} = $new; push @alt, quotemeta($old);
            }
            @alt = sort { length($b) <=> length($a) } @alt;
            my $a = join("|", @alt);
            $RE = qr{(?<![A-Za-z0-9_.-])($a)(?![A-Za-z0-9_.-])};
        }
        s{$RE}{$MAP{$1}}g;
    ' < "$lst"
    rm -f "$lst"
    echo "display-rename: $dir: applied $n rule(s) to $np page(s)." >&2
}

# THE MILLISECOND SWEEP (2026-09-30, user request: "General site rule, never
# show the .mmm of a time, only hh:mm:ss"): every rendered page and client-side
# data payload under docs/ (not the code in docs/assets/) drops the ".mmm" after
# an hh:mm:ss — table cells, drill entries, log lines, File pages, the -data.js
# payloads alike. Presentation only, like the renames: the caches and the .rpt
# files keep the milliseconds (sort precision). The front-end decoders read the
# drill entries by pattern (report.js expandFileList / bindDrill: a leading
# \d\d:\d\d:\d\d, the UUID / 32-hex CoreId), never by position, so the shorter
# stamps decode the same. Only the files that carry one are rewritten.
# ONE perl per batch of files, in parallel, each reading a file whole and
# writing it back only when the substitution changed something; each batch
# prints its count as ONE short line (atomic on the pipe). NOT a parallel
# `grep -l` into one list: concurrent greps interleave their buffered output
# and garble the file names (the first try, 2026-09-30 — 12 pages missed).
ms_sweep() {
    local nj np
    nj=${AXWAY_NJOBS:-$(sysctl -n hw.ncpu 2>/dev/null || echo 4)}
    np=$(find docs -type f \( -name '*.html' -o -name '*.js' \) ! -path 'docs/assets/*' -print0 \
        | xargs -0 -P "$nj" -n 200 perl -e '
            my $n = 0;
            for my $f (@ARGV) {
                open(my $h, "<", $f) or die "ms-sweep: $f: $!"; my $c = do { local $/; <$h> }; close $h;
                next unless $c =~ s{(?<![0-9])([0-9]{2}:[0-9]{2}:[0-9]{2})\.[0-9]{3}(?![0-9])}{$1}g;
                open(my $o, ">", $f) or die "ms-sweep: $f: $!"; print $o $c; close $o or die "ms-sweep: $f: $!";
                $n++;
            }
            print "$n\n";' \
        | awk '{ s += $1 } END { print s + 0 }')
    echo "display-rename: milliseconds dropped from the times on $np page(s) / payload(s)." >&2
}
ms_sweep

r=$(load_rules "input/rename.txt")
[ -n "$r" ] || { echo "display-rename: input/rename.txt holds no usable rule; nothing to rename." >&2; exit 0; }
apply_rules "$r" docs
