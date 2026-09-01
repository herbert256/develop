#!/usr/bin/env bash
#
# migrate-input.sh — a ONE-TIME layout migration, run first by bin/build.sh.
#
# On 2026-08-31 (user request) the eight hand-curated policy files stopped
# being shared and became PER ENVIRONMENT:
#
#     input/BL.txt              -> input/<env>/BL.txt
#     input/blacklist.txt       -> input/<env>/blacklist.txt
#     input/logical.txt         -> input/<env>/logical.txt
#     input/logical_apps.txt    -> input/<env>/logical_apps.txt
#     input/logical_domains.txt -> input/<env>/logical_domains.txt
#     input/logical_partners.txt-> input/<env>/logical_partners.txt
#     input/rename.txt          -> input/<env>/rename.txt
#     input/skip.txt            -> input/<env>/skip.txt
#     input/partner-aliases.tsv -> input/<env>/partner-aliases.tsv
#
# ... and a SECOND one-time migration since 2026-09-01 (user request):
# input/<env>/partner-aliases.tsv is retired altogether, its curated pairs
# folded into input/<env>/logical_partners.txt as PART REPLACEMENTS
# (fold_aliases below).
#
# The develop repo moved its sample
# copies in git; the RUNTIME checkout holds the real files at the old place and
# bin/runtime.sh never syncs input/, so without this step its next build would
# read empty per-env files and silently drop every rule. For each legacy file
# still at input/: copy it into EVERY existing env dir that lacks it (both
# environments start from the same content — the user splits them afterwards),
# then remove the shared copy. Nothing is ever overwritten. Prints what moved;
# a migrated checkout costs one fast no-op.
#
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/../.."

FILES="BL.txt blacklist.txt logical.txt logical_apps.txt logical_domains.txt logical_partners.txt rename.txt skip.txt partner-aliases.tsv"

# fold_aliases ENVDIR — the SECOND one-time migration (2026-09-01, user
# request): input/<env>/partner-aliases.tsv is retired, its curated pairs
# becoming PART REPLACEMENTS in input/<env>/logical_partners.txt. A pair
# "variant<TAB>CANONICAL" says the two tokens name one organisation; as a
# part replacement "VARIANT CANONICAL" the variant is rewritten to the
# canonical BEFORE the partner token enters the merge, which subsumes both
# the old merge rule 4 and the "alias star" that named the merged group.
# Single-token lines were already inert and are dropped. Pairs already in
# logical_partners.txt are not duplicated. The .tsv is removed only after
# the replacements are safely written.
fold_aliases() {
    local ed=$1 al="$1/partner-aliases.tsv" lp="$1/logical_partners.txt" n
    [ -f "$al" ] || return 0
    [ -f "$lp" ] || : > "$lp"
    n=$(awk -v LP="$lp" -v DT="$(date '+%Y-%m-%d')" '
        BEGIN { while ((getline l < LP) > 0) {
                    if (l ~ /^[ \t]*#/ || l ~ /^[ \t]*$/) continue
                    if (split(l, a, /[ \t]+/) >= 2 && a[1] != "") have[toupper(a[1])] = 1 }
                close(LP) }
        /^[ \t]*#/ || /^[ \t]*$/ { next }
        { n = split($0, a, "\t")
          if (n < 2 || a[1] == "" || a[2] == "") next          # a single token was inert
          f = toupper(a[1]); t = toupper(a[2])
          if (f == t || (f in have)) next
          have[f] = 1; PR[++np] = f "\t" t }
        END { if (np) { printf "\n# folded from the retired partner-aliases.tsv (%s)\n", DT >> LP
                        for (i = 1; i <= np; i++) { split(PR[i], b, "\t"); printf "%-28s %s\n", b[1], b[2] >> LP } }
              print np + 0 }' "$al")
    rm -f "$al"
    if [ "${n:-0}" -gt 0 ]; then
        echo "migrate-input: folded $n partner alias pair(s) into $lp; removed $al." >&2
    else
        echo "migrate-input: removed $al (no pair to fold — it was empty, comments only, or already folded)." >&2
    fi
}
envs=""
for e in acceptance production; do [ -d "input/$e" ] && envs="$envs $e"; done
if [ -z "$envs" ]; then
    echo "migrate-input: no input/<env>/ directory yet — nothing to migrate into." >&2
    exit 0
fi

moved=0
for f in $FILES; do
    [ -f "input/$f" ] || continue
    for e in $envs; do
        if [ -f "input/$e/$f" ]; then
            echo "migrate-input: input/$e/$f already exists — the shared input/$f is NOT copied over it." >&2
        else
            cp -p "input/$f" "input/$e/$f"
            echo "migrate-input: input/$f -> input/$e/$f" >&2
        fi
    done
    rm -f "input/$f"
    echo "migrate-input: removed the shared input/$f (per-environment since 2026-08-31 — edit the input/<env>/ copies)." >&2
    moved=$((moved + 1))
done
if [ "$moved" -eq 0 ]; then
    echo "migrate-input: nothing to migrate (already per environment)." >&2
else
    echo "migrate-input: $moved shared policy file(s) moved into$envs." >&2
fi

# the partner-aliases -> logical_partners fold, per environment (see above)
for e in $envs; do fold_aliases "input/$e"; done
