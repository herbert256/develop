#!/usr/bin/env bash
#
# reports.sh — run every server report script, each of which writes
# data/<name>.rpt. Reports ONLY — parsing is a separate step (parse.sh); this
# does not build the cache. The reports are independent of each other (none
# reads another SERVER report's .rpt — the unknown-*/site-failures rosters come
# from the TRANSFER reports, produced in the earlier build stage), so they run
# IN PARALLEL over a core-count job pool. ensure_parsed/ensure_config run ONCE
# up front so a stale cache is rebuilt exactly once, never concurrently by the
# forked reports (each report still calls ensure_parsed itself — by then it is
# a fresh-cache no-op). Mirrors bin/transfer/reports.sh. Strict mode plus a
# fail-collecting pool so any failing report aborts the run instead of leaving
# a stale .rpt behind.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"
ensure_config
ensure_parsed
rm -f "$REPORTS_DIR"/*.rpt.tmp   # orphaned atomic-write temps from a killed run

NJOBS=${AXWAY_NJOBS:-$( (command -v nproc >/dev/null 2>&1 && nproc) || sysctl -n hw.ncpu 2>/dev/null || echo 4 )}   # AXWAY_NJOBS: bin/build.sh caps the parallel production chain
case $NJOBS in ''|*[!0-9]*) NJOBS=4 ;; esac

POOL_PIDS=()
pool_run() {   # run "$@" as a background job, at most NJOBS at once
    while [ "$(jobs -rp | wc -l | tr -d ' ')" -ge "$NJOBS" ]; do sleep 0.1; done
    "$@" &
    POOL_PIDS+=("$!")
}
pool_wait() {  # reap every pooled job; abort the run if any report failed
    local p st rc=0
    [ "${#POOL_PIDS[@]}" -eq 0 ] && return 0
    for p in "${POOL_PIDS[@]}"; do
        st=0
        wait "$p" || st=$?
        [ "$st" -ne 0 ] && rc=$st
    done
    POOL_PIDS=()
    if [ "$rc" -ne 0 ]; then
        echo "ERROR: a report failed (exit $rc) — aborting." >&2
        exit "$rc"
    fi
    return 0
}

pool_run "$SCRIPT_DIR/reports/topview.sh"
pool_run "$SCRIPT_DIR/reports/went-kaput.sh"
pool_run "$SCRIPT_DIR/reports/errors-day.sh"
pool_run "$SCRIPT_DIR/reports/error-timing.sh"
pool_run "$SCRIPT_DIR/reports/error-reasons.sh"
pool_run "$SCRIPT_DIR/reports/failure-flows.sh"
pool_run "$SCRIPT_DIR/reports/config-defects.sh"     # the config-hygiene page's server-log tables (a TSV sidecar, not a page)
pool_run "$SCRIPT_DIR/reports/site-failures.sh"
pool_run "$SCRIPT_DIR/reports/connection-diagnostics.sh"
pool_run "$SCRIPT_DIR/reports/auth-activity.sh"
pool_run "$SCRIPT_DIR/reports/ssh-key-auth.sh"
pool_run "$SCRIPT_DIR/reports/ssh-crypto.sh"
pool_run "$SCRIPT_DIR/reports/logon.sh"
pool_run "$SCRIPT_DIR/reports/scheduler-overruns.sh"
pool_run "$SCRIPT_DIR/reports/pesit.sh"
pool_run "$SCRIPT_DIR/reports/stuck-events.sh"
pool_run "$SCRIPT_DIR/reports/file-cleanup.sh"
pool_run "$SCRIPT_DIR/../analyses/reports/uc1-status.sh"
pool_run "$SCRIPT_DIR/../analyses/reports/uc2-status.sh"
pool_run "$SCRIPT_DIR/../analyses/reports/uc4-status.sh"
pool_run "$SCRIPT_DIR/reports/deploy-errors.sh"
pool_run "$SCRIPT_DIR/reports/remote-poll.sh"
pool_run "$SCRIPT_DIR/reports/transfer-site-missing.sh"
pool_run "$SCRIPT_DIR/../analyses/reports/uc3-status.sh"
pool_run "$SCRIPT_DIR/reports/no-remote-dir.sh"
pool_run "$SCRIPT_DIR/reports/no-remote-files.sh"
pool_run "$SCRIPT_DIR/reports/ssh-sessions.sh"
pool_run "$SCRIPT_DIR/reports/cluster-health.sh"
pool_run "$SCRIPT_DIR/reports/inbound-connections.sh"
pool_run "$SCRIPT_DIR/reports/top-messages.sh"
pool_run "$SCRIPT_DIR/reports/unknown-entities.sh"   # ONE map-reduce pass -> all five unknown-* rpts (2026-07)
pool_wait
# The MERGED reports (2026-07 catalog cleanup) concatenate the pool's .rpt
# files, so they run after it: cheap single-awk merges, no log reading.
"$SCRIPT_DIR/reports/errors.sh"
"$SCRIPT_DIR/reports/missing-entities.sh"
"$SCRIPT_DIR/reports/connections.sh"
"$SCRIPT_DIR/reports/logons.sh"
"$SCRIPT_DIR/reports/platform-health.sh"
"$SCRIPT_DIR/reports/capacity.sh"
"$SCRIPT_DIR/reports/ssh-security.sh"
"$SCRIPT_DIR/../analyses/reports/uc-status.sh"
"$SCRIPT_DIR/../analyses/reports/uc2-visits.sh"   # formats uc2-status.sh's pickup sidecar — must run after the pool
"$SCRIPT_DIR/reports/pickups.sh"   # formats the same sidecar — after the pool, behind uc2-status.sh
