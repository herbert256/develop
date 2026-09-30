#!/usr/bin/env bash
#
# reports.sh — run every server report script, each of which writes
# data/<name>.rpt. Reports ONLY — parsing is a separate step (parse.sh); this
# does not build the cache. The pooled reports are independent of each other
# (none reads another SERVER report's .rpt — the rosters some of them join,
# e.g. site-failures' subscription list, come from the TRANSFER reports of the
# earlier build stage; the unknown-* known sets read the transfer parse cache
# directly), so they run IN PARALLEL over a core-count job pool. The parse caches and the config
# caches are built by bin/build.sh before this runs. Mirrors
# bin/transfer/reports.sh. Strict mode plus a
# fail-collecting pool so any failing report aborts the run instead of leaving
# a stale .rpt behind.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"
source "$SCRIPT_DIR/../timing.sh"   # timed: one TIME line per pooled report (2026-09-27)
source "$SCRIPT_DIR/../merge_rpt.sh"   # append_rpt_tables (2026-09-29)
rm -f "$REPORTS_DIR"/*.rpt.tmp   # orphaned atomic-write temps from a killed run

NJOBS=${AXWAY_NJOBS:-$( (command -v nproc >/dev/null 2>&1 && nproc) || sysctl -n hw.ncpu 2>/dev/null || echo 4 )}   # AXWAY_NJOBS: an optional override of the pool size (nothing sets it; default = the core count)
case $NJOBS in ''|*[!0-9]*) NJOBS=4 ;; esac

POOL_TIMED=1; POOL_WHAT="a report"
source "$SCRIPT_DIR/../pool.sh"   # pool_run / pool_wait — the one job pool (2026-09-30)

# THE SERVER-CACHE SUBSETS (2026-09-27, build-speed round 2): one parallel
# pass copies each consumer's RARE message families out of the 3 GB cache
# (bin/server/subsets.sh); the consumers below read their subset
# (srv_subset) instead of the whole cache. SIDE BY SIDE with the pool since
# 2026-09-29 (speed round 3): it ran BEFORE the pool, and the slowest reports
# — logon, ssh-crypto, uc2/uc4-status, none of which reads a subset — waited
# its ~5 s; now every job that reads the whole cache is queued first, and the
# subset consumers only once the set is complete (srv_subset would fall back
# to the whole cache, correct but slow, without subsets/.done).
timed "$SCRIPT_DIR/subsets.sh" & SUBSETS_PID=$!

# LONGEST FIRST (2026-09-27): the four slowest reports of the pool start
# first (logon 22 s, ssh-crypto 19 s, uc2-status 18 s, uc4-status 16 s on
# production; they sat 17th-25th). Each reads only the transfer reports and
# caches built before this stage; their outputs are read after the pool
# (uc2-visits, pickups) or in later stages.
pool_run "$SCRIPT_DIR/reports/logon.sh"
pool_run "$SCRIPT_DIR/reports/ssh-crypto.sh"
pool_run "$SCRIPT_DIR/../analyses/reports/uc2-status.sh"
pool_run "$SCRIPT_DIR/../analyses/reports/uc4-status.sh"
# unknown-entities right behind them (2026-09-29, speed round 3): it was the
# LAST job and, six workers wide, the one that ran on alone at the end of
# the stage (11 s on production); an early start folds it into the busy part
pool_run "$SCRIPT_DIR/reports/unknown-entities.sh"   # ONE map-reduce pass -> all five unknown-* rpts (2026-07)
pool_run "$SCRIPT_DIR/reports/auth-activity.sh"
pool_run "$SCRIPT_DIR/reports/inbound-connections.sh"   # the whole cache (an "inbound" subset measured a loss, 2026-09-30 — bin/server/subsets.sh)
# (bin/build/kaput-evidence.sh — went-kaput.sh here until 2026-09-30 — is not in this pool: bin/build.sh runs it once, early — right
# after result.sh — because failed.sh and details.sh read its evidence sidecar)
# (transfer-site-missing.sh — the "Transfer site missing" report — was removed
# 2026-09-27, user request. Likewise the 2026-09-28 fewer-server-reports round:
# ssh-key-auth — its tables were the Incoming Bad key / Locked columns and a
# subset of Outgoing — and the three AR-line lists that routing-errors.sh folds
# into one table. Every build is fresh, so no stale .rpt needs dropping.)
# ---- the SUBSET consumers: after the subset set is complete ----------------
if ! wait "$SUBSETS_PID"; then
    echo "ERROR: bin/server/subsets.sh failed — aborting." >&2
    pool_wait || true
    exit 1
fi
# (2026-09-30, the lean round: topview, errors-day, event-queue,
# site-failures, pesit, no-remote-dir and no-remote-files read the whole
# cache until then — now the COUNTS table or an exact subset)
pool_run "$SCRIPT_DIR/reports/topview.sh"
pool_run "$SCRIPT_DIR/reports/errors-day.sh"
pool_run "$SCRIPT_DIR/reports/event-queue.sh"        # "[Pesit Default] Unable to submit event AgentEvent" -> the dashboards' 30-min sidecar (2026-09-14); an unpublished intermediate since 2026-09-27
pool_run "$SCRIPT_DIR/reports/site-failures.sh"
pool_run "$SCRIPT_DIR/reports/pesit.sh"              # -> pesit-slots.tsv only (the dashboards' / day pages' PeSIT view; no page since 2026-09-27, no .rpt since 2026-09-29)
pool_run "$SCRIPT_DIR/reports/no-remote-dir.sh"
pool_run "$SCRIPT_DIR/reports/no-remote-files.sh"
pool_run "$SCRIPT_DIR/reports/error-timing.sh"
pool_run "$SCRIPT_DIR/reports/error-reasons.sh"
pool_run "$SCRIPT_DIR/reports/failure-flows.sh"
pool_run "$SCRIPT_DIR/reports/io-errors.sh"          # "IO Error reading file /data/FlowManager/…" — the srv-errors group's third member (2026-09-06)
pool_run "$SCRIPT_DIR/reports/routing-errors.sh"     # "Advanced Routing errors" — the AR0074 / ARPA0001 / ARRC0009 lines in one table (2026-09-28: was could-not-send, publish-failed, post-client-action)
pool_run "$SCRIPT_DIR/reports/connection-diagnostics.sh"
pool_run "$SCRIPT_DIR/../analyses/reports/uc1-status.sh"
pool_run "$SCRIPT_DIR/reports/deploy-errors.sh"
pool_run "$SCRIPT_DIR/reports/remote-poll.sh"
pool_run "$SCRIPT_DIR/../analyses/reports/uc3-status.sh"
pool_run "$SCRIPT_DIR/reports/ssh-sessions.sh"
pool_run "$SCRIPT_DIR/reports/top-messages.sh"
pool_wait
# The MERGED reports (2026-07 catalog cleanup) concatenate the pool's .rpt
# files, so they run after it: cheap single-awk merges, no log reading.
# The levels per component (errors-day.rpt) ride the Top view page since
# 2026-09-29 — its totals ARE the Top view column totals, only the level x
# component split was new; errors-day stays an unpublished intermediate.
# READERS OF topview.rpt MUST TAKE THE DATE-SHAPED ROWS ONLY: the appended
# table's rows are TM / PESITD / SSHD (dashboards/lib.sh, day/reports.sh,
# overview.sh, area_dates … all filter on a yyyy-mm-dd Date cell).
append_rpt_tables "$REPORTS_DIR/topview.rpt" "$REPORTS_DIR/errors-day.rpt"
"$SCRIPT_DIR/reports/errors.sh"
"$SCRIPT_DIR/reports/missing-entities.sh"   # the five unknown-* tables as one tabbed page (retired and brought back 2026-09-29, user request)
"$SCRIPT_DIR/reports/connections.sh"
"$SCRIPT_DIR/reports/logons.sh"
# (the "Operations & Capacity" group — Platform health, Capacity & sessions,
# EventQueue — was removed 2026-09-27, user request: its merges and the
# cluster-health / stuck-events / scheduler-overruns / file-cleanup
# components went; pesit.sh and event-queue.sh stay for the graph sidecars.)
# SSH security rides the transfer SECURITY PARAMETERS page since 2026-09-30
# (user request: "Merge /transfer/security-params.html and
# /server/ssh-security.html into 1 report"): the ssh-crypto + ssh-sessions
# tables are appended to security-params.rpt (written by transfer phase 1,
# final here) after its SUMMARY line; the SSH security merge and its page went.
# A hand-run security-params.sh drops them until these server reports run again.
append_rpt_tables -f "$TRANSFER_REPORTS/security-params.rpt" "$REPORTS_DIR/ssh-crypto.rpt" "$REPORTS_DIR/ssh-sessions.rpt"
"$SCRIPT_DIR/../analyses/reports/uc3-polling.sh"   # the UC3 tab's polling tables: reads remote-poll.rpt + its sidecars — after the pool, before the uc-status merge (2026-09-05)
"$SCRIPT_DIR/../analyses/reports/polling.sh"   # the flat Polling page (Analyses / Configuration): remote-poll.rpt + sidecars + the cron schedules in ONE table (2026-09-05)
"$SCRIPT_DIR/../analyses/reports/uc2-visits.sh"   # formats uc2-status.sh's pickup sidecar — after the pool, before the uc-status merge (its table rides the UC2 tab, 2026-09-29)
"$SCRIPT_DIR/reports/pickups.sh"   # the same sidecar — likewise on the UC2 tab
"$SCRIPT_DIR/../analyses/reports/uc-status.sh"
