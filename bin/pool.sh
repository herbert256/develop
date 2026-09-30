# bin/pool.sh — SOURCED. The one job pool (2026-09-30, the lean round: the
# transfer / server report runners and the server parse carried three copies).
# The caller sets NJOBS (the pool size) before the first pool_run, and
# optionally POOL_TIMED=1 (wrap each job in bin/timing.sh `timed` — the report
# runners' TIME lines) and POOL_WHAT (the failure message's noun).
POOL_PIDS=()
pool_run() {   # run "$@" as a background job, at most NJOBS at once
    while [ "$(jobs -rp | wc -l | tr -d ' ')" -ge "$NJOBS" ]; do sleep 0.1; done
    if [ -n "${POOL_TIMED:-}" ]; then timed "$@" & else "$@" & fi
    POOL_PIDS+=("$!")
}
pool_wait() {  # reap every pooled job; abort the run if any failed
    local p st rc=0
    [ "${#POOL_PIDS[@]}" -eq 0 ] && return 0
    for p in "${POOL_PIDS[@]}"; do
        st=0
        wait "$p" || st=$?
        [ "$st" -ne 0 ] && rc=$st
    done
    POOL_PIDS=()
    if [ "$rc" -ne 0 ]; then
        echo "ERROR: ${POOL_WHAT:-a pooled job} failed (exit $rc) — aborting." >&2
        exit "$rc"
    fi
    return 0
}
