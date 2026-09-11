#!/usr/bin/env bash
#
# bin/acc.sh — refresh the ACCEPTANCE runtime checkout (../runtime-acceptance, beside this
# develop repo) with this repo's code and rebuild its site from its own real
# data. No arguments. What happens, step by step: bin/runtime-lib.sh.
#
#   bin/acc.sh
#
set -euo pipefail
[ $# -eq 0 ] || { echo "usage: bin/acc.sh   (no arguments — syncs the code into ../runtime-acceptance and runs its bin/fresh.sh)" >&2; exit 2; }
source "$(dirname "${BASH_SOURCE[0]}")/runtime-lib.sh"
runtime_refresh runtime-acceptance
