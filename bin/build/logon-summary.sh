#!/usr/bin/env bash
#
# logon-summary.sh — a BACKGROUND build step (2026-09-27): the per-login and
# per-address logon summary (bin/logons.sh ensure_logons -> data/server/
# cache/_logons.tsv + _logons-hosts.tsv), built ONCE per build.
#
# Its two consumers — details.sh (the detail-page reports, a background step
# too) and the server logon.sh — used to start at the same time, find it
# missing and BOTH compute it (~22-35 s each on production). It reads only the
# server parse cache (+ the blacklist), final once the server parse ends — the
# later mention rescan rebuilds the per-entity caches, never _parse.tsv — so
# bin/build.sh starts it right after the server parse is waited for: it runs
# beside the server-log -> transfer steps and is waited for before the
# report stage. Both consumers still call ensure_logons (the summary exists
# by then, so a no-op in the build; still correct for a manual run).
#
# Usage: bin/build/logon-summary.sh   (bin/build.sh runs it; no arguments)
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
. bin/fastawk.sh
. bin/logons.sh
_t0=$(date +%s)
ensure_logons data/server/cache
printf 'TIME %5ds  %s\n' "$(( $(date +%s) - _t0 ))" "ensure_logons (the logon summary)" >&2
