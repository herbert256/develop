#!/usr/bin/env bash
#
# display-rename.sh — the DISPLAY RENAME sweep (2026-08-30, user request):
# the LAST page-touching build step. input/<env>/rename.txt (PER ENVIRONMENT
# since 2026-08-31, user request) holds that environment's PRESENTATION
# renames; each env's rules rewrite its own docs/<env>/ tree, and the SHARED
# root pages (the home, the acc-vs-prod pages, everything at the docs root
# that shows both environments' names) take the union of both files:
#
#     <entity> <old_value> <new_value>      (whitespace-separated, # comments)
#     e.g.  subscription UC8_..._SRC_..._DEST UC8_HR_PLURALSIGHT_SAPSF
#
# The rename is PUBLISH-TIME ONLY: the parse caches, the .rpt files and every
# join keep the real value; this sweep rewrites the RENDERED pages (and the
# client-side data payloads — search-data.js, the file-search sidecars) so
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
# what rewrites. A missing or empty rename.txt is a no-op. MANUAL-REPUBLISH
# GOTCHA: like crosslink.sh, this runs only in bin/build.sh — a manual
# per-area publish shows real values until the next build.
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
    local pats hits n
    [ -n "$rules" ] && [ -d "$dir" ] || return 0
    pats=$(mktemp "${TMPDIR:-/tmp}/axdr.XXXXXX")
    printf '%s\n' "$rules" | cut -f1 | LC_ALL=C sort -u > "$pats"
    hits=$(find "$dir" "$@" -type f \( -name '*.html' -o -name '*-data.js' -o -name 'search-data.js' \) -print0 \
        | xargs -0 grep -lF -f "$pats" 2>/dev/null || true)
    rm -f "$pats"
    n=$(printf '%s\n' "$rules" | wc -l | tr -d ' ')
    if [ -z "$hits" ]; then
        echo "display-rename: $dir: $n rule(s), 0 pages carry an old value." >&2
        return 0
    fi
    RULES="$rules" perl -pi -e '
        BEGIN {
            my %seen;
            for my $l (split /\n/, $ENV{RULES}) {
                my ($old, $new) = split /\t/, $l;
                next if $seen{$old}++;
                push @R, [qr{(?<![A-Za-z0-9_.-])\Q$old\E(?![A-Za-z0-9_.-])}, $new];
            }
        }
        for my $r (@R) { s{$r->[0]}{$r->[1]}g; }
    ' $hits
    echo "display-rename: $dir: applied $n rule(s) to $(printf '%s\n' "$hits" | wc -l | tr -d ' ') page(s)." >&2
}

# each env's own tree with its own file; the root-level shared pages (not
# descending into the env trees) with the union of both
all=""
for env in acceptance production; do
    r=$(load_rules "input/$env/rename.txt")
    [ -n "$r" ] || continue
    all="${all:+$all
}$r"
    apply_rules "$r" "docs/$env"
done
[ -n "$all" ] || { echo "display-rename: no input/<env>/rename.txt holds a usable rule; nothing to rename." >&2; exit 0; }
apply_rules "$all" docs -maxdepth 1
