#!/usr/bin/env bash
#
# reports.sh — run every transfer report script, each of which writes
# data/<name>.rpt. Reports ONLY — parsing is a separate step (parse.sh); this
# does not build the cache. The reports run IN PARALLEL over a core-count job
# pool, in TWO phases: phase 1 is every independent report (NOT details.sh —
# the longest report step is its own bin/build.sh step, run in the background
# BESIDE phase 1); phase 2 is showseen.sh (lifts rows from the entity summary
# .rpt files and resolves links through details/*/_slugmap.tsv) and
# ranking.sh (reads details.sh's per-type ranking sidecars), which both need
# phase 1 AND details.sh complete. (entity-search.sh runs in the analyses
# stage — see the note at the end.) The parse caches and the
# config caches are built by bin/build.sh before this runs. Strict mode plus a
# fail-collecting pool so any failing report aborts the run instead of leaving
# a stale .rpt behind and exiting success.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"
source "$SCRIPT_DIR/../timing.sh"   # timed: one TIME line per pooled report (2026-09-27)
rm -f "$REPORTS_DIR"/*.rpt.tmp   # orphaned atomic-write temps from a killed run

NJOBS=${AXWAY_NJOBS:-$( (command -v nproc >/dev/null 2>&1 && nproc) || sysctl -n hw.ncpu 2>/dev/null || echo 4 )}   # AXWAY_NJOBS: an optional override of the pool size (nothing sets it; default = the core count)
case $NJOBS in ''|*[!0-9]*) NJOBS=4 ;; esac

POOL_TIMED=1; POOL_WHAT="a report"
source "$SCRIPT_DIR/../pool.sh"   # pool_run / pool_wait — the one job pool (2026-09-30)

# OPTIONAL ARGUMENT (2026-07): "phase1" or "phase2" runs only that half, so
# bin/build.sh can overlap phase 1 with the details.sh step (phase 2 reads
# details/*/_slugmap.tsv, phase 1 does not). No argument = both, in order,
# exactly as before — which is what a manual run wants.
PHASE=${1:-both}
case $PHASE in both|phase1|phase2) ;; *) echo "usage: reports.sh [phase1|phase2]" >&2; exit 2 ;; esac

