#!/usr/bin/env bash
#
# reports.sh — run every server report script, each of which writes
# data/<name>.rpt. Reports ONLY — parsing is a separate step (parse.sh); this
# does not build the cache. The pooled reports are independent of each other
# (none reads another SERVER report's .rpt — the unknown-*/site-failures rosters come
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
source "$SCRIPT_DIR/../timing.sh"   # timed: one TIME line per pooled report (2026-09-27)
ensure_config
ensure_parsed
rm -f "$REPORTS_DIR"/*.rpt.tmp   # orphaned atomic-write temps from a killed run

NJOBS=${AXWAY_NJOBS:-$( (command -v nproc >/dev/null 2>&1 && nproc) || sysctl -n hw.ncpu 2>/dev/null || echo 4 )}   # AXWAY_NJOBS: bin/build.sh caps the parallel production chain
case $NJOBS in ''|*[!0-9]*) NJOBS=4 ;; esac

POOL_PIDS=()
pool_run() {   # run "$@" as a background job, at most NJOBS at once
    while [ "$(jobs -rp | wc -l | tr -d ' ')" -ge "$NJOBS" ]; do sleep 0.1; done
    timed "$@" &
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

# THE SERVER-CACHE SUBSETS (2026-09-27, build-speed round 2): one parallel
# pass copies each consumer's RARE message families out of the 3 GB cache
# (bin/server/subsets.sh); six reports below read their subset
# (srv_subset) instead of the whole cache. Before the pool: they need it.
timed "$SCRIPT_DIR/subsets.sh"

# LONGEST FIRST (2026-09-27): the four slowest reports of the pool start
# first (logon 22 s, ssh-crypto 19 s, uc2-status 18 s, uc4-status 16 s on
# production; they sat 17th-25th). Each reads only the transfer reports and
# caches built before this stage; their outputs are read after the pool
# (uc2-visits, pickups) or in later stages.
pool_run "$SCRIPT_DIR/reports/logon.sh"
pool_run "$SCRIPT_DIR/reports/ssh-crypto.sh"
pool_run "$SCRIPT_DIR/../analyses/reports/uc2-status.sh"
pool_run "$SCRIPT_DIR/../analyses/reports/uc4-status.sh"
pool_run "$SCRIPT_DIR/reports/topview.sh"
pool_run "$SCRIPT_DIR/reports/went-kaput.sh"
pool_run "$SCRIPT_DIR/reports/errors-day.sh"
pool_run "$SCRIPT_DIR/reports/error-timing.sh"
pool_run "$SCRIPT_DIR/reports/error-reasons.sh"
pool_run "$SCRIPT_DIR/reports/failure-flows.sh"
pool_run "$SCRIPT_DIR/reports/io-errors.sh"          # "IO Error reading file /data/FlowManager/…" — the srv-errors group's third member (2026-09-06)
pool_run "$SCRIPT_DIR/reports/could-not-send.sh"     # "Could not send file" (AR0074) — the srv-errors group fourth member (2026-09-12)
pool_run "$SCRIPT_DIR/reports/publish-failed.sh"     # "Publish to account failed" (ARPA0001) — srv-errors (2026-09-12)
pool_run "$SCRIPT_DIR/reports/event-queue.sh"        # "[Pesit Default] Unable to submit event AgentEvent" -> the dashboards' 30-min sidecar (2026-09-14); an unpublished intermediate since 2026-09-27
pool_run "$SCRIPT_DIR/reports/post-client-action.sh" # "Post client action error" (ARRC0009) — srv-errors (2026-09-12)
pool_run "$SCRIPT_DIR/reports/config-defects.sh"     # the config-hygiene page's server-log tables (a TSV sidecar, not a page)
pool_run "$SCRIPT_DIR/reports/site-failures.sh"
pool_run "$SCRIPT_DIR/reports/connection-diagnostics.sh"
pool_run "$SCRIPT_DIR/reports/auth-activity.sh"
pool_run "$SCRIPT_DIR/reports/ssh-key-auth.sh"
pool_run "$SCRIPT_DIR/reports/pesit.sh"              # -> pesit-slots.tsv, the dashboards' PeSIT view; an unpublished intermediate since 2026-09-27
pool_run "$SCRIPT_DIR/../analyses/reports/uc1-status.sh"
pool_run "$SCRIPT_DIR/reports/deploy-errors.sh"
pool_run "$SCRIPT_DIR/reports/remote-poll.sh"
# (transfer-site-missing.sh — the "Transfer site missing" report — was removed
# 2026-09-27, user request; its stale .rpt is dropped here)
rm -f "$REPORTS_DIR/transfer-site-missing.rpt"
pool_run "$SCRIPT_DIR/../analyses/reports/uc3-status.sh"
pool_run "$SCRIPT_DIR/reports/no-remote-dir.sh"
pool_run "$SCRIPT_DIR/reports/no-remote-files.sh"
pool_run "$SCRIPT_DIR/reports/ssh-sessions.sh"
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
# (the "Operations & Capacity" group — Platform health, Capacity & sessions,
# EventQueue — was removed 2026-09-27, user request: its merges and the
# cluster-health / stuck-events / scheduler-overruns / file-cleanup
# components went; pesit.sh and event-queue.sh stay for the graph sidecars.
# Drop what a pre-removal build left behind.)
rm -f "$REPORTS_DIR"/{platform-health,capacity,cluster-health,stuck-events,scheduler-overruns,file-cleanup}.rpt
"$SCRIPT_DIR/reports/ssh-security.sh"
"$SCRIPT_DIR/../analyses/reports/uc3-polling.sh"   # the UC3 tab's polling tables: reads remote-poll.rpt + its sidecars — after the pool, before the uc-status merge (2026-09-05)
"$SCRIPT_DIR/../analyses/reports/polling.sh"   # the flat Polling page (Analyses / Configuration): remote-poll.rpt + sidecars + the cron schedules in ONE table (2026-09-05)
"$SCRIPT_DIR/../analyses/reports/uc-status.sh"
"$SCRIPT_DIR/../analyses/reports/uc2-visits.sh"   # formats uc2-status.sh's pickup sidecar — must run after the pool
"$SCRIPT_DIR/reports/pickups.sh"   # formats the same sidecar — after the pool, behind uc2-status.sh
