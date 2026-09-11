#!/usr/bin/env bash
#
# bin/prd.sh — refresh the PRODUCTION runtime checkout (../runtime-production, beside this
# develop repo) with this repo's code and rebuild its site from its own real
# data. No arguments. What happens, step by step: bin/runtime-lib.sh.
#
#   bin/prd.sh
#
set -euo pipefail
[ $# -eq 0 ] || { echo "usage: bin/prd.sh   (no arguments — syncs the code into ../runtime-production and runs its bin/fresh.sh)" >&2; exit 2; }
source "$(dirname "${BASH_SOURCE[0]}")/runtime-lib.sh"
runtime_refresh runtime-production
