#!/usr/bin/env bash
#
# bin/analyses/reports.sh — run every ANALYSES report script (no HTML):
#
#   reports/cross-reference.sh                -> data/transfer/reports/cross-*.rpt
#                                                (a TRANSFER-data report housed here —
#                                                its pages are analyses/ pages)
#   reports/home.sh                           -> data/analyses/reports/home.rpt
#                                                (the per-member SEEN counts the home
#                                                page's two status tables need; it also
#                                                materializes the PDA coverage TSVs)
#   reports/entity-search.sh                  -> data/transfer/reports/entity-search.rpt
#                                                (transfer-data too; AFTER the pda
#                                                report — it reads the PDA coverage TSVs
#                                                ensure_pda_tsvs materializes)
#   reports/first-seen.sh                     -> data/analyses/reports/first-seen*.rpt + data/first-seen/
#
# The analyses read TRANSFER report outputs (showseen.sh's coverage TSVs and
# Seen counts, the detail-page slugmaps) and the data/flow-manager config caches — so this
# orchestrator must run AFTER bin/transfer/reports.sh, like the server
# reports. Rendering is bin/analyses/publish.sh (the cross-* pages render
# with the transfer area, bin/transfer/publish.sh).
#
# Usage:  bin/analyses/reports.sh    (from any directory)
#
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Sweep orphaned atomic-write temps from a killed run out of the analyses
# reports dir (the transfer-dir ones are swept by bin/transfer/reports.sh,
# which always runs first). rm -f on an unmatched literal glob is a no-op.
_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$SCRIPT_DIR/../timing.sh"   # timed: one TIME line per report (2026-09-27)
rm -f "$_ROOT/data/analyses/reports"/*.rpt.tmp

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
#     cov_put makes each write atomic but not ordered.
#   - first-seen/entity-search AFTER coverage.sh: their seen flags read those
#     TSVs, and on a from-scratch build nothing else has materialized them yet.
# Everything in wave 1 touches neither the PDA TSVs nor home.rpt (verified by
# grep: no ensure_pda_tsvs call, no home.rpt/COVSRC read).
PIDS=()
run_bg() { timed "$@" & PIDS+=("$!"); }
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
run_bg "$SCRIPT_DIR/reports/skipped.sh"               # reads the parse-time skip sidecars only
run_bg "$SCRIPT_DIR/reports/failing-reasons.sh"       # Error reasons (reads failed-files.rpt — the transfer reports ran first)
# (the 2026-08 study reports Partner scorecard, Blast radius and Application
# dependencies went 2026-09-30, user request)
# Partners Out (2026-09-30, user request): every host we connect OUT to —
# base/_hosts.tsv, the logon summary, the ip map, the xref and the server
# pool's logon.rpt Outgoing table; independent of the PDA TSVs and home.rpt
run_bg "$SCRIPT_DIR/reports/partners-out.sh"
run_bg "$SCRIPT_DIR/reports/fe-overview.sh"          # Partners in: config + files cache + logon summary + input/logons_old.txt + the UC2 pickup sidecar (server pool output — bin/build.sh runs the server reports first)

# wave 2 — the ensure_pda_tsvs chain, strictly in order (first-seen moved here
# 2026-08: its seen split now reads the coverage TSVs, incl. the PDA partners).
# ONE background job BESIDE wave 1 (2026-09-27): the chain reads no wave-1
# output and wave 1 reads none of its outputs (the grep above, redone that
# day for the other direction too: no wave-2 script names a wave-1 report,
# nor partners-in), so it no longer waits for the slowest wave-1 report
( timed "$SCRIPT_DIR/reports/coverage.sh"   # the 5 Logical / PDA / BL Configured cell .rpts — the home page Total links
  timed "$SCRIPT_DIR/reports/first-seen.sh"
  timed "$SCRIPT_DIR/reports/home.sh"
  timed "$SCRIPT_DIR/reports/entity-search.sh" ) & PIDS+=("$!")
wait_all
# MERGED (2026-09-13, user request; the whole Logons › Incoming table since
# 2026-09-30): fe-overview.rpt (wave 1, just above) + the Incoming table of
# the server pool's logon.rpt -> Partners in (analyses/partners-in.html);
# reads the two .rpt files only
timed "$SCRIPT_DIR/reports/partners-in.sh"

echo "All analyses reports done." >&2