if [ "$PHASE" != phase2 ]; then
# --- phase 1: independent reports ---
# LONGEST FIRST (2026-09-27): the two slow independent writers start first —
# entities.sh (~25 s on production) sat 56th of ~60 in this list, so its
# whole run was the tail of the stage. Neither reads another report of this
# phase, and nothing here reads what they write.
pool_run "$SCRIPT_DIR/reports/entities.sh"   # the Entities PAGES (the grouped layout, 2026-09-13) + the nine classic <dim>.rpt records (the five classic writers folded in, 2026-09-30)
pool_run "$SCRIPT_DIR/reports/topview.sh"
pool_run "$SCRIPT_DIR/reports/stale-accounts.sh"
pool_run "$SCRIPT_DIR/reports/went-quiet.sh"
pool_run "$SCRIPT_DIR/reports/size-profile.sh"
pool_run "$SCRIPT_DIR/reports/connection-efficiency.sh"
pool_run "$SCRIPT_DIR/reports/recovered.sh"
pool_run "$SCRIPT_DIR/reports/recovered-files.sh"
pool_run "$SCRIPT_DIR/reports/security-outreach.sh"
pool_run "$SCRIPT_DIR/reports/failure-heatmap.sh"
pool_run "$SCRIPT_DIR/reports/not-in-flow-manager.sh"
pool_run "$SCRIPT_DIR/reports/day.sh"
pool_run "$SCRIPT_DIR/reports/weekly.sh"
pool_run "$SCRIPT_DIR/reports/red-run.sh"   # the red-run sidecar (from-green-to-red + only-red until 2026-09-30)
pool_run "$SCRIPT_DIR/reports/waiting.sh"
pool_run "$SCRIPT_DIR/reports/expired.sh"
pool_run "$SCRIPT_DIR/reports/missing-cronjobs.sh"
pool_run "$SCRIPT_DIR/reports/punctuality.sh"   # pageless since 2026-09-29: the Polling pages' file-arrival slot
pool_run "$SCRIPT_DIR/reports/failed.sh"
pool_run "$SCRIPT_DIR/reports/retry.sh"
pool_run "$SCRIPT_DIR/reports/pirates.sh"
pool_run "$SCRIPT_DIR/reports/legs-count.sh"
pool_run "$SCRIPT_DIR/reports/protocol-journey.sh"
pool_run "$SCRIPT_DIR/reports/attempts.sh"
pool_run "$SCRIPT_DIR/reports/resubmissions.sh"
pool_run "$SCRIPT_DIR/reports/patterns.sh"
pool_run "$SCRIPT_DIR/reports/protocol.sh"
pool_run "$SCRIPT_DIR/reports/file-type.sh"
pool_run "$SCRIPT_DIR/reports/size-dist.sh"
pool_run "$SCRIPT_DIR/reports/hourly.sh"
pool_run "$SCRIPT_DIR/reports/weekday.sh"
pool_run "$SCRIPT_DIR/reports/anomalies.sh"
pool_run "$SCRIPT_DIR/reports/duration.sh"
pool_run "$SCRIPT_DIR/reports/duration-longest.sh"        # the Top 50 longest Files (split off duration.sh 2026-09-03)
pool_run "$SCRIPT_DIR/reports/duration-distribution.sh"   # the duration histogram (split off duration.sh 2026-09-03)
pool_run "$SCRIPT_DIR/reports/dwell-time.sh"
pool_run "$SCRIPT_DIR/reports/top-transfers.sh"
pool_run "$SCRIPT_DIR/reports/duplicate-files.sh"
pool_run "$SCRIPT_DIR/reports/file-in-file-out.sh"   # partner-to-partner handovers carried by two subscriptions
pool_run "$SCRIPT_DIR/reports/uc4-to-uc2.sh"         # a UC4 delivery collected back by the same-named UC2 subscription (2026-09-14)
pool_run "$SCRIPT_DIR/reports/same-protocol.sh"      # Files whose first inbound and last outbound leg share one protocol (2026-09-14)
# (cross-reference.sh moved to bin/analyses/reports/ 2026-07 — its pages sit
# in the Analyses menu; bin/analyses/reports.sh runs it, still writing into
# the transfer reports dir)
pool_run "$SCRIPT_DIR/reports/av-scan.sh"
pool_run "$SCRIPT_DIR/reports/security-params.sh"
# (details.sh is its OWN bin/build.sh step since 2026-07 — it runs in the
# background BESIDE phase 1 there (AXWAY_WAIT_FAILED=1: it waits for the
# .phase1-pool-done signal below); the phase-2 scripts read its outputs, so a
# MANUAL run of phase 2 needs bin/transfer/reports/details.sh first)
pool_run "$SCRIPT_DIR/reports/incoming-connections.sh"   # whitelisted-IP detail pages (details/incoming_connections/)
pool_wait
# the phase-1 POOL is done — failed.sh's _srvsubs-map.tsv is written: the
# signal details.sh waits for when bin/build.sh runs it beside this phase
# (AXWAY_WAIT_FAILED, 2026-09-28 fix — it used to race the map)
: > "$REPORTS_DIR/.phase1-pool-done"
# The MERGED reports (2026-07 catalog cleanup) concatenate phase-1 .rpt files,
# so they run after the pool: cheap single-awk merges, no log reading.
"$SCRIPT_DIR/reports/activity.sh"
"$SCRIPT_DIR/reports/retries.sh"
"$SCRIPT_DIR/reports/merge-episodes.sh"   # 2026-09-29: the episodes + the Recovered flows tab
"$SCRIPT_DIR/reports/file-journey.sh"
"$SCRIPT_DIR/reports/merge-file-in-file-out.sh"   # 2026-09-29: the handovers + the UC4 to UC2 tab
"$SCRIPT_DIR/reports/files.sh"
"$SCRIPT_DIR/reports/merge-went-quiet.sh"
"$SCRIPT_DIR/reports/failed-files.sh"          # 2026-09-14: every failed File + its reason — reads the pool failed.sh's reasons sidecar, so after pool_wait
"$SCRIPT_DIR/reports/unknown-transfers.sh"     # 2026-09-29: every File with subscription "Unknown" — links the File pages the pool wrote, so after pool_wait
"$SCRIPT_DIR/reports/merge-duration-dwell.sh"   # 2026-09-05: duration-distribution + dwell-time on one page, histograms side by side
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

