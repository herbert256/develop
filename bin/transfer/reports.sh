#!/usr/bin/env bash
#
# reports.sh — run every transfer report script, each of which writes
# data/<name>.rpt. Reports ONLY — parsing is a separate step (parse.sh); this
# does not build the cache. The reports run IN PARALLEL over a core-count job
# pool, in TWO phases: phase 1 is every independent report (details.sh
# included — it is the longest and paces the wall clock); phase 2 is
# showseen.sh (lifts rows from the entity summary .rpt files and resolves
# links through details/*/_slugmap.tsv) and entity-search.sh (reads the detail
# .rpt files), which both need phase 1 complete. ensure_parsed/ensure_config
# run ONCE up front so a stale cache is rebuilt exactly once, never
# concurrently by the forked reports (each report still calls ensure_parsed
# itself — by then it is a fresh-cache no-op). Strict mode plus a
# fail-collecting pool so any failing report aborts the run instead of leaving
# a stale .rpt behind and exiting success.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"
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

# OPTIONAL ARGUMENT (2026-07): "phase1" or "phase2" runs only that half, so
# bin/build.sh can overlap phase 1 with the details.sh step (phase 2 reads
# details/*/_slugmap.tsv, phase 1 does not). No argument = both, in order,
# exactly as before — which is what a manual run wants.
PHASE=${1:-both}
case $PHASE in both|phase1|phase2) ;; *) echo "usage: reports.sh [phase1|phase2]" >&2; exit 2 ;; esac

if [ "$PHASE" != phase2 ]; then
# --- phase 1: independent reports ---
pool_run "$SCRIPT_DIR/reports/topview.sh"
pool_run "$SCRIPT_DIR/reports/account.sh"
pool_run "$SCRIPT_DIR/reports/stale-accounts.sh"
pool_run "$SCRIPT_DIR/reports/went-quiet.sh"
pool_run "$SCRIPT_DIR/reports/expected-arrival.sh"
pool_run "$SCRIPT_DIR/reports/route-throughput.sh"
pool_run "$SCRIPT_DIR/reports/duration-trend.sh"
pool_run "$SCRIPT_DIR/reports/size-profile.sh"
pool_run "$SCRIPT_DIR/reports/connection-efficiency.sh"
pool_run "$SCRIPT_DIR/reports/recovered.sh"
pool_run "$SCRIPT_DIR/reports/recovered-files.sh"
pool_run "$SCRIPT_DIR/reports/security-outreach.sh"
pool_run "$SCRIPT_DIR/reports/failure-heatmap.sh"
pool_run "$SCRIPT_DIR/reports/not-in-flow-manager.sh"
pool_run "$SCRIPT_DIR/reports/day.sh"
pool_run "$SCRIPT_DIR/reports/weekly.sh"
pool_run "$SCRIPT_DIR/reports/login.sh"
pool_run "$SCRIPT_DIR/reports/subscription.sh"
pool_run "$SCRIPT_DIR/reports/volume.sh"
pool_run "$SCRIPT_DIR/reports/trend.sh"
pool_run "$SCRIPT_DIR/reports/episodes.sh"
pool_run "$SCRIPT_DIR/reports/from-green-to-red.sh"
pool_run "$SCRIPT_DIR/reports/only-red.sh"
pool_run "$SCRIPT_DIR/reports/waiting.sh"
pool_run "$SCRIPT_DIR/reports/expired.sh"
pool_run "$SCRIPT_DIR/reports/missing-cronjobs.sh"
pool_run "$SCRIPT_DIR/reports/punctuality.sh"
pool_run "$SCRIPT_DIR/reports/failed.sh"
pool_run "$SCRIPT_DIR/reports/failure-rate.sh"
pool_run "$SCRIPT_DIR/reports/retry.sh"
pool_run "$SCRIPT_DIR/reports/pirates.sh"
pool_run "$SCRIPT_DIR/reports/legs-count.sh"
pool_run "$SCRIPT_DIR/reports/protocol-journey.sh"
pool_run "$SCRIPT_DIR/reports/attempts.sh"
pool_run "$SCRIPT_DIR/reports/resubmissions.sh"
pool_run "$SCRIPT_DIR/reports/patterns.sh"
pool_run "$SCRIPT_DIR/reports/protocol.sh"
pool_run "$SCRIPT_DIR/reports/arrived-left.sh"
pool_run "$SCRIPT_DIR/reports/file-type.sh"
pool_run "$SCRIPT_DIR/reports/size-dist.sh"
pool_run "$SCRIPT_DIR/reports/hourly.sh"
pool_run "$SCRIPT_DIR/reports/weekday.sh"
pool_run "$SCRIPT_DIR/reports/anomalies.sh"
pool_run "$SCRIPT_DIR/reports/duration.sh"
pool_run "$SCRIPT_DIR/reports/dwell-time.sh"
pool_run "$SCRIPT_DIR/reports/top-transfers.sh"
pool_run "$SCRIPT_DIR/reports/duplicate-files.sh"
pool_run "$SCRIPT_DIR/reports/file-in-file-out.sh"   # partner-to-partner handovers carried by two subscriptions
pool_run "$SCRIPT_DIR/reports/remote-host.sh"
pool_run "$SCRIPT_DIR/reports/pda-entities.sh"
# (cross-reference.sh and seen-in-server-log.sh moved to bin/analyses/reports/
# 2026-07 — their pages sit in the Analyses menu; bin/analyses/reports.sh runs
# them, still writing into the transfer reports dir)
pool_run "$SCRIPT_DIR/reports/av-scan.sh"
pool_run "$SCRIPT_DIR/reports/security-params.sh"
# (details.sh is its OWN bin/build.sh step since 2026-07 — it runs BEFORE
# this orchestrator there; the phase-2 scripts below read its outputs, so a
# MANUAL run needs bin/transfer/reports/details.sh first when details are stale)
pool_run "$SCRIPT_DIR/reports/incoming-connections.sh"   # whitelisted-IP detail pages (details/incoming_connections/)
pool_wait
# The MERGED reports (2026-07 catalog cleanup) concatenate phase-1 .rpt files,
# so they run after the pool: cheap single-awk merges, no log reading.
"$SCRIPT_DIR/reports/activity.sh"
"$SCRIPT_DIR/reports/retries.sh"
"$SCRIPT_DIR/reports/file-journey.sh"
"$SCRIPT_DIR/reports/files.sh"
"$SCRIPT_DIR/reports/merge-volume.sh"
"$SCRIPT_DIR/reports/merge-went-quiet.sh"
fi

if [ "$PHASE" != phase1 ]; then
# --- phase 2: reports that read phase-1 outputs (and details.sh's slugmaps) ---
pool_run "$SCRIPT_DIR/reports/showseen.sh"        # reads the entity summary .rpts + details/*/_slugmap.tsv
pool_run "$SCRIPT_DIR/reports/ranking.sh"         # reads details.sh's per-type ranking sidecars
pool_wait
fi
# NOTE: entity-search.sh is NOT run here — it reads the PDA coverage TSVs
# only the ANALYSES stage materializes (ensure_pda_tsvs), so it is housed
# with the analyses reports and runs there, after the pda/coverage reports

# NOTE: seen-in-server-log.sh is NOT run here — it reads the ANALYSES pda.rpt
# (PDA Seen), so bin/analyses/reports.sh runs it as its LAST report step,
# right after the pda.rpt is written (a fresh build has no pda.rpt earlier).
