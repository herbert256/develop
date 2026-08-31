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
