#!/usr/bin/env bash
#
# bin/analyses/reports.sh — run every ANALYSES report script (no HTML):
#
#   reports/cross-reference.sh                -> data/<env>/transfer/reports/cross-*.rpt
#                                                (a TRANSFER-data report housed here —
#                                                its pages sit in the Analyses menu)
#   reports/home.sh                           -> data/<env>/analyses/reports/home.rpt
#                                                (the per-member SEEN counts the home
#                                                page's two status tables need; it also
#                                                materializes the PDA coverage TSVs)
#   reports/entity-search.sh                  -> data/<env>/transfer/reports/entity-search.rpt
#                                                (transfer-data too; AFTER the pda
#                                                report — it reads the PDA coverage TSVs
#                                                ensure_pda_tsvs materializes)
#   reports/first-seen.sh                     -> data/<env>/analyses/reports/first-seen*.rpt + data/<env>/first-seen/
#   reports/seen-in-server-log.sh             -> data/<env>/transfer/reports/seen-in-server-log.rpt
#                                                (transfer-data too; runs LAST — it reads the
#                                                pda.rpt written just above)
#
# The analyses read TRANSFER report outputs (showseen.sh's coverage TSVs and
# METAs, the detail-page slugmaps) and the data/flow-manager config caches — so this
# orchestrator must run AFTER bin/transfer/reports.sh, like the server
# reports. Rendering is bin/analyses/publish.sh (the cross-* and
# seen-in-server-log pages render with the transfer area, bin/transfer/publish.sh).
#
# Usage:  bin/analyses/reports.sh    (from any directory)
#
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Sweep orphaned atomic-write temps from a killed run out of the analyses
# reports dir (the transfer-dir ones are swept by bin/transfer/reports.sh,
# which always runs first). rm -f on an unmatched literal glob is a no-op.
_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$_ROOT/bin/env.sh"
rm -f "$_ROOT/data/$AXWAY_ENV/analyses/reports"/*.rpt.tmp

# THREE waves. Wave 1 overlaps the independent scripts (cross-reference 1.8 s
# is the wave floor); the ensure_pda_tsvs chain runs sequentially in wave 2 —
# first-seen (3.9 s, the longest script) lives THERE since its seen split
# reads the coverage TSVs (2026-08).
#
# The ordering that MUST hold, and why:
#   - coverage.sh, first-seen.sh, home.sh and entity-search.sh all call
#     ensure_pda_tsvs, which writes the SAME three
#     coverage/{partners,applications,domains}.tsv. They stay strictly
#     sequential — running them together races writers on one file set, and
#     cov_put's cmp-guard makes each write atomic but not ordered.
#   - first-seen/entity-search AFTER coverage.sh: their seen flags read those
#     TSVs, and on a from-scratch build nothing else has materialized them yet.
#   - seen-in-server-log LAST: its status tables read the home.rpt written above.
# Everything in wave 1 touches neither the PDA TSVs nor home.rpt (verified by
# grep: no ensure_pda_tsvs call, no home.rpt/COVSRC read).
NJOBS=${AXWAY_NJOBS:-$( (command -v nproc >/dev/null 2>&1 && nproc) || sysctl -n hw.ncpu 2>/dev/null || echo 4 )}
case $NJOBS in ''|*[!0-9]*) NJOBS=4 ;; esac
PIDS=()
run_bg() { "$@" & PIDS+=("$!"); }
wait_all() {
    local p st rc=0
    [ "${#PIDS[@]}" -eq 0 ] && return 0
    for p in "${PIDS[@]}"; do st=0; wait "$p" || st=$?; [ "$st" -ne 0 ] && rc=$st; done
    PIDS=()
    if [ "$rc" -ne 0 ]; then echo "ERROR: an analyses report failed (exit $rc) — aborting." >&2; exit "$rc"; fi
    return 0
}

# wave 1 — independent of the PDA TSVs and of home.rpt
run_bg "$SCRIPT_DIR/reports/cross-reference.sh"
run_bg "$SCRIPT_DIR/reports/entity-coverage.sh"
run_bg "$SCRIPT_DIR/reports/sources-and-targets.sh"   # subscription From/To paths (Search-style), 3 tables
run_bg "$SCRIPT_DIR/reports/skipped.sh"               # reads the parse-time skip sidecars only
run_bg "$SCRIPT_DIR/reports/file-search.sh"           # Files by name (transfer cache + failed.sh error roster)
run_bg "$SCRIPT_DIR/reports/failing-reasons.sh"       # Error reasons (reads failed.rpt — the transfer reports ran first)
run_bg "$SCRIPT_DIR/reports/account-sharing.sh"       # config-only (xref accounts->subscriptions)
run_bg "$SCRIPT_DIR/reports/twins.sh"                 # formats the twin pair maps details.sh persists
# the 2026-08 study reports — transfer caches + base/xref/blue reads only,
# independent of the PDA TSVs and of home.rpt, so wave 1 is safe.
# data-diff is NOT here: its First-seen table reads the first-seen LEDGER
# (data/<env>/first-seen/*.rpt), a wave-2 output — in wave 1 it read the
# PREVIOUS build's ledger, and on a from-scratch build found none at all
# (caught by the 2026-08-15 fresh-build test).
run_bg "$SCRIPT_DIR/reports/triage.sh"
run_bg "$SCRIPT_DIR/reports/partner-scorecard.sh"
run_bg "$SCRIPT_DIR/reports/blast-radius.sh"
run_bg "$SCRIPT_DIR/reports/app-partners.sh"
run_bg "$SCRIPT_DIR/reports/partner-lifecycle.sh"
run_bg "$SCRIPT_DIR/reports/cleanup-backlog.sh"
run_bg "$SCRIPT_DIR/reports/fe-overview.sh"          # Partners - Incoming: config + files cache + logon summary + input/<env>/logons_old.txt + the UC2 pickup sidecar (server pool output — bin/build.sh runs the server reports first)
wait_all

# wave 2 — the ensure_pda_tsvs chain, strictly in order (first-seen moved here
# 2026-08: its seen split now reads the coverage TSVs, incl. the PDA partners)
"$SCRIPT_DIR/reports/coverage.sh"   # the 3 PDA Configured cell .rpts — the home page Total links
"$SCRIPT_DIR/reports/first-seen.sh"
"$SCRIPT_DIR/reports/data-diff.sh"   # AFTER first-seen.sh: its First-seen table reads the ledger first-seen.sh writes
"$SCRIPT_DIR/reports/home.sh"
"$SCRIPT_DIR/reports/entity-search.sh"

# wave 3 — reads home.rpt
"$SCRIPT_DIR/reports/seen-in-server-log.sh"

echo "All analyses reports done." >&2
