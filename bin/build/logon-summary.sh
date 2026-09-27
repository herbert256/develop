#!/usr/bin/env bash
#
# parse-server.sh — the build's BACKGROUND server step (2026-09-27): the
# server log parse, then the per-login logon summary (bin/logons.sh
# ensure_logons -> data/server/cache/_logons.tsv + _logons-hosts.tsv).
#
# Why here: the summary reads ONLY the server parse cache (+ the blacklist),
# which is final once the parse ends (the later mention rescan rebuilds the
# per-entity caches, never _parse.tsv). Its two consumers — details.sh
# (stage "report: detail pages", in the background) and the server
# logon.sh — used to start at the same time, find it missing and BOTH
# compute it (~35 s each on production). Built here, beside the transfer
# parse, they find it fresh. Both still call ensure_logons: its freshness
# test keeps them correct for a manual run.
#
# Usage: bin/build/parse-server.sh   (bin/build.sh runs it; no arguments)
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
. bin/timing.sh
timed bin/server/parse.sh
. bin/logons.sh
_t0=$(date +%s)
ensure_logons data/server/cache
printf 'TIME %5ds  %s\n' "$(( $(date +%s) - _t0 ))" "ensure_logons (the logon summary)" >&2
