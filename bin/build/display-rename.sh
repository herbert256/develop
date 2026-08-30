#!/usr/bin/env bash
#
# display-rename.sh — the DISPLAY RENAME sweep (2026-08-30, user request):
# the LAST page-touching build step. input/rename.txt (repo root of input/,
# shared by both environments) holds PRESENTATION renames:
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
# The entity column (subscription account login host partner application
# domain profile any) is documentation and validation; the value match is
# what rewrites. A missing or empty rename.txt is a no-op. MANUAL-REPUBLISH
# GOTCHA: like crosslink.sh, this runs only in bin/build.sh — a manual
# per-area publish shows real values until the next build.
#
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/../.."

RENAMES="input/rename.txt"
[ -s "$RENAMES" ] || { echo "display-rename: no $RENAMES; nothing to rename." >&2; exit 0; }
[ -d docs ] || { echo "display-rename: no docs/ tree." >&2; exit 0; }

# the rules, validated: 3 columns, a known entity, values on the name alphabet
rules=$(awk '
    /^[ \t]*#/ || /^[ \t]*$/ { next }
    {
        if (NF != 3) { printf "display-rename: line %d: %d column(s), need 3 — skipped\n", NR, NF > "/dev/stderr"; next }
        if ($1 !~ /^(subscription|account|login|host|partner|application|domain|profile|any)$/) {
            printf "display-rename: line %d: unknown entity \"%s\" — skipped\n", NR, $1 > "/dev/stderr"; next }
        if ($2 !~ /^[A-Za-z0-9_.-]+$/ || $3 !~ /^[A-Za-z0-9_.-]+$/) {
            printf "display-rename: line %d: value outside the name alphabet — skipped\n", NR > "/dev/stderr"; next }
        if ($2 == $3) next
        print $2 "\t" $3
    }' "$RENAMES")
[ -n "$rules" ] || { echo "display-rename: $RENAMES holds no usable rule." >&2; exit 0; }

# only the files that CONTAIN an old value are rewritten (mtime churn and
# write I/O stay proportional to the rules, not the site)
pats=$(mktemp "${TMPDIR:-/tmp}/axdr.XXXXXX")
printf '%s\n' "$rules" | cut -f1 > "$pats"
hits=$(find docs -type f \( -name '*.html' -o -name '*-data.js' -o -name 'search-data.js' \) -print0 \
    | xargs -0 grep -lF -f "$pats" 2>/dev/null || true)
if [ -z "$hits" ]; then
    rm -f "$pats"
    echo "display-rename: $(printf '%s\n' "$rules" | wc -l | tr -d ' ') rule(s), 0 pages carry an old value." >&2
    exit 0
fi

# perl (a stated requirement — crosslink uses it too): boundary-guarded
# replacement, rules loaded once. NOTE s{}{} delimiters, never s|…| (the
# repo's perl trap: an escaped | inside s|…| is alternation).
RULES="$rules" perl -pi -e '
    BEGIN {
        for my $l (split /\n/, $ENV{RULES}) {
            my ($old, $new) = split /\t/, $l;
            push @R, [qr{(?<![A-Za-z0-9_.-])\Q$old\E(?![A-Za-z0-9_.-])}, $new];
        }
    }
    for my $r (@R) { s{$r->[0]}{$r->[1]}g; }
' $hits
rm -f "$pats"
echo "display-rename: applied $(printf '%s\n' "$rules" | wc -l | tr -d ' ') rule(s) to $(printf '%s\n' "$hits" | wc -l | tr -d ' ') page(s)." >&2
